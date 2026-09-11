# Running Arnes on Terminal-Bench

[Terminal-Bench](https://www.tbench.ai), through [Harbor](https://www.harborframework.com/docs/agents),
evaluates terminal agents in disposable containers with independent executable checks.
This adapter is evaluation infrastructure, not a published score.

## Reproducible run (human-operated)

The adapter API and CLI syntax were checked against
[Harbor v0.16.1 source](https://github.com/laude-institute/harbor/tree/v0.16.1).
Install and record that exact version in your evaluation environment; source inspection
and offline mocks are not a successful Harbor/container integration run. On 2026-09-07,
an installation-only check passed on Terminal-Bench 2.0 `fix-git`, rebuilt for Linux
arm64, using the binary built from `81b468c` and the adapter's prerequisite bootstrap.
It verified download, checksum and version 0.7.0; no model or task verifier ran. Supply a
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
export ARNES_KEEP_ALIVE_SECONDS=1200
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
Installation also checks for `do --keep-alive`; older binaries must be rebuilt.
Use an unsigned public artifact URL: Harbor may log installation commands.
On Debian/Ubuntu task images the adapter installs `ca-certificates`, `curl` (including
its libcurl runtime), and `libstdc++6` before downloading the executable. Other images
must already provide these prerequisites and a compatible glibc runtime. A static Swift
standard library build still depends on these system libraries.

The adapter preserves the task image's umask for Arnes and task-created files, while
creating its evidence with owner-only permissions. On a completed turn it returns to
Harbor as soon as the final result and transcript are available. Arnes retains ownership
of managed services for `ARNES_KEEP_ALIVE_SECONDS` (default 1200; allowed 0...3600), so
the independent verifier can connect to them. Choose a grace period longer than the
task's verifier timeout plus scheduling overhead; each job's own timeout still applies. Arnes closes the session and kills its
jobs at that deadline or on SIGINT/SIGTERM; Harbor normally destroys the container first.
No additional model calls occur during this period. Stopped or errored turns close immediately.
Use 0 for immediate shutdown. This option does not extend the model's step/time/cost limits.

The initial reproducible configuration uses OpenRouter, `--bare --no-memory`, disabled
manifest caching, and a separate packs directory. It ignores personal config, skills,
hooks and agents. The adapter passes `OPENROUTER_API_KEY` from per-agent `extra_env`
or the host environment through the container execution API, never shell interpolation
or provenance. Review Harbor/provider logs before sharing them as well. Provider manifests and
upstream routing can still change: compare the recorded routed models, not only the
requested slug.

`ARNES_MODEL` normally refuses a router alias such as `openrouter/auto`: the model would be
chosen per request, so the requested slug would say nothing about what answered and no two
runs would be guaranteed comparable. Set `ARNES_ROUTER_ALIAS=true` when the router *is* the
experiment; the opt-in is recorded in provenance so the evidence says a router chose. Harbor's
`--model` must still match `ARNES_MODEL`. `openrouter/auto` is itself a manifest row, so such a
run keeps reasoning and vision — verified live: the effort dial is delivered and only `think` is
withheld. What it loses is the family prompt pack and any native dialect, because both key off
the requested slug rather than the model that answers. Its manifest price is `-1` ("varies with
whatever it picks"), which `ModelProfile.price` treats as no price at all, so a fallback
estimate declines instead of returning a negative cost; real cost still comes from the
provider's usage. The arms, metrics and publication rules for an alias arm are in
`evals/ab/model-routing.md` (local, Git-ignored, like every Harbor protocol here); read it
before running or publishing one.

For the guidance arm, set `ARNES_PACKS_DIR=evals/ab/packs-tool-guidance` on the host.
The adapter copies Markdown and tool-guidance JSON files into the container and records
their combined content hash. Files must be regular UTF-8 files, at most 64 KB each,
64 files and 1 MB combined; symbolic-link leaves and special files are refused.
Leave it unset for built-in guidance.

**Pin the upstream provider for any comparison.** `ARNES_PROVIDER_ONLY=Together,Fireworks`
restricts which upstream providers may serve the model, strictly — fallbacks off, so a pin
cannot silently unpin itself. A model id names a model, not a machine: OpenRouter chooses a
provider per request, and the same slug served by different providers differs in latency,
price and output quality. On 2026-09-10 one provider returned content wholly unrelated to the
task, which scored as an ordinary task failure. Unpinned, that variance is larger than most
of what a harness comparison is trying to measure, and it is invisible in the result. The
chosen providers are recorded in provenance; leave it unset for the router's own behavior.

Optional, independently controlled experiments (all off/unset in the control):

- `ARNES_COMMAND_DIAGNOSTICS=true`: append bounded findings from foreground bash output.
- `ARNES_PRESERVE_COMMAND_EVIDENCE=true`: keep recent command/result excerpts in compaction input.
- `ARNES_KEEP_RECENT_TOOL_TOKENS=4000`: replace recent-result count with an estimated token budget.
- `ARNES_TIME_AWARE=true`: send remaining-time notices at request boundaries, starting before
  the first request. The existing `ARNES_TIMEOUT` still enforces the deadline.
- `ARNES_MAX_RESPONSE_TOKENS=8192`: set a positive per-response output-token ceiling for the
  main loop, including reasoning and tool arguments. It is not a response-duration timer;
  a cutoff uses the existing bounded continuation and partial-call refusal behavior.

Boolean controls accept only `true` or `false`; the recent-tool token budget is nonnegative
and the response-token ceiling is positive. The adapter writes settings into its isolated
config or CLI arguments and provenance (schema version 5, which added `router_alias`). Installation checks that the
binary supports each enabled CLI experiment. For the independent early-implementation
prompt proposal, use `ARNES_PACKS_DIR=evals/ab/packs-early-implementation`.
See [the controlled time-budget protocol](../../evals/ab/time-budget.md).
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
- `arnes-pid.txt`, `arnes-supervisor.log`: the retained CLI process and its supervisor.

`arnes-exit-code.txt` exists only after the CLI exits; it can be absent when Harbor
collects logs during the grace period. A complete `arnes-result.json` is the turn's
handoff; an absent process exit code alone does not mean an incomplete turn.

The adapter uses uppercase session UUIDs to match Arnes's canonical transcript filenames
on Linux. A completed run should report `transcript_available: true`; check that field
alongside the verifier result before expanding a run. The first human-operated `fix-git`
trial on 2026-09-08 passed both verifier checks for $0.002143683724, but its transcript
was not retained because the earlier adapter used lowercase UUIDs. Its events and result
remain valid; it is not a complete transcript or a full-suite score. The filename fix
is covered by a shell regression and an actual Linux binary with a loopback provider fixture.

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

For pytest tasks that write CTRF (including the five-task development batch), run:

```bash
python3 benchmarks/terminal-bench/check_verification.py /path/to/harbor/job
```

This preserves Harbor's raw reward and distinguishes verified failures from missing,
partial or inconsistent test reports. A September 8 `build-pmars` trial had reward 0
after the uv installer download failed; no task tests ran. It is unverified, not evidence
that the generated program failed its tests. Before spending on a rerun, execute
`preflight-verifier.sh` inside a disposable copy of the task's image. It downloads uv
0.9.5 and resolves Python 3.13, pytest 8.4.1 and pytest-json-ctrf 0.3.5, matching this
development batch. The script refuses to run on the host. It checks dependency availability;
it does not run or modify task tests, and cannot guarantee a later network request succeeds.

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

To compare arms that differ by model — including a `openrouter/auto` arm against fixed
models — give each arm's job directory a label:

```bash
python3 benchmarks/terminal-bench/routing_report.py \
  --arm auto=/path/to/auto-job --arm strong=/path/to/strong-job --reference auto
```

It pairs arms on (task, repetition), reports pass rate, **cost per solved task**, the models
the router actually chose with their upstream providers, an exact McNemar p-value and the
oracle gap, and flags trials whose numbers are unsafe to publish — an estimated cost, a
requested effort that produced no reasoning, malformed events, missing evidence. It exits
nonzero when a held-constant setting differs across arms or no arm solved anything.

After a suite run, triage the failures before deciding what to change:

```bash
python3 benchmarks/terminal-bench/failure_triage.py /path/to/harbor/job \
  --dataset .build/harbor-smoke/datasets/terminal-bench
```

It buckets every failure by what the trajectory supports and ranks the buckets by how many
tasks sit in each, so the next change is chosen by counts. It attributes a failure to the
harness only where the evidence decides on its own — a deadline hit, our own budget ceiling, or
build output left beside the deliverable in a task whose tests assert an exact directory
listing. Everything else lands in one `completed_but_wrong` pool with its numbers exposed,
because the two attempts at inferring "did it verify its work" both produced wrong answers on
real data. A bucket is where to look, not what to fix.

Run offline contract checks without Harbor, containers or model calls:

```bash
python3 -m unittest discover -s benchmarks/terminal-bench -p 'test_*.py' -v
```

The adapter deliberately grants `--yes --add-dir /` only inside disposable Linux task
containers. Container isolation is required: Arnes has no native Linux OS sandbox backend.
Never use this grant on a host machine. Live Harbor/container validation remains a
human-run step; offline tests do not establish a Terminal-Bench score.
