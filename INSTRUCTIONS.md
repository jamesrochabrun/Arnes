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
Sources/arnes/             # the CLI
  ArnesCommand.swift       # root: interactive (default) · chat · do · models · status · runs · sessions
  Interactive.swift        # REPL: turns, slash commands, SIGINT→cancel, TerminalPermissions
  LineReader.swift         # raw-mode line editor + history (readLine() fallback when piped)
  Renderer.swift           # AgentEvent → terminal; cost/route status line per turn
  SlashCommand.swift       # /model /cost /verify /save /clear /status /help /exit
  ANSI.swift               # styling, TTY-gated
```

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
- [ ] Dialect-native execution (`/messages`, `/responses`)
- [ ] Conformance probe + cached model profiles
- [ ] `--panel N` (worktree isolation, judge, labeled eval rows); `subtask` tool (nested Session)
- [ ] MCP tool provider (`~/.arnes/mcp.json`)
- [ ] Scoreboard-driven routing defaults; gated pack proposals
