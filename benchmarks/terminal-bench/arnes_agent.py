"""Harbor adapter that runs Arnes on Terminal-Bench tasks.

Usage:
    pip install harbor
    export OPENROUTER_API_KEY=sk-or-...
    harbor run -d terminal-bench@2.0 --agent benchmarks.terminal_bench.arnes_agent:ArnesAgent

The adapter installs Swift + builds arnes inside the task container, or uses a
prebuilt Linux binary when ARNES_LINUX_BINARY_URL is set (much faster). Pick the
model with ARNES_MODEL (default: openrouter/auto).
"""

import os
import shlex

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

ARNES_REPO = "https://github.com/jamesrochabrun/Arnes"


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
        # Fallback: build from source (slow — a few minutes per container).
        await self.exec_as_root(
            environment,
            "apt-get update && apt-get install -y curl git clang libcurl4-openssl-dev",
        )
        await self.exec_as_root(
            environment,
            "curl -fsSL https://swift.org/install.sh | bash -s -- --yes || true",
        )
        await self.exec_as_agent(
            environment,
            f"git clone --depth 1 {ARNES_REPO} /tmp/arnes-src && "
            "cd /tmp/arnes-src && swift build -c release && "
            "cp .build/release/arnes /usr/local/bin/arnes",
        )

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        model = os.environ.get("ARNES_MODEL", "openrouter/auto")
        # OPENROUTER_API_KEY is merged into the environment by the harness config.
        await self.exec_as_agent(
            environment,
            f"arnes do {shlex.quote(instruction)} -m {shlex.quote(model)}",
        )

    def populate_context_post_run(self, context: AgentContext) -> None:
        # Cost/steps land in ~/.arnes/runs.jsonl inside the container; Terminal-Bench
        # scores via each task's own test suite, so nothing further is required here.
        pass
