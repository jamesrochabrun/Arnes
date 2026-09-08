"""Adapter orchestration against the documented Harbor surface, not a live Harbor test."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from benchmark_contract import BenchmarkConfig


def load_adapter():
  modules = {}
  for name in ["harbor", "harbor.agents", "harbor.agents.installed", "harbor.agents.installed.base",
               "harbor.environments", "harbor.environments.base", "harbor.models",
               "harbor.models.agent", "harbor.models.agent.context"]:
    modules[name] = types.ModuleType(name)
  class InstalledAgentContract:
    def __init__(self, logs_dir, model_name=None, extra_env=None):
      self.logs_dir = Path(logs_dir)
      self.model_name = model_name
      self.extra_env = dict(extra_env or {})
  modules["harbor.agents.installed.base"].BaseInstalledAgent = InstalledAgentContract
  modules["harbor.agents.installed.base"].with_prompt_template = lambda function: function
  modules["harbor.environments.base"].BaseEnvironment = object
  modules["harbor.models.agent.context"].AgentContext = object
  spec = importlib.util.spec_from_file_location("adapter_under_test", Path(__file__).with_name("arnes_agent.py"))
  module = importlib.util.module_from_spec(spec)
  with patch.dict(sys.modules, modules):
    spec.loader.exec_module(module)
  return module


adapter = load_adapter()


class AdapterTests(unittest.IsolatedAsyncioTestCase):
  async def asyncSetUp(self):
    self.directory = tempfile.TemporaryDirectory(prefix="arnes-adapter-test-")
    self.addCleanup(self.directory.cleanup)
    self.agent = adapter.ArnesAgent(logs_dir=Path(self.directory.name))
    self.commands = []
    self.executions = []
    async def execute(environment, command, env=None, timeout_sec=None):
      self.commands.append(command)
      self.executions.append(dict(env=env, timeout_sec=timeout_sec))
      return types.SimpleNamespace(return_code=0)
    self.agent.exec_as_root = execute
    self.agent.exec_as_agent = execute
    async def run_command(**kwargs):
      return await execute(None, **kwargs)
    self.container = types.SimpleNamespace(exec=run_command)
    self.environment = dict(ARNES_LINUX_BINARY_URL="https://example.com/arnes",
      ARNES_LINUX_BINARY_SHA256="a" * 64, ARNES_MODEL="test/model", ARNES_EFFORT="high")

  async def test_install_verifies_before_executing_and_never_falls_back(self):
    with patch.dict("os.environ", self.environment, clear=True):
      await self.agent.install(None)
    command = self.commands[0]
    self.assertLess(command.index("sha256sum -c"), command.index("install -m"))
    self.assertLess(command.index("install -m"), command.index("/usr/local/bin/arnes --version"))
    self.assertNotIn("latest", command)
    self.assertNotIn("git clone", command)
    subprocess.run(["bash", "-n"], input=command, text=True, check=True)

  async def test_install_failure_is_recorded_and_propagated(self):
    async def fail(environment, command):
      raise RuntimeError("download failed")
    self.agent.exec_as_root = fail
    with patch.dict("os.environ", self.environment, clear=True), self.assertRaises(RuntimeError):
      await self.agent.install(None)
    status = json.loads((Path(self.directory.name) / "arnes-status.json").read_text())
    self.assertEqual(status["classification"], "installation_error")

  async def test_run_captures_status_and_uses_session_transcript(self):
    self.agent.arnes_config = BenchmarkConfig.from_environment(self.environment)
    self.agent.arnes_packs = {"other.tools.json": '{"bash":"Do not evaluate $(anything)."}'}
    self.agent.arnes_provenance = self.agent.arnes_config.provenance()
    context = types.SimpleNamespace(metadata={})
    await self.agent.run("fix 'this'\n$(untrusted)", self.container, context)
    command = self.commands[0]
    for expected in ["set +e", "arnes-exit-code.txt", "arnes-events.jsonl", "arnes-transcript.jsonl", "umask 077"]:
      self.assertIn(expected, command)
    subprocess.run(["bash", "-n"], input=command, text=True, check=True)
    self.assertEqual(context.metadata["arnes"]["classification"], "incomplete_trajectory")

  async def test_populates_economics_without_claiming_pass(self):
    root = Path(self.directory.name)
    result = dict(type="result", stop_reason="max_steps", is_error=False, cost_usd=0.4,
      prompt_tokens=100, completion_tokens=20, routed_models=["test/routed"])
    (root / "arnes-events.jsonl").write_text(json.dumps(result) + "\n")
    (root / "arnes-exit-code.txt").write_text("3\n")
    context = types.SimpleNamespace(metadata={})
    self.agent.populate_context_post_run(context)
    self.assertEqual(context.cost_usd, 0.4)
    self.assertEqual(context.n_input_tokens, 100)
    self.assertEqual(context.metadata["arnes"]["classification"], "task_attempt")
    self.assertEqual(context.metadata["arnes"]["routed_models"], ["test/routed"])
    self.assertFalse(context.metadata["arnes"]["transcript_available"])

  async def test_agent_environment_overrides_host_and_credentials_stay_out_of_commands(self):
    self.agent.extra_env = dict(self.environment, ARNES_MAX_STEPS="7", OPENROUTER_API_KEY="unit-test-credential")
    with patch.dict("os.environ", {"ARNES_MAX_STEPS": "999"}, clear=True):
      await self.agent.install(None)
      context = types.SimpleNamespace(metadata=None)
      await self.agent.run("check", self.container, context)
    self.assertEqual(self.agent.arnes_config.max_steps, 7)
    self.assertEqual(self.agent.arnes_provenance["max_steps"], 7)
    self.assertEqual(self.executions[-1]["env"], {"OPENROUTER_API_KEY": "unit-test-credential"})
    self.assertEqual(self.executions[-1]["timeout_sec"], 960)
    self.assertNotIn("unit-test-credential", "\n".join(self.commands))
    self.assertNotIn("unit-test-credential", json.dumps(context.metadata))
    self.assertIn("arnes", context.metadata)

  async def test_conflicting_harbor_model_is_refused_before_install(self):
    self.agent.model_name = "different/model"
    with patch.dict("os.environ", self.environment, clear=True), self.assertRaises(ValueError):
      await self.agent.install(None)
    self.assertEqual(self.commands, [])

  async def test_cache_accounting_and_default_none_metadata(self):
    root = Path(self.directory.name)
    result = dict(type="result", stop_reason="completed", is_error=False, cached_tokens=80,
      cost_usd=0.3, prompt_tokens=100, completion_tokens=20)
    (root / "arnes-events.jsonl").write_text(json.dumps(result) + "\n")
    (root / "arnes-exit-code.txt").write_text("0\n")
    context = types.SimpleNamespace(metadata=None)
    self.agent.populate_context_post_run(context)
    self.assertEqual(context.n_cache_tokens, 80)
    self.assertEqual(context.n_input_tokens, 100)
    self.assertEqual(context.metadata["arnes"]["classification"], "task_attempt")

  async def test_invalid_usage_values_are_not_assigned_to_context(self):
    root = Path(self.directory.name)
    result = dict(type="result", stop_reason="completed", is_error=False,
      cached_tokens=True, cost_usd=float("inf"), prompt_tokens=-1, completion_tokens=1.5)
    (root / "arnes-events.jsonl").write_text(json.dumps(result) + "\n")
    context = types.SimpleNamespace(metadata=None)
    self.agent.populate_context_post_run(context)
    for field in ["cost_usd", "n_input_tokens", "n_output_tokens", "n_cache_tokens"]:
      self.assertFalse(hasattr(context, field))

  async def test_environment_failure_propagates_without_copying_output(self):
    self.agent.arnes_config = BenchmarkConfig.from_environment(self.environment)
    self.agent.arnes_packs = {}
    self.agent.arnes_provenance = self.agent.arnes_config.provenance()
    async def fail(**kwargs):
      return types.SimpleNamespace(return_code=1, stderr="private test fixture")
    context = types.SimpleNamespace(metadata=None)
    with self.assertRaisesRegex(RuntimeError, "evidence capture failed") as raised:
      await self.agent.run("check", types.SimpleNamespace(exec=fail), context)
    self.assertNotIn("private test fixture", str(raised.exception))
    self.assertEqual(context.metadata["arnes"]["classification"], "incomplete_trajectory")


if __name__ == "__main__":
  unittest.main()
