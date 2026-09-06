# Arnes — Design

*Arnés* (Spanish: **harness**). A model-adaptive coding agent and embeddable Swift library
for OpenRouter, LiteLLM, and OpenAI-compatible providers.

This document describes the v0.7.0 source on `main`. See the [README](README.md) for
installation and the distinction between current source and published releases.

## Thesis

Model choice affects more than an API identifier: models differ in wire format, reasoning
state, supported parameters, and how they use tools. Arnes makes those differences explicit
through provider traits, model manifests, and family prompt packs. Other coding agents also
adapt to multiple models; Arnes's focus is making that behavior inspectable and evaluating
its quality and cost, while keeping the same loop embeddable without a UI.

## The four pillars

1. **Dialect-native transport.** Speak each model's home format via OpenRouterSwift:
   `/messages` for Anthropic, `/responses` for OpenAI, `/chat/completions` for everyone else.
   Preserve each dialect's reasoning state across tool calls, with a chat fallback when a
   native endpoint is unavailable before output starts.
   *Status: shipped. `Session` executes `/messages` and `/responses` natively (chosen per
   family, forced with `--dialect`), history stays chat-shaped and is translated per request,
   and reasoning state round-trips both ways — signed `thinking` blocks on `/messages`,
   encrypted reasoning items on `/responses`, `reasoning_details` on chat — carried on the
   assistant message and replayed on the next request of a tool loop (R1).*

2. **Runtime capability manifest.** `ModelProfile`/`ModelCatalog` read OpenRouter's live
   `GET /models` (supported parameters, context, pricing) — or a LiteLLM/OpenAI-compatible
   provider's manifest — and shape requests from its capabilities, context limits, and prices.
   Family-specific dialect and prompt preferences are defined separately.
   *Conformance is self-checking:* every clean native step records an ok verdict and a
   pre-output compatibility failure falls back to chat mid-turn and is remembered
   (`~/.arnes/dialects.jsonl`; durable incompatibilities expire after 7 days,
   transient verdicts after 15 minutes); `arnes probe <model>` checks a
   model explicitly with one echo-tool round-trip (and `--effort` also checks the reasoning
   round-trip). Profiles are cached per provider under `~/.arnes/models/` for 24 hours by
   default; `arnes models --refresh` refetches them, an unknown model earns one refresh,
   and a stale copy can serve during a fetch failure.

3. **Prompt packs per family.** A family-independent core prompt plus per-family adapter
   markdown (`PromptPack`). User-overridable at `~/.arnes/packs/<family>.md` so tuning needs
   no recompile. Packs are the *tunable* half of Arnes and evolve via the eval loops below.
   The pack also owns the *delegation* guidance — when to hand work to a subagent and how to
   brief one — as a `# Delegation` section the session renders only while the `task` tool is
   in the toolset (base text + an optional per-family lean; an override file's `## Delegation`
   section replaces it). Orchestration prose is tuning: the same words damp a model that
   over-delegates and nudge one that never does, so it is not hardcoded in the tool.

4. **Few tools, simple schemas.** File and shell tools, `update_plan`, `think`, `ask_user`,
   and `job`, plus `skill`, `task`, and MCP tools when available. `view_image` requires
   vision support; `web_fetch` requires configuration and a network-allowing sandbox posture.
   With adaptive thinking enabled (the default), a reasoning-capable model with an active
   effort dial is not offered `think`. Tool additions and prompt changes are evaluated on
   smaller models as well as frontier models.

## The three evaluation loops

- **Loop 1 — inline verification (shipped, v0):** after a run, a different (cheaper) model
  adversarially judges "was this task plausibly completed?" (`--verify` flag). Verdict lands
  in the run record.
- **Loop 2 — parallel panel (shipped):** `arnes do --panel N` fans the task to N models in
  isolated snapshots, a judge model picks the winner from reports + diffs, the winner's changes
  sync back, and every candidate lands as a labeled eval row. Policy triggers shipped as
  `arnes do --verify X --yes --panel-on-fail N` (P2, batch 15; `policies.panelOnVerifierFail` for
  the default): a verifier FAIL re-runs the task as a panel over a snapshot of the tree as it was
  before the run, the winner is applied and re-verified, and the final verdict decides the exit code.
