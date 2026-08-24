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
swift build -c release
export OPENROUTER_API_KEY=sk-or-...
.build/release/arnes --help
```

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
```

## What's inside

- **`ArnesKit`** (embeddable, UI-free): the `Session` actor (streaming agent loop, permission
  gating, interrupts), capability manifest (`ModelCatalog`), per-family prompt packs
  (user-overridable at `~/.arnes/packs/`), six tools, session transcripts
  (`~/.arnes/sessions/`), and the `RunRecord` eval substrate (`~/.arnes/runs.jsonl`).
- **`arnes`** (CLI): `interactive` (default) · `chat` · `do` · `models` · `status` · `runs`
  · `sessions`.
- Built on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) — usage cost
  tracked per request, model fallbacks on every call.
- **Routing visibility**: every response reports the model that actually served it
  (`response.model` post-routing); run records keep the requested → served mapping.
- **Stateless by design**: OpenRouter holds no conversation state; history lives client-side
  in the `Session` — which is exactly what makes mid-conversation `/model` swaps possible.

## Status

v0.2 — interactive REPL (permission gating, streaming, Ctrl-C interrupt), mid-session
`/model` swap, session persistence + resume, coding tools (`edit_file`/`grep`/`glob`), on top
of the v0.1 loop (inline verification, run records). Next: context compaction, subagents,
dialect-native execution, MCP. Roadmap in [DESIGN.md](DESIGN.md).
