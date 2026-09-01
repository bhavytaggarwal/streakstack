//
//  Models.swift
//  PrepPulse
//
//  Domain models, the JSON-Schema builder used to constrain Gemini's output,
//  the Codable shapes that schema produces, and the streak engine.
//

import Foundation

// MARK: - Chat primitives

nonisolated enum Role: String, Codable, Sendable {
    case user
    case model // Gemini's name for the assistant turn
}

nonisolated struct Message: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    var isUser: Bool { role == .user }
}

// MARK: - Mode A: objective MCQ

nonisolated struct MCQQuestion: Identifiable, Codable, Hashable, Sendable {
    /// Generated locally — the model never returns a stable id.
    var id = UUID()
    var question: String
    var options: [String]
    var correctIndex: Int
    var explanation: String
    var topic: String

    private enum CodingKeys: String, CodingKey {
        case question
        case options
        case correctIndex = "correct_index"
        case explanation
        case topic
    }

    /// Guards against a model returning an out-of-range index.
    var safeCorrectIndex: Int { options.indices.contains(correctIndex) ? correctIndex : 0 }

    func isCorrect(_ selection: Int?) -> Bool { selection == safeCorrectIndex }

    var correctOption: String {
        options.indices.contains(safeCorrectIndex) ? options[safeCorrectIndex] : "—"
    }

    /// The model's own answer + reasoning, as one line. This is what gets stored
    /// as the AI response on a flagged question and quoted back in the ledger.
    var answerKey: String {
        "Correct answer: \(correctOption). \(explanation)"
    }
}

nonisolated struct MCQSet: Codable, Sendable {
    var questions: [MCQQuestion]
}

nonisolated struct MCQAnswer: Identifiable, Hashable, Sendable {
    var id: UUID { question.id }
    let question: MCQQuestion
    let selectedIndex: Int
    var isCorrect: Bool { question.isCorrect(selectedIndex) }
}

// MARK: - Mode B: descriptive interview

/// Exactly the payload the response schema pins down:
/// `{"score_out_of_5": Int, "feedback": String, "next_question": String}`
nonisolated struct DescriptiveEvaluation: Codable, Hashable, Sendable {
    var scoreOutOfFive: Int
    var feedback: String
    var nextQuestion: String

    private enum CodingKeys: String, CodingKey {
        case scoreOutOfFive = "score_out_of_5"
        case feedback
        case nextQuestion = "next_question"
    }

    var clampedScore: Int { min(5, max(1, scoreOutOfFive)) }
}

/// The opening turn has nothing to evaluate yet, so it uses its own tiny schema.
nonisolated struct OpeningQuestion: Codable, Sendable {
    var question: String
}

/// One interviewer bubble: an optional evaluation of the previous answer,
/// followed by the next question.
nonisolated struct InterviewerTurn: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// `nil` on the opening turn.
    var score: Int?
    var feedback: String?
    var question: String
    let createdAt: Date

    init(id: UUID = UUID(),
         score: Int? = nil,
         feedback: String? = nil,
         question: String,
         createdAt: Date = .now) {
        self.id = id
        self.score = score
        self.feedback = feedback
        self.question = question
        self.createdAt = createdAt
    }

    init(id: UUID = UUID(), evaluation: DescriptiveEvaluation, createdAt: Date = .now) {
        self.id = id
        self.score = evaluation.clampedScore
        self.feedback = evaluation.feedback
        self.question = evaluation.nextQuestion
        self.createdAt = createdAt
    }
}

nonisolated enum ChatEntry: Identifiable, Hashable, Sendable {
    case candidate(Message)
    case interviewer(InterviewerTurn)

    var id: UUID {
        switch self {
        case .candidate(let message): return message.id
        case .interviewer(let turn): return turn.id
        }
    }
}

// MARK: - Meta rating ("did the AI grade me fairly?")

nonisolated enum MetaRating: String, Codable, Hashable, Sendable {
    case good
    case bad
}

// MARK: - Streaks

nonisolated struct Streak: Codable, Hashable, Sendable {
    var current: Int = 0
    var longest: Int = 0
    /// Normalised to the start of day in the user's calendar.
    var lastPracticedDay: Date?
    var totalDaysPracticed: Int = 0
}

nonisolated enum StreakOutcome: Equatable, Sendable {
    case alreadyCountedToday
    case started
    case extended(to: Int)
    case restarted(missedDays: Int)

    var isCelebratory: Bool {
        switch self {
        case .started, .extended: return true
        case .alreadyCountedToday, .restarted: return false
        }
    }
}

