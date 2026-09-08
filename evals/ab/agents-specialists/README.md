# Bounded specialist proposal

These role definitions are opt-in experiments, not new built-ins or evidence that more
delegation is better. The lead can solve a task directly. `investigator` narrows to pure
file-reading tools and read-only permission; `verifier` runs in a disposable snapshot
with shell access for tests and caches. Shell access can write inside that snapshot:
the verifier's prose is guidance, not an additional security boundary. Existing parent
permissions, tool ceilings, sandbox, depth and remaining budget still apply. Neither
role pins a model or effort. Under the default subagent configuration they inherit the
lead's model and effort; a configured `subagents.defaultModel` still takes precedence.
Freeze and record that configuration too, or unset its model override for a same-model A/B.

Each brief should state the objective, relevant paths, constraints, expected evidence,
and out-of-scope work. The investigator returns cited findings; the verifier returns
commands, observed results and coverage limits. Reports do not automatically change the
lead's working tree or establish correctness. The lead must integrate and re-verify.

## Human-run comparison

Use `evals/agentic-work`, whose checks score artifacts and behavior rather than delegation
counts. Run the same explicit model, effort and budget across arms, alternate their order,
and use at least three repetitions. Record the source SHA and SHA-256 of this JSON file.
Live evals are paid and write real Arnes stores; an unattended agent must not run them.

```bash
arnes eval evals/agentic-work -m <explicit-model> --effort high --budget 3 --max-steps 60 -t 3 --agents '[]' --label specialist-control
arnes eval evals/agentic-work -m <explicit-model> --effort high --budget 3 --max-steps 60 -t 3 --agents @evals/ab/agents-specialists/roles.json --label specialist-roles
```

`eval --agents` supplies exactly those definitions, without personal or built-in agents.
It is mutually exclusive with `--subagents`, which retains its existing discovery behavior.
Malformed definitions and parser warnings fail validation before provider work begins.
The file form requires a regular UTF-8 file of at most 64 KB; symlinks and special files
are refused, and the bounded read checks the opened file's identity.
No global config or agent directory needs editing. For an ordinary headless run, existing
`do --agents @path` instead merges inline definitions with discovered agents; do not confuse
that behavior with this isolated eval control.

Report independent check success, total lead-plus-child cost, wall time, steps, child
counts, duplicate work and incorrect child reports. Zero delegations can be the best
outcome. Compare held-out tasks before proposing any default role or prompt change.
Offline tests validate scope, bounds and fixture verifiers—not improved model judgment.
