"""Compare routing arms across Harbor jobs. Routing is a claim about cost, not only reward.

Each `--arm LABEL=JOB` names one Harbor job directory holding that arm's trials. The report
pairs arms by task and repetition, so a router arm (`openrouter/auto`) is judged against the
fixed-model arms that ran the same tasks: what it routed to, what that cost, and which tasks
a fixed model solved that the router missed. See ../../evals/ab/model-routing.md.
"""
import argparse
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path

from check_verification import inspect_trial

# A trial only enters a pass rate when the agent actually attempted the task and the task's
# own checks reached a verdict. Everything else is reliability evidence, reported separately.
SCORED_VERIFICATION = {"passed", "failed"}


def read_json(path):
  try:
    return json.loads(path.read_text())
  except (OSError, ValueError):
    return None


def scan_events(path):
  """Routing timeline and progress counters from the streamed events.

  `routed` is emitted on change, so its sequence is the run's actual routing — the field a
  requested `openrouter/auto` cannot tell you in advance.
  """
  scan = dict(routing=[], reasoning_chars=0, text_chars=0, malformed_lines=0, event_count=0,
              withheld_tools=None, offered_tools=None, init_effort=None, init_model=None,
              ignored_settings=[])
  try:
    lines = path.read_text().splitlines()
  except OSError:
    return dict(scan, events_available=False)
  for line in lines:
    if not line.strip():
      continue
    try:
      event = json.loads(line)
      if not isinstance(event, dict):
        raise ValueError("event is not an object")
    except (ValueError, TypeError):
      scan["malformed_lines"] += 1
      continue
    scan["event_count"] += 1
    kind = event.get("type")
    if kind == "routed":
      model, provider = event.get("model"), event.get("provider")
      if isinstance(model, str):
        scan["routing"].append(dict(model=model, provider=provider))
    elif kind == "reasoning_delta":
      scan["reasoning_chars"] += len(event.get("text") or "")
    elif kind in {"text_delta", "assistant"}:
      scan["text_chars"] += len(event.get("text") or "")
    elif kind == "setting_ignored":
      # The harness says outright that a dial never reached the model — stronger evidence
      # than inferring it from an absence of reasoning, and it names which dial.
      scan["ignored_settings"].append(
        dict(setting=event.get("setting"), reason=event.get("reason")))
    elif kind == "init":
      scan["withheld_tools"] = event.get("withheld_tools")
      scan["offered_tools"] = event.get("tools")
      scan["init_effort"] = event.get("effort")
      scan["init_model"] = event.get("model")
  return dict(scan, events_available=True)


def trial_row(directory, arm):
  """One trial: the task verdict, the agent's own evidence, and what it routed to."""
  verification = inspect_trial(directory)
  agent = directory / "agent"
  result = read_json(agent / "arnes-result.json") or {}
  provenance = read_json(agent / "arnes-provenance.json") or {}
  events = scan_events(agent / "arnes-events.jsonl")
  routed = [step["model"] for step in events["routing"]]
  # `routed_models` is the run record's post-routing set; the event timeline is its order.
  recorded = result.get("routed_models") or []
  row = dict(
    arm=arm, task=verification.get("task"), trial=directory.name,
    verification=verification.get("verification"), raw_reward=verification.get("raw_reward"),
    passed=verification.get("verification") == "passed",
    scored=verification.get("verification") in SCORED_VERIFICATION,
    requested_model=provenance.get("model"), requested_effort=provenance.get("effort"),
    routed_models=sorted(set(routed) | set(recorded)), routing_timeline=events["routing"],
    routing_switches=max(len(dict.fromkeys(routed)) - 1, 0),
    providers=sorted({step["provider"] for step in events["routing"] if step["provider"]}),
    cost_usd=result.get("cost_usd"), cost_estimated=result.get("cost_estimated"),
    duration_seconds=(result.get("duration_ms") or 0) / 1000 if result.get("duration_ms") else None,
    steps=result.get("steps"), tool_calls=result.get("tool_calls"),
    stop_reason=result.get("stop_reason"), is_error=result.get("is_error"),
    dialect=result.get("dialect"), prompt_tokens=result.get("prompt_tokens"),
    completion_tokens=result.get("completion_tokens"), cached_tokens=result.get("cached_tokens"),
    reasoning_chars=events["reasoning_chars"], text_chars=events["text_chars"],
    ignored_settings=events["ignored_settings"],
    malformed_lines=events["malformed_lines"], events_available=events["events_available"],
    withheld_tools=events["withheld_tools"], binary_sha256=provenance.get("binary_sha256"),
    packs_sha256=provenance.get("packs_sha256"), max_steps=provenance.get("max_steps"),
    timeout=provenance.get("timeout"), budget=provenance.get("budget"),
    result_available=bool(result))
  row["flags"] = trial_flags(row)
  return row


