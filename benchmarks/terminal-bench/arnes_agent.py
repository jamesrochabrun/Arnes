"""Pinned Harbor adapter. See README.md for required variables and human-run evaluations."""
import base64
import json
import math
import os
from pathlib import Path
import shlex
import uuid

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from benchmark_contract import BenchmarkConfig, load_packs, pack_fingerprint, parse_trajectory

LOGS = "/logs/agent"


def write_command(path, content):
  """Transfer fixed bytes without interpreting task or pack text as shell syntax."""
  encoded = base64.b64encode(content.encode()).decode()
  return f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(path)}"


class ArnesAgent(BaseInstalledAgent):
  @staticmethod
  def name() -> str:
    return "arnes"

  def get_version_command(self) -> str:
    return "/usr/local/bin/arnes --version"

  async def install(self, environment: BaseEnvironment) -> None:
    settings = dict(os.environ, **self.extra_env)
    self.arnes_config = BenchmarkConfig.from_environment(settings)
    config = self.arnes_config
    if self.model_name is not None and self.model_name != config.model:
      raise ValueError("Harbor's model and ARNES_MODEL disagree; use the same explicit model")
    self.arnes_packs = load_packs(settings.get("ARNES_PACKS_DIR"))
    self.arnes_provenance = config.provenance()
    self.arnes_provenance["packs_sha256"] = pack_fingerprint(self.arnes_packs)
    self.arnes_provenance["packs"] = sorted(self.arnes_packs)
    try:
      await self.exec_as_root(environment, command=(
        "set -eu; candidate=$(mktemp /tmp/arnes-binary.XXXXXXXX); "
        "trap 'rm -f \"$candidate\"' EXIT; "
        f"curl --proto '=https' --proto-redir '=https' -fLsS --retry 2 --max-time 120 {shlex.quote(config.binary_url)} -o \"$candidate\"; "
        f"printf '%s  %s\\n' {shlex.quote(config.binary_sha256)} \"$candidate\" | sha256sum -c -; "
        "install -m 755 \"$candidate\" /usr/local/bin/arnes; "
        "/usr/local/bin/arnes --version"
      ))
    except Exception:
      # Harbor keeps the setup logs; do not duplicate potentially private exception text.
      Path(self.logs_dir).mkdir(parents=True, exist_ok=True)
      (Path(self.logs_dir) / "arnes-status.json").write_text(
        json.dumps(dict(self.arnes_provenance, classification="installation_error")) + "\n")
      raise

  @with_prompt_template
  async def run(self, instruction: str, environment: BaseEnvironment, context: AgentContext) -> None:
    config = self.arnes_config
    session_id = str(uuid.uuid4())
    self.arnes_provenance["session_id"] = session_id
    setup = [
      f"mkdir -p {LOGS}/packs",
      write_command(f"{LOGS}/arnes-provenance.json", json.dumps(self.arnes_provenance) + "\n"),
      write_command(f"{LOGS}/arnes-config.json", json.dumps(config.runtime_config())),
    ]
    for name, text in self.arnes_packs.items():
      setup.append(write_command(f"{LOGS}/packs/{name}", text))
    setup.extend([
      f"/usr/local/bin/arnes --version > {LOGS}/arnes-version.txt",
      f"sha256sum /usr/local/bin/arnes > {LOGS}/arnes-binary.sha256",
      f"export ARNES_CONFIG={LOGS}/arnes-config.json ARNES_PACKS_DIR={LOGS}/packs",
    ])
    # Keep exit status without preventing Harbor's independent task verifier. Event
    # previews are not complete tool results; save the actual session transcript too.
    command = "; ".join(setup)
    command += (
      "; set +e; " + config.command(instruction, session_id)
      + f" </dev/null >{LOGS}/arnes-events.jsonl 2>{LOGS}/arnes-stderr.log; "
      + f"arnes_status=$?; printf '%s\\n' \"$arnes_status\" > {LOGS}/arnes-exit-code.txt; "
      + "arnes_home=$(getent passwd \"$(id -u)\" | cut -d: -f6); "
      + f"if test -n \"$arnes_home\" && test -f \"$arnes_home/.arnes/sessions/{session_id}.jsonl\"; then "
      + f"cp \"$arnes_home/.arnes/sessions/{session_id}.jsonl\" {LOGS}/arnes-transcript.jsonl; fi; true"
    )
    try:
      # Explicit per-exec environment, never interpolate a credential into shell text.
      # Harbor's extra_env wins over host values just as it does for other agents.
      key = self.extra_env.get("OPENROUTER_API_KEY", os.environ.get("OPENROUTER_API_KEY"))
      env = {"OPENROUTER_API_KEY": key} if key else None
      # Some Harbor releases log raw per-exec env in the installed-agent helper.
      # Use the environment API directly for this credential-bearing invocation.
      execution = await environment.exec(command="set -o pipefail; set -eu; umask 077; " + command,
        env=env, timeout_sec=config.timeout + 60)
      if execution.return_code != 0:
        raise RuntimeError("Benchmark setup or evidence capture failed; inspect the environment logs")
    finally:
      self.populate_context_post_run(context)

  def populate_context_post_run(self, context: AgentContext) -> None:
    root = Path(self.logs_dir)
    root.mkdir(parents=True, exist_ok=True)
    try:
      exit_code = int((root / "arnes-exit-code.txt").read_text().strip())
    except (OSError, ValueError):
      exit_code = None
    try:
      with (root / "arnes-events.jsonl").open() as stream:
        parsed = parse_trajectory(stream, exit_code)
    except OSError:
      parsed = parse_trajectory([], exit_code)
    result = parsed.pop("result")
    if result is not None:
      (root / "arnes-result.json").write_text(json.dumps(result) + "\n")
      for key, field in [("cost_usd", "cost_usd"), ("prompt_tokens", "n_input_tokens"),
                         ("completion_tokens", "n_output_tokens"), ("cached_tokens", "n_cache_tokens")]:
        value = result.get(key)
        valid = isinstance(value, int) and not isinstance(value, bool) and value >= 0
        if field == "cost_usd" and isinstance(value, float):
          valid = math.isfinite(value) and value >= 0
        if valid:
          setattr(context, field, value)
      parsed.update({"stop_reason": result.get("stop_reason"),
                     "routed_models": result.get("routed_models"),
                     "steps": result.get("steps"), "tool_calls": result.get("tool_calls")})
    parsed["transcript_available"] = (root / "arnes-transcript.jsonl").is_file()
    (root / "arnes-status.json").write_text(json.dumps(parsed) + "\n")
    if context.metadata is None:
      context.metadata = {}
    context.metadata["arnes"] = parsed
