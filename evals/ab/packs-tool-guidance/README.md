# Tool-guidance proposals

These are two family-specific configurations of one additive guidance experiment:
OpenAI-family and Anthropic-family. Neither has been promoted to a default or measured
as a quality improvement.

The control uses the built-in prompt and tool descriptions. The treatment uses the
same prompt, schemas and toolset, plus the matching `<family>.tools.json` file here.
Each entry appends guidance after the tool's existing description. The `task` entry
has no effect in a bare run, because that run has no delegation tool.

Use the paired-run protocol in [the benchmark guide](../../../benchmarks/terminal-bench/README.md).
Set `ARNES_PACKS_DIR` to this directory for the treatment; leave it unset for the
benchmark control (its adapter creates an empty pack directory). Record binary/pack
hashes, exact model, effort, limits, task IDs and all repetitions. Evaluate families
separately; an improvement on one does not justify changing the other's default.

Inspect exact-match edit failures, redundant file reads, duplicate background jobs,
tool calls, cost and independent task-verifier outcomes. Tool guidance is useful only
if it improves completion or reduces work without harming correctness or safety.
