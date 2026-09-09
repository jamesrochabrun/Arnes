# Time-budget experiment (proposal; defaults unchanged)

A development run with DeepSeek V4 Pro 0813 timed out on adaptive-rejection-sampler
without creating its implementation. Most reasoning arrived before the first tool call.
The same model passed write-compressor after substantial reasoning. This motivates an
experiment, not a conclusion that less reasoning improves Arnes.

Compare the same new binary across arms. Keep the requested model
`deepseek/deepseek-v4-pro-0813`, effort `high`, 100 steps, 900 seconds, $1 cost threshold
per trial, 1200-second service keep-alive, dialect `auto`, and `--bare --no-memory`.
Use one concurrent trial, zero retries, unchanged task images/files and verifiers.
Record actual routed models, binary digest, pack hash and settings from provenance.
The cost threshold is checked between requests; it is not a hard spending cap.

| Arm | Time notices | Response tokens | Pack override |
| --- | --- | --- | --- |
| control | off | unset | none |
| time | on | unset | none |
| cap | off | 8192 | none |
| time-cap | on | 8192 | none |
| prompt | off | unset | `packs-early-implementation` |

Start with control versus time-cap on adaptive-rejection-sampler, write-compressor and
cancel-async-tasks, two attempts per task per arm: 12 real model trials total. The sampler
is the target failure; the other two passed with this model and check for regressions,
including a task that benefited from long reasoning. Each arm has six $1 thresholds;
they sum to $6 per arm, not an enforced batch cap. Inspect after the first arm before
starting the next. If the combination helps, use time and cap separately to attribute
the gain. Test prompt separately before combining it with runtime controls.

The response limit is a provider output-token limit, including reasoning and tool
arguments where the provider counts them. It is not a response-duration timer and does
not guarantee a complete tool call. Existing truncation handling drops incomplete calls,
offers one continuation, then stops with `truncated` after another text/reasoning-only
cutoff. Transport retries never replay a response that already emitted output.
Compaction, verifier and hook side requests retain their own existing request shapes.

Time notices enter user history before the first request and at remaining-time thresholds
of 50%, 25%, 10% and zero, at most five per turn. They cannot arrive during a running
response. `--timeout` still interrupts the whole run. The prompt arm adds only the
generic early-implementation paragraph in `packs-early-implementation/deepseek.md`;
the built-in DeepSeek family body is currently empty. It adds no task-specific solution
or verifier information. No default pack is changed.

Use verifier pass rate as the primary outcome. Also compare timeout/truncation counts,
cost, steps, tool calls, tokens and whether required artifacts were produced. Inspect
full trajectories for cut-off tool arguments or repeated empty reasoning continuations.
Do not count partial test credit as a passed task or combine these selected development
tasks into a general Terminal-Bench score. Two attempts are a screening exercise, not
strong statistical evidence; repeat promising arms and validate on fresh tasks before
proposing a default change for human review.

## Validation

Unit and isolated Linux scripted-provider checks verify request fields, time notices,
prefix stability, safe truncation handling and service lifecycle. These make zero external
model calls and cannot establish model-quality improvement.

## Results — 2026-09-09

The frozen control and time-cap arms each ran six real trials, two per task, with the
settings above. Both used source commit `81b01eb` and binary SHA256
`bf6cf6bf5f06bd7fef766fad5c0fa70b0c2cc7c3a896de798f2dad19420cc549`.

| Outcome | Control | Time-cap |
| --- | --- | --- |
| Passed attempts | 2/6 | 1/6 |
| Tasks solved at least once | 1/3 | 1/3 |
| Runtime | 1h 2m 35s | 34m 27s |
| Recorded model cost | $0.612307 | $0.275381 |
| Arnes endings | 2 completed, 3 timeout, 1 decoding error | 2 completed, 4 truncated |

Harbor reported zero exceptions in both arms. The separate Arnes decoding error still
counts as an agent/provider failure; the available logs do not establish its source.
Interrupted streams can omit final usage, so the recorded cost difference does not
establish the full billing savings.

Both sampler attempts and both compressor attempts in time-cap stopped after two
reasoning-only cutoffs, 264–291 seconds into their 900-second allowance, without the
required implementation or compressed artifact. The continuation request omitted the
interrupted reasoning. The remaining failure completed but missed an async-cancellation
cleanup requirement. Two attempts do not establish whether the cap caused that
correctness difference.

Decision: keep both controls opt-in and the response cap unset by default. The combined
arm showed no quality improvement. Time notices alone and the prompt proposal remain
untested. These selected tasks are development evidence, not an overall benchmark score.

## Next: verify context preservation before further tuning

Fix the confirmed loss of ordinary plaintext chat reasoning at a cutoff. Replay the
whole supported sequence unchanged, retain the single continuation allowance, and
continue dropping incomplete tool calls. Avoid extending this change to signed or
opaque cutoff blocks without evidence that they are complete and replayable. This is
consistent with OpenRouter's [reasoning replay contract](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens);
acceptance and usefulness of an interrupted sequence still need a live check.

After offline validation, screen the revised binary on adaptive-rejection-sampler and
write-compressor, one attempt each, using the failed time-cap settings above. This is
two real trials with $1 thresholds each, not a hard $2 batch cap. Compare with the frozen
time-cap trajectories, explicitly retaining their two-attempt counts. Check replayed
context, provider acceptance, steps after recovery, required artifacts and final verifier
results. A faster stop or a replay counter alone is not a quality gain. Do not treat this
small historical comparison as proof of causality.

If those trials again stop without implementation progress, stop capped experiments.
The next quality experiment is the existing early-implementation prompt proposal against
an uncapped control, with the same model and effort, changing only the pack. If recovery
does help, repeat a matched comparison with two attempts per arm on all three development
tasks, then validate on fresh tasks before proposing any default change for human review.
