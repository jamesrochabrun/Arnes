# Running Arnes on Terminal-Bench

[Terminal-Bench](https://www.tbench.ai), through [Harbor](https://www.harborframework.com/docs/agents),
evaluates terminal agents in disposable containers with independent executable checks.
This adapter is evaluation infrastructure, not a published score.

## Reproducible run (human-operated)

The adapter API and CLI syntax were checked against
[Harbor v0.16.1 source](https://github.com/laude-institute/harbor/tree/v0.16.1).
Install and record that exact version in your evaluation environment; source inspection
and offline mocks are not a successful Harbor/container integration run. Supply a
Linux binary built from the source revision under test, its SHA-256 digest, an explicit
model, and an effort setting. There is no moving-release download or source fallback.

```bash
export OPENROUTER_API_KEY=...
export ARNES_LINUX_BINARY_URL=https://your-host/arnes-linux-x86_64
export ARNES_LINUX_BINARY_SHA256='REPLACE_WITH_64_CHARACTER_SHA256'
export ARNES_MODEL='REPLACE_WITH_EXPLICIT_MODEL_SLUG'
export ARNES_EFFORT=high
export ARNES_MAX_STEPS=100
export ARNES_TIMEOUT=900
export ARNES_BUDGET=5
export ARNES_DIALECT=auto

PYTHONPATH=benchmarks/terminal-bench harbor run -d terminal-bench@2.0 \
  --agent arnes_agent:ArnesAgent --model "$ARNES_MODEL"
```

The limits above are defaults; binary URL, digest, model and effort are required.
Harbor's model must agree with `ARNES_MODEL`. Per-agent `extra_env` settings override
host environment values. Harbor also applies its own task execution deadline: choose
and record its `--agent-timeout-multiplier` consistently across arms so that deadline
allows the intended Arnes budget plus evidence collection. The adapter's per-command
deadline is `ARNES_TIMEOUT + 60` seconds; it cannot extend Harbor's outer deadline.
The binary must match the task container's architecture and support the current CLI
flags. A bad download, checksum, architecture or executable fails installation visibly.
Use an unsigned public artifact URL: Harbor may log installation commands.

The initial reproducible configuration uses OpenRouter, `--bare --no-memory`, disabled
manifest caching, and a separate packs directory. It ignores personal config, skills,
hooks and agents. The adapter passes `OPENROUTER_API_KEY` from per-agent `extra_env`
or the host environment through the container execution API, never shell interpolation
or provenance. Review Harbor/provider logs before sharing them as well. Provider manifests and
upstream routing can still change: compare the recorded routed models, not only the
requested slug.

For the guidance arm, set `ARNES_PACKS_DIR=evals/ab/packs-tool-guidance` on the host.
The adapter copies Markdown and tool-guidance JSON files into the container and records
their combined content hash. Files must be regular UTF-8 files, at most 64 KB each,
64 files and 1 MB combined; symbolic-link leaves and special files are refused.
Leave it unset for built-in guidance.

Optional, independently controlled experiments (all off/unset in the control):

- `ARNES_COMMAND_DIAGNOSTICS=true`: append bounded findings from foreground bash output.
- `ARNES_PRESERVE_COMMAND_EVIDENCE=true`: keep recent command/result excerpts in compaction input.
- `ARNES_KEEP_RECENT_TOOL_TOKENS=4000`: replace recent-result count with an estimated token budget.

Boolean controls accept only `true` or `false`; the token budget is a nonnegative integer.
The adapter writes these into its isolated config and provenance (schema version 2).
Manifest caching is disabled through `policies.manifestCache.enabled`; no personal config
is edited. A feature's implementation is not evidence that it improves task completion.

## Retained evidence

Each trial's mounted `/logs/agent` directory contains:

- `arnes-provenance.json`: requested model, effort, limits, dialect, binary digest and pack hash.
- `arnes-version.txt`, `arnes-binary.sha256`: identity read from the installed executable.
- `arnes-events.jsonl`: streamed events, including text/reasoning deltas.
- `arnes-transcript.jsonl`: persisted messages and tool results, copied after the run.
- `arnes-result.json`, `arnes-last-message.md`: result envelope and readable final answer.
- `arnes-exit-code.txt`, `arnes-stderr.log`, `arnes-status.json`: failure evidence.

A killed container can leave an incomplete event stream and no copied transcript; the
status records this instead of silently treating it as success. Tool-result previews
in the event stream are not a substitute for the transcript. Output caps still apply
to the actual conversation. Review trajectories before sharing: task data, code and
reasoning may be sensitive even when provider credentials are withheld.

Installation errors, usage errors, interruptions, incomplete trajectories, and combined
agent/provider errors are distinct from normal task attempts. Separating an agent bug
from a provider failure requires inspecting the recorded error; the adapter does not
guess from error prose. `completed` means the agent stopped, **not that the task passed**.
Harbor's task verifier determines correctness. Report infrastructure failures separately
and also include them in an end-to-end reliability denominator.

## Comparing changes

1. Freeze the dataset revision, task IDs, Harbor version, image architecture, binary
   digest, model, effort, limits and pack hash with the results.
   Include diagnostics, command-evidence and token-retention settings; change one initially.
2. Keep a development subset and a disjoint held-out subset; do not tune on held-out failures.
3. Run both arms on the same tasks, at least three repetitions, alternating arm order.
4. Report task-verifier success by task and repetition, failures by category, total cost,
   elapsed time and tool calls. Include all trials; do not discard failed installations.
5. Inspect regressions and use paired task outcomes before promoting a prompt default.
   A small or noisy improvement is inconclusive, not a new default.

Run offline contract checks without Harbor, containers or model calls:

```bash
python3 -m unittest discover -s benchmarks/terminal-bench -p 'test_*.py' -v
```

The adapter deliberately grants `--yes --add-dir /` only inside disposable Linux task
containers. Container isolation is required: Arnes has no native Linux OS sandbox backend.
Never use this grant on a host machine. Live Harbor/container validation remains a
human-run step; offline tests do not establish a Terminal-Bench score.
