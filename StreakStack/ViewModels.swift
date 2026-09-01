//
//  ViewModels.swift
//  PrepPulse
//
//  Observable state for both modes, plus the two @AppStorage-backed stores
//  (streaks and the "did the AI grade me fairly?" meta ratings).
//

import Combine
import Foundation
import SwiftData
import SwiftUI

// MARK: - Streak storage

/// `@AppStorage` gives free `UserDefaults` persistence with the right
/// semantics. Because the wrappers sit on a class rather than a `View`, the
/// mutating paths publish by hand so SwiftUI still refreshes.
@MainActor
final class StreakStore: ObservableObject {

    enum Keys {
        static let current = "streak.current"
        static let longest = "streak.longest"
        static let lastDay = "streak.lastPracticedDay"
        static let totalDays = "streak.totalDaysPracticed"
        static let recentDays = "streak.recentDays"
    }

    @AppStorage(Keys.current) private var storedCurrent = 0
    @AppStorage(Keys.longest) private var storedLongest = 0
    @AppStorage(Keys.lastDay) private var storedLastDay = ""
    @AppStorage(Keys.totalDays) private var storedTotalDays = 0
    /// Comma-separated `yyyy-MM-dd` keys, newest last, capped at 14 — enough
    /// to draw the week strip.
    @AppStorage(Keys.recentDays) private var storedRecentDays = ""

    @Published private(set) var pulse = 0
    @Published private(set) var lastOutcome: StreakOutcome?

    private let engine = StreakEngine()

    var streak: Streak {
        Streak(current: storedCurrent,
               longest: storedLongest,
               lastPracticedDay: storedLastDay.isEmpty ? nil : DayKey.date(from: storedLastDay),
               totalDaysPracticed: storedTotalDays)
    }

    /// Reads zero once the grace day has passed, without touching storage.
    func displayedStreak(asOf date: Date = .now) -> Int {
        engine.displayedStreak(for: streak, asOf: date)
    }

    func hasPracticedToday(asOf date: Date = .now) -> Bool {
        engine.hasPracticedToday(streak, asOf: date)
    }

    var longest: Int { storedLongest }
    var totalDaysPracticed: Int { storedTotalDays }

    /// Run is alive but today is unlogged — the moment to nudge.
    func isAtRisk(asOf date: Date = .now) -> Bool {
        displayedStreak(asOf: date) > 0 && !hasPracticedToday(asOf: date)
    }

    /// Trailing seven days, oldest first, flagged with whether they were practised.
    func weekStrip(asOf date: Date = .now) -> [(date: Date, practiced: Bool)] {
        let today = engine.calendar.startOfDay(for: date)
        let logged = Set(storedRecentDays.split(separator: ",").map(String.init))
        return (0..<7).reversed().compactMap { offset in
            guard let day = engine.calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return (day, logged.contains(DayKey.string(from: day)))
        }
    }

    @discardableResult
    func recordPracticeToday(now: Date = .now) -> StreakOutcome {
        let (updated, outcome) = engine.apply(streak, practicedOn: now)
        lastOutcome = outcome
        guard outcome != .alreadyCountedToday else { return outcome }

        objectWillChange.send()
        storedCurrent = updated.current
        storedLongest = updated.longest
        storedTotalDays = updated.totalDaysPracticed
        if let day = updated.lastPracticedDay {
            storedLastDay = DayKey.string(from: day)
            appendRecentDay(day)
        }
        pulse += 1
        return outcome
    }

    func reset() {
        objectWillChange.send()
        storedCurrent = 0
        storedLongest = 0
        storedLastDay = ""
        storedTotalDays = 0
        storedRecentDays = ""
    }

    private func appendRecentDay(_ day: Date) {
        let key = DayKey.string(from: day)
        var days = storedRecentDays.split(separator: ",").map(String.init)
        guard !days.contains(key) else { return }
        days.append(key)
        if days.count > 14 { days.removeFirst(days.count - 14) }
        storedRecentDays = days.joined(separator: ",")
    }
}

