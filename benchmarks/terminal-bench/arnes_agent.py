"""Harbor adapter that runs Arnes on Terminal-Bench tasks.

Usage:
    pip install harbor
    export OPENROUTER_API_KEY=sk-or-...
    PYTHONPATH=benchmarks/terminal-bench harbor run -d terminal-bench@2.0 --agent arnes_agent:ArnesAgent

The adapter downloads the latest published Linux binary by default, or the URL in
ARNES_LINUX_BINARY_URL. A source build is the fallback when the default download
fails. Pick the model with ARNES_MODEL (default: openrouter/auto).
"""

import json
import os
import shlex

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

ARNES_REPO = "https://github.com/jamesrochabrun/Arnes"

# Where the run's result envelope and final message land inside the container. Harbor mounts
# the agent's log directory at this path, so the host-side `populate_context_post_run` can
# read them back from `self.logs_dir`.
CONTAINER_LOGS_DIR = "/logs/agent"
RESULT_FILE = "arnes-result.json"
LAST_MESSAGE_FILE = "arnes-last-message.md"


class ArnesAgent(BaseInstalledAgent):
    """Runs `arnes do "<instruction>"` headlessly inside the task container."""

    @staticmethod
    def name() -> str:
        return "arnes"

    async def install(self, environment: BaseEnvironment) -> None:
        binary_url = os.environ.get("ARNES_LINUX_BINARY_URL")
        if binary_url:
            await self.exec_as_root(
                environment,
                "curl -fsSL {url} -o /usr/local/bin/arnes && chmod +x /usr/local/bin/arnes".format(
                    url=shlex.quote(binary_url)
                ),
            )
            return
        # Default: the static binary from the latest GitHub release, matched to the
        # container's arch. Leaves nothing behind on failure so the source-build
        # fallback below can detect it.
        await self.exec_as_root(
            environment,
            'arch="$(uname -m)"; '
            f'curl -fsSL "{ARNES_REPO}/releases/latest/download/arnes-linux-${{arch}}" '
            "-o /usr/local/bin/arnes && chmod +x /usr/local/bin/arnes "
            "&& arnes --help >/dev/null 2>&1 || rm -f /usr/local/bin/arnes",
        )
        # Fallback: build from source (slow — a few minutes per container).
        await self.exec_as_root(
            environment,
            "command -v arnes >/dev/null || "
            "(apt-get update && apt-get install -y curl git clang libcurl4-openssl-dev)",
        )
        await self.exec_as_root(
            environment,
            "command -v arnes >/dev/null || "
            "curl -fsSL https://swift.org/install.sh | bash -s -- --yes || true",
        )
        await self.exec_as_agent(
            environment,
            "command -v arnes >/dev/null || ("
            f"git clone --depth 1 {ARNES_REPO} /tmp/arnes-src && "
            "cd /tmp/arnes-src && swift build -c release && "
            "cp .build/release/arnes /usr/local/bin/arnes)",
        )

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        model = os.environ.get("ARNES_MODEL", "openrouter/auto")
        result_path = f"{CONTAINER_LOGS_DIR}/{RESULT_FILE}"
        last_message_path = f"{CONTAINER_LOGS_DIR}/{LAST_MESSAGE_FILE}"
        # OPENROUTER_API_KEY is merged into the environment by the harness config.
        await self.exec_as_agent(
            environment,
            # --yes: the task container is disposable and nobody answers permission prompts.
            # --add-dir /: --yes approves ordinary work inside the working directory only;
            # Terminal-Bench tasks legitimately write all over a throwaway container, so the
            # widening is stated explicitly instead of riding along with --yes.
            # --output-format json: stdout is one result envelope (cost, steps, stop_reason),
            # saved for populate_context_post_run; --output-last-message keeps the final
            # report readable on its own. </dev/null: arnes reads a non-terminal stdin as
            # context, and a harness may hold the pipe open. The exit code is deliberately
            # not propagated (a max_steps stop is exit 3): Terminal-Bench scores each task
            # with its own tests, and the envelope says how the run ended.
            f"mkdir -p {shlex.quote(CONTAINER_LOGS_DIR)}; "
            f"arnes do {shlex.quote(instruction)} -m {shlex.quote(model)} --yes --add-dir / "
            f"--output-format json --output-last-message {shlex.quote(last_message_path)} "
            f"</dev/null >{shlex.quote(result_path)}; true",
        )

    def populate_context_post_run(self, context: AgentContext) -> None:
        # The result envelope written inside the container (see `run`) is read back from the
        # mounted logs directory. Terminal-Bench scores via each task's own test suite, so
        # everything here is bookkeeping — best effort, never a failure.
        try:
            path = os.path.join(str(self.logs_dir), RESULT_FILE)
            with open(path, encoding="utf-8") as handle:
                envelope = json.loads(handle.read().strip().splitlines()[-1])
        except (OSError, ValueError, IndexError, AttributeError):
            return
        try:
            cost = envelope.get("cost_usd")
            if cost is not None:
                context.cost_usd = float(cost)
            prompt_tokens = envelope.get("prompt_tokens")
            if prompt_tokens is not None:
                context.n_input_tokens = int(prompt_tokens)
            completion_tokens = envelope.get("completion_tokens")
            if completion_tokens is not None:
                context.n_output_tokens = int(completion_tokens)
            metadata = getattr(context, "metadata", None)
            if isinstance(metadata, dict):
                metadata.update(
                    {
                        "arnes_stop_reason": envelope.get("stop_reason"),
                        "arnes_steps": envelope.get("steps"),
                        "arnes_tool_calls": envelope.get("tool_calls"),
                        "arnes_denied_calls": envelope.get("denied_calls"),
                        "arnes_routed_models": envelope.get("routed_models"),
                        "arnes_cost_estimated": envelope.get("cost_estimated"),
                    }
                )
        except (AttributeError, TypeError, ValueError):
            # An AgentContext without these fields: the envelope is still on disk.
            return
