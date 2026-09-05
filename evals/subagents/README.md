# evals/subagents — does the delegation guidance fire, and only when it should?

Run with `arnes eval evals/subagents --subagents -m <model>` — without `--subagents` a trial
has no `task` tool and every task here fails by construction. Five tasks score the pack's
`# Delegation` section (`PromptPack.baseDelegation` + `familyDelegationDefaults`): damping on
the trivial task, delegation on the four search tasks — two of which one grep pipeline settles
(they are the shell-solvable baselines), one of which no pipeline settles but a patient lead
still reads alone (the judgment probe), and one whose volume puts reading alone past a context
budget (the context probe — the task whose pass proves the text).

- `wide-search-delegates` — thirty notes, one holds the name; passes only when the answer is
  right **and** a nested run tagged `"agent":"explore"` was recorded during the trial. A single
  `grep` solves the search itself, so this task measures whether a model delegates a *modest*
  search — batches 6–11 found deepseek and haiku find TAMARIND themselves in 5–6 steps.
- `noisy-search-delegates` (P1) — three hundred notes; forty meetings each "agreed to ship the
  release under the name <X>" (forty distinct names) and thirty-nine of those names are
  withdrawn in *other* meetings, in three phrasings that all mention the trademark check. One
  grep yields forty candidates; only cross-referencing the withdrawals leaves the survivor
  (`KESTREL`). Deterministic setup (a `sh` loop over fixed names, no `$RANDOM`), 600 s. The
  check is the first task's: the right answer **and** an `explore` run. **What it measures now**
  (batch 13, `evals/ab/README.md` `## Results` §3): both models solved it alone in 5–13 steps with
  one `grep`/`comm` pipeline — the three withdrawal phrasings share an anchor token
  (`trademark`), the names have one surface form (ALL CAPS) and the answer is a set difference,
  every piece a regex encodes — so a model that solves it alone in N steps is the
  **shell-solvable baseline** (record steps and cost), not a failure of the text. The judgment
  probe below is the task where delegation is the rational move.
- `judgment-search-delegates` (A9) — `tickets/` holds two hundred and forty customer-support
  tickets (~92 KB; two id shapes, `TK-nnnn` and `cs-nnnnn`; mixed-case names; greeting, account,
  context and sign-off lines that vary by index), and **exactly one** asks to stop a subscription
  — its id is the answer. Every ticket carries cancel-family vocabulary (`cancel`,
  `cancellation`, `terminate`, `end my plan`, `close my account`, `stop billing`,
  `unsubscribe`), so presence is uninformative; the decoys use it in eight other senses —
  negated requests, other objects (a cancelled flight, the wrong order, a duplicate invoice),
  hypotheticals and conditionals, a past cancellation that is a refund ask, requests to undo a
  cancellation, third parties (a colleague's seat, the previous owner), the opposite intent in
  cancel-words ("end my trial and move me to the paid plan"), and incidental mentions (the
  cancel button, the cancellation policy) — with varied surface forms; some carry no negation
  word and read positively at the sentence level, and the positive asks without the word
  `cancel` ("please end my plan at the end of this billing cycle and do not renew it"). No
  keyword, negation-filter, count-per-file or odd-one-out pipeline isolates it:
  `DelegationProbeTests` runs fourteen such pipelines against the generated tree and asserts
  none returns the positive alone, so reading the tickets is the only way, `cat tickets/*`
  overflows the 30 000-char tool-result cap, and the built-in `explore` (`read_file`, `grep`,
  `glob` — no bash) can do the reading and report the id. Deterministic `sh` (fixed pools keyed
  on the index, no `$RANDOM`), 600 s. The check is task 03's shape: the right id (case-insensitive,
  a `tickets/` prefix or `.txt` suffix tolerated) **and** an `explore` run. **What it measures
  now** (batch 14, `evals/ab/README.md` §3b): both models solved it alone — `grep` down to ~40
  cancel-family candidates, then read them into their own context in 9–24 steps; one delegation
  in 32 trials, and that one after the lead had read most of the evidence itself. So it is the
  **shell-proof control a patient lead still solves alone**: no one-shot pipeline isolates the
  ticket, but 92 KB is three or four spilled results, and both models are willing to read that.
  Its rows are a steps/cost baseline for the judgment work; the context probe below is where
  reading alone stops paying.
