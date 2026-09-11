# Proposal: execution, not syntax, as the last check

Not merged. Sibling of `packs-workspace-hygiene`; run them as separate arms —
one variable at a time.

## The evidence

All 26 `completed_but_wrong` failures of the 2026-09-11 suite run (47/89) were
read. Four ended on a check that only proves the file parses:

| task | last check | ran the artifact for real? |
| --- | --- | --- |
| `configure-git-webserver` | `bash -n /app/setup-server.sh` | no — the server was never started |
| `sam-cell-seg` | `python -m py_compile /app/convert_masks.py` | no |
| `video-processing` | `python3 -m py_compile /app/jump_analyzer.py` | only a `grep -c` on the output |
| `extract-elf` | `node --check /app/extract.js` | earlier, yes; the final check was syntax |

## Honest expectation

This is worth **at most** those four tasks and probably fewer. Running the
artifact would have exposed a fixable problem in `configure-git-webserver`;
`sam-cell-seg` needs MobileSAM weights that may not be present, so executing it
might fail for reasons the agent cannot fix. Treat one or two tasks as the
realistic outcome, and do not let a suite-wide pass rate at one repetition be
the evidence — it cannot resolve that.

Judge it the same way as its sibling: on the trajectory. The arm does what it
was asked if the final tool call executes the deliverable against the task's own
input rather than checking that it parses. That is directly readable.

## The wider finding this came from

Of the 26, roughly twenty were the agent doing real validation — running the
program, comparing against a reference, checking numerics — and being wrong
anyway. That is capability, not harness. See `model-routing.md` for the full
breakdown and what it implies about where effort goes next.