- **Loop 3 — measured improvement (partly implemented):** labeled A/B runs, prompt-pack
  overrides, eval-history comparisons, and regression gates exist today. Automatic
  scoreboard-driven routing and automatic pack proposals remain planned. Pack changes
  require a diff and an A/B evaluation on a frozen task set, merged by a human.

**Shared substrate:** `RunRecord` (task, model, dialect, pack, steps, tool calls, cost from
`usage.cost`, verifier verdict) appended to `~/.arnes/runs.jsonl` after every run. Recording
adds no model request; optional verification and judging do. `arnes runs` renders the
scoreboard, and gateway costs are identified as estimates when the provider does not price responses.

## Router-native primitives used

- `models` fallback arrays on every request (reliability)
- `usage.cost` on every response → live budgets, cost-per-task reporting
- `openrouter/auto` as the default model; provider preferences and ZDR as user policy (later)
- `session_id` sticky routing (later)

**Other routers.** The loop is OpenAI-compatible at the wire level, so it also runs
against a LiteLLM gateway or a plain OpenAI-compatible endpoint (`~/.arnes/config.json`
providers). Everything router-specific — manifest source, fallback spelling, whether
cost is reported or must be estimated, whether native dialects exist — is isolated in
`ProviderTraits`; OpenRouterSwift stays the client, pointed at the other root by a
URL-rewriting HTTP client. A LiteLLM *model group* plays the role `openrouter/auto`
plays here: the gateway owns the routing policy, Arnes owns the harness.

## The interactive layer

Arnes is a tool you live in, not just script. `arnes` with no arguments opens a REPL over a
`Session` actor: client-side message history, streamed output, y/n/always permission gating
before mutating tools, Ctrl-C interruption, and crash-safe persistence to
`~/.arnes/sessions/<id>.jsonl` (`--resume <id>` / `--continue`).

Because the history is fully client-side and OpenRouter is stateless, **`/model` swaps the
entire conversation to any model mid-session** — 20 turns into Claude, type
`/model openai/gpt-4o-mini` and the same conversation continues on GPT with full context.
Model switching reuses the saved conversation; content is adapted to the destination's
capabilities, including removal of image parts when switching to a text-only model.
`/cost` (live `usage.cost` totals), `/verify` (loop-1 on the last turn), `/save`, and a
per-turn status line (requested → served model, steps, tools, turn + session cost) round out
the router-native UX. Headless mode stays first-class: `arnes do` runs the same `Session`
loop one-shot — read-only unless `--yes`, since nobody is there to answer the prompts.

## Package layout

```
ArnesKit  (library)   — Dialect, ModelProfile/ModelCatalog (+ fuzzy search), PromptPack,
                        AgentTool + Permission (+ PathScope, PermissionRules, sandbox),
                        StreamAccumulator + the dialect translators/accumulators + ReasoningState,
                        Session (the loop), Agent (headless wrapper), CodingTools, HarnessAssembly,
                        Hooks/HookEngine, Subagents/TaskTool, Skills, MCP, StructuredOutput,
                        Verifier, Review, Eval/EvalGraders, WorkspaceSnapshot, LoopGuard/ToolOutput,
                        SessionStore/TranscriptEntry, RunRecord/RunRecordStore
arnes     (executable) — interactive (default) · chat · do · resume · models · status ·
                        providers · runs · sessions · eval · evals · probe · mcp · skills ·
                        agents · hooks · trust · doctor · debug · review · memory · init
```

Depends on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) (API client;
all three dialects already wrapped there). ArnesKit stays UI-free so native apps can embed it.

## Execution, context, and recovery

The CLI and embedders use the same `Session` actor. It serializes conversation state and
tool results while allowing independent tool work and nested sessions to run concurrently.
Each subagent has its own history, run record, and optional transcript; inherited permissions,
tools, budgets, and depth limits can narrow the parent's authority.

