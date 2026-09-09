"""Pure benchmark configuration/result parsing; no Harbor or model account required."""
from dataclasses import asdict, dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
from urllib.parse import urlsplit


@dataclass(frozen=True)
class BenchmarkConfig:
  binary_url: str
  binary_sha256: str
  model: str
  effort: str
  max_steps: int = 100
  timeout: int = 900
  keep_alive_seconds: int = 1200
  budget: float = 5.0
  dialect: str = "auto"
  command_diagnostics: bool = False
  preserve_command_evidence: bool = False
  keep_recent_tool_tokens: int | None = None
  time_aware: bool = False
  max_response_tokens: int | None = None

  @classmethod
  def from_environment(cls, environment):
    def required(name):
      value = environment.get(name, "").strip()
      if not value:
        raise ValueError(f"{name} is required for reproducible benchmark runs")
      return value
    def boolean(name):
      value = environment.get(name, "false").lower()
      if value not in {"true", "false"}:
        raise ValueError(f"{name} must be true or false")
      return value == "true"
    config = cls(
      binary_url=required("ARNES_LINUX_BINARY_URL"),
      binary_sha256=required("ARNES_LINUX_BINARY_SHA256").lower(),
      model=required("ARNES_MODEL"), effort=required("ARNES_EFFORT"),
      max_steps=int(environment.get("ARNES_MAX_STEPS", "100")),
      timeout=int(environment.get("ARNES_TIMEOUT", "900")),
      keep_alive_seconds=int(environment.get("ARNES_KEEP_ALIVE_SECONDS", "1200")),
      budget=float(environment.get("ARNES_BUDGET", "5")),
      dialect=environment.get("ARNES_DIALECT", "auto"),
      command_diagnostics=boolean("ARNES_COMMAND_DIAGNOSTICS"),
      preserve_command_evidence=boolean("ARNES_PRESERVE_COMMAND_EVIDENCE"),
      keep_recent_tool_tokens=int(environment["ARNES_KEEP_RECENT_TOOL_TOKENS"])
        if "ARNES_KEEP_RECENT_TOOL_TOKENS" in environment else None,
      time_aware=boolean("ARNES_TIME_AWARE"),
      max_response_tokens=int(environment["ARNES_MAX_RESPONSE_TOKENS"])
        if "ARNES_MAX_RESPONSE_TOKENS" in environment else None)
    url = urlsplit(config.binary_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password:
      raise ValueError("Binary URL must be HTTPS without credentials")
    if not re.fullmatch(r"[0-9a-f]{64}", config.binary_sha256):
      raise ValueError("Invalid ARNES_LINUX_BINARY_SHA256")
    if config.model == "openrouter/auto":
      raise ValueError("Choose an explicit model, not openrouter/auto")
    if config.effort not in {"minimal", "low", "medium", "high", "xhigh", "max", "none"}:
      raise ValueError("Invalid ARNES_EFFORT")
    if config.dialect not in {"auto", "chat", "messages", "responses"}:
      raise ValueError("Invalid ARNES_DIALECT")
    if config.max_steps <= 0 or config.timeout <= 0 or not math.isfinite(config.budget) or config.budget <= 0:
      raise ValueError("Benchmark limits must be positive and finite")
    if config.keep_recent_tool_tokens is not None and config.keep_recent_tool_tokens < 0:
      raise ValueError("ARNES_KEEP_RECENT_TOOL_TOKENS must be nonnegative")
    if not 0 <= config.keep_alive_seconds <= 3600:
      raise ValueError("ARNES_KEEP_ALIVE_SECONDS must be between 0 and 3600")
    if config.max_response_tokens is not None and config.max_response_tokens < 1:
      raise ValueError("ARNES_MAX_RESPONSE_TOKENS must be positive")
    return config

  def provenance(self):
    values = asdict(self)
    del values["binary_url"]  # A signed URL is private; the digest identifies its contents.
    return dict(values, provider="openrouter", bare=True, memory=False, schema_version=4)

  def runtime_config(self):
    config = {
      "provider": "openrouter", "memory": {"enabled": False},
      "policies": {"manifestCache": {"enabled": False},
        "commandDiagnostics": self.command_diagnostics},
      "compaction": {"preserveCommandEvidence": self.preserve_command_evidence},
    }
    if self.keep_recent_tool_tokens is not None:
      config["compaction"]["keepRecentToolTokens"] = self.keep_recent_tool_tokens
    return config

  def command(self, instruction, session_id):
    experiments = ["--time-aware"] if self.time_aware else []
    if self.max_response_tokens is not None:
      experiments += ["--max-response-tokens", str(self.max_response_tokens)]
    return shlex.join([
      "/usr/local/bin/arnes", "do", instruction, "-m", self.model,
      "--effort", self.effort, "--dialect", self.dialect,
      "--max-steps", str(self.max_steps), "--timeout", str(self.timeout),
      "--keep-alive", str(self.keep_alive_seconds),
      "--budget", str(self.budget), "--yes", "--add-dir", "/", "--bare",
      "--no-memory", "--session", "--session-id", session_id,
      "--output-format", "stream-json", "--include-partial",
      "--output-last-message", "/logs/agent/arnes-last-message.md"] + experiments)


def pack_fingerprint(files):
  encoded = json.dumps(files, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
  return hashlib.sha256(encoded.encode()).hexdigest()


def load_packs(directory):
  """Load explicit host-side proposals without following leaves or reading special files."""
  if not directory:
    return {}
  result, total = {}, 0
  for path in sorted(Path(directory).iterdir()):
    if path.suffix != ".md" and not path.name.endswith(".tools.json"):
      continue
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > 65_536:
      raise ValueError(f"Pack must be a regular file of at most 64 KB: {path.name}")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, "rb") as stream:
      opened = os.fstat(stream.fileno())
      if not stat.S_ISREG(opened.st_mode) or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
        raise ValueError("Pack file changed while opening")
      data = stream.read(65_537)
    total += len(data)
    if len(data) > 65_536 or total > 1_048_576 or len(result) >= 64:
      raise ValueError("Pack set exceeds its file/count/total byte limit")
    result[path.name] = data.decode("utf-8")
  return result


def parse_trajectory(lines, exit_code=None):
  """Completion is not correctness. The task verifier remains authoritative."""
  result, malformed, events = None, 0, 0
  for line in lines:
    if not line.strip():
      continue
    try:
      event = json.loads(line)
      if not isinstance(event, dict):
        raise ValueError("event is not an object")
    except (ValueError, TypeError):
      malformed += 1
      continue
    events += 1
    if event.get("type") == "result":
      if not isinstance(event.get("is_error"), bool) or not (
        isinstance(event.get("stop_reason"), str) or event["is_error"]
      ):
        malformed += 1
        continue
      result = event
  if result is None:
    classification = "usage_error" if exit_code == 64 else "incomplete_trajectory"
  elif exit_code in {130, 137, 143}:
    classification = "interrupted"
  elif result.get("is_error") or result.get("stop_reason") == "error":
    classification = "agent_or_provider_error"
  elif result.get("stop_reason") in {"timeout", "interrupted"}:
    classification = "interrupted"
  elif exit_code == 64:
    classification = "usage_error"
  else:
    classification = "task_attempt"
  return dict(classification=classification, exit_code=exit_code, malformed_lines=malformed,
              event_count=events, result=result)
