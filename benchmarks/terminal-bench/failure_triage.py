"""Bucket a suite's failures by what the trajectory says went wrong, so the next harness
change is chosen by counts rather than by hunch.

Every bucket is a *hypothesis* carrying the evidence that produced it, never a verdict. The
one time these were read by hand, a third of the "gave up early" group turned out to be the
model being right about its environment — so the ranking says where to look, and the
trajectory still decides. Nothing here calls a model.
"""
import argparse
import json
import posixpath
import re
from collections import Counter, defaultdict
from pathlib import Path

import routing_report

# `-o path`, the shape that puts a compiler's output somewhere on purpose.
OUTPUT_FLAG = re.compile(r"-o\s+(\S+)")
EXIT_CODE = re.compile(r"^exit\s+(\d+)")
# Scratch trees are where build output *belongs*; leaving something here is the good outcome,
# so they can never count as a polluted deliverable.
SCRATCH_DIRS = ("/tmp", "/var/tmp", "/dev", "/run")
# A file tool is not the only way to produce a deliverable — a shell redirect, a heredoc, `tee`,
# `cp`, `mv` and `touch` all create files, and an agent that used them has not "written nothing".
SHELL_WRITE = re.compile(
  r"(?<![>\d])>(?!&)|\btee\b|\bcp\b|\bmv\b|\btouch\b|\bdd\b|\binstall\b|\bpatch\b")

# Each bucket: who it points at, and what would confirm or kill the hypothesis.
BUCKETS = {
  "infrastructure": ("environment",
                     "The trial never produced a result. Re-run it; it is not a score."),
  "deadline": ("harness or model",
               "Read the last minute of the trajectory: still making progress (raise the "
               "deadline) or looping (a loop-guard question)?"),
  "budget_stop": ("harness",
                  "Our own per-trial ceiling ended the run. Check what it was mid-way through."),
  "agent_error": ("harness or provider",
                  "Read the recorded error before attributing it."),
  "polluted_deliverable": ("harness",
                           "Build output landed beside the deliverable. Confirm the task asserts "
                           "on directory contents, then this is a free fix."),
  "completed_but_wrong": ("unattributed",
                          "The agent finished and the verifier disagreed. Read these; the "
                          "columns below are where to start, not a verdict."),
}

# Deliberately absent: a bucket splitting "never verified its work" from "verified and was still
# wrong". Both attempts at that inference were wrong on real data — counting only the file tools
# missed every deliverable written by a shell redirect, and then counting redirects as writes made
# `python test.py > out.txt` look like a write rather than the check it is. A signal that cannot
# survive its own evidence does not get to assign blame, so those trials stay in one bucket with
# their numbers exposed for a human to sub-triage.


def trajectory(path):
  """Ordered tool calls and their results, plus what the agent wrote."""
  calls, written, shell_writes, failures = [], [], [], 0
  try:
    lines = path.read_text().splitlines()
  except OSError:
    return dict(calls=[], written=[], shell_writes=[], failed_results=0, available=False)
  for line in lines:
    if not line.strip():
      continue
    try:
      event = json.loads(line)
    except ValueError:
      continue
    if not isinstance(event, dict):
      continue
    if event.get("type") == "tool_call":
      arguments = event.get("arguments")
      arguments = arguments if isinstance(arguments, dict) else {}
      calls.append(dict(name=event.get("name"), arguments=arguments))
      if event.get("name") in {"write_file", "edit_file"}:
        target = arguments.get("path")
        if isinstance(target, str):
          written.append(target)
      elif event.get("name") == "bash":
        if SHELL_WRITE.search(str(arguments.get("command") or "")):
          shell_writes.append(len(calls) - 1)
    elif event.get("type") == "tool_result":
      match = EXIT_CODE.match(str(event.get("preview") or ""))
      if match and match.group(1) != "0":
        failures += 1
  return dict(calls=calls, written=written, shell_writes=shell_writes,
              failed_results=failures, available=True)


