//
//  AdminDashboardView.swift
//  PrepPulse
//
//  Admin view over the SwiftData feedback logs: everything the user flagged as
//  "Bad", with triage. The top unresolved entries are exactly what
//  `CorrectionLedgerStore` replays into the system instructions, so resolving
//  an item here changes the next prompt.
//

import SwiftData
import SwiftUI

struct AdminDashboardView: View {

    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open"
        case resolved = "Resolved"
        case all = "All"
        var id: String { rawValue }
    }

    /// Static predicate + in-memory filtering: the flagged set is small, and it
    /// keeps the query from being rebuilt on every segment change.
    @Query(filter: #Predicate<FeedbackLog> { $0.ratingRaw == "bad" },
           sort: \FeedbackLog.createdAt, order: .reverse)
    private var flagged: [FeedbackLog]

    @Environment(\.modelContext) private var context
    @ObservedObject var store: FeedbackLogStore

    @State private var filter: Filter = .open
    @State private var confirmClearAll = false

    private var visible: [FeedbackLog] {
        switch filter {
        case .open: return flagged.filter { !$0.isResolved }
        case .resolved: return flagged.filter(\.isResolved)
        case .all: return flagged
        }
    }

    /// Seeded guardrails, oldest first — the order they reach the prompt in.
    private var rules: [FeedbackLog] {
        visible.filter { $0.kind == .rule }.sorted { $0.createdAt < $1.createdAt }
    }

    private var evaluations: [FeedbackLog] {
        visible.filter { $0.kind == .evaluation }
    }

    /// Exactly what `CorrectionLedgerStore` sends: every open rule, plus the
    /// five most recent open evaluations.
    private var ledgerIDs: Set<UUID> {
        let openRules = flagged.filter { $0.kind == .rule && !$0.isResolved }
        let openEvaluations = flagged.filter { $0.kind == .evaluation && !$0.isResolved }.prefix(5)
        return Set((openRules + openEvaluations).map(\.turnID))
    }

    var body: some View {
        Group {
            if flagged.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        summary
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                    }

                    if !rules.isEmpty {
                        Section {
                            ForEach(rules) { log in row(for: log) }
                        } header: {
                            Text("Standing rules")
                        } footer: {
                            Text("Foundational guardrails, seeded on first launch. Every open rule goes into the <CorrectionLedger> on every call — they're never crowded out by recent flags.")
                        }
                    }

                    Section {
                        if evaluations.isEmpty {
                            Text(filter == .resolved ? "Nothing resolved yet." : "No flagged evaluations.")
                                .font(.pp(.footnote))
                                .foregroundStyle(Pastel.inkSoft)
                        } else {
                            ForEach(evaluations) { log in row(for: log) }
                        }
                    } header: {
                        Text("Flagged evaluations")
                    } footer: {
                        Text("The five most recent open evaluations are appended to the interviewer's system instructions alongside the rules. Resolving one drops it from the next prompt.")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Pastel.canvas.ignoresSafeArea())
        .navigationTitle("Correction ledger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                    Divider()
                    Button("Resolve all open", systemImage: "checkmark.circle") { resolveAll() }
                        .disabled(flagged.allSatisfy(\.isResolved))
                    Button("Delete all flagged", systemImage: "trash", role: .destructive) {
                        confirmClearAll = true
                    }
                    .disabled(flagged.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.pp(size: 15, .semibold))
                }
                .accessibilityLabel("Dashboard actions")
            }
        }
        .confirmationDialog("Delete every flagged evaluation?",
                            isPresented: $confirmClearAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the correction ledger. It can't be undone.")
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func row(for log: FeedbackLog) -> some View {
        NavigationLink {
            FeedbackLogDetailView(log: log, store: store)
        } label: {
            LogRow(log: log, inLedger: ledgerIDs.contains(log.turnID))
        }
        .swipeActions(edge: .leading) {
            Button {
                toggleResolved(log)
            } label: {
                Label(log.isResolved ? "Reopen" : "Resolve",
                      systemImage: log.isResolved ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(log.isResolved ? Pastel.butter : Pastel.mint)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(log)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            statTile(value: "\(flagged.filter { $0.kind == .rule }.count)",
                     label: "rules", tint: Pastel.mintSoft)
            statTile(value: "\(flagged.filter { $0.kind == .evaluation }.count)",
                     label: "flagged", tint: Pastel.blushSoft)
            statTile(value: "\(ledgerIDs.count)", label: "in prompt", tint: Pastel.lavenderSoft)
        }
    }

    private func statTile(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.pp(size: 22, .heavy))
                .foregroundStyle(Pastel.ink)
            Text(label)
                .font(.pp(size: 11, .medium))
                .foregroundStyle(Pastel.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(tint, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Pastel.mintSoft).frame(width: 82, height: 82)
                Image(systemName: "checkmark.seal.fill")
                    .font(.pp(size: 30, .semibold))
                    .foregroundStyle(Pastel.mint)
            }
            Text("Nothing flagged")
                .font(.pp(.headline, .semibold))
                .foregroundStyle(Pastel.ink)
            Text("Thumbs-down an evaluation during an interview and it lands here, then gets replayed to the model so it calibrates.")
                .font(.pp(.footnote))
                .foregroundStyle(Pastel.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Mutations

    private func toggleResolved(_ log: FeedbackLog) {
        log.isResolved.toggle()
        persist()
    }

    private func resolveAll() {
        for log in flagged where !log.isResolved { log.isResolved = true }
        persist()
    }

    private func delete(_ log: FeedbackLog) {
        context.delete(log)
        persist()
    }

    private func deleteAll() {
        for log in flagged { context.delete(log) }
        persist()
    }

    private func persist() {
        do {
            try context.save()
            // Keep the in-memory mirror the chat UI reads from in sync.
            store.reload()
        } catch {
            #if DEBUG
            print("[PrepPulse] Dashboard save failed: \(error.localizedDescription)")
            #endif
        }
    }
}

// MARK: - Row

private struct LogRow: View {
    let log: FeedbackLog
    let inLedger: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if log.kind == .rule {
                    Text("RULE")
                        .font(.pp(size: 9, .heavy))
                        .foregroundStyle(Pastel.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Pastel.mintSoft, in: .capsule)
                } else if log.mode == .mcq {
                    Text("MCQ")
                        .font(.pp(size: 9, .heavy))
                        .foregroundStyle(Pastel.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Pastel.blushSoft, in: .capsule)
                } else {
                    PastelStars(score: log.score, size: 11)
                }
                Spacer(minLength: 4)
                if inLedger {
                    Text("in prompt")
                        .font(.pp(size: 9, .heavy))
                        .foregroundStyle(Pastel.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Pastel.lavenderSoft, in: .capsule)
                }
                if log.isResolved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.pp(size: 12))
                        .foregroundStyle(Pastel.mint)
                }
            }

            Text(log.question)
                .font(.pp(.footnote, .semibold))
                .foregroundStyle(Pastel.ink)
                .lineLimit(2)

            Text(log.kind == .rule || log.mode == .mcq
                 ? log.note
                 : (log.aiFeedback.isEmpty ? "No critique recorded" : log.aiFeedback))
                .font(.pp(.caption))
                .foregroundStyle(Pastel.inkSoft)
                .lineLimit(2)

            if log.kind == .evaluation {
                Text(log.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.pp(size: 10))
                    .foregroundStyle(Pastel.inkSoft.opacity(0.75))
            }
        }
        .padding(.vertical, 4)
        .opacity(log.isResolved ? 0.55 : 1)
    }
}