def trial_flags(row):
  """Conditions that make a trial's numbers unsafe to publish as they stand."""
  flags = []
  if not row["result_available"]:
    flags.append("no_agent_result")
  if not row["events_available"]:
    flags.append("no_event_stream")
  if row["malformed_lines"]:
    flags.append("malformed_events")
  if row["cost_estimated"]:
    # An estimated cost comes from the manifest's pricing, not the provider's usage. A
    # router alias has no manifest pricing, so an estimated cost there is near-meaningless.
    flags.append("cost_estimated")
  if row["cost_usd"] in (None, 0) and row["scored"]:
    flags.append("no_recorded_cost")
  if any(entry["setting"] == "effort" for entry in row["ignored_settings"]):
    # The run said so itself: the dial was accepted and never sent. An arm carrying this is
    # not running at the effort its provenance records.
    flags.append("effort_not_sent")
  elif row["requested_effort"] not in (None, "", "none") and row["reasoning_chars"] == 0:
    # No explicit notice — an older binary predates it — so fall back to the symptom: a run
    # that asked for an effort and emitted no reasoning very likely never sent the parameter.
    flags.append("effort_requested_without_reasoning")
  if row["routing_switches"]:
    flags.append("routing_changed_mid_run")
  if not row["routed_models"] and row["scored"]:
    flags.append("routing_unrecorded")
  return flags


def collect_arm(label, job, seen_tasks):
  """Trials of one arm, each stamped with its repetition index within (arm, task)."""
  rows = [trial_row(path.parent, label) for path in sorted(job.glob("*/result.json"))]
  counts = Counter()
  for row in sorted(rows, key=lambda item: item["trial"]):
    key = row["task"]
    row["repetition"] = counts[key]
    counts[key] += 1
    seen_tasks.add(key)
  return rows


def median(values):
  usable = [value for value in values if value is not None]
  return statistics.median(usable) if usable else None


def summarize_arm(label, rows):
  scored = [row for row in rows if row["scored"]]
  passes = [row for row in scored if row["passed"]]
  cost = sum(row["cost_usd"] or 0 for row in scored)
  return dict(
    arm=label, trials=len(rows), scored=len(scored), passed=len(passes),
    pass_rate=len(passes) / len(scored) if scored else None,
    unscored=len(rows) - len(scored),
    total_cost_usd=cost, cost_per_solved_usd=cost / len(passes) if passes else None,
    median_cost_usd=median([row["cost_usd"] for row in scored]),
    median_duration_seconds=median([row["duration_seconds"] for row in scored]),
    median_steps=median([row["steps"] for row in scored]),
    routed_models=sorted({model for row in rows for model in row["routed_models"]}),
    # The upstream provider pool this arm actually reached. Two arms naming the same model can
    # still draw from disjoint pools — observed on 2026-09-10, where `openrouter/auto` and the
    # model it picks were served by entirely different providers — and then a difference between
    # them is provider assignment, not the thing the arms were meant to isolate.
    providers=sorted({name for row in rows for name in row["providers"]}),
    timeouts=sum(1 for row in rows if row["stop_reason"] == "timeout"),
    flagged_trials=sum(1 for row in rows if row["flags"]),
    flags=dict(Counter(flag for row in rows for flag in row["flags"])))


