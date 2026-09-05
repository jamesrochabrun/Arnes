# Arnes — Design

*Arnés* (Spanish: **harness**). A model-adaptive agent harness built on OpenRouter.

## Thesis

Every major harness is tuned for one model family; swapping the model under it (Ori,
claude-code-router) leaves the wrong prompts, wrong wire format, and wrong edit idioms in
place. Arnes inverts this: **the model choice drives everything downstream** — wire dialect,
prompt pack, request parameters, edit strategy.

## The four pillars

1. **Dialect-native transport.** Speak each model's home format via OpenRouterSwift:
   `/messages` for Anthropic, `/responses` for OpenAI, `/chat/completions` for everyone else.
   Never cross dialects, never lose reasoning state in translation.
   *Status: shipped. `Session` executes `/messages` and `/responses` natively (chosen per
   family, forced with `--dialect`), history stays chat-shaped and is translated per request,
   and reasoning state round-trips both ways — signed `thinking` blocks on `/messages`,
   encrypted reasoning items on `/responses`, `reasoning_details` on chat — carried on the
   assistant message and replayed on the next request of a tool loop (R1).*

2. **Runtime capability manifest.** `ModelProfile`/`ModelCatalog` read OpenRouter's live
   `GET /models` (supported parameters, context, pricing) — or a LiteLLM/OpenAI-compatible
   provider's manifest — and shape every request from it. Nothing about a model is hardcoded.
   *Conformance is self-checking:* every clean native step records an ok verdict and a
   pre-output native failure falls back to chat mid-turn and is remembered
   (`~/.arnes/dialects.jsonl`, failures expire after 7 days); `arnes probe <model>` checks a
   model explicitly with one echo-tool round-trip (and `--effort` also checks the reasoning
   round-trip). Cached model profiles (the manifest is still fetched per process) are the
   remaining piece.

3. **Prompt packs per family.** A family-independent core prompt plus per-family adapter
   markdown (`PromptPack`). User-overridable at `~/.arnes/packs/<family>.md` so tuning needs
   no recompile. Packs are the *tunable* half of Arnes and evolve via the eval loops below.
   The pack also owns the *delegation* guidance — when to hand work to a subagent and how to
   brief one — as a `# Delegation` section the session renders only while the `task` tool is
   in the toolset (base text + an optional per-family lean; an override file's `## Delegation`
   section replaces it). Orchestration prose is tuning: the same words damp a model that
   over-delegates and nudge one that never does, so it is not hardcoded in the tool.

4. **Few tools, dumb schemas.** `read_file`, `write_file`, `edit_file`, `bash`, `grep`,
   `glob`, `update_plan`, `think`, `ask_user`, plus `skill` and `task` (delegation) when
   available and any MCP server's. Every extra tool or clever schema is where a non-frontier
   model face-plants, so each addition has to be survivable by one.

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
- **Loop 3 — gated self-improvement (later):** the run-record scoreboard automatically tunes
  *routing defaults* ("Swift refactors here: sonnet-5 wins at 1/3 cost") and flags
  regressions. Prompt-pack changes are only ever **proposed** — a diff plus an A/B eval on a
  frozen task set, merged by a human. No ungated self-modification (reward-hacking risk).

**Shared substrate:** `RunRecord` (task, model, dialect, pack, steps, tool calls, cost from
`usage.cost`, verifier verdict) appended to `~/.arnes/runs.jsonl` after every run. Loop 1
populates it for free; loops 2–3 read it. `arnes runs` renders the scoreboard.

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

## The interactive layer (v0.2, shipped)

Arnes is a tool you live in, not just script. `arnes` with no arguments opens a REPL over a
`Session` actor: client-side message history, streamed output, y/n/always permission gating
before mutating tools, Ctrl-C interruption, and crash-safe persistence to
`~/.arnes/sessions/<id>.jsonl` (`--resume <id>` / `--continue`).

Because the history is fully client-side and OpenRouter is stateless, **`/model` swaps the
entire conversation to any model mid-session** — 20 turns into Claude, type
`/model openai/gpt-4o-mini` and the same conversation continues on GPT with full context.
That one command is the identity of the tool: no single-vendor harness can offer it.
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
                        agents · hooks · trust · doctor · debug · review
