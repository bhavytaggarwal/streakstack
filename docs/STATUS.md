# Project status

Snapshot of where PrepPulse actually is, as of **2026-09-02**. `CHANGELOG.md` is
the running history; this file is the current-state view — including what is
*not* done, so nothing is a surprise later.

**Stage:** working prototype. Builds clean, runs on device/simulator, no release
tagged. **Never exercised against the live Gemini API** — see Verification below.

---

## What exists

| Area | State |
| --- | --- |
| Mode A — Rapid MCQ | Working. 5 questions per constrained-JSON call, swipe deck, explanations, score ring, per-question flagging. |
| Mode B — Live interview | Working. Structured `{score, feedback, next_question}` per turn, pastel stars, thumbs rating, TTS read-aloud, keyboard dictation. |
| Streaks | Working. Pure date arithmetic, `@AppStorage`, week strip, grace day. |
| Correction ledgers | Working. Per-mode scoping, standing rules never crowded out. |
| Admin dashboard | Working. Triage, editable rules and notes, "in prompt" badge. |
| Training corpus | 7 sections, ~4,301 tokens, prepended to both modes. |
| Explicit caching | On by default, per-role caches, fallback on any failure. |
| App icon | Light + dark 1024×1024, opaque. |

## Source map

| File | Role |
| --- | --- |
| `Models.swift` | Chat/MCQ/streak models, Gemini payloads, `JSONSchema` builder |
| `PreTrainingMaterials.swift` | `TrainingCorpus` — 7 benchmark sections |
| `GeminiJSONService.swift` | API client: constrained JSON, sliding window, caching, ledger injection, retries |
| `FeedbackLog.swift` | SwiftData model, `DefaultRules`, ledger rendering, `CorrectionLedgerStore` |
| `ViewModels.swift` | `StreakStore`, `FeedbackLogStore`, `Preferences`, both mode view models, mock engine |
| `Views.swift` | Design system, `HomeView`, `DescriptiveInterviewView`, `SettingsSheet` |
| `MCQTestView.swift` / `MCQCardView.swift` | Mode A screens, flag button, correction sheet |
| `AdminDashboardView.swift` | Ledger triage |
| `SpeechSynthesizerService.swift` | `AVSpeechSynthesizer` output |
| `StreakStackApp.swift` | Entry point, `ModelContainer`, first-launch seeding |

## Verification

| Behaviour | How it was checked |
| --- | --- |
| JSON schema encoding, MCQ/evaluation decoding | Standalone `swiftc` harness printing real request JSON |
| Streak arithmetic (same day / +1 / gap / display decay) | Same harness |
| Corpus size and section composition | Same harness — 7 sections, 4,301 tokens |
| Cached vs uncached request shape, cache reuse, create failure, stale-cache recovery | Stubbed `URLSession` (`URLProtocol`), 6 scenarios asserting request JSON |
| First-launch seeding, version re-seed, ledger rendering | Simulator run, ledger dumped to console |
| Ledger mode isolation (MCQ flags absent from interview prompt) | Simulator run, asserted 0 matches |
| Home / MCQ deck / results / correction sheet / interview / dashboard UI | Simulator screenshots |

**Not verified:** any live call to Gemini. No API key was available during
development, so every request path is stub- or simulator-checked only. The first
real session is the true test — start with Mode A, it is the simplest round trip.

## Known gaps

1. **No live API run.** Highest-value next step: add a key in Settings and run
   both modes once.
2. **No test target.** All checks so far are throwaway harnesses. `StreakEngine`,
   `JSONSchema`, `TokenEstimator` and `CorrectionLedger.render` are pure and would
   be trivial to cover with XCTest/Swift Testing.
3. **API key in `UserDefaults`.** Fine for personal use; move to the Keychain (or
   proxy through a backend) before this goes anywhere near the App Store.
4. **Rule re-seed overwrites hand edits.** Bumping `DefaultRules.version` replaces
   seeded rules wholesale, including text edited in the dashboard. An
   `isUserEdited` flag skipped during re-seed would fix it.
5. **MCQ flag state is session-scoped.** `MCQQuestion.id` is generated per fetch,
   so a flagged card reads unflagged in a later session. Harmless today (questions
   are freshly generated anyway); would need a content hash to persist.
6. **Prompt cost is corpus-dominated.** ~4.4k stable tokens per call. Explicit
   caching should absorb most of it — worth confirming against real
   `usageMetadata.cachedContentTokenCount` on the first live run.
7. **No accessibility audit.** Labels exist on controls; Dynamic Type at the
   largest sizes and VoiceOver navigation are untested.
8. **No iPad or landscape pass.** Layouts assume iPhone portrait.

## Before pushing publicly

- [x] No key material anywhere in the tree (scanned for `AIza…`, `sk-…`, PEM blocks)
- [x] `.gitignore` covers `xcuserdata/`, `DerivedData/`, `.DS_Store`, and secret files
- [x] Key resolution is runtime-only — nothing committed
- [ ] `git init` and first commit (not done — your call)

The three key-resolution paths are UserDefaults (runtime), an Info.plist
`GEMINI_API_KEY` entry, and a `GEMINI_API_KEY` environment variable. None is
populated in this repo. If you ever add an xcconfig for it, name it
`Secrets.xcconfig` — `.gitignore` already excludes that.
