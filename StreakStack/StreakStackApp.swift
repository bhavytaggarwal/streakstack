//
//  StreakStackApp.swift
//  PrepPulse
//

import SwiftData
import SwiftUI

@main
struct PrepPulseApp: App {

    private let container: ModelContainer

    @StateObject private var streaks = StreakStore()
    @StateObject private var preferences = Preferences()
    @StateObject private var logs: FeedbackLogStore

    init() {
        let container = Self.makeContainer()
        self.container = container
        // The UI mirror reads and writes on the main context; the correction
        // ledger reads the same store from its own ModelActor.
        _logs = StateObject(wrappedValue: FeedbackLogStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(streaks)
                .environmentObject(preferences)
                .environmentObject(logs)
                .modelContainer(container)
                .tint(Pastel.lavender)
        }
    }

    // MARK: - Container

    /// Builds the container and seeds the foundational rules before handing it
    /// back, so the admin dashboard and the very first `<CorrectionLedger>` both
    /// see them without waiting on a later pass.
    ///
    /// Falls back to an in-memory store rather than refusing to launch: losing
    /// the ledger is survivable, a crash on cold start is not.
    @MainActor
    private static func makeContainer() -> ModelContainer {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: FeedbackLog.self)
        } catch {
            print("[PrepPulse] Persistent store unavailable (\(error.localizedDescription)); using in-memory.")
            do {
                container = try ModelContainer(
                    for: FeedbackLog.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Could not create a SwiftData container: \(error)")
            }
        }

        seedDefaultRulesIfNeeded(in: container.mainContext)
        return container
    }

    /// Seeds the foundational rules when the store is empty — first launch or a
    /// fresh install — and re-seeds when `DefaultRules.version` moves ahead of
    /// what this install last wrote, so an existing install isn't stranded on an
    /// older rule set.
    ///
    /// A version re-seed replaces the seeded rules only; flagged evaluations are
    /// left alone. Hand-edited rule text is replaced too, which is the trade for
    /// being able to ship rule changes at all.
    @MainActor
    private static func seedDefaultRulesIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        do {
            // `fetchCount` avoids materialising objects just to ask "is it empty?".
            let existing = try context.fetchCount(FetchDescriptor<FeedbackLog>())
            let seededVersion = defaults.integer(forKey: DefaultRules.versionKey)
            let isEmptyStore = existing == 0
            let isStale = seededVersion != DefaultRules.version

            guard isEmptyStore || isStale else { return }

            if isStale, !isEmptyStore {
                let rule = LogKind.rule.rawValue
                try context.delete(model: FeedbackLog.self,
                                   where: #Predicate { $0.kindRaw == rule })
            }

            for rule in DefaultRules.makeLogs() {
                context.insert(rule)
            }
            try context.save()
            defaults.set(DefaultRules.version, forKey: DefaultRules.versionKey)

            #if DEBUG
            print("[PrepPulse] Seeded \(DefaultRules.all.count) foundational rules (v\(DefaultRules.version)).")
            #endif
        } catch {
            // A seeding failure must not block launch — the app simply runs
            // without standing rules until the next cold start retries.
            print("[PrepPulse] Rule seeding failed: \(error.localizedDescription)")
        }
    }
}
