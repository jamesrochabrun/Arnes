# Arnes — Contributor & Agent Instructions

Single source of truth for working on this repo. `CLAUDE.md` and `AGENTS.md` are symlinks to
this file — edit only `INSTRUCTIONS.md`. Read `DESIGN.md` first for the architecture and
roadmap; this file is the *how*, that one is the *why*.

## What this is

Arnes (*arnés* = harness) is a **model-adaptive agent harness** on OpenRouter: the chosen
model drives the wire dialect, prompt pack, and request shape. Two products:
`ArnesKit` (embeddable library, UI-free) and `arnes` (CLI).

## Invariants

1. **Model knowledge comes from the manifest, never hardcode.** Capabilities, context sizes,
   and pricing flow from `ModelCatalog` (OpenRouter `GET /models`). If you need a new
   capability bit, derive it from `supported_parameters` in `ModelProfile`.
2. **Prompt tuning goes in packs, not code.** Family-specific behavior belongs in
   `PromptPack.familyDefaults` (or user overrides at `~/.arnes/packs/`), never inline in the
   agent loop.
3. **Tools stay few and schemas stay dumb.** Adding a tool needs a reason a non-frontier
   model can survive. No nested/clever schemas.
4. **Every run appends a `RunRecord`.** Any new execution path (panel, dialect-native, subtask)
   must write records — the eval loops depend on complete data. Always capture the
   **post-routing** model (`response.model` → `routedModels`), not just the requested slug.
5. **ArnesKit stays UI-free and OpenRouterSwift stays upstream.** If ArnesKit needs a typed
   field the client lacks, file/fix it in OpenRouterSwift — don't parse `extraBody`/raw JSON
   here as a workaround.
6. **Loop-3 discipline:** routing defaults may self-tune from the scoreboard; prompt-pack
   changes are proposals (diff + A/B eval) merged by a human. Never silent self-modification.

## Code style

- 2-space indent; modern concurrency only (`async/await`, actors); services injected as
  protocols (`OpenRouterService`) for mocking.
- Public models `Sendable`; `Codable` with explicit `CodingKeys` when keys aren't camelCase.

## Layout

```
Sources/ArnesKit/
  Dialect.swift            # ModelFamily → preferred wire dialect
  ModelProfile.swift       # capability manifest + fuzzy search (ModelCatalog actor, GET /models)
  PromptPack.swift         # base prompt + per-family adapters + ~/.arnes/packs overrides
  AgentTool.swift          # AgentTool protocol (+ permission/summary) + read_file / write_file / bash
  CodingTools.swift        # edit_file / grep / glob — the coding toolset
  Permission.swift         # ToolPermission, PermissionDecision, PermissionDelegate
  StreamAccumulator.swift  # chunk stream → text + merged tool calls + usage
  Session.swift            # the loop, interactive-first: history, /model swap, gating, interrupts
  Agent.swift              # headless one-shot wrapper over Session (arnes do)
  SessionStore.swift       # TranscriptEntry JSONL → ~/.arnes/sessions/<id>.jsonl
  RunRecord.swift          # eval substrate → ~/.arnes/runs.jsonl (now with sessionId/turnIndex)
  Eval.swift               # EvalTask/Suite/Runner/Stats → ~/.arnes/evals.jsonl (arnes eval)
  Panel.swift              # loop 2: --panel N — snapshot workdirs, parallel candidates, judge, winner sync
  MessagesDialect.swift    # /messages native path: chat history → Anthropic shapes + stream accumulator
  ResponsesDialect.swift   # /responses native path: chat history → OpenAI shapes + stream accumulator
  DialectVerdict.swift     # conformance verdicts → ~/.arnes/dialects.jsonl; auto pins broken natives to chat
  MCP.swift                # MCP tool provider: ~/.arnes/mcp.json → stdio JSON-RPC clients → [any AgentTool]
Sources/arnes/             # the CLI
  ArnesCommand.swift       # root: interactive (default) · chat · do · resume · models · status · runs · sessions
  McpCommand.swift         # `arnes mcp` (list servers + tools) + shared CLI MCP bootstrap
  Interactive.swift        # REPL: turns, slash commands, SIGINT→cancel, TerminalPermissions
  Header.swift             # session-start banner box (model, dialect, cwd, MCP; plain line when piped)
  Screen.swift             # pinned bottom input box + status line; transcript commits above (redraw-below, scrollback intact; passthrough when piped)
  LineReader.swift         # raw-mode line editor + history, drawn in the Screen box (readLine() fallback when piped)
  KeyWatcher.swift         # mid-turn stdin: Ctrl-O verbosity toggle, Ctrl-C cancel, live type-ahead queue; feeds permission prompts
  Renderer.swift           # AgentEvent → terminal via Screen; concise tool lines (Ctrl-O for verbose); cost/route status line per turn
  Markdown.swift           # StreamingMarkdown: delta stream → styled prose/headings/bullets + fenced code with Splash highlighting
  SlashCommand.swift       # /model /cost /verify /compact /save /resume /clear /status /help /exit
  ANSI.swift               # styling, TTY-gated
```

