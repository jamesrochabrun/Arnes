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
model calls and cannot establish model-quality improvement. Paid benchmark results are
pending human-operated runs.
