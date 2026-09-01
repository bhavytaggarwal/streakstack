//
//  GeminiJSONService.swift
//  PrepPulse
//
//  URLSession-only Gemini client — no SDK, no third-party dependencies.
//
//  Everything the app asks for comes back as constrained JSON:
//  `responseMimeType: "application/json"` plus an explicit `responseSchema`,
//  so we decode straight into Codable structs instead of parsing prose.
//
//  Cost control lives here too: a stable system-instruction prefix (cache
//  friendly), optional explicit context caching, a sliding window over recent
//  turns, capped output, and zero thinking tokens.
//

import Foundation

// MARK: - Key resolution

nonisolated enum AppSecrets {
    static let userDefaultsKey = "gemini.apiKey"

    /// Resolution order: key entered in-app → Info.plist → environment.
    /// `UserDefaults` is fine for a personal practice app; for anything shipping
    /// to the App Store, move this to the Keychain or proxy through your backend
    /// so the key never lives on the device at all.
    static func geminiAPIKey() -> String {
        if let stored = UserDefaults.standard.string(forKey: userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String {
            let value = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.hasPrefix("$(") { return value } // unexpanded build setting
        }
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        return ""
    }
}

// MARK: - Errors

nonisolated enum GeminiError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL
    case http(status: Int, message: String)
    case blocked(reason: String)
    case emptyResponse
    case malformedJSON(String)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Gemini API key in Settings to start practising."
        case .invalidURL:
            return "The Gemini endpoint could not be built."
        case .http(let status, let message) where status == 400:
            return "Gemini rejected the request (400). \(message)"
        case .http(let status, _) where status == 401 || status == 403:
            return "That API key was refused. Check it in Settings."
        case .http(let status, _) where status == 429:
            return "Rate limited by Gemini. Give it a few seconds and try again."
        case .http(let status, let message):
            return "Gemini returned \(status). \(message)"
        case .blocked(let reason):
            return "The response was blocked (\(reason)). Try rephrasing."
        case .emptyResponse:
            return "Gemini returned an empty response."
        case .malformedJSON(let detail):
            return "Couldn't read Gemini's JSON. \(detail)"
        case .transport(let detail):
            return "Network problem: \(detail)"
        case .cancelled:
            return "Request cancelled."
        }
    }
}

// MARK: - Engine contract (lets the view models run against a mock in previews)

nonisolated protocol GeminiEngine: Sendable {
    /// Whether this engine needs a user-supplied key before it can be called.
    /// Lets the UI gate on the real service without blocking injected doubles.
    var requiresAPIKey: Bool { get }
    func generateMCQSet() async throws -> [MCQQuestion]
    func openingQuestion() async throws -> String
    func evaluate(recent: [Message]) async throws -> DescriptiveEvaluation
    /// Folds turns that fell out of the sliding window into rolling notes.
    func compact(_ messages: [Message]) async throws
    func resetSession() async
    func lastUsage() async -> TokenUsage?
}

// MARK: - Prompts
//
// The interviewer persona is a byte-stable prefix. Gemini's implicit caching
// keys on the leading tokens of a request, so keeping this text identical
// across calls is what makes cache hits possible at all.