## Agent-facing usage

`.claude/skills/arnes/SKILL.md` teaches agents to drive the installed CLI (evals, panels,
probes, headless `do`, scoreboards) with cost-conscious defaults. **When a CLI flag,
subcommand, or output format changes, update the skill in the same commit** — it is the
contract agents rely on. Users symlink it to `~/.claude/skills/arnes` for global use.

## Working on it

- `swift test` — unit tests, no network. Agent/Session tests inject `MockOpenRouterService`
  (`Tests/ArnesKitTests/Mocks/`) with scripted chunk streams; fixtures build chunks from JSON.
- Live smoke: `OPENROUTER_API_KEY=... .build/debug/arnes chat "hi" -m anthropic/claude-haiku-4.5`,
  then `arnes do "create /tmp/x.txt containing hello" --verify openai/gpt-4o-mini`,
  then `arnes runs`.
- REPL smoke (works piped, no TTY needed):
  `printf 'say hi\n/cost\n/save demo\n/exit\n' | arnes -m anthropic/claude-haiku-4.5`,
  then `arnes --continue` to confirm resume, `/model <query>` to confirm mid-session swap.
- Adding a dialect path: implement it behind `Dialect` inside `Session`, keep `send`/`Agent.run`
  signatures stable, and record the dialect actually used in the `RunRecord`.

## Releasing

Bump `arnesVersion` in `Sources/arnes/ArnesCommand.swift`, commit, tag `v<version>`, push the
tag. The release workflow refuses tags that don't match `arnesVersion`, builds linux
x64/arm64 (static stdlib) + a universal macOS binary split into per-arch slices, attaches
everything to a GitHub release, then publishes to npm: four platform packages
(`arnes-{darwin,linux}-{arm64,x64}`, binary only, `os`/`cpu`-gated) plus the `arnes`
launcher (`npm/arnes/`, a Node shim over `optionalDependencies` — no postinstall scripts, so
Bun installs work). `scripts/npm-release.sh` generates the publishable dirs; auth is the
`NPM_TOKEN` secret, or npm trusted publishing once configured per package.

## Status

- [x] v0.1 skeleton — chat-dialect loop, 3 tools, packs, records, `--verify`, scoreboard
- [x] Routing visibility — `AgentEvent.routed`, `RunRecord.routedModels`, requested→served footer
- [x] v0.2 interactive core — `Session` actor (streaming loop, client-side history), REPL with
      permission gating (y/n/always), mid-conversation `/model` swap, `/cost` `/verify` `/save`,
      crash-safe session persistence + `--resume`/`--continue`, Ctrl-C interrupt
- [x] v0.2 coding tools — `edit_file` (unique-match replace), pure-Swift `grep`/`glob` (ungated)
- [x] Context compaction — `/compact` + auto at ~80% of `profile.contextLength`; summary rides
      the system prompt, last user turn kept verbatim, persisted as a `compaction` entry;
      status line shows live `ctx N%`