def routing_breakdown(rows):
  """Per routed model: how often the router chose it, and how that choice worked out.

  A trial that switched models mid-run is attributed to every model it used, so the counts
  describe exposure, not a partition. `routing_changed_mid_run` says when that happened.
  """
  buckets = defaultdict(list)
  for row in rows:
    for model in row["routed_models"]:
      buckets[model].append(row)
  breakdown = []
  for model, group in sorted(buckets.items()):
    scored = [row for row in group if row["scored"]]
    passes = [row for row in scored if row["passed"]]
    breakdown.append(dict(
      model=model, trials=len(group), scored=len(scored), passed=len(passes),
      pass_rate=len(passes) / len(scored) if scored else None,
      total_cost_usd=sum(row["cost_usd"] or 0 for row in scored),
      shared_trials=sum(1 for row in group if len(row["routed_models"]) > 1),
      providers=sorted({provider for row in group for provider in row["providers"]})))
  return breakdown


def mcnemar_exact(discordant_a, discordant_b):
  """Two-sided exact McNemar p-value: a sign test over the tasks the arms disagreed on."""
  total = discordant_a + discordant_b
  if total == 0:
    return None
  smaller = min(discordant_a, discordant_b)
  tail = sum(math.comb(total, index) for index in range(smaller + 1)) / (2 ** total)
  return min(1.0, 2 * tail)


def pair_arms(rows_by_arm, reference, other):
  """Paired comparison on (task, repetition) cells both arms scored."""
  index = {}
  for arm in (reference, other):
    for row in rows_by_arm[arm]:
      if row["scored"]:
        index[(arm, row["task"], row["repetition"])] = row
  cells = sorted({(task, repetition) for (arm, task, repetition) in index if arm == reference}
                 & {(task, repetition) for (arm, task, repetition) in index if arm == other})
  both = neither = only_reference = only_other = 0
  cheaper = dearer = 0
  reference_cost = other_cost = 0.0
  misses = []
  for task, repetition in cells:
    left, right = index[(reference, task, repetition)], index[(other, task, repetition)]
    reference_cost += left["cost_usd"] or 0
    other_cost += right["cost_usd"] or 0
    if left["passed"] and right["passed"]:
      both += 1
      if (left["cost_usd"] or 0) < (right["cost_usd"] or 0):
        cheaper += 1
      elif (left["cost_usd"] or 0) > (right["cost_usd"] or 0):
        dearer += 1
    elif left["passed"]:
      only_reference += 1
    elif right["passed"]:
      only_other += 1
      misses.append(dict(task=task, repetition=repetition,
                         routed_models=left["routed_models"], stop_reason=left["stop_reason"],
                         reference_cost_usd=left["cost_usd"], other_cost_usd=right["cost_usd"]))
    else:
      neither += 1
  return dict(
    reference=reference, other=other, paired_cells=len(cells),
    both_passed=both, neither_passed=neither,
    only_reference_passed=only_reference, only_other_passed=only_other,
    mcnemar_p=mcnemar_exact(only_reference, only_other),
    reference_cost_usd=reference_cost, other_cost_usd=other_cost,
    cost_ratio=reference_cost / other_cost if other_cost else None,
    cheaper_when_both_passed=cheaper, dearer_when_both_passed=dearer,
    routing_misses=misses)


