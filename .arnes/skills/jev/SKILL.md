---
name: jev
description: Turn a natural-language ask ("measure X about this text, show me Y") into a typed jev decision — author the questions JSON, run `arnes decide --json`, and present the calibrated probabilities in whatever format the user asked for. Use when the user wants to measure, classify, route, rank, score, or triage something with jev / a decision model, or asks "how urgent/angry/hard is this" as a number.
---

# jev — typed decisions on request

The user states an intent in plain language; you own the JSON. jev (`typesafe/jev-1.13`,
OpenRouter's Decisions API) generates **no text** — it answers typed questions about a
*state* with calibrated probabilities. A call costs ~$0.00002.

## The flow

1. **Pick the question types** from the intent:
   - yes/no ("is this urgent?") → `noul` — returns P(yes) in [0, 1]
   - pick-one ("which team?", "route to A/B/C") → `choice` — returns the picked key +
     per-option probabilities + confidence. You choose the option keys; return values use
     *your* keys.
   - ordered scale ("how angry, 1–5?", "difficulty easy/medium/hard") → `score` — an
     ordered array of 2–10 level descriptions; returns a fractional expected level +
     per-level probabilities.
2. **Author the questions JSON.** Question names are yours (the answers come back under
   them). Write descriptions carefully — jev calibrates against your wording:

   ```json
   {"urgent": {"type": "noul", "instructions": "Does this message convey urgency?"},
    "team": {"type": "choice", "instructions": "Which team should own this?",
             "criteria": {"billing": "Payments, invoicing, refunds",
                          "technical": "Bugs, outages, integrations"}},
    "anger": {"type": "score", "instructions": "How upset is the writer?",
              "criteria": ["Calm", "Concerned", "Frustrated", "Very angry"]}}
   ```
3. **Run it** with the bash tool (single-quote both arguments; write a temp questions file
   instead if the JSON gets long):

   ```bash
   arnes decide '<the state text>' --questions '<the JSON>' --json
   ```

   With several items to score, loop — one call per state — and aggregate yourself.
4. **Read the one JSON line**: `{answers: {name: {type, noul?, choice?, score?,
   confidence?, probabilities?, legend?}}, model, provider, usage: {cost, …}}`. Score
   probabilities/legend are keyed by stringified level index ("0", "1", …).
5. **Present in the format the user asked for** (table, ranking, one-liner, threshold
   verdict…). Always keep the numbers visible — the probabilities *are* the answer; never
   round a 0.55 noul into a confident "yes". If the user gave a threshold, apply it and
   say which side the number landed on.

## Rules

- Never invent question types: only `noul`, `choice`, `score`. Criteria are
  `{key: description}` for noul (`"true"`/`"false"` only) and choice, an ordered array
  for score.
- If the user's ask is ambiguous about the scale or options, propose them in your reply
  (cheap to rerun) rather than asking first — the call costs nothing.
- Exit code non-zero or an `error` in the output: show the error; do not retry more than
  once.
- The user can also run decisions themselves: `/decide <questions|file.json> <state>` in
  the REPL, `arnes decide` headless. If they'll reuse a question set, offer to save it as
  a `.json` file for `/decide`.
- Jev also grades evals: a task's `"jev"` block (same question grammar, plus
  `expect`/`repeats`/`gate`) judges each trial's evidence, `arnes eval --judge
  typesafe/jev-1.13` bridges plain rubric criteria through it, and `arnes evals judges`
  compares it against an LLM judge — see `evals/jev/README.md` and the arnes skill's eval
  section.
