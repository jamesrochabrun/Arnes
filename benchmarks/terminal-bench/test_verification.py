import json
from pathlib import Path
import tempfile
import unittest
from check_verification import inspect_trial


class VerificationTests(unittest.TestCase):
  def test_zero_reward_without_tests_is_not_a_verified_task_failure(self):
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      (root / "result.json").write_text(json.dumps(dict(task_name="fixture",
        verifier_result={"rewards": {"reward": 0}})))
      self.assertEqual(inspect_trial(root)["verification"], "missing_or_invalid_test_report")

  def test_checks_reward_consistency_and_partial_reports(self):
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      (root / "verifier").mkdir()
      for reward, statuses, expected in [
        (1, ["passed", "passed"], "passed"), (0, ["passed", "failed"], "failed"),
        (1, ["failed"], "inconsistent_verification"),
        (0, ["passed"], "inconsistent_verification"),
        (1, ["passed", "skipped"], "incomplete_verification"),
        (0, [], "missing_or_invalid_test_report"),
      ]:
        (root / "result.json").write_text(json.dumps(dict(verifier_result={"rewards": {"reward": reward}})))
        (root / "verifier/ctrf.json").write_text(json.dumps(dict(results={
          "tests": [dict(status=status) for status in statuses]})))
        self.assertEqual(inspect_trial(root)["verification"], expected)