// MARK: - Meta ratings (SwiftData)

/// Stores "was this evaluation any good?" as a `FeedbackLog` per interviewer
/// turn. The UI reads from an in-memory mirror so a thumb tap is instant; the
/// `ModelContext` is the source of truth and what the correction ledger reads.
@MainActor
final class FeedbackLogStore: ObservableObject {

    private let context: ModelContext
    /// Mirrors only `.evaluation` logs — the thumbs the user actually tapped.
    /// Seeded rules live in the same store but are counted separately.
    @Published private(set) var ratings: [UUID: MetaRating] = [:]
    @Published private(set) var ruleCount = 0
    /// `MCQQuestion.id` → the correction the user wrote, for cards that were
    /// already flagged this session.
    @Published private(set) var mcqCorrections: [UUID: String] = [:]

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    func rating(for turnID: UUID) -> MetaRating? { ratings[turnID] }

    /// Tapping the active thumb clears it, so a mis-tap is undoable.
    func toggle(_ rating: MetaRating, draft: FeedbackDraft) {
        if let existing = log(for: draft.turnID) {
            if existing.rating == rating {
                context.delete(existing)
                ratings.removeValue(forKey: draft.turnID)
            } else {
                existing.rating = rating
                existing.createdAt = .now
                existing.isResolved = false
                ratings[draft.turnID] = rating
            }
        } else {
            context.insert(FeedbackLog(turnID: draft.turnID,
                                       rating: rating,
                                       mode: draft.mode,
                                       question: draft.question,
                                       candidateAnswer: draft.candidateAnswer,
                                       aiFeedback: draft.aiFeedback,
                                       score: draft.score))
            ratings[draft.turnID] = rating
        }
        save()
    }

    var ratedCount: Int { ratings.count }
    var badCount: Int { ratings.values.filter { $0 == .bad }.count }

    // MARK: MCQ corrections

    func hasMCQCorrection(for questionID: UUID) -> Bool {
        mcqCorrections[questionID] != nil
    }

    func mcqCorrection(for questionID: UUID) -> String {
        mcqCorrections[questionID] ?? ""
    }

    /// Writes (or rewrites) the correction for one flagged question.
    func logMCQCorrection(questionID: UUID,
                          question: String,
                          aiResponse: String,
                          userCorrection: String) {
        let text = userCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let existing = log(for: questionID) {
            existing.note = text
            existing.aiFeedback = aiResponse
            existing.createdAt = .now
            existing.isResolved = false
        } else {
            context.insert(FeedbackLog.mcqCorrection(questionID: questionID,
                                                     question: question,
                                                     aiResponse: aiResponse,
                                                     userCorrection: text))
        }
        mcqCorrections[questionID] = text
        save()
    }

    var agreementRate: Double? {
        guard ratedCount > 0 else { return nil }
        return Double(ratings.values.filter { $0 == .good }.count) / Double(ratedCount)
    }

