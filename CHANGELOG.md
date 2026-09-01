# Changelog

All notable changes to PrepPulse. Loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Nothing is released or tagged yet — everything below is unreleased work on `main`.
Dates are when the change landed locally.

---

## [Unreleased]

### Explicit context caching — 2026-09-02

**Added**
- `Configuration.useExplicitCaching` now defaults to **on**. The stable prompt
  prefix (`TrainingCorpus` + persona, ~4.4k tokens) is uploaded once to Gemini's
  `cachedContents` endpoint; later calls reference it by name instead of
  re-sending it.
- **One cache per prompt role.** Interview and MCQ share the corpus but not the
  persona, so `PromptRole.interview` and `.mcq` each get their own entry — a
  single cache would hand the question generator the interviewer's instructions.
- Caches are created lazily, refreshed 30s before expiry (`cacheTTLSeconds`,
  default 1800), and every failure degrades to the uncached path.
- One-shot recovery: a 4xx on a cached call invalidates that cache and retries
  the same request inline, so an expired cache never surfaces as an error.

**Fixed**
- **Latent 400.** `openingQuestion()` and `evaluate()` were sending both
  `systemInstruction` and `cachedContent`; Gemini rejects that combination. The
  request shape is now split by path — when a cache is used, `systemInstruction`
  is omitted and the volatile half (ledgers, session notes) moves to the front of
  the first user turn in `contents`. Identical text reaches the model either way.
- `Prompts.mcqRequest` was a `static let`, freezing its variety seed for the whole
  process — every "New set" in a session sent an identical prompt. Now computed.

**Verified** — six scenarios against a stubbed `URLSession`, asserting on real
request JSON: Mode A cached, Mode B cached (distinct prefix sizes confirm separate
caches), cache reuse on a second call, cache-create rejection, caching disabled,
and a cache that dies mid-session. Not yet exercised against live Gemini.

### TrainingCorpus expanded to seven sections — 2026-09-02

**Added**
- Four new sections in `PreTrainingMaterials.swift`: advanced agentic
  architectures & multi-agent patterns; real-world agentic use cases & domain
  workflows; evaluation, observability & benchmarking (LLMOps); high-performance
  LLM infrastructure & deployment.
- `TrainingCorpus.sections` is now a `[Section]` array with `render(_:)`, so the
  corpus can be trimmed or a subset composed without editing prose.

**Changed**
- Corpus grew from ~1,618 to **~4,301 tokens**, paid on every call in both modes.
  This is what made explicit caching worth enabling.

### TrainingCorpus introduced — 2026-09-02

**Added**
- `PreTrainingMaterials.swift` with `TrainingCorpus` covering MCP architecture,
  RLHF environment design, and AI engineering fundamentals.
- Prepended to **both** system instructions, ahead of the persona and ledgers, so
  the interviewer grades and the generator writes against one fixed standard.
- `GeminiJSONService.debugSystemInstructions()` (DEBUG only) dumps the assembled
  prompts for either mode.

### MCQ question flagging — 2026-09-02

**Added**
- Flag button (`flag` → `flag.fill`) on each summary card in Mode A, opening
  `MCQCorrectionSheet`: the question, its options with key and your pick marked,
  the answer key, and a text editor asking what was wrong or ambiguous.
- Submissions save a `FeedbackLog` (`mode: .mcq`) and the 5 most recent are
  replayed to the generator as `<MCQCorrectionLedger>`.
- Re-tapping a flagged card reopens the sheet pre-filled, so a correction can be
  edited rather than the button being inert.

**Changed**
- MCQ views split out of `Views.swift` into `MCQTestView.swift` and
  `MCQCardView.swift`.
- **Both ledger fetches are now scoped by mode.** Without this, MCQ flags would
  have leaked into the interviewer's `<CorrectionLedger>` and crowded out real
  evaluations.

### App icon — 2026-09-02

**Added**
- `AppIcon.png` and `AppIcon-Dark.png` (1024×1024, opaque) generated from
  `icon.png`: upscaled from 512, alpha flattened onto the app's canvas colours,
  and inset 6% so nothing sits under iOS's corner mask.

### Foundational rule seeding — 2026-09-01 → 02

**Added**
- `DefaultRules` seeded into SwiftData on first launch by
  `PrepPulseApp.seedDefaultRulesIfNeeded`, which runs a `fetchCount` on
  `FeedbackLog` before the container is returned and inserts + saves when empty.
- `DefaultRules.version` re-seeds installs that were seeded from an older rule
  set. Without it, an existing install would never see updated rules — the
  store is not empty, so a plain `count == 0` check never fires.
- Rule set v2 (current): Culture, Constraint, and 5/3/1-star anchors.
  v1 (superseded) was Culture, Constraint, MCP strictness, simplification.

**Changed**
- `FeedbackLog` gained `kind` (`.evaluation` / `.rule`); rules render as
  directives and are never limited by the 5-item ledger cap.
- "Clear AI ratings" deletes only evaluations, leaving guardrails in place.

### SwiftData feedback log & correction ledger — 2026-09-01

**Added**
- `FeedbackLog` `@Model` plus `CorrectionLedgerStore`, a `@ModelActor` so ledger
  fetches never touch the UI context.
- `AdminDashboardView`: triage over standing rules and flagged evaluations, with
  resolve/reopen, delete, editable notes, and an "in prompt" badge showing exactly
  what the next call will carry.
- Thumbs-up/down under every interviewer evaluation, persisted per turn.

### Two-mode restructure & pastel design system — 2026-09-01

**Added**
- Mode A (Rapid MCQ): five questions in one constrained-JSON call, swipeable card
  deck, instant explanations, score ring.
- Mode B (Live interview): every turn returns
  `{score_out_of_5, feedback, next_question}` under a response schema, rendered as
  pastel stars above the critique.
- `JSONSchema` builder emitting Gemini's OpenAPI subset with `propertyOrdering`.
- Pastel design system (SF Rounded, adaptive light/dark tokens, soft cards).

**Fixed**
- API-key gate moved from the view model to `GeminiEngine.requiresAPIKey`. It was
  blocking injected engines, so previews and tests could never start a session.
- Evaluation call merged its grading instruction into the candidate's own turn
  rather than emitting two consecutive `user` contents.

### Initial build — 2026-09-01

**Added**
- SwiftUI app targeting iOS 17+, MVVM, async/await, Gemini over plain
  `URLSession` with no third-party dependencies.
- Sliding window over the last 5–7 turns with older turns folded into a ≤120-word
  summary, `thinkingBudget: 0`, capped output.
- `@AppStorage`-backed streak engine with pure date arithmetic.
- `AVSpeechSynthesizer` read-aloud; dictation via the system keyboard's mic key.
