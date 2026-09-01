//
//  FeedbackLog.swift
//  PrepPulse
//
//  SwiftData record of every evaluation the user rated, plus the ModelActor
//  that turns recent "Bad" ratings into the <CorrectionLedger> block appended
//  to the interviewer's system instructions.
//

import Foundation
import SwiftData

// MARK: - Model

@Model
nonisolated final class FeedbackLog {

    /// Matches `InterviewerTurn.id` so a turn maps to exactly one log.
    @Attribute(.unique) var turnID: UUID
    var createdAt: Date
    /// `MetaRating.rawValue`. Stored as a String because SwiftData predicates
    /// can't compare custom enums.
    var ratingRaw: String
    /// `PracticeMode.rawValue`.
    var modeRaw: String
    /// `LogKind.rawValue`. Defaulted so adding it stays a lightweight migration.
    var kindRaw: String = LogKind.evaluation.rawValue

    /// For `.evaluation`: what was asked, what the user said, and how the model
    /// graded it — the three things the ledger needs to explain a bad call.
    /// For `.rule`: `question` holds the rule's short title, `note` holds the
    /// directive itself, and the answer/critique/score fields stay empty.
    var question: String
    var candidateAnswer: String
    var aiFeedback: String
    var score: Int

    /// Admin dashboard state: triaged items drop out of the ledger.
    var isResolved: Bool
    /// Optional human note ("graded a correct answer as vague").
    var note: String

    init(turnID: UUID,
         createdAt: Date = .now,
         rating: MetaRating,
         mode: PracticeMode = .interview,
         kind: LogKind = .evaluation,
         question: String,
         candidateAnswer: String,
         aiFeedback: String,
         score: Int,
         isResolved: Bool = false,
         note: String = "") {
        self.turnID = turnID
        self.createdAt = createdAt
        self.ratingRaw = rating.rawValue
        self.modeRaw = mode.rawValue
        self.kindRaw = kind.rawValue
        self.question = question
        self.candidateAnswer = candidateAnswer
        self.aiFeedback = aiFeedback
        self.score = score
        self.isResolved = isResolved
        self.note = note
    }

    var rating: MetaRating {
        get { MetaRating(rawValue: ratingRaw) ?? .good }
        set { ratingRaw = newValue.rawValue }
    }

    var mode: PracticeMode {
        get { PracticeMode(rawValue: modeRaw) ?? .interview }
        set { modeRaw = newValue.rawValue }
    }

    var kind: LogKind {
        get { LogKind(rawValue: kindRaw) ?? .evaluation }
        set { kindRaw = newValue.rawValue }
    }

    /// A question the candidate flagged as wrong or ambiguous during an MCQ set.
    ///
    /// Field mapping, since this model is shared with the interview flow:
    /// `question` ← the question text, `aiFeedback` ← the AI response (answer key
    /// plus explanation), `note` ← the user's correction, `createdAt` ← timestamp,
    /// `mode` ← `.mcq`. `turnID` carries the `MCQQuestion.id` so a card can tell
    /// whether it has already been flagged.
    static func mcqCorrection(questionID: UUID,
                              question: String,
                              aiResponse: String,
                              userCorrection: String,
                              createdAt: Date = .now) -> FeedbackLog {
        FeedbackLog(turnID: questionID,
                    createdAt: createdAt,
                    rating: .bad,
                    mode: .mcq,
                    kind: .evaluation,
                    question: question,
                    candidateAnswer: "",
                    aiFeedback: aiResponse,
                    score: 0,
                    note: userCorrection)
    }

    /// A standing instruction rather than a flagged evaluation.
    ///
    /// Rules are stored with `rating: .bad` deliberately: it is the rating that
    /// means "change this behaviour", and it keeps rules flowing through the
    /// same dashboard query and ledger fetch as user-flagged evaluations.
    static func rule(title: String, directive: String, createdAt: Date = .now) -> FeedbackLog {
        FeedbackLog(turnID: UUID(),
                    createdAt: createdAt,
                    rating: .bad,
                    mode: .interview,
                    kind: .rule,
                    question: title,
                    candidateAnswer: "",
                    aiFeedback: "",
                    score: 0,
                    note: directive)
    }

    var snapshot: FeedbackLogSnapshot {
        FeedbackLogSnapshot(turnID: turnID, createdAt: createdAt, rating: rating, mode: mode,
                            kind: kind, question: question, candidateAnswer: candidateAnswer,
                            aiFeedback: aiFeedback, score: score,
                            isResolved: isResolved, note: note)
    }
}