def signals(row, trace):
  """What the trajectory supports, with no interpretation yet."""
  calls = trace["calls"]
  file_tool_writes = [index for index, call in enumerate(calls)
                      if call["name"] in {"write_file", "edit_file"}]
  last_write = max(file_tool_writes + trace["shell_writes"], default=None)
  after = calls[last_write + 1:] if last_write is not None else []
  ran_after_write = [call for call in after if call["name"] == "bash"]
  # Did a build write its output into the directory holding the deliverable? That is how a
  # correct answer fails a task whose test asserts the directory holds exactly one file.
  deliverable_dirs = {posixpath.dirname(path) for path in trace["written"] if path}
  deliverable_dirs = {directory for directory in deliverable_dirs
                      if not directory.startswith(SCRATCH_DIRS)}
  polluted = []
  for call in calls:
    if call["name"] != "bash":
      continue
    command = str(call["arguments"].get("command") or "")
    for target in OUTPUT_FLAG.findall(command):
      if posixpath.dirname(target) in deliverable_dirs and target not in trace["written"]:
        polluted.append(target)
  return dict(
    steps=row["steps"], stop_reason=row["stop_reason"], tool_calls=len(calls),
    wrote=len(trace["written"]) + len(trace["shell_writes"]),
    wrote_with_file_tools=len(trace["written"]),
    wrote_with_shell=len(trace["shell_writes"]),
    written_paths=sorted(set(trace["written"])),
    checks_after_last_write=len(ran_after_write),
    failed_tool_results=trace["failed_results"],
    polluted_paths=sorted(set(polluted)), trajectory_available=trace["available"])


def classify(row, marks):
  """First match wins; order is from least to most about the model."""
  if not row["scored"] or not row["result_available"] or not marks["trajectory_available"]:
    return "infrastructure"
  if row["stop_reason"] == "timeout":
    return "deadline"
  if row["stop_reason"] == "budget":
    return "budget_stop"
  if row["stop_reason"] == "error":
    return "agent_error"
  if marks["polluted_paths"]:
    return "polluted_deliverable"
  return "completed_but_wrong"


# The assertions that make a stray file fatal: a test comparing a directory listing against an
# exact set. Without one, build output beside the deliverable is untidy but harmless.
DIRECTORY_ASSERTION = re.compile(r"(os\.listdir|\.iterdir\(\)|glob\.glob)")
EXACT_SET = re.compile(r"==\s*[\[{]")


def tasks_asserting_directory_contents(dataset):
  """Tasks whose own tests compare a directory listing to an exact set."""
  strict = set()
  if not dataset:
    return strict
  for tests in sorted(Path(dataset).glob("*/tests/*.py")):
    try:
      text = tests.read_text()
    except OSError:
      continue
    for line in text.splitlines():
      if DIRECTORY_ASSERTION.search(line) or ("assert" in line and EXACT_SET.search(line)):
        if "assert" in line and EXACT_SET.search(line):
          strict.add(tests.parent.parent.name)
          break
  return strict


def triage(job, dataset=None):
  strict = tasks_asserting_directory_contents(dataset)
  rows = [routing_report.trial_row(path.parent, "suite")
          for path in sorted(job.glob("*/result.json"))]
  failures, passes = [], 0
  for row in rows:
    if row["scored"] and row["passed"]:
      passes += 1
      continue
    trace = trajectory(job / row["trial"] / "agent" / "arnes-events.jsonl")
    marks = signals(row, trace)
    # A stray file only decided the outcome if the task's own tests police the directory.
    marks["task_asserts_directory"] = row["task"] in strict if strict else None
    failures.append(dict(task=row["task"], bucket=classify(row, marks), cost_usd=row["cost_usd"],
                         seconds=row["duration_seconds"], **marks))
  grouped = defaultdict(list)
  for entry in failures:
    grouped[entry["bucket"]].append(entry)
  scored = [row for row in rows if row["scored"]]
  return dict(
    trials=len(rows), scored=len(scored), passed=passes,
    pass_rate=passes / len(rows) if rows else None,
    buckets={name: sorted(group, key=lambda entry: entry["steps"] or 0)
             for name, group in grouped.items()},
    counts=dict(Counter(entry["bucket"] for entry in failures)),
    failures=failures)


