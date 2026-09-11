# Proposal: workspace hygiene in the family pack

Not merged. A prompt-pack change is a proposal until an A/B earns it
(AGENTS.md invariant 6).

## The evidence

The 2026-09-11 full-suite run (`gpt-5.6-luna-pro`, medium effort, provider pinned
to OpenAI, 47/89 = 52.8%) contains two failures whose solutions were **correct**
and which failed only because the agent left its build output next to the
deliverable.

`polyglot-rust-c` — the task's test opens with:

```python
polyglot_files = os.listdir("/app/polyglot")
assert polyglot_files == ["main.rs"], f"Expected only main.rs, found: {polyglot_files}"
```

The agent verified its work with `rustc /app/polyglot/main.rs -o /app/polyglot/main`
and `g++ -x c++ /app/polyglot/main.rs -o /app/polyglot/cmain`, printing the correct
Fibonacci values (1, 1, 89). Those two binaries stayed in `/app/polyglot`, so the
assertion failed. The agent failed the task *by testing it*.

`polyglot-c-py` — same shape, `assert polyglot_files == ["main.py.c"]`, and four
runs of `gcc /app/polyglot/main.py.c -o /app/polyglot/cmain`.

Three other suite tasks assert on directory contents
(`financial-document-processor`, `reshard-c4-data`, `log-summary-date-ranges`), so
the addressable set is larger than the two confirmed cases but not much larger.

## The change

One paragraph appended to `PromptPack.familyDefaults[.openai]` (this directory's
`openai.md` is the whole replacement text, per the base-override convention).
Nothing else in the pack moves.

## What would earn the merge

Expected movement is **small and specific**: +2 tasks, 52.8% → 55.1%, from tasks
that already produce correct work. It is not a general capability claim, and a
suite-wide pass-rate comparison at one repetition cannot resolve two tasks from
noise — the 2026-09-10 evidence showed run-to-run cost and latency swings above
10x on identical work.

So judge it on the mechanism, not the headline:

1. Run the two polyglot tasks, several repetitions per arm, control versus
   `ARNES_PACKS_DIR=evals/ab/packs-workspace-hygiene`.
2. The arm passes only if the deliverable directory is left clean. That is
   directly observable in the trajectory, and it is the thing being changed.
3. Check the five directory-asserting tasks for regressions, then the wider suite
   for any cost or step-count change — terser build discipline should not make the
   agent slower.

A pass-rate move on two tasks is the outcome; the trajectory is the evidence.