/// Pure date arithmetic — no storage, so the rules are unit-testable.
nonisolated struct StreakEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func dayGap(from start: Date, to end: Date) -> Int {
        let a = calendar.startOfDay(for: start)
        let b = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    func apply(_ streak: Streak, practicedOn date: Date = .now) -> (Streak, StreakOutcome) {
        let today = calendar.startOfDay(for: date)
        var updated = streak

        guard let last = streak.lastPracticedDay else {
            updated.current = 1
            updated.longest = max(streak.longest, 1)
            updated.lastPracticedDay = today
            updated.totalDaysPracticed = streak.totalDaysPracticed + 1
            return (updated, .started)
        }

        switch dayGap(from: last, to: today) {
        case ..<0:
            // Device clock moved backwards; ignore rather than corrupt the run.
            return (streak, .alreadyCountedToday)
        case 0:
            return (streak, .alreadyCountedToday)
        case 1:
            updated.current = streak.current + 1
            updated.longest = max(streak.longest, updated.current)
            updated.lastPracticedDay = today
            updated.totalDaysPracticed = streak.totalDaysPracticed + 1
            return (updated, .extended(to: updated.current))
        case let gap:
            updated.current = 1
            updated.longest = max(streak.longest, 1)
            updated.lastPracticedDay = today
            updated.totalDaysPracticed = streak.totalDaysPracticed + 1
            return (updated, .restarted(missedDays: gap - 1))
        }
    }

    /// A run survives until the end of the day *after* the last session; past
    /// that it reads zero without anything being written to storage.
    func displayedStreak(for streak: Streak, asOf date: Date = .now) -> Int {
        guard let last = streak.lastPracticedDay else { return 0 }
        return dayGap(from: last, to: date) <= 1 ? streak.current : 0
    }

    func hasPracticedToday(_ streak: Streak, asOf date: Date = .now) -> Bool {
        guard let last = streak.lastPracticedDay else { return false }
        return dayGap(from: last, to: date) == 0
    }
}

nonisolated enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}

// MARK: - Token accounting

nonisolated enum TokenEstimator {
    /// ~4 characters per token — good enough for the "saved by windowing"
    /// readout; authoritative numbers come back in `usageMetadata`.
    static func estimate(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }

    static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1.text) + 4 }
    }
}

nonisolated struct SessionUsage: Equatable, Sendable {
    var promptTokens = 0
    var cachedTokens = 0
    var outputTokens = 0
    var requests = 0
    var tokensSavedByWindowing = 0

    var totalTokens: Int { promptTokens + outputTokens }

    mutating func record(_ usage: TokenUsage?, fullHistory: [Message]) {
        requests += 1
        let prompt = usage?.promptTokenCount ?? 0
        promptTokens += prompt
        cachedTokens += usage?.cachedContentTokenCount ?? 0
        outputTokens += usage?.candidatesTokenCount ?? 0
        if prompt > 0 {
            tokensSavedByWindowing += max(0, TokenEstimator.estimate(fullHistory) - prompt)
        }
    }
}

// MARK: - JSON Schema (OpenAPI subset Gemini accepts in `responseSchema`)

nonisolated indirect enum JSONSchema: Sendable {
    case string(description: String?)
    case integer(description: String?)
    case array(of: JSONSchema, minItems: Int?, maxItems: Int?)
    /// Property order is preserved and mirrored into `propertyOrdering`, which
    /// measurably improves adherence for structured output.
    case object(properties: [(String, JSONSchema)], required: [String])
}

extension JSONSchema: Encodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .string(let description):
            try container.encode("STRING", forKey: Key("type"))
            try container.encodeIfPresent(description, forKey: Key("description"))

        case .integer(let description):
            try container.encode("INTEGER", forKey: Key("type"))
            try container.encodeIfPresent(description, forKey: Key("description"))

        case .array(let items, let minItems, let maxItems):
            try container.encode("ARRAY", forKey: Key("type"))
            try container.encode(items, forKey: Key("items"))
            try container.encodeIfPresent(minItems, forKey: Key("minItems"))
            try container.encodeIfPresent(maxItems, forKey: Key("maxItems"))

        case .object(let properties, let required):
            try container.encode("OBJECT", forKey: Key("type"))
            var nested = container.nestedContainer(keyedBy: Key.self, forKey: Key("properties"))
            for (name, schema) in properties {
                try nested.encode(schema, forKey: Key(name))
            }
            try container.encode(required, forKey: Key("required"))
            try container.encode(properties.map(\.0), forKey: Key("propertyOrdering"))
        }
    }
}

