# Agent Client Protocol

`arnes acp` serves [ACP v1](https://agentclientprotocol.com/protocol/v1/overview) over
newline-delimited JSON-RPC on stdin/stdout. It uses the same ArnesKit `Session` and
permission gates as the CLI, not a second agent loop.

Configure an ACP-capable editor to launch `arnes` with arguments
`acp --model <model-slug> --effort high`. The editor needs the provider key in its
environment or the normal Arnes credential configuration. `--provider` selects a gateway.
Initialization and session-ID allocation work without credentials. The first prompt resolves
provider configuration and starts approved MCP servers, after the client knows the session ID.
No interactive authentication method is advertised.

Options: `-m/--model`, `--provider`, `--effort`, `--max-steps` (100 by default), and
`--budget` (a **session-wide**, not per-turn, USD ceiling; default $5).
There is no `--yes` or permission-bypass option.
Cost ceilings are checked between model steps against reported/estimated usage; a request
already in flight can cross the ceiling. They are not provider-side prepaid limits.

`--state-directory /absolute/path` redirects configuration (`config.json`), credential
fallback (`credentials`), prompt overrides (`packs/`), model/dialect caches, spill files,
run records and transcripts to one explicit directory. It ignores ambient `ARNES_CONFIG`
and `ARNES_PACKS_DIR` locations and skips the personal retention sweep. Provider environment
overrides still apply. The directory joins the harness write floor and OS sandbox's protected
paths; its credential/configuration files remain sensitive reads. Without this option,
the existing `~/.arnes` and environment-based configuration behavior is unchanged.

## Supported contract

- `initialize`: negotiates version 1 and advertises supported capabilities.
- `session/new`: an existing absolute `cwd` and `mcpServers` array create an independent session.
- `session/prompt`: text and resource-link blocks; streams assistant text, reasoning and plans.
- `session/update`: tool-call creation and pending/running/completed/failed progress,
  with a unique invocation ID and bounded, scrubbed result excerpts. Permission questions
  reference that same ID; concurrent calls and repeated model IDs remain distinct.
- `session/request_permission`: explicit allow-once/reject-once choices. Missing replies,
  unknown options, cancellation and disconnect deny pending requests. Timeout: five minutes.
- `session/cancel`: cancels model/tool work, releases permissions, stops background jobs,
  and drains the turn before returning its cancelled result and preserving its run record.
- `session/close`: cancels and releases one session, including its MCP connections.

Message shapes follow the [initialization](https://agentclientprotocol.com/protocol/v1/initialization),
[session](https://agentclientprotocol.com/protocol/v1/session-setup), and
[permission/cancellation](https://agentclientprotocol.com/protocol/v1/prompt-turn) contracts;
tool progress follows the [tool-call lifecycle](https://agentclientprotocol.com/protocol/v1/tool-calls).
Limits: 1 MiB input lines, 64 outstanding requests, 32 sessions, 16 MCP servers per session.
An output write that stalls for five seconds fails the connection. Writes run on a serial
IO queue so a client that stops reading cannot block the cooperative executor indefinitely.

## Files, processes and trust

Core tools resolve paths and shell commands relative to the session's `cwd`; Arnes never
changes the process-wide directory between sessions. Resource links are references, not
automatic reads or permission grants. Configured path restrictions and hard permission
floors remain in effect after client approval. The configured OS sandbox applies to core
tools (on by default where supported); Linux needs external OS-level isolation.

Client-provided stdio MCP servers require an absolute executable and explicit startup
approval. Their results are untrusted. Provider tokens are withheld unless explicitly
supplied by the client; ACP environment values are literal, without `${VAR}` expansion.
Servers start in the session directory and use process-tree cleanup on close. Approval
authorizes external code with the user's privileges: core-tool sandboxing does not sandbox
arbitrary MCP server code.

This initial adapter loads core tools and client MCP servers, not ambient project hooks,
skills, agents, instructions or memory. It does not expose `ask_user`; questions can be
answered in subsequent prompt turns. No terminal prompt competes for protocol stdin.

Each executed turn appends the normal run record and transcript under `~/.arnes`.
Disconnect/SIGINT/SIGTERM closes sessions and jobs. Closing stdout while leaving stdin open
also wakes the input loop and drains cleanup. Concurrent shutdown callers await the same
cleanup task. stdout is protocol-only; transport
diagnostics go to stderr.

## Current limits and verification

No session loading, model/mode switching, images/audio/embedded content, editor-owned file
or terminal operations, MCP HTTP/SSE, file-diff rendering or live terminal-output streaming
is provided yet. Tool lifecycle status describes the invocation, not task-verifier success;
result excerpts are not full transcripts. Startup MCP permission questions precede model
tool calls and are separate operations. Permission requests describe the operation being
authorized. Saved transcripts remain
inspectable with regular Arnes commands, but `session/load` is not implemented.

Tests use injected mock models and temporary stores for streaming, records, permissions,
cancellation, disconnect, close, malformed input, framing, and MCP environment/cwd behavior.
Tool-progress tests exercise out-of-order same-name calls, repeated model IDs across turns,
permission correlation/denial, preflight/tool failure, and cancellation before the final reply.
The executable test client is [scripts/test-acp.py](../scripts/test-acp.py):

```bash
swift build --product arnes
python3 scripts/test-acp.py --binary .build/debug/arnes
# Socket-free subset for restricted environments:
python3 scripts/test-acp.py --binary .build/debug/arnes --transport-only
```

The full suite uses a local HTTP provider fixture, isolated state and a minimal child
environment. It exercises streamed prompts/tool progress, approval/denial and the harness
floor, cancel/restart, background process-tree cleanup, disconnect, signals, session
isolation and durable records. It keeps the normal platform sandbox policy. Mac and Linux
CI is configured to run it without paid calls. All 11 executable cases pass on Mac and
Linux arm64. Linux also passes the full Swift suite after the process-supervision fix;
Arnes uses SwiftOpenAI 4.6.1, which includes the dependency correction from PR #199, so a
clean Linux build requires no dependency checkout edits.
[VALIDATION.md](VALIDATION.md) records the exact evidence boundary. A real editor's UI
and a live provider's behavior remain separate compatibility checks.