- `context-search-delegates` (A10, batch 15) — the same task family beyond one context window.
  `tickets/` holds **two thousand** support tickets (**~1.55 MB on disk**, 650–950 bytes each;
  `cat tickets/*` is fifty times the 30 000-char tool-result cap, and evals spill nothing — the
  middle is lost), two id shapes half each, mixed-case names, greeting/account/environment/
  context/"what we tried"/second-paragraph/sign-off lines all keyed on the index so no `uniq -c`
  exposes filler, and **exactly one** asks to stop a subscription (the same request sentence as
  04, without the word `cancel`, at a mid index whose context lines are the neutral variants).
  What 04 lacked, twice over: **volume**, and **the positive's vocabulary is shared** — every
  distinctive phrase of its request sentence (`end my plan`, `do not renew`, `no further
  charges`, `billing cycle`, `done with`, `decided to leave`) appears in other senses in over a
  third of the tickets (≥ 750 files each), the two most distinctive still co-occur in ~520
  files (≈ 420 KB), and decoys use the exact phrases in other senses ("please do not renew my
  *domain*", "end my *trial* early", "no further charges *appeared*, thanks", "at the end of this
  billing cycle I want to *upgrade*", a "for planning only: if I asked you to end my plan and
  do not renew it, would no further charges apply…" hypothetical carrying every phrase at once)
  on top of 04's eight decoy classes, widened to 36 body templates. So a lead that greps the
  positive's own words gets a candidate set several times larger than one spilled result — on a
  128k-token model past the compaction threshold when read serially — where four `explore`
  fan-outs each read a quarter (the explorer has exactly `read_file`/`grep`/`glob`, and the lead
  finishes from its prose report: an id). Generated by **one `awk` process** (POSIX awk, fixed
  pools keyed on the index, `close()` per file, no `$RANDOM`/`shuf`/clock — 0.3 s here, pinned
  < 30 s against the runner's 60 s setup cap), 900 s for the agent. The check is 04's shape with
  the id swapped: the right id **and** an `explore` run. `ContextProbeTests` pins the shape, the
  tree, the sharing numbers, determinism and 26 one-shot pipelines (04's fourteen plus twelve
  that target the positive's own vocabulary) none of which returns the positive alone. **A pass
  with the text as written — the right id and an `explore` run — is the proof of the delegation
  text**; a lead that reads two thousand tickets itself, or writes a wrong id, is the row to
  record (steps, spills, cost) — `evals/ab/README.md` §3 and §3c.
- `trivial-task-stays-direct` — passes only when the file is right and **no** nested run was
  recorded.

## How a check knows what the trial spawned

`EvalRunner` hands every **check** script (never the setup — it runs before the session exists)
two variables: `ARNES_SESSION_ID`, the trial's lead session id, and `ARNES_RUN_ID`, its
`RunRecord.id`. A nested record carries `"parentSessionId":"<lead session id>"`, so each check
greps `~/.arnes/runs.jsonl` for exactly the records this trial's session spawned — another arnes
process delegating meanwhile cannot skew it. When the variable is unset (an older runner, a
check run by hand) the checks fall back to the line delta against `.runs-before`, which the
setup still snapshots — and then the two caveats below apply in full.

## Run it with a real `HOME`

- **`HOME` must be the real home.** The runner writes records via `NSHomeDirectory()`, which
  ignores an overridden `$HOME`; the check scripts read `$HOME/.arnes/runs.jsonl`. With `HOME`
  pointed elsewhere (the fake-gateway smoke recipe does this) they look at two different files
  and every trial fails.
- **Under the fallback only**: nothing else may append to `runs.jsonl` while the suite runs
  (another REPL handing work to `explore` makes `trivial-task-stays-direct` fail and the search
  tasks pass spuriously). With `ARNES_SESSION_ID` set — every `arnes eval` since P1 — the
  session-id grep closes that race.
- The `"agent":"` grep (fallback of the trivial task) matches any nested record's `agent` field
  (a lead record carries no `agent` key — the encoder omits a nil optional — so it never
  matches). The strict path asks for no record whose `parentSessionId` is this trial's session.
- The search tasks demand `explore` by name, deliberately: a model that delegates the search to
  `general` fails them, because steering it to the read-only searcher is the listing's job.
  Loosen the grep to `"agent":"` only if the models in question consistently pick `general` for
  a well-described read-only search.

Per invariant 6 a pack text change is a proposal: run this suite on deepseek and haiku (chat
and native dialects) before merging any change to the delegation text, and re-run
`evals/basics` on the same models to confirm the section costs nothing there (it is absent
without the task tool, so `arnes eval evals/basics` is byte-identical; the comparison that
matters is `arnes do`-shaped runs, which carry it). The recipe, with labels for each arm, is
`evals/ab/README.md`.
