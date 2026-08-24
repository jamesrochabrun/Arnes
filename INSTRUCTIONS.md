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
  Dialect.swift        # ModelFamily → preferred wire dialect
  ModelProfile.swift   # capability manifest (ModelCatalog actor caches GET /models)
  PromptPack.swift     # base prompt + per-family adapters + ~/.arnes/packs overrides
  AgentTool.swift      # AgentTool protocol + read_file / write_file / bash
  Agent.swift          # the loop: chat → tools → repeat; loop-1 verifier; cost tracking
  RunRecord.swift      # eval substrate → ~/.arnes/runs.jsonl
Sources/arnes/main.swift  # chat · do · models · status · runs (ArgumentParser)
```

## Working on it

- `swift test` — unit tests (no network; agent-loop tests should inject a mock
  `OpenRouterService` — see OpenRouterSwift's `MockHTTPClient` pattern).
- Live smoke: `OPENROUTER_API_KEY=... .build/debug/arnes chat "hi" -m anthropic/claude-haiku-4.5`,
  then `arnes do "create /tmp/x.txt containing hello" --verify openai/gpt-4o-mini`,
  then `arnes runs`.
- Adding a dialect path: implement it behind `Dialect`, keep the `Agent.run` signature stable,
  and record the dialect actually used in the `RunRecord`.

## Status

- [x] v0.1 skeleton — chat-dialect loop, 3 tools, packs, records, `--verify`, scoreboard
- [x] Routing visibility — `AgentEvent.routed`, `RunRecord.routedModels`, requested→served footer
- [ ] Dialect-native execution (`/messages`, `/responses`)
- [ ] Conformance probe + cached model profiles
- [ ] `--panel N` (worktree isolation, judge, labeled eval rows)
- [ ] Scoreboard-driven routing defaults; gated pack proposals