nonisolated enum ResponseSchemas {

    /// Five MCQs, four options each, with the index of the right answer.
    static let mcqSet: JSONSchema = .object(
        properties: [
            ("questions", .array(
                of: .object(
                    properties: [
                        ("question", .string(description: "The question stem. One sentence, no preamble.")),
                        ("options", .array(of: .string(description: "A plausible answer option."),
                                           minItems: 4, maxItems: 4)),
                        ("correct_index", .integer(description: "Zero-based index of the correct option.")),
                        ("explanation", .string(description: "Why the correct option is right, in under 40 words.")),
                        ("topic", .string(description: "One of: LLMs, RAG, Agents, MCP, Evaluation, Inference."))
                    ],
                    required: ["question", "options", "correct_index", "explanation", "topic"]
                ),
                minItems: 5, maxItems: 5
            ))
        ],
        required: ["questions"]
    )

    /// The evaluation contract for Mode B.
    static let descriptiveEvaluation: JSONSchema = .object(
        properties: [
            ("score_out_of_5", .integer(description: "Integer 1-5 grading the candidate's last answer.")),
            ("feedback", .string(description: "Two sentences max: what was strong, what was missing.")),
            ("next_question", .string(description: "One follow-up question probing the weakest part of that answer."))
        ],
        required: ["score_out_of_5", "feedback", "next_question"]
    )

    static let openingQuestion: JSONSchema = .object(
        properties: [
            ("question", .string(description: "The opening interview question. One sentence."))
        ],
        required: ["question"]
    )
}

// MARK: - Gemini REST payloads

nonisolated struct GeminiRequest: Encodable, Sendable {
    var contents: [GeminiContent]
    var systemInstruction: GeminiContent?
    var generationConfig: GenerationConfig?
    /// Resource name of an explicit context cache, e.g. `cachedContents/abc123`.
    var cachedContent: String?
}

nonisolated struct GeminiContent: Codable, Sendable {
    /// `nil` for `systemInstruction`, which carries no role.
    var role: String?
    var parts: [GeminiPart]
}

nonisolated struct GeminiPart: Codable, Sendable {
    var text: String
}

nonisolated struct GenerationConfig: Encodable, Sendable {
    var temperature: Double?
    var topP: Double?
    var maxOutputTokens: Int?
    /// `"application/json"` switches the model into constrained decoding.
    var responseMimeType: String?
    var responseSchema: JSONSchema?
    /// `thinkingBudget: 0` disables Gemini 2.5 reasoning tokens.
    var thinkingConfig: ThinkingConfig?
}

nonisolated struct ThinkingConfig: Encodable, Sendable {
    var thinkingBudget: Int
}

nonisolated struct GeminiResponse: Decodable, Sendable {
    var candidates: [GeminiCandidate]?
    var usageMetadata: TokenUsage?
    var promptFeedback: PromptFeedback?

    var firstText: String? {
        candidates?.first?.content?.parts
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var finishReason: String? { candidates?.first?.finishReason }

    struct PromptFeedback: Decodable, Sendable {
        var blockReason: String?
    }
}

nonisolated struct GeminiCandidate: Decodable, Sendable {
    var content: GeminiContent?
    var finishReason: String?
}

nonisolated struct TokenUsage: Decodable, Hashable, Sendable {
    var promptTokenCount: Int?
    var candidatesTokenCount: Int?
    var totalTokenCount: Int?
    /// Present when a cache (implicit or explicit) served part of the prompt.
    var cachedContentTokenCount: Int?
}

nonisolated struct GeminiErrorEnvelope: Decodable, Sendable {
    struct APIError: Decodable, Sendable {
        var code: Int?
        var message: String?
        var status: String?
    }
    var error: APIError
}

// MARK: - Explicit context caching

nonisolated struct CachedContentRequest: Encodable, Sendable {
    /// Fully-qualified, e.g. `models/gemini-2.5-flash`.
    var model: String
    var systemInstruction: GeminiContent?
    var contents: [GeminiContent]?
    var ttl: String
    var displayName: String?
}

nonisolated struct CachedContentResponse: Decodable, Sendable {
    /// `cachedContents/xyz` — this is what goes in `GeminiRequest.cachedContent`.
    var name: String
    var expireTime: String?
}