```

Depends on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) (API client;
all three dialects already wrapped there). ArnesKit stays UI-free so native apps can embed it.

## Harness primitives — evaluation vs. the Anthropic & Codex playbooks

Measured against Anthropic's agent guidance (*Building effective agents*, *Effective context
engineering*, *Writing tools for agents*, the *think* tool, Claude Code) and OpenAI's Codex
CLI, Arnes was already strong on the hard, differentiating parts — **model-adaptive dialects**,
**prompt packs**, **an eval/scoreboard substrate**, **panels (parallelization + judge)**,
**skills / subagents / MCP**, **compaction**, **session persistence**, and — uniquely — the
**two orthogonal safety axes** both playbooks converge on: an OS **sandbox** (capability)
crossed with a **permission policy** (interruption). What it lacked were the ordinary,
canonical building blocks. Those are now in:

| Primitive | Both ship it | Arnes |
| --- | --- | --- |
| Project instructions (AGENTS.md/CLAUDE.md → system prompt) | ✓ / ✓ | `ProjectInstructions`, trust-gated, precedence global→root→subdir; `.override`/`.local` variants, `@path` imports, `/init` |
| Task checklist (TodoWrite / update_plan) | ✓ / ✓ | `update_plan`, stateless (full list each call) |
| Reasoning scratchpad (the *think* tool) | Anthropic | `think`, no-op readOnly |
| Token-efficient file reads (paging + cap) | ✓ / ✓ | `read_file` offset/limit + 2000-line cap |
| Verify against ground truth | ✓ / ✓ | base-prompt gather→act→verify framing + `--verify` loop |
| Budget stop (max cost) | ✓ / ✓ | `--budget` → `.budgetReached` |

Each is a *dumb, readOnly-where-possible* tool or a bit of context plumbing — consistent with
the invariant that a tool must be survivable by a non-frontier model, and none regress the
default toolset (evals/basics holds 8/8 on DeepSeek with the additions).

**Shipped since** (see the `## Status` list in INSTRUCTIONS.md for the full record):
- **Hooks — the whole lifecycle.** `~/.arnes/hooks.json` (and a trusted project's
  `.arnes/hooks.json`, hash-gated) run at PreToolUse (block/ask/allow/rewrite before the prompt),
  PostToolUse / PostToolUseFailure (output fed back), PermissionRequest, Stop (block→continue),
  SubagentStart/SubagentStop, UserPromptSubmit, SessionStart/SessionEnd, PreCompact/PostCompact
  and Notification, with `when`/`agent`/`enabled` matchers, a `type: prompt` in-model variant and
  an in-process `HookHandler`, all on Claude Code's stdin-JSON + exit-code contract; `arnes hooks
  test` dry-runs them.
- **Reasoning-effort dial** — `--effort` maps to `reasoning.effort` or a thinking budget, gated on
  the manifest's reasoning support, and the reasoning it produces round-trips (pillar 1).
- **The canonical primitives** a Claude Code / Codex user expects: project instructions
  (AGENTS.md/CLAUDE.md, trust-gated, `@imports`, `/init`), `update_plan`, `think`, `ask_user`,
  the `# Environment` block, structured output (`--output-schema`), background subagents,
  snapshot/fork isolation, skills preloading, subagent transcripts + resume, delegation guidance
  in packs, tool-loop hygiene (one cap + spill + loop guard), the headless run contract
  (`RunResult`, `--output-format`, exit codes), the introspection CLI (`--json` everywhere,
  `arnes doctor`, `arnes debug prompt`), and `arnes review`.
- **Prompt-cache discipline (C7) — the prefix stability rules.** Every step of a turn re-sends
  the same system prompt and tool definitions, so the request is shaped to make that prefix
  cacheable and the harness measures whether it was: (1) **static first** — pack, project
  instructions, the `# Environment` and `# Memory` sections, the tool listings and the role
  suffix are rendered from facts captured once per session, byte-identical request after request;
  (2) **reminders ride user messages** — a notice, the loop guard's nudge, a hook's feedback, a
  plan update land in the growing history, never in the system text; (3) **never a timestamp**
  finer than the date — a clock in the prefix would miss the cache every minute; (4) **the tool
  list is fixed per session** — the same definitions in the same order; (5) **the prefix moves
  only at a turn boundary** — a compaction, `/model`, `/effort`, `/permissions` — and a cheaper
  model belongs in a subagent, not in a `/model` swap on a hot cache. On the Anthropic family
  (where the provider takes the field) the requests mark the prefix with `cache_control`
  breakpoints — the system text and the last message on chat, the last tool and the last block on
  `/messages` — and every dialect reports what it read from a cache (`RunRecord.cachedTokens`, the
  footer's `cache N%`, the scoreboard's `cache=` column). `PrefixStabilityTests` audits the rules
  against the real prompt.

**Deliberately deferred**, with rationale:
- **Background *shell* jobs** (`run_in_background`) — background *subagents* shipped (A4); a
  detached-bash `job` registry is the remaining half (T2), deferred until a long-running-command
  need lands.
- **Structured note-taking** (auto-memory) — compaction covers the conversational case;
  agent-managed notes under `~/.arnes/memory` are the iterative-milestone complement (C3),
  achievable today via `write_file` + convention before earning a dedicated store.
