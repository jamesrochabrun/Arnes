"""Audit a pytest/CTRF Harbor job without treating missing verifier tests as model failures."""
import argparse
import json
from pathlib import Path


def inspect_trial(root):
  result = json.loads((root / "result.json").read_text())
  reward = (result.get("verifier_result") or {}).get("rewards", {}).get("reward")
  report = dict(task=result.get("task_name", root.name), raw_reward=reward)
  try:
    tests = json.loads((root / "verifier/ctrf.json").read_text())["results"]["tests"]
    if not isinstance(tests, list) or not tests:
      raise ValueError("empty test report")
    statuses = [test["status"] for test in tests]
    if any(status not in {"passed", "failed", "skipped", "pending", "other"} for status in statuses):
      raise ValueError("invalid test status")
  except (OSError, ValueError, KeyError, TypeError):
    return dict(report, verification="missing_or_invalid_test_report")
  if result.get("exception_info"):
    verdict = "trial_error"
  elif any(status != "passed" for status in statuses) and "failed" not in statuses:
    verdict = "incomplete_verification"
  elif "failed" in statuses and reward == 0:
    verdict = "failed"
  elif all(status == "passed" for status in statuses) and reward == 1:
    verdict = "passed"
  else:
    verdict = "inconsistent_verification"
  return dict(report, verification=verdict, tests=len(tests),
    passed=statuses.count("passed"), failed=statuses.count("failed"))


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("job", type=Path, help="Harbor job directory (tasks must write verifier/ctrf.json)")
  args = parser.parse_args()
  reports = [inspect_trial(path.parent) for path in sorted(args.job.glob("*/result.json"))]
  print(json.dumps(reports, indent=2))
  # Task failures are usable evidence. Missing, inconsistent or partial checks are not.
  return 0 if reports and all(row["verification"] in {"passed", "failed"} for row in reports) else 1


if __name__ == "__main__":
  raise SystemExit(main())