nonisolated enum Prompts {

    static let interviewerPersona = """
    You are a senior AI engineer at Micro1 running a rigorous technical screen for an \
    AI Engineer role. You are direct, warm but demanding, and you never pad your speech.

    HOW YOU RUN THE INTERVIEW
    - Ask exactly ONE question at a time. Never stack multiple questions.
    - Grade the candidate's most recent answer out of 5, where 1 is hand-waving with no \
      specifics, 3 is a correct but shallow textbook answer, and 5 is a precise answer \
      with real trade-offs, numbers, or production scars.
    - Feedback is at most two sentences: name what was strong, then what was missing.
    - The next question must dig into the weakest part of the answer they just gave, not \
      a fixed script. Escalate when they are strong; drop to fundamentals when they are weak.
    - Push on trade-offs constantly: latency vs quality, cost vs accuracy, build vs buy, \
      managed vs self-hosted, and when NOT to reach for the fancy option.

    TOPIC SURFACE
    LLM system architecture and serving; RAG (chunking, embeddings, hybrid retrieval, \
    re-ranking, chunk-level evals, freshness); agentic workflows (tool schemas, planning, \
    loops, retries, failure modes, human handoff); MCP and tool/server pipelines; \
    fine-tuning vs prompting vs distillation; evaluation and guardrails; inference cost, \
    caching, batching and latency budgets.

    STYLE
    Plain conversational prose. No markdown, no bullet lists, no emoji. Never answer your \
    own question for the candidate. If an answer is vague, say so plainly and demand a specific.
    """

    static let examinerPersona = """
    You write objective screening questions for AI Engineer candidates.

    RULES
    - Exactly five multiple-choice questions, four options each, exactly one correct.
    - Spread them across LLM internals, RAG, agents, MCP / tool pipelines, evaluation, \
      and inference cost or latency. Never two questions on the same narrow point.
    - Target a working practitioner: the kind of thing you'd only know from building, not \
      from a blog post summary. Avoid trivia about version numbers or vendor branding.
    - Distractors must be genuinely plausible to someone who half-knows the topic.
    - Keep the stem to one sentence and each option under twelve words.
    - The explanation says why the right answer is right in under 40 words.
    """

    /// Computed, not stored: a `static let` would freeze the seed for the whole
    /// process, so every "New set" in a session shipped an identical prompt.
    static var mcqRequest: String {
        """
        Generate a fresh set of five questions now. Vary the topics and the position of the \
        correct answer across the set. Seed for variety: \(UUID().uuidString.prefix(8)).
        """
    }

    static let openingRequest = """
    Open the interview with your first question. Make it broad enough that a strong \
    candidate can show depth immediately — architecture or a shipped system, not trivia.
    """

    static let evaluationRequest = """
    Grade the candidate's most recent answer above, then ask your follow-up.
    """

    static func summarizer(previous: String?, transcript: String) -> String {
        """
        You are compressing an ongoing technical interview so it can be carried forward cheaply.

        Existing notes:
        \(previous?.isEmpty == false ? previous! : "(none yet)")

        New transcript to fold in:
        \(transcript)

        Rewrite the notes as one third-person block of at most 120 words covering: topics \
        already asked, demonstrated strengths, concrete gaps, and the current difficulty \
        level. Output only the notes.
        """
    }
}

// MARK: - Service