nonisolated enum LogKind: String, Codable, Sendable, CaseIterable {
    /// A specific evaluation the candidate flagged as inaccurate.
    case evaluation
    /// A standing guardrail that applies to every turn.
    case rule

    var label: String {
        switch self {
        case .evaluation: return "Flagged evaluation"
        case .rule: return "Standing rule"
        }
    }
}

nonisolated enum PracticeMode: String, Codable, Sendable, CaseIterable {
    case interview
    case mcq

    var label: String {
        switch self {
        case .interview: return "Live interview"
        case .mcq: return "Rapid MCQ"
        }
    }
}

/// `@Model` classes aren't `Sendable`, so anything crossing an actor boundary
/// travels as this value type instead.
nonisolated struct FeedbackLogSnapshot: Identifiable, Hashable, Sendable {
    var id: UUID { turnID }
    let turnID: UUID
    let createdAt: Date
    let rating: MetaRating
    let mode: PracticeMode
    let kind: LogKind
    let question: String
    let candidateAnswer: String
    let aiFeedback: String
    let score: Int
    let isResolved: Bool
    let note: String

    /// Rules carry their directive in `note`; fall back to the title if empty.
    var ledgerBody: String { note.isEmpty ? question : note }
}

/// Everything the UI needs to write a log when a thumb is tapped.
nonisolated struct FeedbackDraft: Sendable {
    let turnID: UUID
    let mode: PracticeMode
    let question: String
    let candidateAnswer: String
    let aiFeedback: String
    let score: Int
}

// MARK: - First-launch guardrails

/// Seeded into SwiftData on the very first launch so the `<CorrectionLedger>`
/// has calibration to send before the candidate has flagged anything.
nonisolated enum DefaultRules {

    struct Rule: Sendable {
        let title: String
        let directive: String
    }

    /// Bump when `all` changes so installs seeded with an older set pick up the
    /// new one instead of being stuck on whatever shipped first.
    static let version = 2
    static let versionKey = "rules.seedVersion"

    static let all: [Rule] = [
        Rule(title: "Culture",
             directive: "Reward responses that demonstrate rapid iteration, product thinking, and founder energy. When hackathon projects are mentioned, evaluate the architectural trade-offs made to ship quickly."),
        Rule(title: "Constraint",
             directive: "The interviewer is strictly prohibited from asking about, evaluating, or mentioning pricing engines in any capacity. Pivot backend architecture questions toward LLM orchestration."),
        Rule(title: "5-star anchor",
             directive: "Award 5 stars only if the candidate demonstrates exceptional mastery, proposes non-obvious approaches, and knows when to use a deterministic solution over an LLM."),
        Rule(title: "3-star anchor",
             directive: "Award 3 stars if the candidate puts forward a fair system considering data flow and scalability, providing at least one relevant example."),
        Rule(title: "1-star anchor",
             directive: "Award 1 star if the candidate suggests a solution without identifying key scalability or architectural constraints, or provides minimal understanding.")
    ]

    /// Ordered a second apart so `createdAt` sorting keeps them in the order above.
    static func makeLogs(now: Date = .now) -> [FeedbackLog] {
        all.enumerated().map { index, rule in
            FeedbackLog.rule(title: rule.title,
                             directive: rule.directive,
                             createdAt: now.addingTimeInterval(Double(index)))
        }
    }
}

// MARK: - Ledger formatting