- [x] Eval framework — `arnes eval <suite>`: models × tasks × trials in isolated temp
      workdirs, bash `check` scripts as ground truth, per-model stats (pass rate, cost,
      steps, time), outcomes → ~/.arnes/evals.jsonl; starter suite in evals/basics;
      Terminal-Bench/Harbor adapter in benchmarks/terminal-bench
- [x] `arnes do --panel N` — loop 2: candidates run in parallel snapshots of the working
      directory (tools root-bound via `Session.tools(root:)`, so no CWD games), a judge
      model picks the winner from reports + diffs, the winner's changes sync back
      (`--no-apply` to keep the snapshot), and every candidate lands as a labeled
      `EvalOutcome` (suite "panel") — real work grows the eval history for free
- [x] Dialect-native execution — `Session` executes `/messages` (Anthropic) and `/responses`
      (OpenAI) natively, chosen per model family by `DialectOverride.auto` (forced with
      `--dialect` on `do`/`eval` for A/Bs). History stays chat-shaped and is translated per
      request (`MessagesDialect`/`ResponsesDialect`), so cross-dialect `/model` swaps keep
      working; `RunRecord.dialect`/`EvalOutcome.dialect` record what actually executed.
      Live A/B on evals/basics: haiku native = same pass rate, −15% cost, −14% time.
- [x] Conformance probe — optimistic: every clean native step records an ok verdict and a
      native failure *before any output* records failed + falls back to chat mid-turn
      (`.dialectFellBack` event), so the probe costs zero extra requests on the happy path.
      Verdicts live in ~/.arnes/dialects.jsonl (latest wins, failures expire after 7 days);
      `.auto` consults them, forced `--dialect` ignores them. `arnes probe <model>` checks a
      model explicitly with one echo-tool round-trip.
- [x] Eval lifecycle tooling — `arnes evals` (history bars per suite × model × dialect,
      filters), `arnes evals capture` (writer model distills a session or description into
      a validated `EvalTask` — setup must succeed, check must fail pre-work, silly timeouts
      dropped; `--split` auto-slices a session into one task per user turn with rolling
      context so follow-ups stay self-contained, writer may SKIP non-task turns),
      `arnes evals prune` (--older-than/--suite/--model/--all, atomic rewrite)
- [x] REPL polish — `arnes resume [id|id-prefix|name]` subcommand (most recent when omitted,
      ambiguous prefixes listed), and markdown-styled streaming output: headings/bullets/
      quotes/inline styles rendered as they stream, fenced code in a gutter box with
      Swift highlighted via Splash (`StreamingMarkdown`, TTY-gated — piped output stays raw)
- [x] Pinned input bar — `Screen`: the transcript flows top-to-bottom into native
      scrollback while a bordered input box (+ spinner/status line) stays redrawn at the
      bottom; mid-turn typing is visible live with an "N queued" tag instead of blind
      type-ahead; permission prompts ask via the status line. TTY-only — piped sessions
      keep the plain line-by-line output
- [ ] Cached model profiles (manifest still fetched per process)
- [ ] Panel policy triggers (e.g. auto-panel after verifier rejections); `subtask` tool (nested Session)
- [x] MCP tool provider — `~/.arnes/mcp.json` (Claude Desktop `mcpServers` shape, stdio
      transport, `ARNES_MCP_CONFIG` per-project override) bridges server tools into the
      loop as `mcp__<server>__<tool>`, schemas passed through untouched; `.mutating`
      (permission-gated) unless the server annotates `readOnlyHint`; `arnes mcp` lists
      servers + tools, `--no-mcp` on `interactive`/`do` skips connecting; panels stay
      MCP-free (candidates would share server side effects)
- [x] Distribution — tag-driven releases: GitHub release binaries (macOS arm64/x64,
      Linux x64/arm64) + npm publish, so `bun add -g arnes` / `npm i -g arnes` / `bunx arnes`
      install a prebuilt binary (see "Releasing")
- [ ] Scoreboard-driven routing defaults; gated pack proposals
