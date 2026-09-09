#!/usr/bin/env python3
"""Offline executable ACP integration. No provider credentials or personal stores.

Run after swift build: python3 scripts/test-acp.py --binary .build/debug/arnes
--transport-only needs no listening socket; the full suite uses a loopback HTTP fixture.
The fixture deliberately leaves the production sandbox policy enabled on macOS.
"""
import argparse
import collections
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest


def eventually(check, seconds=10):
  deadline = time.monotonic() + seconds
  while time.monotonic() < deadline:
    value = check()
    if value:
      return value
    time.sleep(0.01)
  raise AssertionError("Timed out waiting for integration condition")


class Client:
  def __init__(self, binary, state, cwd):
    # An explicit allowlist also excludes ambient ARNES_CONFIG/provider/pack overrides.
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
    self.process = subprocess.Popen(
      [str(binary), "acp", "--state-directory", str(state), "--max-steps", "8"],
      cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
      stderr=subprocess.PIPE, start_new_session=True)
    self.messages = queue.Queue()
    self.seen = []
    self.errors = []

    def read():
      try:
        for line in self.process.stdout:
          self.messages.put(json.loads(line))
      except Exception as error:
        self.messages.put(error)

    self.reader = threading.Thread(target=read, daemon=True)
    self.reader.start()
    self.stderr_reader = threading.Thread(
      target=lambda: self.errors.append(self.process.stderr.read()), daemon=True)
    self.stderr_reader.start()

  def send(self, method, params=None, ident=None):
    value = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if ident is not None:
      value["id"] = ident
    self.write(value)

  def write(self, value):
    self.process.stdin.write(json.dumps(value).encode() + b"\n")
    self.process.stdin.flush()

  def wait(self, predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
      try:
        value = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
      except queue.Empty:
        break
      if isinstance(value, Exception):
        raise value
      self.seen.append(value)
      if predicate(value):
        return value
    raise AssertionError("Timed out waiting for ACP message; stderr=" + repr(self.errors))

  def reply(self, ident):
    return self.wait(lambda value: value.get("id") == ident)

  def initialize(self):
    self.send("initialize", {"protocolVersion": 1, "clientCapabilities": {}}, 0)
    return self.reply(0)["result"]

  def new(self, cwd, servers=None, ident=1):
    self.send("session/new", {"cwd": str(cwd), "mcpServers": servers or []}, ident)
    return self.reply(ident)["result"]["sessionId"]

  def prompt(self, session, ident=2, text="Run the scripted check."):
    self.send("session/prompt", {"sessionId": session,
      "prompt": [{"type": "text", "text": text}]}, ident)

  def permission(self, allow):
    request = self.wait(lambda value: value.get("method") == "session/request_permission")
    self.write({"jsonrpc": "2.0", "id": request["id"], "result": {
      "outcome": {"outcome": "selected", "optionId": "allow-once" if allow else "reject-once"}}})
    return request["params"]["toolCall"]["toolCallId"]

  def eof(self):
    self.process.stdin.close()
    return self.process.wait(timeout=10)

  def close(self):
    if self.process.poll() is None:
      self.process.stdin.close()
      try:
        self.process.wait(timeout=10)
      except subprocess.TimeoutExpired:
        os.killpg(self.process.pid, signal.SIGKILL)
        self.process.wait(timeout=5)
        raise AssertionError("ACP did not cleanly exit after EOF")
    self.reader.join(timeout=2)
    self.stderr_reader.join(timeout=2)
    for handle in (self.process.stdin, self.process.stdout, self.process.stderr):
      handle.close()


class TransportTests(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory(prefix="arnes-acp-executable-")
    self.addCleanup(self.temp.cleanup)
    self.root = Path(self.temp.name).resolve()
    self.state = self.root / "state"
    self.cwd = self.root / "work"
    self.state.mkdir()
    self.cwd.mkdir()
    self.configure("http://127.0.0.1:1/v1")
    self.client = Client(BINARY, self.state, self.cwd)
    self.addCleanup(self.client.close)

  def configure(self, url):
    (self.state / "config.json").write_text(json.dumps({
      "provider": "fixture", "providers": {"fixture": {
        "kind": "openrouter", "baseURL": url, "apiKey": "offline-fixture",
        "defaultModel": "test/model", "nativeDialects": False}},
      "policies": {"commandDiagnostics": True,
        "transport": {"maxRequestRetries": 0, "maxStreamRetries": 0}},
      "limits": {"toolResultChars": 4000}}))
    (self.state / "config.json").chmod(0o600)

  def test_initialization_framing_and_close(self):
    result = self.client.initialize()
    self.assertEqual(result["protocolVersion"], 1)
    self.assertFalse(result["agentCapabilities"]["loadSession"])
    session = self.client.new(self.cwd)
    self.client.send("session/close", {"sessionId": session}, 3)
    self.assertEqual(self.client.reply(3)["result"], {})
    self.assertFalse((self.state / "runs.jsonl").exists())
    self.assertEqual(self.client.eof(), 0)

  def test_invalid_json_then_valid_request(self):
    self.client.process.stdin.write(b"invalid\n")
    self.client.process.stdin.flush()
    self.assertEqual(self.client.reply(None)["error"]["code"], -32700)
    self.assertEqual(self.client.initialize()["protocolVersion"], 1)

  def test_cancel_pending_mcp_startup_without_a_model_call(self):
    self.client.initialize()
    session = self.client.new(self.cwd, [{"name": "fixture", "command": "/bin/sh",
      "args": ["-c", "touch must-not-start"], "env": []}])
    self.client.prompt(session)
    permission = self.client.wait(lambda value: value.get("method") == "session/request_permission")
    self.assertEqual(permission["params"]["sessionId"], session)
    self.client.send("session/cancel", {"sessionId": session})
    self.assertEqual(self.client.reply(2)["result"]["stopReason"], "cancelled")
    self.assertFalse((self.cwd / "must-not-start").exists())

  def test_output_disconnect_exits_even_when_stdin_is_open(self):
    # A separate process without a reader: close the sole stdout read end before output.
    process = subprocess.Popen([str(BINARY), "acp", "--state-directory", str(self.state)],
      cwd=self.cwd, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
      process.stdout.close()
      process.stdin.write(b'{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}\n')
      process.stdin.flush()
      self.assertEqual(process.wait(timeout=5), 0)
    finally:
      if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
      process.stdin.close()
      process.stderr.close()


def tool(name, **arguments):
  return {"tool_calls": [{"index": 0, "id": "repeated-model-id", "type": "function",
    "function": {"name": name, "arguments": json.dumps(arguments)}}]}


class Provider:
  def __init__(self):
    self.scripts = collections.deque()
    self.requests = []
    self.release = threading.Event()
    owner = self

    class Handler(http.server.BaseHTTPRequestHandler):
      def log_message(self, *args):
        pass

      def do_GET(self):
        if self.path != "/v1/models":
          self.send_error(404)
          return
        body = json.dumps({"data": [{"id": "test/model", "context_length": 200000,
          "supported_parameters": ["tools"], "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

      def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        owner.requests.append(request)
        if self.path != "/v1/chat/completions" or not owner.scripts:
          self.send_error(500, "Unscripted request")
          return
        script = owner.scripts.popleft()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
          if script == "hold":
            # Headers sent, no tokens; cancellation must abort an actual streaming request.
            owner.release.wait(timeout=30)
            return
          script = dict(script)
          finish_reason = script.pop("finish_reason", "tool_calls" if "tool_calls" in script else "stop")
          chunk = {"id": "fixture", "model": "test/routed", "choices": [{"index": 0, "delta": script}]}
          self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
          usage = {"model": "test/routed", "choices": [{"index": 0, "delta": {},
            "finish_reason": finish_reason}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "cost": 0.001}}
          self.wfile.write(("data: " + json.dumps(usage) + "\n\ndata: [DONE]\n\n").encode())
          self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
          pass

    class Server(http.server.ThreadingHTTPServer):
      def server_bind(self):
        # Numeric loopback needs no reverse DNS during fixture startup.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]

    self.server = Server(("127.0.0.1", 0), Handler)
    self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
    self.thread.start()
    self.url = "http://127.0.0.1:%s/v1" % self.server.server_port

  def close(self):
    self.release.set()
    self.server.shutdown()
    self.server.server_close()
    self.thread.join(timeout=5)


class ProviderTests(TransportTests):
  def setUp(self):
    super().setUp()
    self.provider = Provider()  # Failure to bind is a failed integration check, never a skip.
    self.addCleanup(self.provider.close)
    self.configure(self.provider.url)
    self.client.initialize()
    self.session = self.client.new(self.cwd)

  # Transport-only cases run once, in TransportTests.
  test_initialization_framing_and_close = None
  test_invalid_json_then_valid_request = None
  test_cancel_pending_mcp_startup_without_a_model_call = None
  test_output_disconnect_exits_even_when_stdin_is_open = None

  def rows(self):
    path = self.state / "runs.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

  def updates(self, ident):
    return [value["params"]["update"] for value in self.client.seen
      if value.get("method") == "session/update"
      and value["params"]["update"].get("toolCallId") == ident]

  def test_prompt_read_progress_routing_and_records(self):
    (self.cwd / "input.txt").write_text("fixture evidence")
    self.provider.scripts.extend([tool("read_file", path="input.txt"), {"content": "Verified fixture."}])
    self.client.prompt(self.session)
    self.assertEqual(self.client.reply(2)["result"]["stopReason"], "end_turn")
    announced = next(value["params"]["update"] for value in self.client.seen
      if value.get("method") == "session/update" and value["params"]["update"]["sessionUpdate"] == "tool_call")
    self.assertEqual([v["status"] for v in self.updates(announced["toolCallId"])],
      ["pending", "in_progress", "completed"])
    self.assertIn("fixture evidence", json.dumps(self.provider.requests[-1]))
    row = self.rows()[0]
    self.assertEqual(row["sessionId"], self.session)
    self.assertEqual(row["routedModels"], ["test/routed"])
    self.assertAlmostEqual(row["costUSD"], 0.002)
    self.assertTrue((self.state / "sessions" / (self.session + ".jsonl")).exists())
    self.assertTrue((self.state / "models").is_dir())

  def test_approval_denial_and_harness_floor(self):
    for index, (name, allow) in enumerate([("allowed.txt", True), ("denied.txt", False),
                                        (str(self.state / "cannot-write"), True)]):
      self.provider.scripts.extend([tool("write_file", path=name, content="fixture"), {"content": "Finished check."}])
      self.client.prompt(self.session, ident=10 + index)
      ident = self.client.permission(allow)
      self.assertEqual(self.client.reply(10 + index)["result"]["stopReason"], "end_turn")
      self.assertEqual((self.cwd / name).exists(), allow and index != 2)
      self.assertEqual(self.updates(ident)[-1]["status"], "completed" if index == 0 else "failed")
    self.assertEqual(len(self.rows()), 3)
    self.assertEqual(self.rows()[1]["deniedCalls"], 1)

  def test_cancel_pending_permission_then_restart(self):
    self.provider.scripts.append(tool("write_file", path="cancelled.txt", content="fixture"))
    self.client.prompt(self.session)
    self.client.wait(lambda value: value.get("method") == "session/request_permission")
    self.client.send("session/cancel", {"sessionId": self.session})
    self.assertEqual(self.client.reply(2)["result"]["stopReason"], "cancelled")
    self.assertEqual(self.rows()[0]["stopReason"], "interrupted")
    self.assertFalse((self.cwd / "cancelled.txt").exists())
    self.provider.scripts.append({"content": "Restarted."})
    self.client.prompt(self.session, ident=3)
    self.assertEqual(self.client.reply(3)["result"]["stopReason"], "end_turn")
    self.assertEqual(len(self.rows()), 2)

  def test_disconnect_during_model_stream_preserves_record(self):
    self.provider.scripts.append("hold")
    self.client.prompt(self.session)
    eventually(lambda: len(self.provider.requests) == 1)
    self.assertEqual(self.client.eof(), 0)
    self.assertEqual(self.rows()[0]["stopReason"], "interrupted")

  def test_background_process_tree_cancel_then_restart(self):
    self.provider.scripts.extend([tool("bash", command="sleep 60 & echo $! > child.pid; wait", background=True), "hold"])
    self.client.prompt(self.session)
    self.client.permission(True)
    eventually(lambda: (self.cwd / "child.pid").exists())
    pid = int((self.cwd / "child.pid").read_text())
    self.addCleanup(lambda: self.kill_if_alive(pid))
    eventually(lambda: len(self.provider.requests) == 2)
    self.client.send("session/cancel", {"sessionId": self.session})
    self.assertEqual(self.client.reply(2)["result"]["stopReason"], "cancelled")
    eventually(lambda: not self.alive(pid))
    self.provider.release.set()
    self.provider.scripts.clear()
    self.provider.scripts.extend([tool("bash", command="printf recovered > recovered.txt"), {"content": "Recovered."}])
    self.client.prompt(self.session, ident=3)
    self.client.permission(True)
    self.assertEqual(self.client.reply(3)["result"]["stopReason"], "end_turn")
    self.assertEqual(len(self.rows()), 2)

  def test_sigterm_during_stream_drains_record_before_exit(self):
    self.provider.scripts.append("hold")
    self.client.prompt(self.session)
    eventually(lambda: len(self.provider.requests) == 1)
    self.client.process.send_signal(signal.SIGTERM)
    self.assertEqual(self.client.process.wait(timeout=10), 143)
    self.assertEqual(self.rows()[0]["stopReason"], "interrupted")

  def test_second_session_is_independent_and_close_denies_pending_permission(self):
    other = self.root / "other"
    other.mkdir()
    second = self.client.new(other, ident=3)
    self.provider.scripts.extend([tool("write_file", path="owned.txt", content="second session"),
      {"content": "Created."}])
    self.client.prompt(second, ident=4)
    self.client.permission(True)
    self.assertEqual(self.client.reply(4)["result"]["stopReason"], "end_turn")
    self.assertEqual((other / "owned.txt").read_text(), "second session")
    self.assertFalse((self.cwd / "owned.txt").exists())
    self.provider.scripts.append(tool("write_file", path="never.txt", content="denied by close"))
    self.client.prompt(self.session, ident=5)
    self.client.wait(lambda value: value.get("method") == "session/request_permission")
    self.client.send("session/close", {"sessionId": self.session}, 6)
    self.assertEqual(self.client.reply(5)["result"]["stopReason"], "cancelled")
    self.assertEqual(self.client.reply(6)["result"], {})
    self.assertFalse((self.cwd / "never.txt").exists())
    self.assertEqual({row["sessionId"] for row in self.rows()}, {self.session, second})

  @staticmethod
  def alive(pid):
    # A zombie has exited; Linux init may reap it after the check.
    status = Path("/proc/%d/stat" % pid)
    try:
      if status.exists() and status.read_text().split(") ", 1)[1].startswith("Z"):
        return False
      os.kill(pid, 0)
      return True
    except ProcessLookupError:
      return False

  @classmethod
  def kill_if_alive(cls, pid):
    if cls.alive(pid):
      os.kill(pid, signal.SIGKILL)


if __name__ == "__main__":
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--binary", type=Path, default=Path(".build/debug/arnes"))
  parser.add_argument("--transport-only", action="store_true")
  args = parser.parse_args()
  BINARY = args.binary.resolve(strict=True)
  suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(TransportTests))
  if not args.transport_only:
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(ProviderTests))
  raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
