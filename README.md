# Arnes

*Arnés* — Spanish for **harness**. A model-adaptive agent harness for
[OpenRouter](https://openrouter.ai), built in Swift.

Every major coding agent is tuned for one model family; swapping the model underneath leaves
the wrong prompts and wire format in place. Arnes inverts that: **the model you pick drives
everything** — the wire dialect, the prompt pack, the request shape — all discovered from
OpenRouter's live model manifest, never hardcoded. See [DESIGN.md](DESIGN.md) for the full
architecture; [INSTRUCTIONS.md](INSTRUCTIONS.md) if you're contributing.

## Install

```bash
git clone https://github.com/jamesrochabrun/Arnes && cd Arnes
./scripts/install.sh            # builds release + installs to /opt/homebrew/bin (pass a dir to override)
export OPENROUTER_API_KEY=sk-or-...
arnes --help
```

(The script removes the old binary and ad-hoc re-signs the new one — overwriting a signed
binary in place gets it SIGKILLed on Apple Silicon.)

## Use

```bash
# interactive session (the default): converse, steer, follow up
arnes
› refactor Sources/App/Router.swift to use async/await
# streams the answer; asks y/n/always before bash / write_file / edit_file;
# every turn ends with a status line:
# ─ openrouter/auto → deepseek/deepseek-v4-flash · 3 steps · 2 tools · turn $0.0004 · session $0.0021
```

Inside the REPL:

```text
/model sonnet     switch the WHOLE conversation to another model, mid-session —
                  history is client-side, so 20 turns into Claude you can finish on GPT
/cost             running session total (live usage.cost)
/verify           loop-1: a second model judges whether the last task was completed
/compact          summarize older turns to free context (also automatic at ~80% full;
                  the status line shows live usage: · ctx 34%)
/save demo        name the session; resume later with `arnes --resume <id>`
/clear /status /help /exit
```

Sessions persist to `~/.arnes/sessions/` as they happen (crash-safe):

```bash
arnes --continue        # resume the most recent session
arnes --resume <id>     # resume a specific one
arnes sessions          # list them
```

Headless stays first-class:

```bash
# one-shot chat, router picks the model, cost printed after
arnes chat "explain actors in swift" -m openrouter/auto

# agent loop with tools (read/write/edit/bash/grep/glob), verified by a second model
arnes do "add a --version flag to main.swift" \
  -m anthropic/claude-sonnet-5 \
  --fallback openai/gpt-5.6-luna \
  --verify openai/gpt-4o-mini \
  # add --safe to deny all mutating tools
# prints "⇄ routed to <model> (<provider>)" live when routing changes, and ends with
# [requested openrouter/auto → served by deepseek/deepseek-v4-flash · 3 steps · $0.0003]

# discover models
arnes models "grok" --supports tools

# key limits + credit balance
arnes status

# the local scoreboard: cost + verifier pass-rate per model
arnes runs

# evals: models × tasks × trials in isolated workdirs, scored by check scripts
arnes eval evals/basics -m anthropic/claude-haiku-4.5,openai/gpt-4o-mini -t 3
# ✓ fix-bug · anthropic/claude-haiku-4.5 · 5 steps · $0.0112 · 14.1s
# model                        pass        cost      steps  time   errors
# anthropic/claude-haiku-4.5   24/24 (100%)  $0.15   3.4    8.5s   0

# panel: fan one task to N models in isolated snapshots, judge picks, winner lands here
arnes do "make the greeting configurable" --panel 3 \
  -m anthropic/claude-sonnet-5,openai/gpt-5.6-luna,deepseek/deepseek-v4 \
  --judge anthropic/claude-sonnet-5    # --no-apply keeps the winner in its snapshot
# every candidate becomes a labeled eval row — real work grows the eval history for free
```

Evals append to `~/.arnes/evals.jsonl` (and feed the `runs` scoreboard). A task is one
JSON file — prompt + optional bash `setup` + a bash `check` whose exit code is the ground
truth — so adding your own suite is trivial. For the industry benchmark,
`benchmarks/terminal-bench/` has a [Harbor](https://www.harborframework.com) adapter to run
Arnes on [Terminal-Bench](https://www.tbench.ai) — the same harness used to score Claude
Code and Codex CLI — with `ARNES_MODEL` selecting the model per run.

## What's inside

- **`ArnesKit`** (embeddable, UI-free): the `Session` actor (streaming agent loop, permission
  gating, interrupts), capability manifest (`ModelCatalog`), per-family prompt packs
  (user-overridable at `~/.arnes/packs/`), six tools, session transcripts
  (`~/.arnes/sessions/`), and the `RunRecord` eval substrate (`~/.arnes/runs.jsonl`).
- **`arnes`** (CLI): `interactive` (default) · `chat` · `do` · `models` · `status` · `runs`
  · `sessions` · `eval` · `probe`.
- Built on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) — usage cost
  tracked per request, model fallbacks on every call.
- **Routing visibility**: every response reports the model that actually served it
  (`response.model` post-routing); run records keep the requested → served mapping.
- **Stateless by design**: OpenRouter holds no conversation state; history lives client-side
  in the `Session` — which is exactly what makes mid-conversation `/model` swaps possible.
- **Dialect-native transport**: Anthropic models run on `/messages` and OpenAI models on
  `/responses` (chat-completions for everyone else) — chosen per model automatically, forced
  with `--dialect` for A/Bs. History stays chat-shaped internally and is translated per
  request, so `/model` swaps work *across* dialects mid-conversation. On the starter suite,
  claude-haiku-4.5 native vs chat: same 8/8 pass, −15% cost, −11% steps, −14% time.
  Conformance is self-checking: clean native runs record an ok verdict, a misbehaving
  native endpoint falls back to chat mid-turn and is remembered (`~/.arnes/dialects.jsonl`,
  failures retried after 7 days) — `arnes probe <model>` checks a model explicitly.

## Status

v0.3 — dialect-native execution (`/messages`, `/responses`, per-model auto + `--dialect`),
`--panel N` (parallel candidates, judge, labeled eval rows), eval framework (`arnes eval`,
bash checks as ground truth), CI (macOS + Linux) with static Linux release binaries and a
Terminal-Bench/Harbor adapter, on top of v0.2's interactive REPL (permission gating,
mid-session `/model` swap, persistence + resume, coding tools, context compaction) and the
v0.1 loop (inline verification, run records). Next: conformance probe, subagents, MCP.
Roadmap in [DESIGN.md](DESIGN.md).
