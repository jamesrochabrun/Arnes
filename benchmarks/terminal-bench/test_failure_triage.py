"""Offline checks for failure triage. No Harbor, containers or model calls."""
import json
import tempfile
import unittest
from pathlib import Path

import failure_triage
from test_routing_report import make_trial, write


def events(trial, calls, results=()):
  lines = [dict(type="init", model="m", effort="high", tools=["bash"], withheld_tools=[])]
  for name, arguments in calls:
    lines.append(dict(type="tool_call", name=name, arguments=arguments))
  for preview in results:
    lines.append(dict(type="tool_result", name="bash", preview=preview))
  lines.append(dict(type="result", is_error=False, stop_reason="completed"))
  (trial / "agent/arnes-events.jsonl").write_text(
    "".join(json.dumps(line) + "\n" for line in lines))


class FailureTriageTests(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary.name)
    self.job = self.root / "job"

  def tearDown(self):
    self.temporary.cleanup()

  def test_build_output_beside_the_deliverable_is_flagged(self):
    trial = make_trial(self.job, "polyglot", passed=False)
    events(trial, [("write_file", {"path": "/app/polyglot/main.rs"}),
                   ("bash", {"command": "rustc /app/polyglot/main.rs -o /app/polyglot/main"})])
    report = failure_triage.triage(self.job)
    entry = report["failures"][0]
    self.assertEqual(entry["bucket"], "polluted_deliverable")
    self.assertEqual(entry["polluted_paths"], ["/app/polyglot/main"])

  def test_building_into_scratch_is_the_good_outcome(self):
    """Compiling to /tmp is exactly what we want; it must never read as pollution."""
    trial = make_trial(self.job, "compressor", passed=False)
    events(trial, [("write_file", {"path": "/tmp/scratch.c"}),
                   ("bash", {"command": "gcc /tmp/scratch.c -o /tmp/make"})])
    entry = failure_triage.triage(self.job)["failures"][0]
    self.assertEqual(entry["polluted_paths"], [])
    self.assertEqual(entry["bucket"], "completed_but_wrong")

  def test_a_stray_file_is_only_causal_when_the_task_polices_the_directory(self):
    dataset = self.root / "dataset"
    strict = dataset / "polyglot/tests"
    strict.mkdir(parents=True)
    (strict / "test_outputs.py").write_text(
      'def test_x():\n    assert os.listdir("/app/polyglot") == ["main.rs"]\n')
    loose = dataset / "render/tests"
    loose.mkdir(parents=True)
    (loose / "test_outputs.py").write_text("def test_y():\n    assert compare(out, ref)\n")
    for task in ("polyglot", "render"):
      trial = make_trial(self.job, task, passed=False, suffix=task)
      events(trial, [("write_file", {"path": f"/app/{task}/main.c"}),
                     ("bash", {"command": f"gcc /app/{task}/main.c -o /app/{task}/bin"})])
    report = failure_triage.triage(self.job, dataset)
    marks = {entry["task"]: entry["task_asserts_directory"] for entry in report["failures"]}
    self.assertTrue(marks["polyglot"], "the task compares a listing to an exact set")
    self.assertFalse(marks["render"], "no directory assertion, so the stray file is untidy only")
    self.assertIn("2 of 3 are causal".replace("2 of 3", "1 of 2"),
                  failure_triage.markdown(report))

  def test_a_shell_redirect_counts_as_producing_something(self):
    trial = make_trial(self.job, "scripted", passed=False)
    events(trial, [("bash", {"command": "cat > /app/answer.txt <<'EOF'\\nhi\\nEOF"})])
    entry = failure_triage.triage(self.job)["failures"][0]
    self.assertEqual(entry["wrote_with_shell"], 1)
    self.assertEqual(entry["wrote_with_file_tools"], 0)

  def test_stop_reasons_take_precedence_over_content(self):
    for stop, bucket in (("timeout", "deadline"), ("budget", "budget_stop"),
                         ("error", "agent_error")):
      job = self.root / f"job-{stop}"
      trial = make_trial(job, "t", passed=False)
      result = json.loads((trial / "agent/arnes-result.json").read_text())
      result["stop_reason"] = stop
      write(trial / "agent/arnes-result.json", result)
      events(trial, [("write_file", {"path": "/app/x"})])
      self.assertEqual(failure_triage.triage(job)["failures"][0]["bucket"], bucket)

  def test_passes_never_enter_the_failure_pool(self):
    trial = make_trial(self.job, "good", passed=True)
    events(trial, [("write_file", {"path": "/app/x"})])
    report = failure_triage.triage(self.job)
    self.assertEqual(report["passed"], 1)
    self.assertEqual(report["failures"], [])

  def test_report_is_json_serializable_and_renders(self):
    trial = make_trial(self.job, "t", passed=False)
    events(trial, [("write_file", {"path": "/app/x"})])
    report = failure_triage.triage(self.job)
    json.dumps(report, sort_keys=True)
    self.assertIn("# Failure triage", failure_triage.markdown(report))


if __name__ == "__main__":
  unittest.main()