// MARK: - Detail

private struct FeedbackLogDetailView: View {
    @Bindable var log: FeedbackLog
    @ObservedObject var store: FeedbackLogStore

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private var isRule: Bool { log.kind == .rule }

    var body: some View {
        Form {
            if isRule {
                Section("Rule") {
                    TextField("Title", text: $log.question)
                        .font(.pp(.callout, .semibold))
                }

                Section {
                    TextField("Directive", text: $log.note, axis: .vertical)
                        .lineLimit(3...12)
                        .font(.pp(.callout))
                } header: {
                    Text("Directive")
                } footer: {
                    Text("Sent verbatim inside the <CorrectionLedger> on every interview call, above the flagged evaluations.")
                }
            } else {
                Section("Evaluation") {
                    if log.mode == .interview { PastelStars(score: log.score) }
                    LabeledContent("Mode", value: log.mode.label)
                    LabeledContent("Logged", value: log.createdAt.formatted(date: .abbreviated,
                                                                            time: .shortened))
                }

                Section(log.mode == .mcq ? "Question generated" : "Question asked") {
                    Text(log.question).font(.pp(.callout))
                }

                if log.mode == .interview {
                    Section("Your answer") {
                        Text(log.candidateAnswer.isEmpty ? "—" : log.candidateAnswer)
                            .font(.pp(.callout))
                    }
                }

                Section(log.mode == .mcq ? "Answer key" : "Model's critique") {
                    Text(log.aiFeedback.isEmpty ? "—" : log.aiFeedback)
                        .font(.pp(.callout))
                }

                Section {
                    TextField("What did it get wrong?", text: $log.note, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.pp(.callout))
                } header: {
                    Text(log.mode == .mcq ? "Your correction" : "Your note")
                } footer: {
                    Text(log.mode == .mcq
                         ? "Replayed to the question generator inside <MCQCorrectionLedger>."
                         : "Included verbatim in the correction ledger, so keep it short and specific.")
                }
            }

            Section {
                Toggle(isRule ? "Disabled" : "Resolved", isOn: isRule
                       ? Binding(get: { log.isResolved }, set: { log.isResolved = $0 })
                       : $log.isResolved)
                Button(isRule ? "Delete rule" : "Delete log", role: .destructive) {
                    context.delete(log)
                    save()
                    dismiss()
                }
            }
        }
        .navigationTitle(log.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            store.reload()
        } catch {
            #if DEBUG
            print("[PrepPulse] Detail save failed: \(error.localizedDescription)")
            #endif
        }
    }
}

// MARK: - Preview

#Preview("Dashboard") {
    let container = try! ModelContainer(
        for: FeedbackLog.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    for rule in DefaultRules.makeLogs() { context.insert(rule) }
    context.insert(FeedbackLog(
        turnID: UUID(), rating: .bad, mode: .interview,
        question: "How would you evaluate a RAG pipeline end to end?",
        candidateAnswer: "I'd measure recall@k on a golden set, then answer faithfulness with an LLM judge calibrated against human labels.",
        aiFeedback: "Vague — you didn't name any metric.",
        score: 2))
    context.insert(FeedbackLog(
        turnID: UUID(), rating: .bad, mode: .interview,
        question: "When would you not use an agent?",
        candidateAnswer: "When the task is a fixed pipeline with no branching, agents just add latency and failure modes.",
        aiFeedback: "Missing the point about tool schemas.",
        score: 3, isResolved: true))

    return NavigationStack {
        AdminDashboardView(store: FeedbackLogStore(context: context))
    }
    .modelContainer(container)
}
