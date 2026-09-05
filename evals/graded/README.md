# evals/graded — the X4 graders on two small tasks

Run with `arnes eval evals/graded -m <model> --judge <cheap model> --verify <cheap model>`.
`evals/basics` stays the ungraded A/B baseline; this suite exists to exercise the three
optional task keys, so the A/B runs are not disturbed by them.

- **`add-docstring-rubric`** — the check proves a docstring exists and the program still
  prints 12; the **rubric** (three criteria, threshold 0.7, `gate: true`) decides whether the
  docstring says the right thing and whether the diff touched nothing else. The judge reads
  the task, the agent's final report, the post-setup→post-run diff and the check's verdict —
  never the transcript. A rubric miss fails the trial (`passed: false`) even though the check
  passed; `checkPassed` stays recorded as the ground truth. The **limits** here are
  recorded only (`gate: false`): `maxSteps: 6` caps the run, `requiredTools: ["edit_file"]`
  notes a model that rewrote the file instead of editing it.
- **`fix-typo-efficiently`** — no rubric; the **limits gate** (`gate: true`): at most 4
  steps and 3 tool calls, `bash` and `write_file` forbidden, `edit_file` required. A model
  that shells out `sed -i` passes the check and fails the trial. `verify: true` runs the
  loop-1 verifier when `--verify <model>` is given; its verdict is recorded on the row
  (`verifierPassed`), never gating.

- **`multi-edit-one-call`** — a 37-line `metrics.py` uses `compute_total` in five places; the
  prompt asks to rename it everywhere in that file with the file tools. The check greps the new
  name five times and the old never (and runs the file). The **limits** are recorded only
  (`gate: false`): `maxToolCalls: 4` is the question — a model that passes `edit_file`'s `edits`
  array (T7) finishes in a read and one edit, one that calls `edit_file` five times is over it —,
  `bash`/`write_file` forbidden, `edit_file` required. Read `limitsViolations` on the row to see
  which form the model used; nothing here gates.

What a graded row adds to `~/.arnes/evals.jsonl`: `rubricScore`, `rubricPassed`,
`rubricUnknown`, `rubricNotes`, `limitsPassed`, `limitsViolations`, `verifierPassed`,
`graderCostUSD` (the judge's spend — apart from `costUSD`, so model comparisons stay fair;
the verifier's spend is inside `costUSD` because the session books it with the turn),
`sessionId`/`runId`, tokens, `stopReason`, and `passed` (the graded verdict). A row without
graders has none of them and aggregates exactly as before.

Without `--judge` the rubric is graded by the candidate model itself and `arnes eval` warns
`self-grading: judge == candidate` on stderr — fine for a smoke run, not for a comparison.
Every trial's transcript lands under `~/.arnes/eval-sessions/`; read one with
`arnes evals transcript <id>` (the row's `sessionId`, or its `runId` prefix).
