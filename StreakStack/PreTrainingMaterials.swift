//
//  PreTrainingMaterials.swift
//  PrepPulse
//
//  Benchmark reference material prepended to every system instruction, so both
//  the interviewer and the question generator work against a fixed technical
//  standard instead of whatever the model happens to recall.
//
//  Placement matters: this block goes FIRST and is byte-stable across calls, so
//  it sits inside the cacheable prompt prefix. See `GeminiJSONService`.
//
//  It is also the single largest prompt cost in the app — every section is paid
//  on every call. `sections` is a plain array so you can drop one, and
//  `render(_:)` builds a corpus from any subset.
//

import Foundation

nonisolated enum TrainingCorpus {

    struct Section: Identifiable, Sendable {
        /// Short key, so a subset can be selected in code without matching titles.
        let id: String
        let title: String
        let body: String
    }

    // MARK: - Model Context Protocol

    static let modelContextProtocol = """
    Wire format: JSON-RPC 2.0 request/response/notification. Architecture is host \
    application → one MCP client per connection → MCP server. Sessions are stateful and \
    open with an `initialize` handshake that negotiates protocol version and capabilities; \
    servers emit `*/list_changed` notifications when their surface changes at runtime.

    Transports. stdio: the server runs as a child process, newline-delimited JSON-RPC over \
    stdin/stdout, no network auth because the trust boundary is the process — the default \
    for local servers. Streamable HTTP (superseding the older HTTP+SSE transport): client \
    POSTs JSON-RPC to a single endpoint, the server may reply with a plain JSON body or \
    upgrade to a Server-Sent Events stream for progress, partial results and \
    server-initiated messages. Remote transports require auth, Origin validation, and \
    binding to localhost for local servers, or they are trivially exploitable via DNS \
    rebinding.

    Primitives. Tools are model-invoked functions with JSON Schema inputs — the model \
    decides when to call them. Resources are application-controlled, URI-addressed, \
    read-only context the host chooses to attach. Prompts are user-initiated templates. \
    Server-side counterparts: sampling (the server asks the host to run an LLM completion, \
    so servers stay model-agnostic), roots (the host tells the server which filesystem or \
    URI scopes it may touch), and elicitation (the server requests structured user input).

    The distinction that matters: an MCP server is NOT a REST wrapper. REST is stateless, \
    fixed at the OpenAPI contract, and human-integrated at build time. MCP is a stateful \
    session with runtime capability discovery, bidirectional notifications, host-mediated \
    sampling, and schemas written for a model rather than a developer. A candidate who \
    describes MCP as "just an API wrapper with a manifest" has missed discovery, session \
    lifecycle, and the sampling inversion of control.
    """

    // MARK: - RLHF environment design

    static let rlhfEnvironmentDesign = """
    Deterministic verification is the first principle: the reward must be computable by \
    code, not vibes. Prefer unit tests, exact state assertions, parser round-trips, and \
    checksum comparisons over LLM-judge scoring. Where a judge is unavoidable, calibrate it \
    against human labels, report agreement, and pin the judge model and prompt — an \
    uncalibrated judge silently rewrites the objective. Every source of non-determinism \
    (wall-clock time, network, dict/set ordering, unseeded RNG, concurrency) must be seeded \
    or stubbed, or the same trajectory scores differently on replay.

    Golden reference solutions serve three purposes: they prove the task is solvable at all, \
    they set the difficulty ceiling, and they anchor partial-credit rubrics. An environment \
    without a golden trajectory is unvalidated — you cannot distinguish "the model is weak" \
    from "the task is impossible or the grader is broken". Track solve rate across a model \
    ladder: an environment every model solves or none solves carries no gradient signal.

    Multi-turn agentic tasks add credit assignment. Decide deliberately between terminal \
    reward (clean objective, sparse signal) and per-step shaping (dense signal, invites \
    reward hacking on the shaped proxy). State must reset idempotently between episodes, \
    tool failures should be injected on purpose rather than left to chance, and step and \
    wall-clock budgets need explicit timeouts or a looping agent burns the episode.

    Edge cases that break environments in practice: degenerate solutions that satisfy the \
    grader without doing the task (writing to the test file, catching and swallowing the \
    assertion); unreachable states created by a bad reset; flaky graders that fail on \
    formatting rather than substance; partial completion with no defined score; ties and \
    ambiguous success criteria; and answer leakage where the prompt, filesystem, or error \
    message contains the solution. Audit by running the golden solution, an empty solution, \
    and a deliberately cheating solution — all three should score exactly as expected.
    """

    // MARK: - AI engineering fundamentals

    static let aiEngineeringFundamentals = """
    Quantization. Decode is memory-bandwidth bound, so shrinking weights buys throughput, \
    not just footprint. Post-training weight-only methods (GPTQ, AWQ) at int8/int4 are the \
    default; activation quantization is harder because of outlier channels (hence SmoothQuant \
    and per-channel/group scales). QAT costs a training run and is reserved for aggressive \
    bit widths. KV-cache quantization is often the larger win at long context, since the \
    cache, not the weights, dominates memory. Always report the accuracy delta on a task \
    metric, not perplexity alone.

    Latency. Separate prefill (compute-bound, parallel over prompt tokens, sets TTFT) from \
    decode (bandwidth-bound, sequential, sets inter-token latency). Levers: continuous / \
    in-flight batching to keep the GPU fed, paged attention to stop KV fragmentation, prefix \
    and prompt caching for a stable system prompt, speculative decoding to trade compute for \
    steps, and streaming to cut perceived latency without changing total time. Budget in p50 \
    and p95 separately — tail latency is usually queueing, not model speed — and remember \
    every extra prompt token is paid on every call.

    Vector embeddings and retrieval. Dense embeddings capture semantics but miss exact terms; \
    sparse/BM25 catches identifiers and rare tokens. Hybrid retrieval fused with reciprocal \
    rank fusion beats either alone on most corpora. Normalize vectors so cosine and dot \
    product agree. ANN indexes trade recall for speed (HNSW: M and efSearch; IVF-PQ: nlist, \
    nprobe and quantization loss) — measure recall@k against exact search before shipping. \
    Chunking with overlap governs whether the answer survives a boundary; a cross-encoder \
    re-ranker over the top 50 usually beats any embedding upgrade. Evaluate retrieval \
    separately from generation (recall@k, nDCG, MRR) or you cannot tell which half is wrong, \
    and re-embed the whole corpus when the model changes — mixed embedding spaces are silently \
    broken.
    """

    // MARK: - Agentic architectures

    static let agenticArchitectures = """
    Start from the workflow/agent distinction. A workflow is a fixed DAG of model calls and \
    tool calls the engineer wired up; an agent decides its own control flow at runtime. \
    Workflows are cheaper, testable and debuggable — reach for an agent only when the set of \
    steps genuinely cannot be enumerated in advance. Most "we need multi-agent" problems are \
    one under-specified single agent with bad tools.

    Core single-agent loop: model observes state, selects a tool, receives an observation, \
    repeats until a termination condition. Everything hard lives in that loop — tool schema \
    design (names and descriptions are prompt surface, not documentation), observation \
    formatting, error text the model can actually act on, and an explicit stop condition. \
    Bound it with a step budget, a wall-clock budget and a token budget.

    Multi-agent patterns. Prompt chaining (sequential decomposition with checkable \
    intermediates); routing (a classifier dispatches to specialized handlers, keeping each \
    prompt narrow); parallel fan-out with an aggregator (map-reduce for independent subtasks, \
    or n-way sampling for voting); orchestrator-worker (a planner spawns subagents for \
    subtasks it discovers at runtime and merges their results); evaluator-optimizer (a \
    generator/critic loop with an explicit accept criterion, effective only when the critique \
    signal is better than the generation); hierarchical supervisors for deep task trees.

    Subagent-as-tool vs handoff. Subagent-as-tool keeps one context owner: the parent calls \
    the child like a function and receives a compressed result, so the parent's window holds \
    conclusions rather than transcripts. A handoff transfers control and context ownership \
    outright — simpler for a linear pipeline, but the originating agent loses visibility. \
    Pass structured messages between agents, not free prose.

    Context engineering is the real constraint. Each subagent gets its own window, which is \
    why fan-out scales at all; the parent must receive summaries, not raw history. Watch for \
    context rot on long horizons, poisoning where one hallucination is quoted downstream as \
    fact, and distraction as the window fills. Compaction, scratchpad files and externalized \
    memory (episodic notes, semantic/vector recall) exist to keep the working set small.

    Failure modes to name in an interview: unbounded loops on a failing tool; cascading \
    hallucination where an early wrong fact is laundered through three agents into confident \
    output; cost blowup (n agents × k turns is multiplicative, and parallel research agents \
    routinely burn 10-15× a single chat); duplicated work from overlapping subtask \
    decomposition; conflicting writes to shared state; and swallowed errors, where a subagent \
    reports success on a failed step. Guardrails: tool allowlists per agent, idempotent tools \
    with retries, human approval gates on irreversible actions, and full trajectory tracing.
    """

    // MARK: - Applied agentic workflows

    static let agenticUseCases = """
    The unit of value is a completed task, not a good message. Every serious deployment is \
    designed around three things: the verification loop that proves the work is right, the \
    escalation path when it is not, and the reversibility of any action the agent can take.

    Coding agents. Repo-scale context via search rather than stuffing files; the test suite is \
    the reward signal, so the loop is edit → run tests → read failure → repeat. Patches, not \
    whole-file rewrites. Review gates before merge, sandboxed execution, and an explicit \
    budget or the agent thrashes on a flaky test.

    Customer support. Retrieval over policy documents plus real tool actions (order lookup, \
    refund, cancellation). The design questions are deflection vs escalation thresholds, \
    which actions require confirmation, how PII is redacted before it reaches the model, and \
    what the audit trail records. KPI is resolution rate and cost per resolved ticket, not \
    response quality ratings.

    Research and deep research. Query decomposition into independent subquestions, parallel \
    search subagents, source triangulation, and explicit contradiction handling. Every claim \
    carries a citation, and unresolved conflicts surface rather than being averaged away. \
    This is the canonical read-heavy fan-out case: parallelism helps because subagents each \
    get a fresh window.

    Data and analytics. Text-to-SQL is a retrieval problem first — fetch the relevant schema \
    and business definitions, then generate. Validate with a dry run or EXPLAIN before \
    execution, enforce row and cost limits, and prefer a semantic layer over raw table access \
    so joins and metric definitions are not re-derived per query.

    Document and back-office workflows. Schema-constrained extraction, confidence thresholds, \
    and a human review queue for anything below them. The metric is straight-through \
    processing rate — the share of documents completed with no human touch — measured \
    alongside the error rate of what went straight through.

    Browser and computer use. Accessibility tree or DOM beats raw screenshots where available; \
    every action needs post-hoc verification because clicks silently no-op; expect flakiness, \
    rate limits and anti-automation defenses, and design for resumability rather than long \
    unattended runs.

    Across all of them, measure task success rate, human intervention rate, cost per completed \
    task, and time to resolution. A demo that looks good on ten happy-path examples tells you \
    nothing about the hundredth adversarial one.
    """

    // MARK: - Evaluation, observability and benchmarking

    static let llmOps = """
    Evals are the test suite of an LLM system, and the discipline is the same: cheap \
    deterministic checks first, expensive holistic ones last. Layer them — assertion-level \
    checks (JSON schema validity, required fields, no PII, latency and cost ceilings), \
    task-level end-to-end evals on a curated set, and online production metrics.

    Datasets. Build the golden set from real traffic, stratified by failure mode rather than \
    sampled uniformly — twenty examples that each break the system differently beat a thousand \
    that all pass. Version the dataset alongside the prompt, hold out a slice you never tune \
    on, and check for contamination before trusting any public benchmark number. Public \
    leaderboards saturate and leak; domain evals are the only ones that predict production.

    Graders. Deterministic wherever the task allows: exact match, schema validation, unit \
    tests, SQL result-set equivalence, compiler success. LLM-as-judge is a fallback, not a \
    default — it needs a written rubric, calibration against human labels with a reported \
    agreement statistic, and mitigation for known biases (position bias, verbosity bias, \
    self-preference). Pairwise comparison is more reliable than absolute scoring; randomize \
    order.

    What to measure, by system type. RAG: retrieval (recall@k, nDCG, MRR) strictly separated \
    from generation (groundedness/faithfulness, answer relevance, citation precision) — \
    combine them and you cannot tell which half regressed. Agents: task success rate, tool-call \
    precision and recall, trajectory quality, steps to completion, cost and latency per task. \
    Classification/extraction: per-class precision and recall, not accuracy on an imbalanced set.

    Regression and release. Treat prompts and model versions as versioned artifacts; run the \
    eval suite in CI on every change; block on a regression the way you would on a failing \
    test. Ship behind canary or shadow deploys, A/B with guardrail metrics, and keep the \
    rollback one config change away. A model upgrade is a breaking change until the evals say \
    otherwise.

    Observability. Trace everything: a span per LLM call, tool call and retrieval, carrying \
    prompt version, model id, parameters, token counts, latency and cost. Sample and persist \
    full trajectories, not just inputs and outputs, or agent failures are undebuggable. \
    Redact PII at the boundary. OpenTelemetry's GenAI semantic conventions give you a vendor- \
    neutral schema.

    Close the loop. Production signals — thumbs, retries, abandonment, escalation to a human, \
    user corrections — are the cheapest source of new eval cases. A flagged failure should end \
    up in the golden set, and the fix should be a test that would have caught it.
    """

    // MARK: - Serving infrastructure

    static let servingInfrastructure = """
    Memory math first, because it decides everything else. Weights ≈ parameters × bytes per \
    parameter. KV cache ≈ 2 × layers × kv_heads × head_dim × bytes × sequence length × batch \
    size — linear in both context and concurrency, which is why long-context serving is a \
    memory problem, not a compute one. GQA/MQA and MLA shrink kv_heads; KV quantization \
    shrinks bytes. Whatever is left over from weights is your concurrency budget.

    Serving stacks. vLLM, TensorRT-LLM and SGLang all converge on the same primitives: \
    continuous (in-flight) batching so finished sequences leave the batch immediately, \
    PagedAttention so the KV cache is not fragmented by variable lengths, chunked prefill so a \
    long prompt does not stall every decode in flight, and prefix/radix caching so a shared \
    system prompt is computed once. Prefill/decode disaggregation splits the two phases onto \
    separate pools because one is compute-bound and the other bandwidth-bound.

    Parallelism. Tensor parallel splits each layer across GPUs and is chatty — keep it inside \
    a node on NVLink. Pipeline parallel splits layers across nodes and introduces bubbles that \
    only large batches hide. Expert parallel applies to MoE, where routing imbalance is the \
    failure mode. Data-parallel replicas scale throughput, not model size. The usual answer is \
    TP within a node, PP across nodes, replicas for load.

    Deployment. GPU cold starts are dominated by pulling weights, so keep a warm pool, stream \
    weights from local NVMe or a fast object store, and consider process snapshotting. \
    Autoscale on queue depth and time-to-first-token, never on CPU utilization. Route \
    intelligently: cascade from a small model and escalate on low confidence, cache \
    semantically identical requests, prioritize interactive traffic over batch, and apply \
    admission control with backpressure instead of letting the queue grow unbounded.

    Reliability and cost. Structured retries with jitter, circuit breakers, provider failover, \
    timeouts tied to a token budget rather than a fixed wall clock, and graceful degradation to \
    a smaller model before failing outright. The unit economic is tokens per second per GPU; \
    the biggest wins are usually a smaller model for the task, a shorter prompt, and a cache \
    hit — not a faster GPU. Use batch APIs and preemptible capacity for anything offline.

    SLOs. Specify time-to-first-token and inter-token latency separately, at p50, p95 and p99. \
    Throughput and latency are the same dial turned in opposite directions: batch size. State \
    which one you are optimizing before you tune anything.
    """

    // MARK: - Assembly

    /// Ordered, and each one is prompt cost on every call. Drop an entry here to
    /// trim the corpus, or pass a subset to `render(_:)`.
    static let sections: [Section] = [
        Section(id: "mcp",
                title: "MODEL CONTEXT PROTOCOL (MCP)",
                body: modelContextProtocol),
        Section(id: "rlhf",
                title: "RLHF / RL ENVIRONMENT DESIGN",
                body: rlhfEnvironmentDesign),
        Section(id: "fundamentals",
                title: "AI ENGINEERING FUNDAMENTALS",
                body: aiEngineeringFundamentals),
        Section(id: "agentic-architecture",
                title: "ADVANCED AGENTIC ARCHITECTURES & MULTI-AGENT PATTERNS",
                body: agenticArchitectures),
        Section(id: "agentic-use-cases",
                title: "REAL-WORLD AGENTIC USE CASES & DOMAIN WORKFLOWS",
                body: agenticUseCases),
        Section(id: "llmops",
                title: "EVALUATION, OBSERVABILITY & BENCHMARKING (LLMOps)",
                body: llmOps),
        Section(id: "infrastructure",
                title: "HIGH-PERFORMANCE LLM INFRASTRUCTURE & DEPLOYMENT",
                body: servingInfrastructure)
    ]

    private static let preamble = """
    The following is the benchmark technical standard for this session. Treat it as ground \
    truth. Evaluate every answer strictly against these frameworks: an answer that \
    contradicts this material is wrong, and an answer that restates it without applying it \
    to the candidate's own system is shallow. Do not quote or recite this material at the \
    candidate, and do not turn it into a checklist to read out — use it to know what a \
    complete answer looks like and where the candidate's answer falls short.
    """

    /// The full corpus, wrapped so the model can refer to it as a named source.
    static let all = render(sections)

    static func render(_ selected: [Section]) -> String {
        let body = selected
            .map { "\($0.title)\n\($0.body)" }
            .joined(separator: "\n\n")

        return """
        <TrainingCorpus>
        \(preamble)

        \(body)
        </TrainingCorpus>
        """
    }

    /// Rough token cost of the block, for the cost readout and cache planning.
    static var estimatedTokens: Int { TokenEstimator.estimate(all) }
}
