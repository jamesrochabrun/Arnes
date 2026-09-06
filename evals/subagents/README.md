# evals/subagents — delegation behavior probes

Run with `arnes eval evals/subagents --subagents -m <model>`. The `--subagents` flag
offers the `task` tool. Without it, the four search tasks cannot pass their delegation
checks; the trivial task can still pass by working directly.

These five tasks measure the pack's `# Delegation` guidance. A search-task pass requires
both a correct answer and a recorded `explore` subagent run. That is a behavior check,
not a coding-quality score: a lead that solves the task correctly and cheaply by itself
can fail the delegation check.

| Task | Fixture | Passing check |
| --- | --- | --- |
| `wide-search-delegates` | Thirty notes, one release name | Correct name and an `explore` run |
| `noisy-search-delegates` | Three hundred notes, forty names, thirty-nine withdrawals | Correct surviving name and an `explore` run |
| `judgment-search-delegates` | 240 support tickets, one subscription cancellation request | Correct ticket ID and an `explore` run |
| `context-search-delegates` | 2,000 tickets, approximately 1.55 MB, shared cancellation vocabulary | Correct ticket ID and an `explore` run |
| `trivial-task-stays-direct` | A small file task | Correct file and no nested run |

The fixtures are deterministic. `DelegationProbeTests` and `ContextProbeTests` test
specific misleading search strategies and generated data properties. They do not prove
that all shell strategies fail or that delegation is required.

## What the recorded runs show

The first two searches can be solved with short grep/set-difference pipelines. Later
experiments also solved the judgment and context probes through repeated narrowing searches.
In the September 4 follow-up with a 60-step cap, DeepSeek and Sonnet produced **16 correct
answers in 16 trials with no delegations**, across both prompt arms. The wider Anthropic
delegation override was not adopted.

Use these tasks as steps/cost baselines and delegation-behavior probes. A delegation
count alone does not demonstrate a better outcome. The dated methods, model aliases,
budgets, results, and decisions are in [the A/B record](../ab/README.md), especially §3b–3d.

## How a check identifies nested runs

`EvalRunner` gives check scripts `ARNES_SESSION_ID` (the trial's lead session) and
`ARNES_RUN_ID` (its run record). Checks match nested records in `~/.arnes/runs.jsonl`
by `parentSessionId`, so a different session's delegation does not count.

When those variables are absent, the scripts fall back to rows appended since setup's
`.runs-before` snapshot. For that fallback, run the suite without another Arnes process
appending records. The search checks specifically require `explore`; delegating to
`general` does not satisfy them.

## Running the suite

Run live evaluations as an explicit human step: they make paid model requests and append
to the real Arnes stores. `NSHomeDirectory()` ignores a substituted `HOME`, while these
check scripts read `$HOME/.arnes/runs.jsonl`; changing `HOME` makes them disagree.
Unit tests inject temporary stores instead.

For a prompt change, use labeled arms and comparable model, provider, dialect, and budget
settings. Keep `evals/basics` as a baseline and report correct answers, steps, and cost
alongside the delegation checks. Prompt changes remain proposals until the A/B evidence
has been reviewed.
