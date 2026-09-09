#!/usr/bin/env python3
"""Actual Linux CLI + adapter shell regression; run only in a disposable Docker container.

Requires python3, curl/libcurl, libstdc++6, /usr/local/bin/arnes, and a writable
/logs/agent. Run with --network none: the provider is scripted numeric loopback.
This checks integration behavior, not model quality or a Terminal-Bench score.
"""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import types
import urllib.request


async def main():
  if sys.platform != "linux" or not Path("/.dockerenv").exists():
    raise SystemExit("Run this fixture inside a disposable Docker container, never on the host.")
  repo = Path(__file__).resolve().parents[1]
  sys.path.insert(0, str(repo / "benchmarks/terminal-bench"))
  from test_adapter import adapter
  from benchmark_contract import BenchmarkConfig
  spec = importlib.util.spec_from_file_location("acp_fixture", repo / "scripts/test-acp.py")
  fixture = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(fixture)
  reports = []
  for mode, grace in [("default", 0), ("deadline", 3), ("signal", 30), ("time-aware", 0), ("time-limit", 0)]:
    root = Path("/logs/agent") / mode
    root.mkdir(parents=True)
    work = Path("/work") / mode
    work.mkdir(parents=True)
    os.chdir(work)
    with socket.socket() as listener:
      listener.bind(("127.0.0.1", 0))
      port = listener.getsockname()[1]
    provider = fixture.Provider()
    provider.scripts.extend([
      fixture.tool("bash", command=f"mkdir www && printf fixture-data > www/index.html"),
      fixture.tool("bash", command=f"exec python3 -m http.server {port} --bind 127.0.0.1 --directory {work}/www", background=True),
      fixture.tool("bash", command=f"curl --retry 10 --retry-connrefused --retry-delay 0 -fsS http://127.0.0.1:{port}/index.html"),
      {"content": "Fixture complete."},
    ])
    if mode == "time-limit":
      provider.scripts.clear()
      provider.scripts.append("hold")
    async def execute(**kwargs):
      environment = dict(os.environ, **(kwargs.get("env") or {}), ARNES_BASE_URL=provider.url)
      result = await asyncio.to_thread(subprocess.run, ["bash", "-c", kwargs["command"]],
        env=environment, capture_output=True, text=True, timeout=kwargs["timeout_sec"])
      assert result.returncode == 0, result.stderr
      return types.SimpleNamespace(return_code=result.returncode)
    agent = adapter.ArnesAgent(logs_dir=root, extra_env={"OPENROUTER_API_KEY": "offline-fixture"})
    settings = {
      "ARNES_LINUX_BINARY_URL": "https://fixture.invalid/arnes",
      "ARNES_LINUX_BINARY_SHA256": "a" * 64,
      "ARNES_MODEL": "test/model", "ARNES_EFFORT": "high", "ARNES_MAX_STEPS": "5",
      "ARNES_TIMEOUT": "30", "ARNES_BUDGET": "1", "ARNES_KEEP_ALIVE_SECONDS": str(grace),
    }
    if mode in {"time-aware", "time-limit"}:
      settings.update(ARNES_TIME_AWARE="true", ARNES_MAX_RESPONSE_TOKENS="8192")
    if mode == "time-limit":
      settings["ARNES_TIMEOUT"] = "2"
    agent.arnes_config = BenchmarkConfig.from_environment(settings)
    agent.arnes_provenance = agent.arnes_config.provenance()
    agent.arnes_packs = {}
    context = types.SimpleNamespace(metadata=None)
    adapter.LOGS = str(root)
    try:
      await agent.run("Run the scripted fixture.", types.SimpleNamespace(exec=execute), context)
      result = json.loads((root / "arnes-result.json").read_text())
      if mode == "time-limit":
        assert result["stop_reason"] == "timeout", result
        assert (root / "arnes-exit-code.txt").read_text().strip() == "3"
        assert len(provider.requests) == 1
        assert provider.requests[0]["max_tokens"] == 8192
        assert "[arnes time budget]" in json.dumps(provider.requests[0]["messages"])
        assert context.metadata["arnes"]["transcript_available"]
        reports.append(dict(mode=mode, checks="passed", scripted_requests=1, external_model_calls=0))
        continue
      assert result["stop_reason"] == "completed", result
      assert result["tool_calls"] == 3, result
      assert context.metadata["arnes"]["transcript_available"]
      assert (work / "www").stat().st_mode & 0o777 == 0o755
      assert (work / "www/index.html").stat().st_mode & 0o777 == 0o644
      other = subprocess.run(["su", "-s", "/bin/sh", "nobody", "-c", f"cat {work}/www/index.html"], capture_output=True)
      assert other.returncode == 0 and other.stdout == b"fixture-data", other
      for name in ["arnes-events.jsonl", "arnes-stderr.log", "arnes-transcript.jsonl"]:
        assert (root / name).stat().st_mode & 0o777 == 0o600, name
      if grace:
        assert urllib.request.urlopen(f"http://127.0.0.1:{port}/index.html", timeout=2).read() == b"fixture-data"
        assert not (root / "arnes-exit-code.txt").exists(), "the CLI exited before verification"
      if mode == "signal":
        os.kill(int((root / "arnes-pid.txt").read_text()), signal.SIGTERM)
      deadline = time.monotonic() + 10
      while not (root / "arnes-exit-code.txt").exists() and time.monotonic() < deadline:
        await asyncio.sleep(0.05)
      expected = "143" if mode == "signal" else "0"
      assert (root / "arnes-exit-code.txt").read_text().strip() == expected
      with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", port)) != 0, "managed service survived cleanup"
      assert len(provider.requests) == 4, "the grace period must not make model requests"
      assert result["routed_models"] == ["test/routed"]
      if mode == "time-aware":
        assert all(request.get("max_tokens") == 8192 for request in provider.requests)
        assert any("[arnes time budget]" in json.dumps(message) for message in provider.requests[0]["messages"])
        assert "[arnes time budget]" in (root / "arnes-transcript.jsonl").read_text()
        assert agent.arnes_provenance["time_aware"]
        assert agent.arnes_provenance["max_response_tokens"] == 8192
      else:
        assert all("max_tokens" not in request for request in provider.requests)
        assert "[arnes time budget]" not in json.dumps(provider.requests)
      reports.append(dict(mode=mode, checks="passed", scripted_requests=4, external_model_calls=0))
    finally:
      provider.close()
  Path("/logs/agent/integration.json").write_text(json.dumps(reports, indent=2) + "\n")
  print(json.dumps(reports))


if __name__ == "__main__":
  asyncio.run(main())
