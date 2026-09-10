"""Offline checks for the routing report. No Harbor, containers or model calls."""
import json
import tempfile
import unittest
from pathlib import Path

import routing_report


def write(path, value):
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps(value) + "\n")


def make_trial(job, task, *, passed=True, cost=0.01, routed=("deepseek/deepseek-v4-pro-0813",),
               providers=None, effort="high", reasoning=True, tests=2, ctrf=True,
               suffix="", duration_ms=1000, binary="a" * 64, steps=5, estimated=False,
               ignored_effort=False):
  """One trial directory shaped like Harbor's, with the adapter's evidence beside it."""
  trial = job / f"{task}__{suffix or 'x'}"
  write(trial / "result.json", dict(
    task_name=task, verifier_result=dict(rewards=dict(reward=1 if passed else 0))))
  if ctrf:
    statuses = ["passed"] * tests if passed else ["passed"] * (tests - 1) + ["failed"]
    write(trial / "verifier/ctrf.json",
          dict(results=dict(tests=[dict(status=status) for status in statuses])))
  write(trial / "agent/arnes-result.json", dict(
    type="result", cost_usd=cost, cost_estimated=estimated, steps=steps, tool_calls=steps,
    stop_reason="completed", is_error=False, dialect="chat", duration_ms=duration_ms,
    prompt_tokens=100, completion_tokens=10, cached_tokens=0, routed_models=list(routed)))
  write(trial / "agent/arnes-provenance.json", dict(
    model="openrouter/auto", effort=effort, max_steps=100, timeout=900, budget=1.0,
    binary_sha256=binary, packs_sha256="p" * 64))
  events = [dict(type="init", model="openrouter/auto", effort=effort,
                 tools=["bash"], withheld_tools=["view_image"])]
  for index, model in enumerate(routed):
    events.append(dict(type="routed", model=model,
                       provider=(providers or ["Fireworks"])[min(index, len(providers or [1]) - 1)]
                       if providers else "Fireworks"))
  if ignored_effort:
    events.append(dict(type="setting_ignored", setting="effort",
                       reason="the manifest doesn't advertise reasoning for openrouter/auto"))
  if reasoning:
    events.append(dict(type="reasoning_delta", text="thinking" * 10))
  events.append(dict(type="result", is_error=False, stop_reason="completed"))
  (trial / "agent/arnes-events.jsonl").write_text(
    "".join(json.dumps(event) + "\n" for event in events))
  return trial


