import json
import os
from pathlib import Path
import shlex
import tempfile
import unittest
from benchmark_contract import BenchmarkConfig, load_packs, pack_fingerprint, parse_trajectory


class BenchmarkContractTests(unittest.TestCase):
  def environment(self, **extra):
    return dict(ARNES_LINUX_BINARY_URL="https://example.com/arnes",
                ARNES_LINUX_BINARY_SHA256="a" * 64,
                ARNES_MODEL="test/model", ARNES_EFFORT="high", **extra)

  def test_requires_explicit_identity(self):
    for key in self.environment():
      environment = self.environment()
      del environment[key]
      with self.assertRaises(ValueError):
        BenchmarkConfig.from_environment(environment)

  def test_rejects_invalid_settings(self):
    for key, value in [
      ("ARNES_MODEL", "openrouter/auto"), ("ARNES_EFFORT", "banana"),
      ("ARNES_DIALECT", "banana"), ("ARNES_TIMEOUT", "0"),
      ("ARNES_MAX_STEPS", "-1"), ("ARNES_BUDGET", "nan"), ("ARNES_BUDGET", "inf"),
      ("ARNES_LINUX_BINARY_SHA256", "bad"),
      ("ARNES_KEEP_ALIVE_SECONDS", "-1"), ("ARNES_KEEP_ALIVE_SECONDS", "3601"),
      ("ARNES_LINUX_BINARY_URL", "http://example.com/binary"),
      ("ARNES_LINUX_BINARY_URL", "https://user:secret@example.com/binary"),
    ]:
      with self.subTest(key=key, value=value), self.assertRaises(ValueError):
        BenchmarkConfig.from_environment(dict(self.environment(), **{key: value}))

  def test_router_alias_needs_an_explicit_opt_in(self):
    """The default stays reproducible; the router experiment says so out loud."""
    alias = dict(self.environment(), ARNES_MODEL="openrouter/auto")
    with self.assertRaises(ValueError):
      BenchmarkConfig.from_environment(alias)
    with self.assertRaises(ValueError):
      BenchmarkConfig.from_environment(dict(alias, ARNES_ROUTER_ALIAS="false"))
    with self.assertRaises(ValueError):
      BenchmarkConfig.from_environment(dict(alias, ARNES_ROUTER_ALIAS="yes"))
    config = BenchmarkConfig.from_environment(dict(alias, ARNES_ROUTER_ALIAS="true"))
    self.assertEqual(config.model, "openrouter/auto")
    self.assertTrue(config.router_alias)
    # The evidence must say the run deliberately let a router choose.
    self.assertIs(config.provenance()["router_alias"], True)
    self.assertEqual(config.provenance()["schema_version"], 5)

  def test_opting_in_does_not_change_an_explicit_model_run(self):
    plain = BenchmarkConfig.from_environment(self.environment())
    self.assertFalse(plain.router_alias)
    self.assertIs(plain.provenance()["router_alias"], False)
    opted = BenchmarkConfig.from_environment(
      dict(self.environment(), ARNES_ROUTER_ALIAS="true"))
    self.assertEqual(opted.command("t", "S"), plain.command("t", "S"),
                     "the flag gates a refusal, it never reshapes the command")

  def test_provenance_omits_download_url(self):
    config = BenchmarkConfig.from_environment(dict(self.environment(),
      ARNES_LINUX_BINARY_URL="https://example.com/binary?token=private"))
    self.assertNotIn("private", json.dumps(config.provenance()))
    self.assertEqual(config.provenance()["binary_sha256"], "a" * 64)
    self.assertEqual(config.provenance()["keep_alive_seconds"], 1200)

  def test_experiment_settings_match_runtime_config_and_provenance(self):
    base = BenchmarkConfig.from_environment(self.environment())
    self.assertFalse(base.runtime_config()["policies"]["commandDiagnostics"])
    self.assertFalse(base.runtime_config()["policies"]["manifestCache"]["enabled"])
    self.assertNotIn("keepRecentToolTokens", base.runtime_config()["compaction"])
    arm = BenchmarkConfig.from_environment(self.environment(ARNES_COMMAND_DIAGNOSTICS="true",
      ARNES_PRESERVE_COMMAND_EVIDENCE="true", ARNES_KEEP_RECENT_TOOL_TOKENS="4000"))
    self.assertTrue(arm.runtime_config()["policies"]["commandDiagnostics"])
    self.assertEqual(arm.runtime_config()["compaction"],
      {"preserveCommandEvidence": True, "keepRecentToolTokens": 4000})
    self.assertTrue(arm.provenance()["command_diagnostics"])
    self.assertTrue(arm.provenance()["preserve_command_evidence"])
    self.assertEqual(arm.provenance()["keep_recent_tool_tokens"], 4000)

  def test_invalid_experiment_settings_are_not_silently_coerced(self):
    for key, value in [("ARNES_COMMAND_DIAGNOSTICS", "yes"),
      ("ARNES_TIME_AWARE", "yes"), ("ARNES_MAX_RESPONSE_TOKENS", "0"),
      ("ARNES_MAX_RESPONSE_TOKENS", "NaN"),
      ("ARNES_PRESERVE_COMMAND_EVIDENCE", "1"), ("ARNES_KEEP_RECENT_TOOL_TOKENS", "-1"),
      ("ARNES_KEEP_RECENT_TOOL_TOKENS", "NaN")]:
      with self.subTest(key=key, value=value), self.assertRaises(ValueError):
        BenchmarkConfig.from_environment(dict(self.environment(), **{key: value}))

  def test_time_experiment_flags_and_provenance(self):
    base = BenchmarkConfig.from_environment(self.environment())
    self.assertNotIn("--time-aware", base.command("go", "session"))
    self.assertNotIn("--max-response-tokens", base.command("go", "session"))
    arm = BenchmarkConfig.from_environment(self.environment(
      ARNES_TIME_AWARE="true", ARNES_MAX_RESPONSE_TOKENS="8192"))
    args = shlex.split(arm.command("go", "session"))
    self.assertIn("--time-aware", args)
    self.assertEqual(args[args.index("--max-response-tokens") + 1], "8192")
    self.assertTrue(arm.provenance()["time_aware"])
    self.assertEqual(arm.provenance()["max_response_tokens"], 8192)
    self.assertEqual(arm.provenance()["schema_version"], 5)

  def test_instruction_is_one_literal_argument(self):
    instruction = "fix 'it'; $(touch /tmp/not-executed)\n--help"
    command = BenchmarkConfig.from_environment(self.environment()).command(instruction, "session")
    arguments = shlex.split(command)
    self.assertEqual(arguments[2], instruction)
    for argument in ["--bare", "--session", "--no-memory", "--include-partial", "stream-json"]:
      self.assertIn(argument, arguments)

  def test_pack_hash_is_order_independent_but_content_sensitive(self):
    self.assertEqual(pack_fingerprint({"a": "1", "b": "2"}), pack_fingerprint({"b": "2", "a": "1"}))
    self.assertNotEqual(pack_fingerprint({"a": "1"}), pack_fingerprint({"a": "2"}))

  def test_pack_loader_rejects_links_special_files_and_oversize(self):
    with tempfile.TemporaryDirectory(prefix="arnes-pack-contract-") as directory:
      root = Path(directory)
      target = root / "target.txt"
      target.write_text("private fixture")
      link = root / "other.tools.json"
      link.symlink_to(target)
      with self.assertRaises(ValueError):
        load_packs(root)
      link.unlink()
      os.mkfifo(link)
      with self.assertRaises(ValueError):
        load_packs(root)
      link.unlink()
      link.write_bytes(b" " * 65_537)
      with self.assertRaises(ValueError):
        load_packs(root)
      link.write_text('{"bash":"Observed guidance."}')
      self.assertEqual(load_packs(root), {"other.tools.json": '{"bash":"Observed guidance."}'})

  def test_pack_loader_bounds_the_whole_set(self):
    with tempfile.TemporaryDirectory(prefix="arnes-pack-contract-") as directory:
      root = Path(directory)
      for index in range(65):
        (root / f"{index}.md").write_text("small")
      with self.assertRaises(ValueError):
        load_packs(root)
    self.assertEqual(load_packs(None), {})

  def test_completion_is_only_a_task_attempt(self):
    result = {"type": "result", "stop_reason": "completed", "is_error": False}
    parsed = parse_trajectory([json.dumps(result)], 0)
    self.assertEqual(parsed["classification"], "task_attempt")
    self.assertEqual(parsed["result"], result)
    self.assertNotIn("passed", parsed)

  def test_errors_and_interruption_are_not_scored_as_attempts(self):
    for reason, expected in [("error", "agent_or_provider_error"), ("timeout", "interrupted")]:
      result = {"type": "result", "stop_reason": reason, "is_error": reason == "error"}
      self.assertEqual(parse_trajectory([json.dumps(result)], 1)["classification"], expected)

  def test_missing_and_malformed_results_are_visible(self):
    parsed = parse_trajectory(['{"type":"init"}', "truncated {", "[]"], 137)
    self.assertEqual(parsed["classification"], "incomplete_trajectory")
    self.assertEqual(parsed["malformed_lines"], 2)
    self.assertEqual(parsed["event_count"], 1)
    self.assertEqual(parse_trajectory([], 64)["classification"], "usage_error")
    self.assertEqual(parse_trajectory(['{"type":"result"}'], 0)["classification"], "incomplete_trajectory")

  def test_signal_exit_overrides_an_existing_completion_envelope(self):
    result = {"type": "result", "stop_reason": "completed", "is_error": False}
    for code in [130, 137, 143]:
      parsed = parse_trajectory([json.dumps(result)], code)
      self.assertEqual(parsed["classification"], "interrupted")
      self.assertEqual(parsed["result"], result)


if __name__ == "__main__":
  unittest.main()
