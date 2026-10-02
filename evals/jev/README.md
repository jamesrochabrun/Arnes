# evals/jev — typed decisions (jev) as the grader

Run with `arnes eval evals/jev -m <model>`. The `jev` tasks need no flags — the decisions
judge defaults to `arnes decide`'s model (`typesafe/jev-1.13`); the bridge task shows the
same judge over a plain rubric. `evals/graded` stays as-is: this suite exists to exercise
the `jev` key without disturbing the grader suite's history.

A `jev` block asks a decisions model typed questions about the same evidence the rubric
judge reads — the task, the agent's final report, the post-setup→post-run diff, the check's
verdict and output; never the transcript. The answers come back as calibrated probabilities
instead of generated text (~$0.0004/call), so a trial can be judged several times for the
price of one LLM verdict, and the row records how much the judgment moved.

- **`add-docstring-jev`** — the check proves a docstring exists and the program still prints
  12; the **jev block** (`gate: true`) asks one question of each type: a `noul` (P(the
  docstring says the right thing) ≥ 0.7), a `choice` (`nothing` must win over `other` on
  what else the diff touched), and a `score` (a 3-level quality rubric, expected level
  ≥ 1.0). A missed expectation fails the trial even though the check passed; `checkPassed`
  stays the ground truth.
- **`rename-constant-bridge`** — a plain `rubric`, no `jev` key at all. Run it as written and
  an LLM judge grades it; run `arnes eval evals/jev --task rename-constant-bridge -m <model>
  --judge typesafe/jev-1.13` and **the bridge** converts the criteria to noul questions and
  grades them through the Decisions API — same fields, same gate, same scoreboard, the
  per-criterion P(yes) means kept in `jevQuestions` for audit.
- **`explain-fix-variance`** — `repeats: 3`: the judge is asked three times and the row
  records the mean verdict plus `jevVariance` (the per-repeat score variance — the
  repeatability signal). `report_brevity` declares no `expect`, so it is recorded, never
  counted: a free observation column. `--judge-repeats N` is the run-wide version of the
  same dial.

Judge alignment: `arnes eval evals/jev -m <model> --judge <llm judge> --second-judge
typesafe/jev-1.13` grades every rubric task twice and prints an agreement block;
`arnes evals judges` reads the pairs back across the whole history.

What a jev row adds to `~/.arnes/evals.jsonl`: `judgeModel`, `jevScore`, `jevPassed`,
`jevUnknown`, `jevNotes`, `jevRepeats`/`jevVariance` (only under repeats), `jevQuestions`
(per-question mean/variance/verdict/choice), and with `--second-judge` the
`secondJudgeModel`/`secondRubric*` fields. Spend lands in `graderCostUSD`, apart from
`costUSD`, so model comparisons stay fair.