Permission policy and OS containment are separate layers. Interactive mutations normally ask;
headless `do` is read-only unless `--yes`. The `acceptEdits` and `bypass` modes can approve
plain out-of-tree reads, but cannot turn a credential or configured deny-read path into one.
Unattended execution is sandboxed by default where supported (macOS). Linux binaries exist,
but a requested Linux sandbox cannot currently be enforced. Tool-result framing, redaction,
and taint handling add checks around untrusted content; they do not make arbitrary content safe.

Context is managed at two levels. Microcompaction stubs older large tool results in the
request's view of history while preserving the stored transcript. When more room is needed,
automatic or manual compaction summarizes older turns with task state and file notes.
System text and tool definitions remain stable between turn-boundary changes, and supported
providers receive explicit prompt-cache breakpoints. Cached-token usage is recorded.

Before `write_file` or `edit_file`, the harness checkpoints the pre-image. `/rewind` can
restore files and/or conversation history; `/undo` restores the last turn's checkpointed
files. Shell edits and commits are not covered. File-version checks refuse edits based on
unread or stale contents, and an `edits` array changes one file atomically.

Background shell commands belong to a session's job registry and are read or stopped through
`job`. Subprocesses have closed stdin, bounded output, timeouts, environment filtering, and
process-tree cancellation. Per-project memory is a capped, scanned `MEMORY.md` section;
writes through the file tools require sensitive approval.

## Integration boundaries

- **Library:** `ArnesKit` exposes sessions, tools, events, configuration, evaluation, and
  storage without a UI dependency. Services and permission/input delegates are injectable.
- **CLI:** interactive sessions and headless `do` share the loop. JSON result envelopes and
  event streams support scripts; `--output-schema` optionally validates the final answer.
- **Extensions:** skills, scoped project instructions, lifecycle hooks, MCP tools/resources/
  prompts, and configured subagents. Panels deliberately omit MCP to keep candidates isolated.
- **Provider client:** typed API fields belong in OpenRouterSwift. URL rewriting and
  `ProviderTraits` supply gateway-specific behavior in Arnes.
- **Current interfaces:** terminal CLI and Swift library. Desktop/web clients, editor
  extensions, ACP, and built-in LSP support are not implemented.

## Evaluation and evidence

`arnes eval` runs models × tasks × trials in isolated directories. Task check scripts provide
ground truth; rubric and limit graders may further restrict a pass. Optional verifier
judgments are recorded separately. Rubric and eval-verifier spend is recorded in
`graderCostUSD`, apart from the agent's `costUSD`.

The [A/B record](evals/ab/README.md) includes successful changes and proposals that were
not adopted. Adaptive thinking is on by default following the September 3 experiment.
The wider delegation prompt was not adopted: the September 4 follow-up obtained 16 correct
answers with no delegations, showing that those search tasks could be solved by the lead.
A delegation count is not itself a measure of better coding.

The [Terminal-Bench adapter](benchmarks/terminal-bench/README.md) enables external evaluation;
it is not a published score. Existing small-suite results do not establish superiority to
another harness. Comparisons need matched model/provider versions, tasks, environments,
budgets, and repeated trials, with correctness and total cost reported together.

## Remaining work

- **Linux OS containment:** a bwrap/Landlock backend; macOS enforcement is implemented.
- **Scoreboard-driven routing:** use recorded outcomes to propose or select routing defaults.
  Today routing belongs to the provider or explicit user model choices.
- **Automated pack proposals:** generate a reviewable diff and A/B evidence. The override,
  labeling, and evaluation mechanisms already exist; changes still require human review.
- **Panel result integration:** verifier-triggered escalation currently has text output only,
  with no combined JSON envelope or resumed-session support.

The separate `apply_patch` tool is deliberately not implemented: `edit_file` (including
multiple replacements in one file) and `write_file` are the current editing interface.

Implementation history, completed milestones, and per-file details live in
[INSTRUCTIONS.md](INSTRUCTIONS.md#status). Current usage and release availability live in
[README.md](README.md).