def oracle_view(rows_by_arm, tasks):
  """What perfect per-task model choice would have scored, and what each arm left on it.

  The oracle is the best outcome any arm achieved on a task — an upper bound on routing,
  measured on these arms only. An arm's regret is the tasks the oracle solved and it did not.
  """
  solved_by = defaultdict(set)
  cheapest_pass = {}
  for arm, rows in rows_by_arm.items():
    for row in rows:
      if row["scored"] and row["passed"]:
        solved_by[row["task"]].add(arm)
        cost = row["cost_usd"] or 0
        if row["task"] not in cheapest_pass or cost < cheapest_pass[row["task"]]["cost_usd"]:
          cheapest_pass[row["task"]] = dict(arm=arm, cost_usd=cost)
  oracle = sorted(task for task in tasks if solved_by.get(task))
  regret = {}
  for arm, rows in rows_by_arm.items():
    solved = {row["task"] for row in rows if row["scored"] and row["passed"]}
    missed = sorted(task for task in oracle if task not in solved)
    overpaid = 0.0
    for task in solved:
      arm_cost = min(row["cost_usd"] or 0 for row in rows
                     if row["task"] == task and row["scored"] and row["passed"])
      overpaid += max(arm_cost - cheapest_pass[task]["cost_usd"], 0)
    regret[arm] = dict(solved=len(solved), missed_by_arm=missed,
                       oracle_gap=len(missed), excess_cost_usd=overpaid)
  return dict(tasks_any_arm_solved=len(oracle), tasks_seen=len(tasks),
              oracle_tasks=oracle, cheapest_pass=cheapest_pass, per_arm=regret)


def comparability(rows_by_arm):
  """Settings that must match across arms for the comparison to mean anything."""
  fields = ["binary_sha256", "max_steps", "timeout", "budget", "requested_effort", "packs_sha256"]
  report = {}
  for field in fields:
    values = {arm: sorted({str(row[field]) for row in rows}) for arm, rows in rows_by_arm.items()}
    distinct = {value for group in values.values() for value in group}
    report[field] = dict(consistent=len(distinct) <= 1, by_arm=values)
  return report


