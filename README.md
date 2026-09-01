# PrepPulse

An AI mock-interviewer for AI Engineer screens. SwiftUI (iOS 17+), MVVM, async/await,
Google Gemini over plain `URLSession` — no third-party dependencies.

## Running it

1. Get a key at [aistudio.google.com](https://aistudio.google.com).
2. Launch the app → **Settings** (slider icon) → paste the key.

The key resolves in this order: entered in-app (`UserDefaults`) → `GEMINI_API_KEY`
in `Info.plist` → `GEMINI_API_KEY` environment variable. For anything shipping,
move it to the Keychain or proxy through your own backend.

## Files

| File | Contains |
| --- | --- |
| `Models.swift` | `Message`, `MCQQuestion`, `DescriptiveEvaluation`, `StreakEngine`, the `JSONSchema` builder and every Gemini REST payload |
| `GeminiJSONService.swift` | The API client: constrained JSON output, sliding window, context caching, correction ledger, retries |
| `FeedbackLog.swift` | SwiftData `@Model` for rules and rated evaluations, `DefaultRules`, ledger rendering, `CorrectionLedgerStore` (`@ModelActor`) |
| `ViewModels.swift` | `StreakStore`, `FeedbackLogStore`, `Preferences`, `MCQViewModel`, `DescriptiveInterviewViewModel`, `MockGeminiEngine` |
| `Views.swift` | Pastel design system, `HomeView`, `DescriptiveInterviewView`, `SettingsSheet` |
| `MCQTestView.swift` | Mode A screen: loading, swipe deck, summary with per-question flags |
| `MCQCardView.swift` | `MCQCardView`, `MCQResultCard` (flag button), `MCQCorrectionSheet` |
| `PreTrainingMaterials.swift` | `TrainingCorpus` — benchmark reference prepended to every system instruction |
| `AdminDashboardView.swift` | Admin list over standing rules and flagged logs, with triage and detail editing |
| `SpeechSynthesizerService.swift` | `AVSpeechSynthesizer` read-aloud |

## Modes

**Rapid MCQ** — one call returns five questions as strict JSON
(`responseMimeType: "application/json"` + a `responseSchema` pinning five items,
four options each). Swipeable card deck, instant explanations, score ring.

**Live interview** — every turn returns
`{"score_out_of_5": Int, "feedback": String, "next_question": String}` under a
response schema, rendered as pastel stars above the critique. Answers are typed
or dictated with the keyboard's mic key.

## Prompt composition

Every call in either mode is assembled in the same order, cacheable material first:

```
<TrainingCorpus>   ← benchmark standard, byte-stable  (~4,300 tokens)  ┐ cached
persona            ← interviewer or examiner, byte-stable              ┘
<CorrectionLedger> / <MCQCorrectionLedger>   ← volatile
session notes      ← volatile (Mode B only)
```

The cached half rides in `systemInstruction`; the volatile half is appended to it.
When explicit caching is active the split becomes physical: the cached half is
referenced by `cachedContent` and the request sends **no** `systemInstruction` at
all (the API rejects setting both), so the volatile half moves to the front of the
first user turn in `contents`. Same text reaches the model either way.

`TrainingCorpus` is seven sections, ~4,300 tokens total, paid on every call in both modes:

| Section | ≈ tokens |
| --- | --- |
| Model Context Protocol | 477 |
| RLHF / RL environment design | 507 |
| AI engineering fundamentals | 480 |
| Advanced agentic architectures & multi-agent patterns | 717 |
| Real-world agentic use cases & domain workflows | 618 |
| Evaluation, observability & benchmarking (LLMOps) | 663 |
| High-performance LLM infrastructure & deployment | 635 |

Both modes grade against it, so questions are written to the same standard the answers are
judged by. `TrainingCorpus.sections` is a plain array — drop an entry to trim the corpus, or
pass a subset to `TrainingCorpus.render(_:)`.
`GeminiJSONService.debugSystemInstructions()` (DEBUG only) dumps the assembled prompts.

## Cost control

- **Sliding window** — only the last 5–7 turns are sent verbatim; older turns are
  folded into a ≤120-word summary. Prompt size stays flat as the interview grows.
- **`thinkingBudget: 0`** — no Gemini 2.5 reasoning tokens for short structured replies.
- **Capped output** — 400 tokens for an evaluation, 1,600 for a question set.
- **Explicit context caching** — ON by default (`Configuration.useExplicitCaching`).
  The stable prefix (corpus + persona, ~4.4k tokens) is uploaded once to
  `cachedContents` and later calls reference it by name instead of re-sending it.
  **One cache per role**, since interview and MCQ share the corpus but not the
  persona. Caches are created lazily, refreshed on expiry (`cacheTTLSeconds`,
  default 30 min), and every failure falls back to sending the prefix inline —
  a cache problem costs money, never a broken call.
- **Stable prefix** — the corpus and persona are byte-identical across calls, so
  implicit caching can hit even with explicit caching disabled.

## Correction ledger

Two kinds of `FeedbackLog` feed one `<CorrectionLedger>` block, appended to the
system instructions after the cacheable persona prefix (so caching still works):

- **Standing rules** (`kind: .rule`) — five foundational guardrails (two culture /
  constraint rules and three star anchors) seeded into SwiftData by
  `PrepPulseApp.seedDefaultRulesIfNeeded`, which runs a `fetchCount` on
  `FeedbackLog` before the container is returned and inserts + saves when the store
  is empty. `DefaultRules.version` also re-seeds installs that were seeded from an
  older rule set — bump it whenever `DefaultRules.all` changes. Rules render as
  directives and are **never limited**, so recent flags can't crowd out a guardrail.
- **Flagged evaluations** (`kind: .evaluation`, `mode: .interview`) — thumbs-down during an
  interview. The **5 most recent unresolved** ones render as case notes.
- **Flagged MCQs** (`kind: .evaluation`, `mode: .mcq`) — the flag on a summary card opens a
  correction sheet; what you type is saved and the **5 most recent** are replayed to the
  question generator in a separate `<MCQCorrectionLedger>`. The two ledgers are scoped by
  mode, so MCQ flags never reach the interviewer's prompt and vice versa.

`CorrectionLedgerStore` is a `@ModelActor`, so the fetch on every API call never
touches the UI context. Resolving or deleting an item in the admin dashboard drops
it from the next prompt; editing a rule's directive there changes it verbatim.
Clearing your ratings leaves the rules in place — wiping guardrails is a deliberate
act in the dashboard.

## Streaks

`StreakEngine` is pure date arithmetic (same day → no-op, +1 day → extend,
gap → restart at 1), persisted through `@AppStorage`. A run stays lit through the
day after the last session, then displays zero without rewriting storage.
