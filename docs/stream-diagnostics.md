# Private stream failure diagnostics

The opt-in `ARNES_STREAM_DIAGNOSTICS_DIR` captures the existing SDK's typed
`OpenRouterError.decodingFailure` at the session's request/stream boundary, before
the error is converted to the run record's string. It does not change retry,
fallback, truncation recovery, prompts, token limits, time limits or cost limits.
The normal CLI JSON and event streams gain no fields or log lines.

## Capture contract

Create a new directory outside the working project, owned by the current user,
with mode 0700. Supply its absolute path through the environment variable. No path
component may be a symlink; on macOS use `/private/tmp` instead of `/tmp` if needed.
An unsafe configured path is rejected before inference. The default is no sink.

The store writes `stream-failure-0.json` through `stream-failure-7.json`, exclusively,
with mode 0600. Slots are shared across sessions, subagents and processes using
that directory. Existing files are never read, replaced or pruned. The directory's
device/inode is checked again on each write; replacing it causes capture refusal.
Each artifact is limited to 32 KiB, including encoding. A full directory, a failed
write or an oversized encoded artifact never changes the provider error or recovery.
Check for artifacts after the run; absence is not proof that decoding succeeded.

Artifacts contain session ID, requested model, dialect, request/stream phase,
whether output was emitted, the decoder description, original payload length and
`payload_base64`. The payload is the SDK's normalized decoder input, **not HTTP
chunks or original SSE bytes**. `wire_framing` explicitly marks this unavailable
context. Current SDK errors do not expose event boundaries or byte-buffer offsets.
Routed models remain in the run record and streamed events.

Payloads over 16 KiB are omitted wholesale. Accepted payloads are decoded as UTF-8,
scrubbed for recognized secrets and configured static provider/header values, then
base64 encoded. Metadata is scrubbed in full before its display cap. The
`payload_changed` flag marks any redaction or UTF-8 replacement; only an unomitted,
unchanged payload is an exact replay of the SDK decoder input. Captures can still
contain private provider/user content. Keep them local and publish only synthetic
regressions. Dynamic gateway tokens are covered by pattern scrubbing, not an exact
token lookup. Diagnostic storage never grants tool access to the directory.

## Confirmed offline defect and limits

Before SwiftOpenAI 4.6.2, its Linux HTTP adapter decoded each arbitrary network
`ByteBuffer` into a string and split it separately. It could yield an incomplete JSON
line when the network split an SSE event, split a UTF-8 character, and manufacture
blank lines at chunk boundaries. The [upstream fix](https://github.com/jamesrochabrun/SwiftOpenAI/pull/200),
released in 4.6.2, retains bytes until a real line delimiter arrives and connects
consumer cancellation to the body reader. It preserves malformed
payloads for the SDK to reject and leaves connection failures as failures.

Synthetic split tests exercise every split of a JSON/UTF-8 event, one-byte chunks,
empty chunks, multiple lines, LF/CRLF/CR boundaries, partial EOF, malformed JSON,
connection failure and cancellation. HTTP chunks are not SSE event boundaries;
the [SSE parsing specification](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream)
defines line delimiters independently of network buffering.

This is a demonstrated client defect, not proof of what caused any previous
uncaptured live failure. The historical 278/358-byte payloads were not retained.
The OpenRouterSwift parser also treats individual `data:` lines as events; multiline
SSE handling remains separate work, and no parser or recovery changes are included
here. Arnes requires SwiftOpenAI 4.6.2 or newer and resolves the 4.6.2 release at
`c757e0b3b00aa775f0ce41aa3d18e343990a145a`, with no local dependency override.

## Next diagnostic

Use `scripts/test-stream-framing.py` before any model call. It requires a disposable
Linux Docker container with `--network none` and only loopback active; it refuses
to launch Arnes on a host. Mount a Linux binary and the script read-only, plus a
new evidence directory. Do not mount a real home or supply provider credentials.

```bash
mkdir -m 700 .build/stream-framing-results
docker run --rm --network none \
  --mount "type=bind,src=$PWD/scripts/test-stream-framing.py,dst=/fixture.py,readonly" \
  --mount "type=bind,src=/absolute/path/to/patched-linux-arnes,dst=/arnes,readonly" \
  --mount "type=bind,src=$PWD/.build/stream-framing-results,dst=/evidence" \
  python:3.13-slim-bookworm python3 /fixture.py \
  --binary /arnes --output /evidence/patched \
  --expect-framing fixed --expect-diagnostics
```

The binary must carry its Linux Swift runtime or the container must supply it.
Use `--expect-framing broken` and omit `--expect-diagnostics` for a frozen binary
without either patch. Each invocation uses a fresh output subdirectory. Nine cases
cover ordinary responses, JSON splits before/after output, a split UTF-8 character,
malformed JSON before/after output, diagnostics off, partial EOF and cancellation.
Every case asserts one request, zero tool calls and exactly one JSON result. The
fixed run additionally checks exact malformed-payload captures and private file modes.
These fixtures use no external model and do not measure model quality. Preserve
existing benchmark logs, prompt defaults, uncapped responses and disabled time notices.

The frozen Linux binary reproduced decoding failures in all three valid split-response
cases. The isolated build with the upstream fix completed those same responses with
exact text, including UTF-8. All nine fixed-build cases passed; malformed/partial input
still failed, captures preserved the malformed decoder input, and timeout closed the
connection. Each case made one request, executed no tools and returned one JSON result.
The upstream SDK suites also passed on macOS (101 tests) and Linux (99 tests).
The same nine cases pass with the released 4.6.2 dependency and no local override;
that Linux binary also passes all 11 ACP and seven Harbor CLI fixtures.

If a human needs a live check with the released dependency, run **one** attempt of
the previously affected development task with the default prompt and the same
model/effort: `deepseek/deepseek-v4-pro-0813`, `high`, 900 seconds, 100 steps, `$1`
between-request cost threshold, no response cap, no time notices, no retrying the
trial, `--bare --no-memory`. Use a new private capture directory, save the run's
JSON/events/transcript, and inspect any decoding artifact before scheduling more
trials. The cost threshold is not a hard spending cap, and missing final usage does
not establish lower billing. A human must launch this step; no paid trial is queued
or automatically run by the diagnostic implementation.