class RoutingReportTests(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary.name)

  def tearDown(self):
    self.temporary.cleanup()

  def test_routing_timeline_and_switch_detection(self):
    job = self.root / "auto"
    make_trial(job, "alpha", routed=("model-a", "model-b"), providers=["Fireworks", "Together"])
    row = routing_report.trial_row(next(job.glob("*")), "auto")
    self.assertEqual(row["routed_models"], ["model-a", "model-b"])
    self.assertEqual(row["routing_switches"], 1)
    self.assertEqual(row["providers"], ["Fireworks", "Together"])
    self.assertIn("routing_changed_mid_run", row["flags"])

  def test_effort_without_reasoning_is_flagged(self):
    """A router alias gets an assumed profile, so a requested effort may never be sent."""
    job = self.root / "auto"
    make_trial(job, "alpha", effort="high", reasoning=False)
    row = routing_report.trial_row(next(job.glob("*")), "auto")
    self.assertIn("effort_requested_without_reasoning", row["flags"])

  def test_effort_none_is_not_flagged(self):
    job = self.root / "auto"
    make_trial(job, "alpha", effort="none", reasoning=False)
    row = routing_report.trial_row(next(job.glob("*")), "auto")
    self.assertNotIn("effort_requested_without_reasoning", row["flags"])

  def test_explicit_setting_ignored_event_beats_the_inference(self):
    """A binary that says the dial was dropped is better evidence than absent reasoning."""
    job = self.root / "auto"
    make_trial(job, "alpha", effort="high", reasoning=False, ignored_effort=True)
    row = routing_report.trial_row(next(job.glob("*")), "auto")
    self.assertIn("effort_not_sent", row["flags"])
    self.assertNotIn("effort_requested_without_reasoning", row["flags"])
    self.assertEqual(row["ignored_settings"][0]["setting"], "effort")

  def test_estimated_cost_is_flagged(self):
    job = self.root / "auto"
    make_trial(job, "alpha", estimated=True)
    row = routing_report.trial_row(next(job.glob("*")), "auto")
    self.assertIn("cost_estimated", row["flags"])

  def test_unverified_trial_is_not_a_failure(self):
    job = self.root / "auto"
    make_trial(job, "alpha", passed=False, ctrf=False)
    row = routing_report.trial_row(next(job.glob("*")), "auto")
    self.assertFalse(row["scored"])
    self.assertFalse(row["passed"])
    summary = routing_report.summarize_arm("auto", [row])
    self.assertIsNone(summary["pass_rate"])
    self.assertEqual(summary["unscored"], 1)

  def test_missing_agent_evidence_is_flagged_not_crashed(self):
    job = self.root / "auto"
    trial = make_trial(job, "alpha")
    (trial / "agent/arnes-result.json").unlink()
    (trial / "agent/arnes-events.jsonl").unlink()
    row = routing_report.trial_row(trial, "auto")
    self.assertIn("no_agent_result", row["flags"])
    self.assertIn("no_event_stream", row["flags"])

  def test_malformed_event_lines_counted(self):
    job = self.root / "auto"
    trial = make_trial(job, "alpha")
    path = trial / "agent/arnes-events.jsonl"
    path.write_text(path.read_text() + "not json\n[1,2]\n")
    row = routing_report.trial_row(trial, "auto")
    self.assertEqual(row["malformed_lines"], 2)
    self.assertIn("malformed_events", row["flags"])

  def test_cost_per_solved_uses_passes_only(self):
    job = self.root / "auto"
    make_trial(job, "alpha", passed=True, cost=0.02, suffix="1")
    make_trial(job, "beta", passed=False, cost=0.02, suffix="2")
    rows = routing_report.collect_arm("auto", job, set())
    summary = routing_report.summarize_arm("auto", rows)
    self.assertEqual(summary["scored"], 2)
    self.assertEqual(summary["passed"], 1)
    self.assertAlmostEqual(summary["total_cost_usd"], 0.04)
    self.assertAlmostEqual(summary["cost_per_solved_usd"], 0.04)

  def test_repetition_index_pairs_arms(self):
    auto, fixed = self.root / "auto", self.root / "fixed"
    for suffix in ("1", "2"):
      make_trial(auto, "alpha", passed=suffix == "1", suffix=suffix)
      make_trial(fixed, "alpha", passed=True, suffix=suffix)
    document = routing_report.build({"auto": auto, "fixed": fixed}, "auto")
    pair = document["pairs"][0]
    self.assertEqual(pair["paired_cells"], 2)
    self.assertEqual(pair["both_passed"], 1)
    self.assertEqual(pair["only_other_passed"], 1)
    self.assertEqual(pair["routing_misses"][0]["task"], "alpha")

  def test_mcnemar_exact_matches_sign_test(self):
    self.assertIsNone(routing_report.mcnemar_exact(0, 0))
    self.assertEqual(routing_report.mcnemar_exact(1, 1), 1.0)
    self.assertAlmostEqual(routing_report.mcnemar_exact(0, 5), 0.0625)
    self.assertAlmostEqual(routing_report.mcnemar_exact(0, 1), 1.0)

  def test_oracle_gap_and_excess_cost(self):
    auto, cheap, strong = self.root / "auto", self.root / "cheap", self.root / "strong"
    make_trial(auto, "alpha", passed=True, cost=0.10)
    make_trial(cheap, "alpha", passed=True, cost=0.01)
    make_trial(strong, "beta", passed=True, cost=0.50)
    make_trial(auto, "beta", passed=False, cost=0.20, suffix="b")
    document = routing_report.build({"auto": auto, "cheap": cheap, "strong": strong}, "auto")
    oracle = document["oracle"]
    self.assertEqual(oracle["tasks_any_arm_solved"], 2)
    self.assertEqual(oracle["per_arm"]["auto"]["oracle_gap"], 1)
    self.assertEqual(oracle["per_arm"]["auto"]["missed_by_arm"], ["beta"])
    # auto solved alpha for $0.10 where the cheap arm solved it for $0.01.
    self.assertAlmostEqual(oracle["per_arm"]["auto"]["excess_cost_usd"], 0.09)
    self.assertAlmostEqual(oracle["per_arm"]["cheap"]["excess_cost_usd"], 0.0)

  def test_routing_breakdown_attributes_shared_trials(self):
    job = self.root / "auto"
    make_trial(job, "alpha", routed=("model-a", "model-b"), providers=["X", "Y"])
    rows = routing_report.collect_arm("auto", job, set())
    breakdown = {entry["model"]: entry for entry in routing_report.routing_breakdown(rows)}
    self.assertEqual(breakdown["model-a"]["shared_trials"], 1)
    self.assertEqual(breakdown["model-b"]["trials"], 1)

  def test_comparability_detects_a_changed_setting(self):
    auto, fixed = self.root / "auto", self.root / "fixed"
    make_trial(auto, "alpha", binary="a" * 64)
    make_trial(fixed, "alpha", binary="b" * 64)
    document = routing_report.build({"auto": auto, "fixed": fixed}, "auto")
    self.assertFalse(document["comparability"]["binary_sha256"]["consistent"])
    self.assertIn("comparison is confounded", routing_report.render(document))

  def test_disjoint_provider_pools_are_called_out(self):
    """Two arms naming the same model can still draw from entirely different providers."""
    auto, pinned = self.root / "auto", self.root / "pinned"
    make_trial(auto, "alpha", routed=("m",), providers=["Together"])
    make_trial(pinned, "alpha", routed=("m",), providers=["Novita"])
    document = routing_report.build({"auto": auto, "pinned": pinned}, "auto")
    text = routing_report.render(document)
    self.assertIn("Upstream provider pools", text)
    self.assertIn("no upstream provider at all", text)

  def test_shared_provider_pools_say_so(self):
    auto, pinned = self.root / "auto", self.root / "pinned"
    make_trial(auto, "alpha", routed=("m",), providers=["Together"])
    make_trial(pinned, "alpha", routed=("m",), providers=["Together"])
    text = routing_report.render(routing_report.build({"auto": auto, "pinned": pinned}, "auto"))
    self.assertIn("Arms share Together.", text)

  def test_render_is_plain_markdown(self):
    auto, fixed = self.root / "auto", self.root / "fixed"
    make_trial(auto, "alpha", passed=True)
    make_trial(fixed, "alpha", passed=True)
    text = routing_report.render(routing_report.build({"auto": auto, "fixed": fixed}, "auto"))
    self.assertIn("# Routing comparison", text)
    self.assertIn("## What `auto` routed to", text)
    self.assertIn("Completion is not correctness", text)

  def test_document_is_json_serializable(self):
    auto = self.root / "auto"
    make_trial(auto, "alpha")
    json.dumps(routing_report.build({"auto": auto}, "auto"), sort_keys=True)


if __name__ == "__main__":
  unittest.main()
