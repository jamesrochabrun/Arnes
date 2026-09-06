# Running Arnes on Terminal-Bench

[Terminal-Bench](https://www.tbench.ai) (run via the [Harbor](https://www.harborframework.com)
harness) evaluates terminal agents on containerized tasks with programmatic test suites.
`arnes_agent.py` is a Harbor `BaseInstalledAgent` adapter that installs `arnes` in each
task container and drives it headlessly with `arnes do`.

This directory provides an adapter, not a published score or a claim of parity with another
agent. A live run spends model credits and requires a container environment. The adapter
has not been exercised as part of the documentation checks.

## Run

```bash
pip install harbor
export OPENROUTER_API_KEY=sk-or-...
export ARNES_MODEL=anthropic/claude-sonnet-5        # optional, default openrouter/auto

# from the repo root:
PYTHONPATH=benchmarks/terminal-bench harbor run -d terminal-bench@2.0 \
  --agent arnes_agent:ArnesAgent
```

Notes:

- **Prebuilt binary is the default.** Every tagged release ships static-stdlib Linux
  binaries (`arnes-linux-x86_64`, `arnes-linux-aarch64`) built by the Release workflow;
  the adapter fetches the latest one matching the container's arch automatically and only
  builds from source if no asset matches. Set `ARNES_LINUX_BINARY_URL` to pin a specific
  binary instead.
- The default download uses the **published release**, not the local checkout. To evaluate
  a particular source revision, build and host its Linux binary and pass its URL through
  `ARNES_LINUX_BINARY_URL`. Record the binary version/commit with the results.
- Harbor evaluates *model + harness together* — that's exactly Arnes's thesis, so a run
  matrix over `ARNES_MODEL` values measures how well the model-adaptive harness carries
  each model. Compare against the same models under Terminus/Claude Code adapters.
- Terminal-Bench scores with each task's own verification suite; Arnes's `RunRecord`
  (cost, steps, routed models) accrues inside the container at `~/.arnes/runs.jsonl`
  per task if you want the economics too.
- The adapter also writes `/logs/agent/arnes-result.json` and `arnes-last-message.md`.
  It reads the result envelope into Harbor's cost/token fields; Harbor's task tests decide
  correctness independently of Arnes's exit code or final report.
- The adapter passes `--yes --add-dir /` inside each disposable task container. The container
  supplies isolation; Arnes does not currently have a Linux OS sandbox backend. Do not use
  that broad directory grant as a host-machine example.
- Smaller/faster local iteration: `arnes eval evals/basics -m <model> -t 3` gives the
  same pass/cost/steps stats shape without Docker.

Adapter contract sourced from the [Harbor agent docs](https://www.harborframework.com/docs/agents)
(`BaseInstalledAgent`: `install()`,
`run()` with `@with_prompt_template`, `harbor run --agent path.to.module:Class`).
Verify against the current docs when Harbor updates.
