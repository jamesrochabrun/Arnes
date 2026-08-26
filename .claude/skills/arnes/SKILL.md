---
name: arnes
description: Drive the arnes CLI (model-adaptive agent harness on OpenRouter) — run evals, panels, conformance probes, headless agent tasks, and read its scoreboards. Use when the user says things like "arnes run evals", "run the eval suite", "panel this task", "probe a model", "check the arnes scoreboard", or wants to benchmark/compare models cheaply.
---

# Driving arnes

`arnes` is an installed CLI (`arnes --help` to confirm; if missing, build with
`./scripts/install.sh` from the repo root). Every command needs an OpenRouter key:
`OPENROUTER_API_KEY` in the environment, or a `~/.arnes/credentials` file (the key on one
line). If neither is set, ask the user to provide it.
All commands are safe to run non-interactively **except** bare `arnes` (the REPL), which
prompts for tool permissions — prefer `arnes do` for headless work.

## Cost defaults (matters — every run spends real money)

- Cheap workhorse: `deepseek/deepseek-v4-flash` (~$0.001 for the whole starter suite, scored 8/8).
- Cheap-but-strong: `anthropic/claude-haiku-4.5` (~$0.05 per suite pass).
- Don't launch big models or many trials without the user asking. A full
  `evals/basics` pass costs cents with the models above; report actual cost from the output.

## Run evals — "arnes run evals"

```bash
arnes eval evals/basics -m deepseek/deepseek-v4-flash                  # one model
arnes eval evals/basics -m anthropic/claude-haiku-4.5,openai/gpt-4o-mini -t 3   # matrix × 3 trials
arnes eval evals/basics -m <model> --task fix-bug                      # single task
arnes eval evals/basics -m <model> --dialect chat                      # force a dialect (A/B)
```

- A suite is a directory of JSON tasks (`{"id","prompt","setup"?,"check","timeoutSeconds"?}`);
  the bash `check` script's exit 0 is the ground truth. `evals/basics` in the Arnes repo is
  the starter suite; point at any other directory or single .json file.
- Output ends with a per-model table: pass rate, total cost, avg steps, avg time, errors.
  Report that table to the user (and per-task ✗ lines for failures).
- Dialect A/B: run the same suite twice, `--dialect chat` vs `--dialect messages` (Anthropic)
  or `--dialect responses` (OpenAI), and compare the two tables.
- Rows append to `~/.arnes/evals.jsonl` (fields: suite, taskId, model, trial, checkPassed,
  steps, costUSD, durationSeconds, routedModels, dialect, error).

## Headless agent task

```bash
arnes do "add a --version flag to main.swift" -m <model>     # runs in the CURRENT directory
arnes do "..." --verify openai/gpt-4o-mini                   # second model judges completion
arnes do "..." --safe                                        # read-only (mutating tools denied)
arnes do "..." --dialect chat                                # force wire dialect
```

Footer reports requested→served model, dialect, steps, tool calls, cost.

## Panel — best-of-N with a judge ("panel this task")

```bash
arnes do "make the greeting configurable" --panel 3 \
  -m deepseek/deepseek-v4-flash,anthropic/claude-haiku-4.5,openai/gpt-4o-mini \
  --judge anthropic/claude-haiku-4.5
```

- N candidates run in parallel snapshots of the current directory; a judge model picks the
  winner from reports + diffs; the winner's changes are applied back here.
- `--no-apply` keeps the winner in its snapshot (path is printed) instead of applying.
- One model in `-m` + `--panel N` = N samples of that model. Costs ≈ N × a single run.
- Every candidate lands in `~/.arnes/evals.jsonl` labeled won/lost (suite "panel").

## MCP tools — "hook up an MCP server"

```bash
arnes mcp                      # connect servers from ~/.arnes/mcp.json, list their tools
arnes do "..." --no-mcp        # run without MCP servers
ARNES_MCP_CONFIG=./mcp.json arnes do "..."   # per-project config override
```

- Config is the Claude Desktop `mcpServers` shape (stdio servers: `command`, `args`, `env`)
  at `~/.arnes/mcp.json` — existing Claude configs can be copied verbatim. No config file
  means MCP is simply off.
- When configured, `arnes` (REPL) and `arnes do` connect the servers automatically and the
  model sees their tools as `mcp__<server>__<tool>`. MCP tools are permission-gated like
  `bash` unless the server marks them read-only, so `--safe` denies them and the REPL
  prompts. Panels never load MCP tools (parallel candidates would share server side
  effects). `arnes mcp` needs no API key — use it to debug a server config.

## Conformance probe — "probe a model"

```bash
arnes probe <model>                    # one cheap echo-tool round-trip on its native dialect
```

Verdicts live in `~/.arnes/dialects.jsonl`; auto dialect selection reads them (failed →
pinned to chat, failures retried after 7 days). Normal runs also record verdicts
optimistically, so probing is optional — use it to pre-check a model or retest a failure.

## Capture an eval from a fumble — "make an eval from that"

When the user says the agent fumbled something and wants it as a reusable test:

```bash
arnes evals capture                                   # distill the most recent session
arnes evals capture --split                           # auto-slice: one task per user turn,
                                                      # non-tasks skipped, follow-ups self-contained
arnes evals capture --session <id> --hint "focus on the part it got wrong"
arnes evals capture --task "<plain description>"      # no session needed
arnes evals capture -o evals/mine -m anthropic/claude-haiku-4.5   # output dir + writer model
```

Use `--split` when the user wants a whole session (or "everything we just did") turned into
a dataset; use single capture + `--hint` to extract one specific fumble. After capturing,
show the user each task's `check` — captured checks deserve a quick human review before
they become the bar other models are judged against.

A writer model drafts `{id, prompt, setup, check}`; the draft is auto-validated (setup must
succeed, check must FAIL pre-work) and written to the output dir (default `evals/captured/`).
Rerun it any time with `arnes eval <dir> -m <model>`. Report the captured task's id, path,
and check to the user.

## View / prune eval history — "show me the evals"

```bash
arnes evals                                  # pass-rate bars per suite × model × dialect
arnes evals show --suite basics --model haiku --days 7
arnes evals prune --older-than 30            # delete old rows (also --suite, --model, --all)
```

## Scoreboards & discovery

```bash
arnes runs                             # per-model runs, cost, verifier pass rate
arnes models "flash" --supports tools  # search the live manifest (pricing, context)
arnes status                           # key limits + credit balance
arnes sessions                         # saved interactive sessions (ids for evals capture)
tail ~/.arnes/evals.jsonl              # raw eval rows (JSONL) for custom analysis
```

`arnes resume [id|id-prefix|name]` reopens a saved session interactively (most recent when
omitted) — it starts a TTY REPL, so it's for the user to run, not for agents.

## Adding an eval task

Write one JSON file into the suite directory:

```json
{"id": "rename-var", "prompt": "rename count to total in main.py",
 "setup": "printf 'count = 1\\nprint(count)\\n' > main.py",
 "check": "grep -q total main.py && ! grep -q count main.py && python3 main.py"}
```

Keep checks programmatic and strict — they are the ground truth, not an LLM opinion.