actor GeminiJSONService: GeminiEngine {

    struct Configuration: Sendable {
        var model = "gemini-2.5-flash"
        var baseURL = "https://generativelanguage.googleapis.com/v1beta"

        // --- Token / cost budget ---
        /// Verbatim turns kept in the prompt (a turn = one answer + one reply).
        /// Everything older is represented by the rolling summary.
        var windowTurns = 5
        /// Slack so summarisation runs every few turns, not every single one.
        var windowSlackTurns = 2
        var maxOutputTokens = 400
        var mcqMaxOutputTokens = 1600
        var summaryMaxOutputTokens = 200
        /// `0` disables Gemini 2.5 reasoning tokens — the single biggest saving
        /// for short structured replies. Set `nil` to let the model think.
        var thinkingBudget: Int? = 0
        var temperature = 0.75
        var mcqTemperature = 1.0
        var topP = 0.95

        // --- Explicit context caching ---
        //
        // Implicit caching is automatic and needs nothing beyond a stable prompt
        // prefix; it applies whether or not the flag below is set.
        //
        // Explicit caching (`cachedContents`) uploads that stable prefix once and
        // bills later references to it at a discount instead of re-sending it.
        // The cached payload must exceed the model's minimum — 1,024 tokens for
        // gemini-2.5-flash — which `TrainingCorpus` clears at roughly 4.3k.
        //
        // One cache per role: interview and MCQ share the corpus but not the
        // persona, so a single entry cannot serve both. Both are created lazily
        // on first use, refreshed on expiry, and any failure degrades to the
        // uncached path rather than failing the call.
        //
        // Cost note: a cache is billed for storage per token-hour while it lives,
        // so the TTL is a real dial — long enough to be reused across a session,
        // short enough not to pay for idle time.
        var useExplicitCaching = true
        var cacheTTLSeconds = 1800

        // --- Correction ledger ---
        /// How many flagged evaluations get replayed to the model as calibration.
        /// Each one costs prompt tokens on every call, so keep it small.
        var ledgerLimit = 5

        // --- Networking ---
        var requestTimeout: TimeInterval = 60
        var maxRetries = 2

        var apiKey: @Sendable () -> String = { AppSecrets.geminiAPIKey() }

        /// Hard ceiling on messages placed in `contents`.
        var maxWindowMessages: Int { (windowTurns + windowSlackTurns) * 2 }
        /// The view model summarises once the tail passes this…
        var compactionThreshold: Int { maxWindowMessages }
        /// …and trims it back to this.
        var compactionTarget: Int { windowTurns * 2 }
    }

    private let configuration: Configuration
    private let session: URLSession
    /// Supplies the `<CorrectionLedger>` block. Optional so the service still
    /// runs standalone (previews, tests, MCQ-only flows).
    private let ledger: CorrectionLedgerProviding?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Rolling notes for turns that have fallen out of the sliding window.
    private var runningSummary: String?
    /// One live `cachedContents` entry per prompt role.
    private var caches: [PromptRole: CachedPrefix] = [:]
    private var recentUsage: TokenUsage?

    init(configuration: Configuration = .init(),
         ledger: CorrectionLedgerProviding? = nil,
         session: URLSession? = nil) {
        self.configuration = configuration
        self.ledger = ledger
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = configuration.requestTimeout
            config.timeoutIntervalForResource = configuration.requestTimeout * 2
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    nonisolated var settings: Configuration { configuration }
    nonisolated var requiresAPIKey: Bool { true }

    func lastUsage() async -> TokenUsage? { recentUsage }
    func currentSummary() -> String? { runningSummary }

    // MARK: - Mode A: objective MCQ

    func generateMCQSet() async throws -> [MCQQuestion] {
        let ask = Prompts.mcqRequest
        let set: MCQSet = try await generateJSON(role: .mcq) { prompt in
            GeminiRequest(
                contents: Self.applying(
                    preface: prompt.preface,
                    to: [.init(role: Role.user.rawValue, parts: [.init(text: ask)])]
                ),
                systemInstruction: prompt.systemInstruction,
                generationConfig: .init(
                    temperature: configuration.mcqTemperature,
                    topP: configuration.topP,
                    maxOutputTokens: configuration.mcqMaxOutputTokens,
                    responseMimeType: "application/json",
                    responseSchema: ResponseSchemas.mcqSet,
                    thinkingConfig: configuration.thinkingBudget.map(ThinkingConfig.init)
                ),
                cachedContent: prompt.cachedContent
            )
        }
        // The schema pins the count, but never trust a model with your array bounds.
        let cleaned = set.questions
            .filter { $0.options.count >= 2 && !$0.question.isEmpty }
            .prefix(5)
        guard !cleaned.isEmpty else {
            throw GeminiError.malformedJSON("No usable questions came back.")
        }
        return Array(cleaned)
    }

    // MARK: - Mode B: descriptive interview

    func openingQuestion() async throws -> String {
        let opening: OpeningQuestion = try await generateJSON(role: .interview) { prompt in
            GeminiRequest(
                contents: Self.applying(
                    preface: prompt.preface,
                    to: [.init(role: Role.user.rawValue,
                               parts: [.init(text: Prompts.openingRequest)])]
                ),
                systemInstruction: prompt.systemInstruction,
                generationConfig: .init(
                    temperature: configuration.temperature,
                    topP: configuration.topP,
                    maxOutputTokens: 200,
                    responseMimeType: "application/json",
                    responseSchema: ResponseSchemas.openingQuestion,
                    thinkingConfig: configuration.thinkingBudget.map(ThinkingConfig.init)
                ),
                cachedContent: prompt.cachedContent
            )
        }
        let question = opening.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw GeminiError.emptyResponse }
        return question
    }

    /// `recent` is the un-summarised tail of the transcript; the service applies
    /// its own hard cap before sending.
    func evaluate(recent: [Message]) async throws -> DescriptiveEvaluation {
        var contents = Self.contents(
            from: Self.slidingWindow(recent, maxMessages: configuration.maxWindowMessages)
        )
        // Attach the grading instruction to the candidate's own turn rather than
        // appending a second consecutive user content, which some models reject.
        if let last = contents.indices.last, contents[last].role == Role.user.rawValue {
            contents[last].parts.append(.init(text: Prompts.evaluationRequest))
        } else {
            contents.append(.init(role: Role.user.rawValue,
                                  parts: [.init(text: Prompts.evaluationRequest)]))
        }

        let window = contents
        var evaluation: DescriptiveEvaluation = try await generateJSON(role: .interview) { prompt in
            GeminiRequest(
                contents: Self.applying(preface: prompt.preface, to: window),
                systemInstruction: prompt.systemInstruction,
                generationConfig: .init(
                    temperature: configuration.temperature,
                    topP: configuration.topP,
                    maxOutputTokens: configuration.maxOutputTokens,
                    responseMimeType: "application/json",
                    responseSchema: ResponseSchemas.descriptiveEvaluation,
                    thinkingConfig: configuration.thinkingBudget.map(ThinkingConfig.init)
                ),
                cachedContent: prompt.cachedContent
            )
        }
        evaluation.scoreOutOfFive = evaluation.clampedScore
        guard !evaluation.nextQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.malformedJSON("The reply had no follow-up question.")
        }
        return evaluation
    }

    /// Folds turns that fell out of the window into short notes carried in the
    /// system instruction. Cheap, and it keeps prompt size flat.
    func compact(_ messages: [Message]) async throws {
        guard !messages.isEmpty else { return }
        let transcript = messages
            .map { "\($0.isUser ? "Candidate" : "Interviewer"): \($0.text)" }
            .joined(separator: "\n")

        let request = GeminiRequest(
            contents: [.init(role: Role.user.rawValue, parts: [.init(
                text: Prompts.summarizer(previous: runningSummary, transcript: transcript)
            )])],
            systemInstruction: nil,
            generationConfig: .init(
                temperature: 0.2,
                topP: 0.9,
                maxOutputTokens: configuration.summaryMaxOutputTokens,
                responseMimeType: nil,
                responseSchema: nil,
                thinkingConfig: configuration.thinkingBudget.map(ThinkingConfig.init)
            ),
            cachedContent: nil
        )

        let response = try await perform(path: "models/\(configuration.model):generateContent",
                                         body: request,
                                         as: GeminiResponse.self)
        if let notes = response.firstText, !notes.isEmpty {
            runningSummary = notes
        }
    }

    func resetSession() {
        runningSummary = nil
        recentUsage = nil
    }

    // MARK: - Sliding window

    /// The whole trick: prompt size stops growing with conversation length, so
    /// a 40-turn interview costs about the same per call as a 5-turn one.
    nonisolated static func slidingWindow(_ messages: [Message], maxMessages: Int) -> [Message] {
        guard messages.count > maxMessages else { return messages }
        return Array(messages.suffix(maxMessages))
    }

    /// Gemini requires `contents` to open on a user turn, so if the window
    /// starts mid-exchange we prepend a stub rather than drop the question.
    nonisolated static func contents(from messages: [Message]) -> [GeminiContent] {
        var mapped = messages.map {
            GeminiContent(role: $0.role.rawValue, parts: [GeminiPart(text: $0.text)])
        }
        if mapped.first?.role == Role.model.rawValue {
            mapped.insert(.init(role: Role.user.rawValue,
                                parts: [.init(text: "(continuing the interview)")]), at: 0)
        }
        return mapped
    }

    // MARK: - Prompt assembly

    /// Which stable prefix a call needs. Each role gets its own cache entry —
    /// they share the corpus but not the persona, so one cache cannot serve both.
    private enum PromptRole: Hashable, Sendable {
        case interview
        case mcq
    }

    /// The byte-stable half of the system instruction: corpus first, then persona.
    /// This is exactly what goes into an explicit cache.
    private func cacheablePrefix(for role: PromptRole) -> String {
        switch role {
        case .interview: return TrainingCorpus.all + "\n\n" + Prompts.interviewerPersona
        case .mcq:       return TrainingCorpus.all + "\n\n" + Prompts.examinerPersona
        }
    }

    /// The half that changes between calls, so it can never live in a cache:
    /// the correction ledgers and the running session notes.
    private func volatileContext(for role: PromptRole) async -> String? {
        switch role {
        case .mcq:
            return await ledger?.mcqLedgerText(limit: configuration.ledgerLimit)

        case .interview:
            var parts: [String] = []
            if let ledgerText = await ledger?.ledgerText(limit: configuration.ledgerLimit) {
                parts.append(ledgerText)
            }
            if let summary = runningSummary, !summary.isEmpty {
                parts.append("""
                NOTES FROM EARLIER IN THIS INTERVIEW (already compressed — do not repeat \
                questions you have already asked):
                \(summary)
                """)
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
    }

    /// How one call should carry its instructions.
    ///
    /// Cached and uncached are semantically identical — the same text reaches the
    /// model either way. What changes is *where* it rides: a request that names a
    /// `cachedContent` must NOT also set `systemInstruction` (the API rejects it),
    /// so the volatile half moves into `contents` as a leading user turn instead.
    private struct PreparedPrompt {
        var systemInstruction: GeminiContent?
        var cachedContent: String?
        /// Volatile text to prepend to `contents`, used only on the cached path.
        var preface: GeminiContent?
    }

    private func preparePrompt(for role: PromptRole, allowCache: Bool = true) async -> PreparedPrompt {
        let volatileText = await volatileContext(for: role)

        if allowCache, let name = await cacheName(for: role) {
            return PreparedPrompt(
                systemInstruction: nil,
                cachedContent: name,
                preface: volatileText.map {
                    GeminiContent(role: Role.user.rawValue, parts: [.init(text: $0)])
                }
            )
        }

        var instruction = cacheablePrefix(for: role)
        if let volatileText { instruction += "\n\n" + volatileText }
        return PreparedPrompt(
            systemInstruction: .init(role: nil, parts: [.init(text: instruction)]),
            cachedContent: nil,
            preface: nil
        )
    }

    /// Merges the volatile preface into the first user turn rather than adding a
    /// second consecutive user content, which some models reject.
    private static func applying(preface: GeminiContent?,
                                 to contents: [GeminiContent]) -> [GeminiContent] {
        guard let preface else { return contents }
        var result = contents
        if let first = result.first, first.role == Role.user.rawValue {
            result[0].parts.insert(contentsOf: preface.parts, at: 0)
        } else {
            result.insert(preface, at: 0)
        }
        return result
    }

    // MARK: - Explicit context caching

    private struct CachedPrefix: Sendable {
        let name: String
        let expiresAt: Date
    }

    /// Returns a live `cachedContents/…` name for this role, creating one on first
    /// use and after expiry. Degrades to `nil` on any failure — a cache miss must
    /// never break an interview, it just costs full price.
    private func cacheName(for role: PromptRole) async -> String? {
        guard configuration.useExplicitCaching else { return nil }

        // Refresh a little early so a call can't land on an expiring cache.
        if let entry = caches[role], entry.expiresAt > Date().addingTimeInterval(30) {
            return entry.name
        }

        let body = CachedContentRequest(
            model: "models/\(configuration.model)",
            systemInstruction: .init(role: nil, parts: [.init(text: cacheablePrefix(for: role))]),
            contents: nil,
            ttl: "\(configuration.cacheTTLSeconds)s",
            displayName: role == .interview
                ? "PrepPulse interviewer prefix"
                : "PrepPulse examiner prefix"
        )

        do {
            let created = try await perform(path: "cachedContents",
                                            body: body,
                                            as: CachedContentResponse.self)
            caches[role] = CachedPrefix(
                name: created.name,
                expiresAt: Date().addingTimeInterval(TimeInterval(configuration.cacheTTLSeconds))
            )
            #if DEBUG
            print("[PrepPulse] Cached \(role) prefix as \(created.name) " +
                  "(≈\(TokenEstimator.estimate(cacheablePrefix(for: role))) tokens).")
            #endif
            return created.name
        } catch {
            #if DEBUG
            print("[PrepPulse] Explicit cache unavailable, continuing without it: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func invalidateCache(for role: PromptRole) {
        caches[role] = nil
    }

    /// A cache that expired or was deleted server-side comes back as a 4xx naming
    /// the resource. Treat any 4xx on a cached call as "retry without the cache".
    private static func looksLikeCacheFailure(_ error: GeminiError) -> Bool {
        guard case .http(let status, _) = error else { return false }
        return status == 400 || status == 403 || status == 404
    }

    #if DEBUG
    /// The exact system instructions that go out with each mode's call, as
    /// assembled on the uncached path. Useful for eyeballing prompt composition.
    func debugSystemInstructions() async -> (interview: String, mcq: String) {
        let interview = await preparePrompt(for: .interview, allowCache: false)
        let mcq = await preparePrompt(for: .mcq, allowCache: false)
        return (interview.systemInstruction?.parts.first?.text ?? "",
                mcq.systemInstruction?.parts.first?.text ?? "")
    }
    #endif


    // MARK: - Networking

    /// Builds the request for `role`, sends it, and — if the call fails in a way
    /// that looks like a dead cache — drops the cache and retries once inline.
    /// The retry sends identical instructions, just not via `cachedContent`.
    private func generateJSON<T: Decodable>(
        role: PromptRole,
        build: (PreparedPrompt) -> GeminiRequest
    ) async throws -> T {
        let prompt = await preparePrompt(for: role)
        do {
            return try await execute(build(prompt))
        } catch let error as GeminiError {
            guard prompt.cachedContent != nil, Self.looksLikeCacheFailure(error) else { throw error }
            #if DEBUG
            print("[PrepPulse] Cached prefix rejected (\(error.localizedDescription)); retrying uncached.")
            #endif
            invalidateCache(for: role)
            let fallback = await preparePrompt(for: role, allowCache: false)
            return try await execute(build(fallback))
        }
    }

    private func execute<T: Decodable>(_ request: GeminiRequest) async throws -> T {
        let response = try await perform(path: "models/\(configuration.model):generateContent",
                                         body: request,
                                         as: GeminiResponse.self)
        recentUsage = response.usageMetadata

        if let blocked = response.promptFeedback?.blockReason {
            throw GeminiError.blocked(reason: blocked)
        }
        guard let text = response.firstText, !text.isEmpty else {
            if response.finishReason == "MAX_TOKENS" {
                throw GeminiError.malformedJSON("The reply was cut off before the JSON closed.")
            }
            throw GeminiError.emptyResponse
        }
        return try Self.decodeJSON(T.self, from: text)
    }

    /// `responseMimeType` makes fenced output rare, not impossible — so we strip
    /// fences and fall back to the outermost brace pair before decoding.
    nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            payload = payload
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let open = payload.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let close = payload.lastIndex(where: { $0 == "}" || $0 == "]" }),
           open < close {
            payload = String(payload[open...close])
        }
        guard let data = payload.data(using: .utf8) else {
            throw GeminiError.malformedJSON("The reply wasn't valid UTF-8.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GeminiError.malformedJSON(String(describing: error))
        }
    }

    private func perform<Body: Encodable, Result: Decodable>(
        path: String,
        body: Body,
        as: Result.Type
    ) async throws -> Result {
        let key = configuration.apiKey()
        guard !key.isEmpty else { throw GeminiError.missingAPIKey }

        guard var components = URLComponents(string: "\(configuration.baseURL)/\(path)") else {
            throw GeminiError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { throw GeminiError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw GeminiError.transport("Could not encode request: \(error.localizedDescription)")
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw GeminiError.transport("Malformed response")
                }

                if (200..<300).contains(http.statusCode) {
                    do {
                        return try decoder.decode(Result.self, from: data)
                    } catch {
                        throw GeminiError.malformedJSON("Unreadable response envelope.")
                    }
                }

                if Self.isRetryable(http.statusCode), attempt < configuration.maxRetries {
                    // Retryable — fall through to the backoff below.
                } else {
                    throw GeminiError.http(status: http.statusCode,
                                           message: Self.errorMessage(from: data))
                }
            } catch let error as GeminiError {
                throw error
            } catch is CancellationError {
                throw GeminiError.cancelled
            } catch let error as URLError {
                if error.code == .cancelled { throw GeminiError.cancelled }
                guard attempt < configuration.maxRetries else {
                    throw GeminiError.transport(error.localizedDescription)
                }
            } catch {
                throw GeminiError.transport(error.localizedDescription)
            }

            attempt += 1
            do {
                try await Task.sleep(nanoseconds: Self.backoffNanoseconds(attempt: attempt))
            } catch {
                throw GeminiError.cancelled
            }
        }
    }

    nonisolated private static func isRetryable(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    /// 0.6s, 1.2s, 2.4s… plus jitter so parallel clients don't sync up.
    nonisolated private static func backoffNanoseconds(attempt: Int) -> UInt64 {
        let base = 0.6 * pow(2, Double(attempt - 1))
        return UInt64((base + Double.random(in: 0...0.25)) * 1_000_000_000)
    }

    nonisolated private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data),
           let message = envelope.error.message, !message.isEmpty {
            return message
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }
}