nonisolated enum CorrectionLedger {

    /// Renders logs as the `<CorrectionLedger>` block. Pure and testable —
    /// the actor only supplies the rows.
    ///
    /// Standing rules read as directives; flagged evaluations read as case
    /// notes, because the model needs to be told the difference.
    static func render(_ logs: [FeedbackLogSnapshot]) -> String? {
        let rules = logs.filter { $0.kind == .rule }
        let flagged = logs.filter { $0.kind == .evaluation }
        guard !rules.isEmpty || !flagged.isEmpty else { return nil }

        var body = ""

        if !rules.isEmpty {
            let lines = rules.enumerated().map { index, rule in
                "R\(index + 1). \(rule.ledgerBody.truncated(to: 400))"
            }
            body += """
            STANDING RULES — these override your default behaviour and apply to every turn:
            \(lines.joined(separator: "\n"))
            """
        }

        if !flagged.isEmpty {
            let entries = flagged.enumerated().map { index, log -> String in
                var line = """
                \(index + 1). [\(Self.day.string(from: log.createdAt))] \
                You asked: "\(log.question.truncated(to: 160))" \
                The candidate answered: "\(log.candidateAnswer.truncated(to: 220))" \
                You graded it \(log.score)/5 and said: "\(log.aiFeedback.truncated(to: 160))" \
                The candidate flagged this evaluation as inaccurate.
                """
                if !log.note.isEmpty {
                    line += " Their note: \"\(log.note.truncated(to: 120))\""
                }
                return line
            }
            if !body.isEmpty { body += "\n\n" }
            body += """
            PAST EVALUATIONS THE CANDIDATE FLAGGED AS INACCURATE — calibrate against these, \
            but do not overcorrect into inflating scores:
            \(entries.joined(separator: "\n\n"))
            """
        }

        return """
        <CorrectionLedger>
        \(body)
        </CorrectionLedger>
        """
    }

    /// Questions the candidate flagged as wrong or ambiguous, rendered for the
    /// MCQ generator so it stops producing the same kind of broken item.
    static func renderMCQ(_ logs: [FeedbackLogSnapshot]) -> String? {
        guard !logs.isEmpty else { return nil }

        let entries = logs.enumerated().map { index, log in
            """
            \(index + 1). [\(Self.day.string(from: log.createdAt))] \
            You generated: "\(log.question.truncated(to: 200))" \
            Your answer key: "\(log.aiFeedback.truncated(to: 200))" \
            The candidate flagged it and said: "\(log.note.truncated(to: 220))"
            """
        }

        return """
        <MCQCorrectionLedger>
        Questions you previously generated that the candidate flagged as erroneous or \
        ambiguous. Do not regenerate these questions, and do not repeat the same failure \
        mode — especially on these topics. If a topic below keeps producing ambiguity, \
        write a sharper, more concrete question on it instead of avoiding it.

        \(entries.joined(separator: "\n\n"))
        </MCQCorrectionLedger>
        """
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension String {
    /// Ledger entries are prompt tokens on every call — keep them short.
    nonisolated func truncated(to limit: Int) -> String {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }
}

// MARK: - Ledger source

nonisolated protocol CorrectionLedgerProviding: Sendable {
    /// The rendered `<CorrectionLedger>` block for the interviewer, or `nil` when
    /// there's nothing to correct. Never throws — a ledger failure must not break
    /// an interview.
    func ledgerText(limit: Int) async -> String?
    /// The rendered `<MCQCorrectionLedger>` block for the question generator.
    func mcqLedgerText(limit: Int) async -> String?
}

/// Reads the store off the main actor on its own `ModelContext`, so a fetch
/// on every API call never touches the UI context.
@ModelActor
actor CorrectionLedgerStore: CorrectionLedgerProviding {

    /// Standing rules, in the order they were seeded. Never limited — these are
    /// guardrails, so they must not get pushed out by recent flags.
    func standingRules() -> [FeedbackLogSnapshot] {
        let rule = LogKind.rule.rawValue
        let descriptor = FetchDescriptor<FeedbackLog>(
            predicate: #Predicate { $0.kindRaw == rule && $0.isResolved == false },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return fetch(descriptor)
    }

    /// The most recent flagged interview evaluations, newest first. Scoped to
    /// `.interview` so MCQ flags stay out of the interviewer's prompt.
    func recentBadLogs(limit: Int = 5) -> [FeedbackLogSnapshot] {
        let bad = MetaRating.bad.rawValue
        let evaluation = LogKind.evaluation.rawValue
        let interview = PracticeMode.interview.rawValue
        var descriptor = FetchDescriptor<FeedbackLog>(
            predicate: #Predicate {
                $0.kindRaw == evaluation && $0.modeRaw == interview
                    && $0.ratingRaw == bad && $0.isResolved == false
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    /// The most recent flagged MCQ questions, newest first.
    func recentMCQCorrections(limit: Int = 5) -> [FeedbackLogSnapshot] {
        let evaluation = LogKind.evaluation.rawValue
        let mcq = PracticeMode.mcq.rawValue
        var descriptor = FetchDescriptor<FeedbackLog>(
            predicate: #Predicate {
                $0.kindRaw == evaluation && $0.modeRaw == mcq && $0.isResolved == false
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    func ledgerText(limit: Int = 5) async -> String? {
        // Rules first, then flagged cases oldest-first — reads as a running ledger.
        CorrectionLedger.render(standingRules() + recentBadLogs(limit: limit).reversed())
    }

    func mcqLedgerText(limit: Int = 5) async -> String? {
        CorrectionLedger.renderMCQ(recentMCQCorrections(limit: limit).reversed())
    }

    private func fetch(_ descriptor: FetchDescriptor<FeedbackLog>) -> [FeedbackLogSnapshot] {
        do {
            return try modelContext.fetch(descriptor).map(\.snapshot)
        } catch {
            #if DEBUG
            print("[PrepPulse] Ledger fetch failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }
}
