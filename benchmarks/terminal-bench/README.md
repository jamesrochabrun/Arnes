# Running Arnes on Terminal-Bench

[Terminal-Bench](https://www.tbench.ai) (run via the [Harbor](https://www.harborframework.com)
harness) is the standard benchmark for terminal agents: containerized tasks with
programmatic test suites, the same scoring used for Claude Code, Codex CLI, and OpenHands.
`arnes_agent.py` is a Harbor `BaseInstalledAgent` adapter that installs `arnes` in each
task container and drives it headlessly with `arnes do`.

## Run

```bash
pip install harbor
export OPENROUTER_API_KEY=sk-or-...
export ARNES_MODEL=anthropic/claude-sonnet-5        # optional, default openrouter/auto

# from the repo root:
harbor run -d terminal-bench@2.0 \
  --agent benchmarks.terminal_bench.arnes_agent:ArnesAgent
```

Notes:

- **Prebuilt binary is the default.** Every tagged release ships static-stdlib Linux
  binaries (`arnes-linux-x86_64`, `arnes-linux-aarch64`) built by the Release workflow;
  the adapter fetches the latest one matching the container's arch automatically and only
  builds from source if no asset matches. Set `ARNES_LINUX_BINARY_URL` to pin a specific
  binary instead.
- Harbor evaluates *model + harness together* — that's exactly Arnes's thesis, so a run
  matrix over `ARNES_MODEL` values measures how well the model-adaptive harness carries
  each model. Compare against the same models under Terminus/Claude Code adapters.
- Terminal-Bench scores with each task's own verification suite; Arnes's `RunRecord`
  (cost, steps, routed models) accrues inside the container at `~/.arnes/runs.jsonl`
  per task if you want the economics too.
- Smaller/faster local iteration: `arnes eval evals/basics -m <model> -t 3` gives the
  same pass/cost/steps stats shape without Docker.

Adapter contract sourced from the Harbor docs (`BaseInstalledAgent`: `install()`,
`run()` with `@with_prompt_template`, `harbor run --agent path.to.module:Class`).
Verify against the current docs when Harbor updates.
