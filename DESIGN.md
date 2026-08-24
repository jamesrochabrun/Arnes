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
   *Status: v0 runs all loops over `/chat/completions` (OpenRouter normalizes); `Dialect`
   already routes per family so the native paths slot in without API changes.*

2. **Runtime capability manifest.** `ModelProfile`/`ModelCatalog` read OpenRouter's live
   `GET /models` (supported parameters, context, pricing) and shape every request from it.
   Nothing about a model is hardcoded. Later: a 30-second conformance probe per new model
   (tool-call validity, edit-format adherence), cached to `~/.arnes/profiles/`.

3. **Prompt packs per family.** A family-independent core prompt plus per-family adapter
   markdown (`PromptPack`). User-overridable at `~/.arnes/packs/<family>.md` so tuning needs
   no recompile. Packs are the *tunable* half of Arnes and evolve via the eval loops below.

4. **Few tools, dumb schemas.** `read_file`, `write_file`, `bash` (+ `search`, `subtask`
   later). Every extra tool or clever schema is where a non-frontier model face-plants.

## The three evaluation loops

- **Loop 1 — inline verification (shipped, v0):** after a run, a different (cheaper) model
  adversarially judges "was this task plausibly completed?" (`--verify` flag). Verdict lands
  in the run record.
- **Loop 2 — parallel panel (next):** `arnes do --panel N` fans the task to N models in
  isolated worktrees, judges results, keeps the winner. Every panel run doubles as a labeled
  eval row. Policy triggers (e.g. "panel after two verifier rejections") come with it.
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

## Package layout

```
ArnesKit  (library)   — Dialect, ModelProfile/ModelCatalog, PromptPack, AgentTool,
                        Agent (loop + verifier), RunRecord/RunRecordStore
arnes     (executable) — chat · do · models · status · runs
```

Depends on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) (API client;
all three dialects already wrapped there). ArnesKit stays UI-free so native apps can embed it.

## Roadmap

- **v0.1 (now):** chat-dialect agent loop, 3 tools, prompt packs, run records, `--verify`,
  scoreboard command.
- **v0.2:** dialect-native execution for Anthropic (`/messages`) and OpenAI (`/responses`);
  conformance probe; `--panel N` with worktree isolation; policy triggers.
- **v0.3:** scoreboard-driven routing defaults; pack-improvement proposals with A/B evals;
  provider/ZDR/budget policy files.