def render(document):
  lines = ["# Routing comparison", ""]
  lines.append(f"Tasks seen: {document['oracle']['tasks_seen']} · "
               f"arms: {', '.join(sorted(document['arms']))}")
  lines += ["", "## Arms", "",
            "| arm | scored | passed | pass rate | total $ | $/solved | median s | flagged |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
  for summary in document["summaries"]:
    rate = "n/a" if summary["pass_rate"] is None else f"{summary['pass_rate']:.0%}"
    per = "n/a" if summary["cost_per_solved_usd"] is None else f"${summary['cost_per_solved_usd']:.4f}"
    duration = "n/a" if summary["median_duration_seconds"] is None else f"{summary['median_duration_seconds']:.0f}"
    lines.append(f"| {summary['arm']} | {summary['scored']} | {summary['passed']} | {rate} | "
                 f"${summary['total_cost_usd']:.4f} | {per} | {duration} | {summary['flagged_trials']} |")
  for arm, breakdown in sorted(document["routing"].items()):
    if not breakdown:
      continue
    lines += ["", f"## What `{arm}` routed to", "",
              "| routed model | trials | passed | pass rate | total $ | providers |",
              "| --- | ---: | ---: | ---: | ---: | --- |"]
    for entry in breakdown:
      rate = "n/a" if entry["pass_rate"] is None else f"{entry['pass_rate']:.0%}"
      lines.append(f"| {entry['model']} | {entry['trials']} | {entry['passed']} | {rate} | "
                   f"${entry['total_cost_usd']:.4f} | {', '.join(entry['providers']) or 'n/a'} |")
  if document["pairs"]:
    lines += ["", "## Paired against the reference arm", "",
              "| arm | cells | both | only ref | only arm | McNemar p | ref $ / arm $ |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for pair in document["pairs"]:
      probability = "n/a" if pair["mcnemar_p"] is None else f"{pair['mcnemar_p']:.3f}"
      ratio = "n/a" if pair["cost_ratio"] is None else f"{pair['cost_ratio']:.2f}x"
      lines.append(f"| {pair['other']} | {pair['paired_cells']} | {pair['both_passed']} | "
                   f"{pair['only_reference_passed']} | {pair['only_other_passed']} | "
                   f"{probability} | {ratio} |")
  pools = {summary["arm"]: set(summary["providers"]) for summary in document["summaries"]
           if summary["providers"]}
  if len(pools) > 1:
    lines += ["", "## Upstream provider pools", "",
              "| arm | providers | timeouts |", "| --- | --- | ---: |"]
    for summary in document["summaries"]:
      lines.append(f"| {summary['arm']} | {', '.join(summary['providers']) or 'n/a'} | "
                   f"{summary['timeouts']} |")
    shared = set.intersection(*pools.values())
    lines += ["", "Arms share " + (f"{', '.join(sorted(shared))}." if shared else
                                   "**no upstream provider at all** — any difference between them "
                                   "is provider assignment as much as the variable under test, "
                                   "and cannot be attributed to that variable alone.")]
  oracle = document["oracle"]
  lines += ["", "## Oracle gap", "",
            f"Tasks at least one arm solved: {oracle['tasks_any_arm_solved']}", "",
            "| arm | solved | oracle gap | excess $ vs cheapest passing arm |",
            "| --- | ---: | ---: | ---: |"]
  for arm, entry in sorted(oracle["per_arm"].items()):
    lines.append(f"| {arm} | {entry['solved']} | {entry['oracle_gap']} | "
                 f"${entry['excess_cost_usd']:.4f} |")
  inconsistent = [field for field, entry in document["comparability"].items() if not entry["consistent"]]
  lines += ["", "## Comparability", ""]
  lines.append("All held-constant settings match across arms."
               if not inconsistent else
               "**Settings differ across arms — the comparison is confounded until explained: "
               + ", ".join(sorted(inconsistent)) + ".**")
  flags = Counter(flag for summary in document["summaries"] for flag, count in summary["flags"].items()
                  for _ in range(count))
  if flags:
    lines += ["", "Trial flags: " + ", ".join(f"{flag} ({count})" for flag, count in sorted(flags.items()))]
  lines += ["", "Completion is not correctness, and an unscored trial is not a failure — it is "
            "reliability evidence. Report both denominators.", ""]
  return "\n".join(lines)


def build(arms, reference):
  seen_tasks = set()
  rows_by_arm = {label: collect_arm(label, job, seen_tasks) for label, job in arms.items()}
  summaries = [summarize_arm(label, rows) for label, rows in sorted(rows_by_arm.items())]
  pairs = []
  if reference in rows_by_arm:
    pairs = [pair_arms(rows_by_arm, reference, other)
             for other in sorted(rows_by_arm) if other != reference]
  return dict(
    arms=sorted(rows_by_arm), reference=reference, summaries=summaries,
    routing={label: routing_breakdown(rows) for label, rows in rows_by_arm.items()},
    pairs=pairs, oracle=oracle_view(rows_by_arm, seen_tasks),
    comparability=comparability(rows_by_arm),
    trials=[row for rows in rows_by_arm.values() for row in rows])


def parse_arm(value):
  label, separator, path = value.partition("=")
  if not separator or not label.strip() or not path.strip():
    raise argparse.ArgumentTypeError("expected LABEL=/path/to/harbor/job")
  return label.strip(), Path(path.strip())


def main():
  parser = argparse.ArgumentParser(description=__doc__,
                                   formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("--arm", type=parse_arm, action="append", required=True, metavar="LABEL=JOB",
                      help="one arm's Harbor job directory; repeat for each arm")
  parser.add_argument("--reference", default="auto",
                      help="arm every other arm is paired against (default: auto)")
  parser.add_argument("--json", action="store_true", help="emit the full document instead of the report")
  args = parser.parse_args()
  arms = dict(args.arm)
  missing = [str(job) for job in arms.values() if not job.is_dir()]
  if missing:
    parser.error("not a Harbor job directory: " + ", ".join(missing))
  document = build(arms, args.reference)
  print(json.dumps(document, indent=2, sort_keys=True) if args.json else render(document))
  # A confounded or evidence-short batch exits nonzero: it is not a publishable comparison.
  confounded = any(not entry["consistent"] for entry in document["comparability"].values())
  return 1 if confounded or not document["oracle"]["tasks_any_arm_solved"] else 0


if __name__ == "__main__":
  raise SystemExit(main())