- **apply_patch** (Codex's multi-file envelope) — a deliberate *non*-adoption: `edit_file`
  (unique-match) + `write_file` already cover multi-file edits without a bespoke patch grammar.
- **A Linux OS-sandbox backend** — the macOS `sandbox-exec` profile ships; bubblewrap/Landlock
  is the Linux equivalent still to wire.

Shipped that this list once deferred: session fork (`/fork`, `arnes resume --fork`), the
reasoning-effort dial, and interactive plan mode (`/plan`, `--permission-mode plan`).

## Roadmap

- **v0.1 (shipped):** chat-dialect agent loop, 3 tools, prompt packs, run records, `--verify`,
  scoreboard command.
- **v0.2 (shipped):** interactive core — `Session`, REPL, permission gating, streaming,
  `/model` mid-session swap, session persistence/resume; coding tools (`edit_file`,
  `grep`, `glob`).
- **v0.3 (shipped):**
  - *Context compaction:* `usage.promptTokens` vs `profile.contextLength` drives an
    auto-trigger at ~80% (plus manual `/compact [model]`): everything before the last user
    turn is summarized (router picks the summarizer by default), the summary rides the
    system prompt, and a `compaction` transcript entry makes it survive resume. The status
    line shows live context usage (`ctx N%`). OpenRouter's server-side `context-compression`
    plugin remains the alternative to evaluate.
  - *Dialect-native execution* for Anthropic (`/messages`) and OpenAI (`/responses`) under
    `Session`, with the optimistic conformance probe (clean native steps record ok verdicts,
    pre-output failures fall back to chat and are remembered); `--panel N` with snapshot
    isolation and a judge model.
- **v0.4 (shipped):** eval lifecycle tooling — `arnes evals` (history bars per suite ×
  model × dialect), `evals capture` (writer model distills sessions or descriptions into
  validated tasks; `--split` slices a session into a dataset), `evals prune`; MCP tool provider
  (stdio + streamable-HTTP), REPL polish (`arnes resume`, streaming markdown, the pinned input
  bar, type-ahead queueing), the anti-stall loop.
- **Since v0.4 (unreleased, on `feat/p1-hardening`):** a large harness-parity effort against the
  Claude Code and Codex playbooks, in waves — the full record is the `## Status` list in
  INSTRUCTIONS.md. In brief:
  - *Safety:* two orthogonal axes — an OS **sandbox** (macOS `sandbox-exec`, confinement) crossed
    with a **permission policy** (`PathScope` write/read gates, a catastrophic-bash floor, rules +
    modes, session grants, an audit trail, a read-only floor, env scrubbing, an optional cheap-model
    command judge).
  - *Subagents:* a `task` tool = nested `Session` (own `RunRecord`, lineage, fresh history,
    inherited-and-narrowed delegate + toolset), parallel delegation, background runs, snapshot/fork
    isolation, `maxDepth`, persisted transcripts + resume, delegation guidance in packs.
  - *Tools & context:* project instructions, `update_plan`/`think`/`ask_user`, the `# Environment`
    block, tool-loop hygiene (one cap + spill + loop guard), structured output, skills v2.
  - *Headless & introspection:* the `RunResult` contract + `--output-format` + exit codes, headless
    parity flags on `do`, `--json` on every listing, `arnes doctor`, `arnes debug prompt`,
    `arnes review`, eval graders (rubric/limits/verifier).
  - *Dialects:* native `/messages` + `/responses`, the conformance probe, and the reasoning
    round-trip (pillar 1).
  - *Context & cost:* eval CI gates + parallelism, verifier v2 (diff-aware, schema verdict),
    file checkpoints + `/rewind`, untrusted-content framing/redaction/taint, the REPL dials +
    introspection (`/context`, `/btw`, `/effort`, `/budget`, `/thinking`), context-budget
    microcompaction (a request-time history *view* — old tool results stubbed, the persisted
    history untouched — with mid-turn relief and compaction steering), prompt-cache discipline
    (`cache_control` breakpoints on the Anthropic-family stable prefix with a cached-token metric
    on every dialect), transport resilience (jittered retries before any output token, a stream
    idle timeout, output-limit truncation handling), auto-memory (`~/.arnes/memory/<project>/`
    through a narrow carve-out of the `~/.arnes` floor).
  - *Tools:* bash v2 (`timeout_seconds`, a process-tree kill, background jobs behind a `job`
    tool), and capability-gated tools — `view_image` for vision models (manifest-gated, the image
    delivered as a content part), `web_fetch` under `URLPolicy.strict` with a `.sensitive` floor,
    model-adaptive `think` omission.
- **The harness-parity effort is complete on `feat/p1-hardening`** (47 items over eleven batches;
  the `## Status` list in INSTRUCTIONS.md is the full record). **Next / further out:** panel
  policy triggers (auto-panel after verifier rejections), cached model profiles,
  scoreboard-driven routing defaults, gated pack-improvement proposals, a Linux sandbox backend.
