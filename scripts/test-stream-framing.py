#!/usr/bin/env python3
"""Synthetic Linux HTTP chunk integration; requires a disposable --network none container.

No model calls, inherited credentials or host home mounts. The only provider is a
scripted loopback server. Use --expect-framing broken for a frozen pre-fix binary,
then fixed --expect-diagnostics for the isolated binary with the upstream patch.
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import socket
import socketserver
import subprocess
import tempfile
import threading
import time


def save(path, value):
  path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
  path.chmod(0o600)


def event(delta, finish=None):
  value = {"id": "fixture", "model": "test/routed", "choices": [
    {"index": 0, "delta": delta, "finish_reason": finish}]}
  if finish:
    value["usage"] = {"prompt_tokens": 10, "completion_tokens": 5, "cost": 0}
  return ("data: " + json.dumps(value, ensure_ascii=False) + "\n\n").encode()


CONTENT = "Fixture café 🧪 complete."
COMPLETE = event({"content": CONTENT})
FINISH = event({}, "stop") + b"data: [DONE]\n\n"
MALFORMED = b'{"choices":['


def chunks_for(case):
  if case == "cancel":
    return [b": keep-alive\n\n"]
  if case.startswith("malformed"):
    return ([event({"content": "prefix "})] if case.endswith("after-output") else []) + [
      b"data: " + MALFORMED + b"\n\n"]
  if case == "partial-eof":
    return [b"data: " + MALFORMED]
  if case.startswith("split-json"):
    split = COMPLETE.index(b'"content"') + 5
  elif case == "split-utf8":
    split = COMPLETE.index("🧪".encode()) + 2
  else:
    return [COMPLETE + FINISH]
  return ([event({"content": "prefix "})] if case.endswith("after-output") else []) + [
    COMPLETE[:split], COMPLETE[split:] + FINISH]


class Provider:
  def __init__(self, case):
    self.requests = []
    self.closed = threading.Event()
    self.errors = []
    owner = self

    class Handler(http.server.BaseHTTPRequestHandler):
      protocol_version = "HTTP/1.1"

      def log_message(self, *args):
        pass

      def do_GET(self):
        if self.path != "/v1/models":
          self.send_error(404)
          return
        body = json.dumps({"data": [{"id": "test/model", "context_length": 200000,
          "supported_parameters": ["tools"], "pricing": {"prompt": "0", "completion": "0"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

      def do_POST(self):
        owner.requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        if self.path != "/v1/chat/completions" or len(owner.requests) != 1:
          self.send_error(500, "Unexpected request or retry")
          return
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
          chunks = chunks_for(case)
          for index, chunk in enumerate(chunks):
            self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.flush()
            if index < len(chunks) - 1:
              # Give the client an incomplete line before the rest is transmitted.
              time.sleep(0.2)
          if case == "cancel":
            self.connection.settimeout(5)
            if self.connection.recv(1) == b"":
              owner.closed.set()
          else:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
          owner.closed.set()
        except Exception as error:
          owner.errors.append(str(error))

    class Server(http.server.ThreadingHTTPServer):
      def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]

    self.server = Server(("127.0.0.1", 0), Handler)
    self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
    self.thread.start()
    self.url = f"http://127.0.0.1:{self.server.server_port}/v1"

  def close(self):
    self.server.shutdown()
    self.server.server_close()
    self.thread.join(timeout=2)


def run_case(binary, case, output, broken, diagnostics):
  directory = output / case
  directory.mkdir(mode=0o700)
  provider = Provider(case)
  try:
    with tempfile.TemporaryDirectory(prefix="arnes-framing-") as temporary:
      root = Path(temporary)
      work = root / "work"
      work.mkdir()
      captures = root / "captures"
      captures.mkdir(mode=0o700)
      config = root / "config.json"
      save(config, {"provider": "fixture", "providers": {"fixture": {
        "kind": "openrouter", "baseURL": provider.url, "apiKey": "offline-fixture",
        "defaultModel": "test/model", "nativeDialects": False}},
        "policies": {"transport": {"maxRequestRetries": 0, "maxStreamRetries": 0}}})
      env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "ARNES_CONFIG": str(config)}
      capture_enabled = diagnostics and case != "malformed-default"
      if capture_enabled:
        env["ARNES_STREAM_DIAGNOSTICS_DIR"] = str(captures)
      command = [str(binary), "do", "--bare", "--no-memory", "--dialect", "chat",
        "--model", "test/model", "--max-steps", "2", "--timeout", "1" if case == "cancel" else "8",
        "--output-format", "json", "Return the synthetic fixture response."]
      result = subprocess.run(command, cwd=work, env=env, stdin=subprocess.DEVNULL,
        capture_output=True, timeout=15)
      (directory / "stdout.json").write_bytes(result.stdout)
      (directory / "stderr.log").write_bytes(result.stderr)
      lines = result.stdout.splitlines()
      assert len(lines) == 1, (case, "stdout is not one JSON object", result.stdout, result.stderr)
      envelope = json.loads(lines[0])
      split = case.startswith("split-")
      malformed = case.startswith("malformed") or case == "partial-eof"
      expected_error = malformed or (broken and split)
      expected_stop = "timeout" if case == "cancel" else "error" if expected_error else "completed"
      assert envelope["stop_reason"] == expected_stop, (case, envelope)
      assert result.returncode == (3 if case == "cancel" else 1 if expected_error else 0), (case, result.returncode)
      assert len(provider.requests) == 1, (case, "unexpected retry", len(provider.requests))
      assert envelope["tool_calls"] == 0, (case, envelope)
      if expected_error:
        assert "decodingFailure" in envelope["error"], (case, envelope)
      elif case != "cancel":
        assert envelope["result"] == ("prefix " if case.endswith("after-output") else "") + CONTENT, (case, envelope)
        assert envelope["routed_models"] == ["test/routed"], (case, envelope)
      if case == "cancel":
        assert provider.closed.wait(timeout=3), "Timed out stream did not close its connection"
      artifacts = sorted(captures.glob("*.json"))
      assert len(artifacts) == (1 if capture_enabled and expected_error else 0), (case, artifacts)
      for path in artifacts:
        assert path.stat().st_mode & 0o777 == 0o600
        assert path.stat().st_size <= 32768
        artifact = json.loads(path.read_text())
        assert artifact["emitted_output"] == case.endswith("after-output"), (case, artifact)
        assert artifact["phase"] == "stream", (case, artifact)
        if malformed:
          assert base64.b64decode(artifact["payload_base64"]) == MALFORMED, (case, artifact)
          assert not artifact["payload_changed"] and not artifact["payload_omitted"]
        save(directory / path.name, artifact)
      save(directory / "request.json", provider.requests[0])
      save(directory / "chunks.json", [base64.b64encode(chunk).decode() for chunk in chunks_for(case)])
      for path in directory.iterdir():
        path.chmod(0o600)
      assert not provider.errors, (case, provider.errors)
      return {"case": case, "exit_code": result.returncode, "stop_reason": expected_stop,
        "requests": 1, "diagnostics": len(artifacts), "passed": True}
  finally:
    provider.close()


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--binary", type=Path, required=True)
  parser.add_argument("--output", type=Path, required=True)
  parser.add_argument("--expect-framing", choices=("broken", "fixed"), required=True)
  parser.add_argument("--expect-diagnostics", action="store_true")
  args = parser.parse_args()
  if platform.system() != "Linux" or not Path("/.dockerenv").exists():
    parser.error("Run only in a disposable Docker container; never against a host home")
  active_interfaces = {path.name for path in Path("/sys/class/net").iterdir()
    if (path / "flags").is_file() and int((path / "flags").read_text().strip(), 16) & 1}
  if active_interfaces != {"lo"}:
    parser.error("Container must use --network none; only loopback is allowed")
  os.umask(0o077)
  args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
  cases = ["normal", "split-json", "split-json-after-output", "split-utf8", "malformed",
    "malformed-after-output", "malformed-default", "partial-eof", "cancel"]
  results = []
  for case in cases:
    results.append(run_case(args.binary.resolve(), case, args.output,
      args.expect_framing == "broken", args.expect_diagnostics))
    print(json.dumps(results[-1]), flush=True)
  save(args.output / "summary.json", {"binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
    "expected_framing": args.expect_framing, "network": "none", "external_model_calls": 0, "cases": results})


if __name__ == "__main__":
  main()