def markdown(report):
  rate = "n/a" if report["pass_rate"] is None else f"{report['pass_rate']:.1%}"
  lines = ["# Failure triage", "",
           f"{report['passed']} / {report['trials']} passed ({rate}); "
           f"{len(report['failures'])} failures to account for.", "",
           "Each bucket is a hypothesis with its evidence attached, ranked by how many tasks "
           "sit in it — that is the size of the prize, before anyone argues about causes.", "",
           "| bucket | tasks | points | points to | confirm by |",
           "| --- | ---: | ---: | --- | --- |"]
  ordered = sorted(report["counts"].items(), key=lambda item: -item[1])
  for name, count in ordered:
    owner, confirm = BUCKETS.get(name, ("?", ""))
    share = count / report["trials"] * 100 if report["trials"] else 0
    lines.append(f"| {name} | {count} | {share:.1f} | {owner} | {confirm} |")
  harness = sum(count for name, count in report["counts"].items()
                if BUCKETS.get(name, ("", ""))[0] == "harness")
  unattributed = sum(count for name, count in report["counts"].items()
                     if BUCKETS.get(name, ("", ""))[0] == "unattributed")
  lines += ["", f"**Mechanically attributable to the harness: {harness} task(s)**, "
                f"{harness / report['trials'] * 100:.1f} points — the ones the evidence decides "
                "on its own.",
            "", f"**Unattributed: {unattributed} task(s)**, "
                f"{unattributed / report['trials'] * 100:.1f} points. This is the real pool and no "
                "tool can split it for you: the last hand-read of three such trials found one "
                "harness bug, one unavoidable environment limit and one model error."]
  for name, _ in ordered:
    group = report["buckets"][name]
    lines += ["", f"## {name} ({len(group)})", "",
              "| task | steps | file writes | shell writes | failed calls | cost | stop |",
              "| --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    for entry in group:
      cost = "n/a" if entry["cost_usd"] is None else f"${entry['cost_usd']:.4f}"
      lines.append(
        f"| {entry['task']} | {entry['steps'] or 0} | {entry['wrote_with_file_tools']} | "
        f"{entry['wrote_with_shell']} | {entry['failed_tool_results']} | {cost} | "
        f"{entry['stop_reason']} |")
    if name == "polluted_deliverable":
      for entry in group:
        asserts = entry.get("task_asserts_directory")
        verdict = ("— **and the task's tests assert an exact directory listing, so this is why "
                   "it failed**" if asserts else
                   "— the task's tests do not police the directory, so this is untidy, not fatal"
                   if asserts is False else "(pass --dataset to say whether it mattered)")
        lines.append(f"  - `{entry['task']}` left {', '.join(entry['polluted_paths'])} {verdict}")
      causal = [entry for entry in group if entry.get("task_asserts_directory")]
      if causal:
        lines += ["", f"**{len(causal)} of {len(group)} are causal** "
                      f"({len(causal) / report['trials'] * 100:.1f} points): "
                      + ", ".join(entry["task"] for entry in causal) + "."]
  lines += ["", "A bucket is where to look, not what to fix. Read the trajectories in the "
            "largest harness bucket before changing anything.", ""]
  return "\n".join(lines)


def main():
  parser = argparse.ArgumentParser(description=__doc__,
                                   formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("job", type=Path, help="Harbor job directory from a suite run")
  parser.add_argument("--dataset", type=Path, default=None,
                      help="task dataset directory; lets the report say whether a stray file "
                           "actually decided the outcome")
  parser.add_argument("--json", action="store_true", help="emit the full report")
  args = parser.parse_args()
  if not args.job.is_dir():
    parser.error(f"not a Harbor job directory: {args.job}")
  report = triage(args.job, args.dataset)
  print(json.dumps(report, indent=2, sort_keys=True) if args.json else markdown(report))
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