    /// Clears the user's own ratings but leaves the foundational rules in place —
    /// wiping guardrails should be a deliberate act in the dashboard, not a
    /// side effect of "clear my ratings".
    func reset() {
        do {
            let evaluation = LogKind.evaluation.rawValue
            try context.delete(model: FeedbackLog.self,
                               where: #Predicate { $0.kindRaw == evaluation })
            ratings = [:]
            mcqCorrections = [:]
            save()
        } catch {
            report(error)
        }
    }

    /// Called after the dashboard mutates logs directly, to resync the mirror.
    func reload() {
        do {
            let logs = try context.fetch(FetchDescriptor<FeedbackLog>())
            ratings = Dictionary(logs.filter { $0.kind == .evaluation && $0.mode == .interview }
                                    .map { ($0.turnID, $0.rating) },
                                 uniquingKeysWith: { first, _ in first })
            ruleCount = logs.filter { $0.kind == .rule }.count
            mcqCorrections = Dictionary(logs.filter { $0.kind == .evaluation && $0.mode == .mcq }
                                           .map { ($0.turnID, $0.note) },
                                        uniquingKeysWith: { first, _ in first })
        } catch {
            report(error)
        }
    }

    private func log(for turnID: UUID) -> FeedbackLog? {
        var descriptor = FetchDescriptor<FeedbackLog>(
            predicate: #Predicate { $0.turnID == turnID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        guard context.hasChanges else { return }
        do { try context.save() } catch { report(error) }
    }

    private func report(_ error: Error) {
        #if DEBUG
        print("[PrepPulse] FeedbackLogStore: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - Shared preferences

@MainActor
final class Preferences: ObservableObject {
    @AppStorage("prefs.voiceEnabled") private var storedVoiceEnabled = false

    /// `@AppStorage` on a class persists but doesn't publish, so the setter
    /// announces the change itself. `$preferences.isVoiceEnabled` still works.
    var isVoiceEnabled: Bool {
        get { storedVoiceEnabled }
        set {
            objectWillChange.send()
            storedVoiceEnabled = newValue
        }
    }

    @Published var needsAPIKey = AppSecrets.geminiAPIKey().isEmpty

    func refreshKeyState() {
        needsAPIKey = AppSecrets.geminiAPIKey().isEmpty
    }
}

// MARK: - Mode A: MCQ

@MainActor
final class MCQViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case playing
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var questions: [MCQQuestion] = []
    @Published private(set) var index = 0
    @Published private(set) var selection: Int?
    @Published private(set) var answers: [MCQAnswer] = []
    @Published var errorMessage: String?

    private let engine: GeminiEngine
    private let streaks: StreakStore
    let logs: FeedbackLogStore
    private var loadTask: Task<Void, Never>?

    init(engine: GeminiEngine? = nil,
         configuration: GeminiJSONService.Configuration = .init(),
         modelContainer: ModelContainer? = nil,
         streaks: StreakStore,
         logs: FeedbackLogStore) {
        // The generator reads its own <MCQCorrectionLedger> from the same store.
        let ledger = modelContainer.map { CorrectionLedgerStore(modelContainer: $0) }
        self.engine = engine ?? GeminiJSONService(configuration: configuration, ledger: ledger)
        self.streaks = streaks
        self.logs = logs
    }

    var current: MCQQuestion? { questions.indices.contains(index) ? questions[index] : nil }
    var isRevealed: Bool { selection != nil }
    var correctCount: Int { answers.filter(\.isCorrect).count }
    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(answers.count) / Double(questions.count)
    }
    var isLastQuestion: Bool { index == questions.count - 1 }

    func loadIfNeeded() {
        guard phase == .idle else { return }
        load()
    }

    func load() {
        loadTask?.cancel()
        phase = .loading
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let questions = try await self.engine.generateMCQSet()
                guard !Task.isCancelled else { return }
                self.questions = questions
                self.index = 0
                self.selection = nil
                self.answers = []
                self.phase = .playing
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .idle
                self.present(error)
            }
        }
    }

    /// Locks in an answer and reveals the explanation. Ignored once revealed so
    /// a stray tap can't overwrite the result.
    func choose(_ optionIndex: Int) {
        guard phase == .playing, selection == nil, let question = current else { return }
        selection = optionIndex
        answers.append(MCQAnswer(question: question, selectedIndex: optionIndex))
        // First answered question of the day counts as practice.
        if answers.count == 1 { streaks.recordPracticeToday() }
    }

    func advance() {
        guard selection != nil else { return }
        if isLastQuestion {
            phase = .finished
        } else {
            index += 1
            selection = nil
        }
    }

    func restart() {
        phase = .idle
        questions = []
        answers = []
        index = 0
        selection = nil
        load()
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: Flagging

    func isFlagged(_ answer: MCQAnswer) -> Bool {
        logs.hasMCQCorrection(for: answer.question.id)
    }

    /// Pre-fills the sheet when re-opening an already-flagged question.
    func existingCorrection(for answer: MCQAnswer) -> String {
        logs.mcqCorrection(for: answer.question.id)
    }

    func submitCorrection(_ text: String, for answer: MCQAnswer) {
        logs.logMCQCorrection(questionID: answer.question.id,
                              question: answer.question.question,
                              aiResponse: answer.question.answerKey,
                              userCorrection: text)
    }

    private func present(_ error: Error) {
        if let gemini = error as? GeminiError {
            guard gemini != .cancelled else { return }
            errorMessage = gemini.errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Mode B: descriptive interview

@MainActor
final class DescriptiveInterviewViewModel: ObservableObject {

    @Published private(set) var entries: [ChatEntry] = []
    @Published var draft = ""
    @Published private(set) var isThinking = false
    @Published private(set) var isCompacting = false
    @Published var errorMessage: String?
    @Published private(set) var usage = SessionUsage()

    let streaks: StreakStore
    let logs: FeedbackLogStore
    let preferences: Preferences
    let speech: SpeechSynthesizerService

    private let engine: GeminiEngine
    /// Summarise once the un-summarised tail passes this many messages…
    private let compactionThreshold: Int
    /// …trimming it back to this. The gap means we pay for a summarisation
    /// every few turns instead of every single one.
    private let compactionTarget: Int

    /// Raw history in Gemini's shape. `messages[0..<summarizedUpTo]` now lives
    /// in the service's rolling summary and is never sent again.
    private var messages: [Message] = []
    private var summarizedUpTo = 0
    private var activeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(engine: GeminiEngine? = nil,
         configuration: GeminiJSONService.Configuration = .init(),
         modelContainer: ModelContainer? = nil,
         streaks: StreakStore,
         logs: FeedbackLogStore,
         preferences: Preferences,
         speech: SpeechSynthesizerService? = nil) {
        // Built in the body, not as default arguments: default argument
        // expressions are evaluated outside the main actor.
        let speech = speech ?? SpeechSynthesizerService()
        // The ledger reads SwiftData on its own actor, off the UI context.
        let ledger = modelContainer.map { CorrectionLedgerStore(modelContainer: $0) }
        self.engine = engine ?? GeminiJSONService(configuration: configuration, ledger: ledger)
        self.compactionThreshold = configuration.compactionThreshold
        self.compactionTarget = configuration.compactionTarget
        self.streaks = streaks
        self.logs = logs
        self.preferences = preferences
        self.speech = speech

        // Re-broadcast the synthesiser's state so the speaker button animates.
        speech.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Derived state

    var hasStarted: Bool { !entries.isEmpty }
    var canSend: Bool {
        !isThinking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var answeredCount: Int { entries.filter { if case .candidate = $0 { return true } else { return false } }.count }

    var scores: [Int] {
        entries.compactMap { entry in
            if case .interviewer(let turn) = entry { return turn.score }
            return nil
        }
    }
    var averageScore: Double? {
        guard !scores.isEmpty else { return nil }
        return Double(scores.reduce(0, +)) / Double(scores.count)
    }
    /// How many messages the next request will carry — the windowing, visible.
    var windowedMessageCount: Int { max(0, messages.count - summarizedUpTo) }

    // MARK: Intents

    /// Only the live service needs a key; an injected engine runs regardless.
    private var isBlockedOnAPIKey: Bool {
        engine.requiresAPIKey && preferences.needsAPIKey
    }

    func startIfNeeded() {
        preferences.refreshKeyState()
        guard entries.isEmpty, !isThinking, !isBlockedOnAPIKey else { return }

        activeTask?.cancel()
        isThinking = true
        errorMessage = nil

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let question = try await self.engine.openingQuestion()
                guard !Task.isCancelled else { return }
                self.append(InterviewerTurn(question: question))
                self.isThinking = false
                await self.recordUsage()
                if self.preferences.isVoiceEnabled { self.speech.speak(question) }
            } catch {
                guard !Task.isCancelled else { return }
                self.isThinking = false
                self.present(error)
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        preferences.refreshKeyState()
        guard !isBlockedOnAPIKey else {
            errorMessage = GeminiError.missingAPIKey.errorDescription
            return
        }

        speech.stop()
        draft = ""
        errorMessage = nil

        let message = Message(role: .user, text: text)
        entries.append(.candidate(message))
        messages.append(message)
        streaks.recordPracticeToday()

        requestEvaluation()
    }

    /// Re-runs the last request after a failure, without duplicating the answer.
    func retry() {
        guard !isThinking else { return }
        errorMessage = nil
        if entries.isEmpty {
            startIfNeeded()
        } else {
            requestEvaluation()
        }
    }

    func stopGenerating() {
        activeTask?.cancel()
        activeTask = nil
        isThinking = false
    }

    func resetSession() {
        stopGenerating()
        speech.stop()
        entries = []
        messages = []
        summarizedUpTo = 0
        draft = ""
        usage = SessionUsage()
        errorMessage = nil
        Task { await engine.resetSession() }
        startIfNeeded()
    }

    func speakLatestQuestion() {
        guard case .interviewer(let turn)? = entries.last(where: {
            if case .interviewer = $0 { return true } else { return false }
        }) else { return }
        speech.toggle(turn.question)
    }

    func rating(for turn: InterviewerTurn) -> MetaRating? {
        logs.rating(for: turn.id)
    }

    /// Writes a `FeedbackLog` carrying the full context of the evaluation —
    /// the question, what the candidate actually said, and how it was graded.
    func rate(_ rating: MetaRating, for turn: InterviewerTurn) {
        logs.toggle(rating, draft: FeedbackDraft(
            turnID: turn.id,
            mode: .interview,
            question: turn.question,
            candidateAnswer: candidateAnswer(precedingTurnWith: turn.id),
            aiFeedback: turn.feedback ?? "",
            score: turn.score ?? 0
        ))
    }

    /// The answer this turn was grading: the last candidate entry before it.
    private func candidateAnswer(precedingTurnWith id: UUID) -> String {
        guard let position = entries.firstIndex(where: { $0.id == id }) else { return "" }
        for entry in entries[..<position].reversed() {
            if case .candidate(let message) = entry { return message.text }
        }
        return ""
    }

    // MARK: Turn execution

    private func requestEvaluation() {
        activeTask?.cancel()
        isThinking = true

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tail = self.unsummarizedTail()
                let evaluation = try await self.engine.evaluate(recent: tail)
                guard !Task.isCancelled else { return }

                self.append(InterviewerTurn(evaluation: evaluation))
                self.isThinking = false
                await self.recordUsage()

                if self.preferences.isVoiceEnabled {
                    self.speech.speak(evaluation.nextQuestion)
                }
                await self.compactIfNeeded()
            } catch {
                guard !Task.isCancelled else { return }
                self.isThinking = false
                self.present(error)
            }
        }
    }

    private func append(_ turn: InterviewerTurn) {
        entries.append(.interviewer(turn))
        // Only the words the interviewer actually said go back into history —
        // the score is UI state and would just cost tokens.
        let spoken = [turn.feedback, turn.question]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        messages.append(Message(role: .model, text: spoken))
    }

    private func unsummarizedTail() -> [Message] {
        guard summarizedUpTo < messages.count else { return [] }
        return Array(messages[summarizedUpTo...])
    }

    /// Failure here is non-fatal: we keep sending a slightly longer tail and
    /// try again after the next turn.
    private func compactIfNeeded() async {
        guard messages.count - summarizedUpTo > compactionThreshold else { return }
        let cutoff = messages.count - compactionTarget
        guard cutoff > summarizedUpTo else { return }

        isCompacting = true
        defer { isCompacting = false }

        do {
            try await engine.compact(Array(messages[summarizedUpTo..<cutoff]))
            summarizedUpTo = cutoff
        } catch {
            #if DEBUG
            print("[PrepPulse] Compaction skipped: \(error.localizedDescription)")
            #endif
        }
    }

    private func recordUsage() async {
        usage.record(await engine.lastUsage(), fullHistory: messages)
    }

    private func present(_ error: Error) {
        if let gemini = error as? GeminiError {
            guard gemini != .cancelled else { return }
            if gemini == .missingAPIKey { preferences.needsAPIKey = true }
            errorMessage = gemini.errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Offline engine for previews and UI work

nonisolated final class MockGeminiEngine: GeminiEngine, @unchecked Sendable {

    private let delay: Duration
    private var turn = 0

    init(delay: Duration = .milliseconds(600)) {
        self.delay = delay
    }

    func generateMCQSet() async throws -> [MCQQuestion] {
        try? await Task.sleep(for: delay)
        return [
            MCQQuestion(question: "Your RAG answers are fluent but cite the wrong document. What do you fix first?",
                        options: ["The retriever and its ranking", "The generation temperature",
                                  "The system prompt tone", "The embedding model's context length"],
                        correctIndex: 0,
                        explanation: "Fluent-but-wrong citations point at retrieval, not generation — measure recall@k before touching the prompt.",
                        topic: "RAG"),
            MCQQuestion(question: "Which failure mode does a tool-calling agent hit most often in production?",
                        options: ["Token limits", "Looping on a failed tool call",
                                  "Slow embeddings", "Cold starts"],
                        correctIndex: 1,
                        explanation: "Without a retry budget and a terminal state, agents re-issue the same failing call until they exhaust the context.",
                        topic: "Agents"),
            MCQQuestion(question: "What does MCP standardise?",
                        options: ["Model weights format", "How tools and context are exposed to a model",
                                  "GPU scheduling", "Embedding dimensionality"],
                        correctIndex: 1,
                        explanation: "MCP is a protocol for exposing tools, resources and prompts to a model host in a uniform way.",
                        topic: "MCP"),
            MCQQuestion(question: "Chunking at 2,000 tokens with no overlap most likely causes what?",
                        options: ["Higher recall", "Answers split across chunk boundaries",
                                  "Cheaper embeddings", "Better re-ranking"],
                        correctIndex: 1,
                        explanation: "Long, non-overlapping chunks cut through the middle of the passage that actually answers the question.",
                        topic: "RAG"),
            MCQQuestion(question: "Cheapest first lever when p95 inference cost is too high?",
                        options: ["Fine-tune a smaller model", "Cut the prompt and cache the stable prefix",
                                  "Buy reserved GPUs", "Switch vector databases"],
                        correctIndex: 1,
                        explanation: "Prompt size is paid on every call; trimming it and hitting prefix caching is free compared with retraining.",
                        topic: "Inference")
        ]
    }

    func openingQuestion() async throws -> String {
        try? await Task.sleep(for: delay)
        return "Walk me through the architecture of a RAG system you have actually shipped — retrieval strategy, chunking, and where it broke first."
    }

    func evaluate(recent: [Message]) async throws -> DescriptiveEvaluation {
        try? await Task.sleep(for: delay)
        turn += 1
        return DescriptiveEvaluation(
            scoreOutOfFive: min(5, 2 + turn),
            feedback: "Good instinct on hybrid retrieval, and you named a concrete failure. You skipped how you measured that retrieval was the weak link.",
            nextQuestion: "What signal told you the retriever, and not the generator, was the problem?"
        )
    }

    nonisolated var requiresAPIKey: Bool { false }
    func compact(_ messages: [Message]) async throws {}
    func resetSession() async {}
    func lastUsage() async -> TokenUsage? {
        TokenUsage(promptTokenCount: 480, candidatesTokenCount: 92,
                   totalTokenCount: 572, cachedContentTokenCount: 310)
    }
}


