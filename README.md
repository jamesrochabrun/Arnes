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
# one-shot chat, router picks the model, cost printed after
arnes chat "explain actors in swift" -m openrouter/auto

# agent loop with tools (read/write/bash), verified by a second model
arnes do "add a --version flag to main.swift" \
  -m anthropic/claude-sonnet-5 \
  --fallback openai/gpt-5.6-luna \
  --verify openai/gpt-4o-mini

# discover models
arnes models "grok" --supports tools

# key limits + credit balance
arnes status

# the local scoreboard: cost + verifier pass-rate per model
arnes runs
```

## What's inside

- **`ArnesKit`** (embeddable, UI-free): the agent loop, capability manifest (`ModelCatalog`),
  per-family prompt packs (user-overridable at `~/.arnes/packs/`), tools, and the
  `RunRecord` eval substrate (`~/.arnes/runs.jsonl`).
- **`arnes`** (CLI): `chat` · `do` · `models` · `status` · `runs`.
- Built on [OpenRouterSwift](https://github.com/jamesrochabrun/OpenRouterSwift) — usage cost
  tracked per request, model fallbacks on every call.

## Status

v0.1 — working agent loop over the universal chat dialect, inline verification (loop 1), and
run records. Next: dialect-native execution per family, parallel panels, scoreboard-driven
routing. Roadmap in [DESIGN.md](DESIGN.md).
