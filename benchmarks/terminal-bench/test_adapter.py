"""Adapter orchestration against the documented Harbor surface, not a live Harbor test."""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
import uuid
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

  async def test_install_capability_check_consumes_help_under_harbor_pipefail(self):
    with patch.dict("os.environ", self.environment, clear=True):
      await self.agent.install(None)
    root = Path(self.directory.name)
    binary = root / "help-fixture"
    binary.write_text(f"#!{sys.executable}\n" + """import os
os.write(1, b'--keep-alive\\n')
for _ in range(1024):
  os.write(1, b'additional help text ' * 1024 + b'\\n')
""")
    binary.chmod(0o700)
    # Harbor's installed-agent helper enables pipefail. A grep that exits at its first
    # match breaks the producer's later writes and incorrectly fails installation.
    command = self.commands[0]
    check = command[command.index("/usr/local/bin/arnes do --help"):]
    check = check.replace("/usr/local/bin/arnes", shlex.quote(str(binary)))
    completed = subprocess.run(["bash", "-o", "pipefail", "-c", check],
      capture_output=True, text=True, timeout=10)
    self.assertEqual(completed.returncode, 0, completed.stderr)

  async def test_enabled_time_experiments_refuse_an_older_binary(self):
    with patch.dict("os.environ", dict(self.environment,
      ARNES_TIME_AWARE="true", ARNES_MAX_RESPONSE_TOKENS="8192"), clear=True):
      await self.agent.install(None)
    command = self.commands[0]
    check = command[command.index("/usr/local/bin/arnes do --help"):]
    binary = Path(self.directory.name) / "help-fixture"
    binary.write_text("#!/bin/sh\nprintf '%s\\n' --keep-alive\n")
    binary.chmod(0o700)
    check = check.replace("/usr/local/bin/arnes", shlex.quote(str(binary)))
    rejected = subprocess.run(["bash", "-o", "pipefail", "-c", check], capture_output=True, text=True)
    self.assertNotEqual(rejected.returncode, 0)
    self.assertIn("--time-aware", rejected.stderr)
    binary.write_text("#!/bin/sh\nprintf '%s\\n' --keep-alive --time-aware --max-response-tokens\n")
    accepted = subprocess.run(["bash", "-o", "pipefail", "-c", check], capture_output=True, text=True)
    self.assertEqual(accepted.returncode, 0, accepted.stderr)

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

  async def test_copies_transcript_from_canonical_cli_session_filename(self):
    root = Path(self.directory.name)
    home = root / "home"
    binary = root / "arnes-fixture"
    # Like Swift's UUID.uuidString, the CLI fixture canonicalizes the supplied ID.
    # Run the adapter's shell to exercise the actual post-run file lookup and copy.
    binary.write_text(f"#!{sys.executable}\n" + """import json
from pathlib import Path
import sys
import uuid

if '--version' in sys.argv:
  print('fixture')
  sys.exit(0)
session = str(uuid.UUID(sys.argv[sys.argv.index('--session-id') + 1])).upper()
home = Path(__file__).parent / 'home'
store = home / '.arnes/sessions'
store.mkdir(parents=True)
(store / (session + '.jsonl')).write_text('complete tool result\\n')
print(json.dumps(dict(type='result', is_error=False, stop_reason='completed', session_id=session)))
""")
    binary.chmod(0o700)
    async def execute(**kwargs):
      command = kwargs["command"].replace("/usr/local/bin/arnes", shlex.quote(str(binary)))
      passwd = shlex.quote(f"fixture:x:1:1:fixture:{home}:/bin/bash")
      command = f"getent() {{ printf '%s\\n' {passwd}; }}; sha256sum() {{ :; }}; " + command
      result = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=10)
      self.assertEqual(result.returncode, 0, result.stderr)
      return types.SimpleNamespace(return_code=result.returncode)
    self.agent.arnes_config = BenchmarkConfig.from_environment(self.environment)
    self.agent.arnes_packs = {}
    self.agent.arnes_provenance = self.agent.arnes_config.provenance()
    context = types.SimpleNamespace(metadata=None)
    ident = uuid.UUID("abcdefab-1234-4567-89ab-abcdefabcdef")
    with patch.object(adapter, "LOGS", str(root)), patch.object(adapter.uuid, "uuid4", return_value=ident):
      await self.agent.run("fixture", types.SimpleNamespace(exec=execute), context)
    self.assertTrue(context.metadata["arnes"]["transcript_available"])
    self.assertEqual((root / "arnes-transcript.jsonl").read_text(), "complete tool result\n")
    provenance = json.loads((root / "arnes-provenance.json").read_text())
    result = json.loads((root / "arnes-result.json").read_text())
    self.assertEqual(provenance["session_id"], result["session_id"])

  async def test_task_umask_is_preserved_while_evidence_stays_private_and_handoff_is_early(self):
    for mask in [0o022, 0o027]:
      root = Path(self.directory.name) / str(mask)
      root.mkdir()
      binary = root / "arnes-fixture"
      binary.write_text(f"#!{sys.executable}\n" + """import json, os, sys, time
from pathlib import Path
if '--version' in sys.argv:
  print('fixture')
  sys.exit(0)
root = Path(__file__).parent
(root / 'task').mkdir()
(root / 'task/output').write_text('public task content')
(root / 'pid').write_text(str(os.getpid()))
print(json.dumps(dict(type='result', is_error=False, stop_reason='completed')), flush=True)
deadline = time.monotonic() + 10
while not (root / 'release').exists() and time.monotonic() < deadline:
  time.sleep(0.02)
""")
      binary.chmod(0o700)
      async def execute(**kwargs):
        command = kwargs["command"].replace("/usr/local/bin/arnes", shlex.quote(str(binary)))
        command = f"umask {mask:o}; getent() {{ :; }}; sha256sum() {{ :; }}; " + command
        completed = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return types.SimpleNamespace(return_code=completed.returncode)
      self.agent.arnes_config = BenchmarkConfig.from_environment(self.environment)
      self.agent.logs_dir = root
      self.agent.arnes_provenance = self.agent.arnes_config.provenance()
      self.agent.arnes_packs = {}
      context = types.SimpleNamespace(metadata=None)
      with patch.object(adapter, "LOGS", str(root)):
        await self.agent.run("fixture", types.SimpleNamespace(exec=execute), context)
      try:
        self.assertFalse((root / "arnes-exit-code.txt").exists(), "handoff precedes process exit")
        self.assertEqual(context.metadata["arnes"]["classification"], "task_attempt")
        os.kill(int((root / "pid").read_text()), 0)
        self.assertEqual((root / "task").stat().st_mode & 0o777, 0o777 & ~mask)
        self.assertEqual((root / "task/output").stat().st_mode & 0o777, 0o666 & ~mask)
        for name in ["arnes-events.jsonl", "arnes-stderr.log", "arnes-config.json", "arnes-provenance.json",
                     "arnes-result.json", "arnes-status.json"]:
          self.assertEqual((root / name).stat().st_mode & 0o777, 0o600, name)
      finally:
        (root / "release").touch()
      for _ in range(200):
        if (root / "arnes-exit-code.txt").exists():
          break
        await asyncio.sleep(0.05)
      self.assertEqual((root / "arnes-exit-code.txt").read_text().strip(), "0")

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
