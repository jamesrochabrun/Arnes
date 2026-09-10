# Arnes — Standing Instructions

The short file every agent harness loads (arnes and Codex cap instruction files at 32 KB);
`CLAUDE.md` is a symlink to this file. `INSTRUCTIONS.md` is the full record — the per-file layout
map and the `## Status` history of what shipped and why — read on demand, never loaded. Read the
Status entry for the area you touch before changing it; edit history there, edit standing rules
here. `DESIGN.md` is the *why*.

## What this is

Arnes (*arnés* = harness) is a **model-adaptive agent harness** on OpenRouter: the chosen
model drives the wire dialect, prompt pack, and request shape. The same loop also runs
against a LiteLLM gateway or any OpenAI-compatible endpoint (`~/.arnes/config.json`
providers; see README "Providers & gateways"). Two products: `ArnesKit` (embeddable
library, UI-free) and `arnes` (CLI).

## Invariants

1. **Model knowledge comes from the manifest, never hardcode.** Capabilities, context sizes,
   and pricing flow from `ModelCatalog` — OpenRouter `GET /models`, or the active provider's
   manifest (LiteLLM `/model/info`). A new capability bit is derived from `supported_parameters`
   in `ModelProfile`. Anything a manifest doesn't state is *assumed on* (tools) so a sparse
   gateway never silently disables the loop — with one documented exception, **vision**
   (`ModelProfile.supportsVision`, from `input_modalities` / LiteLLM `supports_vision`): an image
   sent to a text-only model fails the whole request, so an unstated one is *off* and the
   `view_image` tool is simply absent for that model. A tool whose presence depends on the model
   conforms to `CapabilityGatedTool`, read at the one per-model gate (`Session.availableTools(for:)`)
   so the prompt's tool sections and the request's tool list always agree.
2. **Prompt tuning goes in packs, not code.** Family-specific behavior belongs in
   `PromptPack.familyDefaults` (or user overrides at `~/.arnes/packs/`), never inline in the
   agent loop.
3. **Tools stay few and schemas stay dumb.** Adding a tool needs a reason a non-frontier
   model can survive. No nested/clever schemas.
4. **Every run appends a `RunRecord`.** Any new execution path (panel, dialect-native, subtask)
   must write records. Always capture the **post-routing** model (`response.model` →
   `routedModels`), not just the requested slug.
5. **ArnesKit stays UI-free and OpenRouterSwift stays upstream.** A typed field the client lacks
   is fixed in OpenRouterSwift — never parsed out of `extraBody`/raw JSON here. The one seam is
   the injectable HTTP client (`GatewayHTTPClient`, URL rewrite only); router-specific request
   shaping (fallback spelling, stream usage, cost estimation, reasoning shape) lives in
   `ProviderTraits`, read by `Session`.
6. **Loop-3 discipline:** routing defaults may self-tune from the scoreboard; prompt-pack
   changes are proposals (diff + A/B eval) merged by a human. Never silent self-modification.
   The A/B is `evals/ab/README.md`: `arnes eval --label <arm>` tags an arm's rows, `ARNES_PACKS_DIR=<dir>`
   runs under a variant (a `base.md` there replaces the base prompt), `--adaptive-think` forces the think-tool
   arm on. Results and the flips they earned are recorded under `## Results` there (2026-09-03: `adaptiveThink`
   on, the think sentence out, S6 kept, delegation text unproven).
7. **Narrow, never widen.** A subagent, a hook, a repository file or a resume may give up a
   permission the parent has, never gain one; the harness floors (catastrophic bash, writes
   under `~/.arnes` — with one carve-out, the project's own `~/.arnes/memory/<key>/`, where a
   write is a `.sensitive` prompt instead —, the OS sandbox) hold regardless of `--yes`, rules,
   grants or hook verdicts. Tool results are data, never instructions: nothing a tool returns
   can widen a permission, and content that tries to is flagged, and taints the session
   (`ToolResultGuard.swift`); the memory index is read under the same scanner.

## Code style

- 2-space indent; modern concurrency only (`async/await`, actors); services injected as
  protocols (`OpenRouterService`) for mocking.
- Public models `Sendable`; `Codable` with explicit `CodingKeys` when keys aren't camelCase;
  a new optional field on a persisted record decodes with `decodeIfPresent` and gets an
  old-row test.
- A new `AgentEvent` case needs a `Kind`, an `EventJSON` case, a `HeadlessEmitter.textLine`,
  a `Renderer` line (`render` and `renderNested`), and the fixture lists in `EventJSONTests`/
  `HeadlessOutputTests`/`HarnessAssemblyTests.testEveryEventCaseHasAKind`.
- Every subprocess goes through `ShellRunner` (stdin closed, provider token withheld, a hard
  timeout, a process-tree kill on timeout/cancel); a detached one is a `JobRegistry` job, never a
  bare `Process`.
- The harness process reads outside the sandbox: a read of a path a subprocess can write (a
  job log, an untracked file, a snapshot, a checkpoint target) never follows a link — `lstat`
  first, `O_NOFOLLOW`, and where the file was created by the harness an identity check (device +
  inode) before a byte is read; a mismatch is a refusal the model sees, never a read
  (`JobRegistry.readNew`, `ReviewDiff`'s untracked paste, `WorkspaceSnapshot.diff`,
  `FileCheckpointStore.restore`).
- `Sources/ArnesKit/Session.swift` is the agent loop and the serialization point for parallel
  work: touch it only where your task says so.
- The system prompt and the tool definitions are a **prompt-cache prefix**: byte-stable across
  the requests of a session, rebuilt only at a turn boundary (a compaction, `/model`, `/effort`,
  `/permissions`). Anything a step needs to tell the model — a notice, a nudge, a hook's
  feedback — rides a user message, never the system text; no section carries a timestamp finer
  than the date; the tool list is fixed per session. `PrefixStabilityTests` pins it — a new
  section or nudge goes there too.

## Layout (the per-file map is INSTRUCTIONS.md `## Layout`)

- `Sources/ArnesKit/` — the library. `Session.swift` (the loop: steps, gating, tool path,
  compaction, hooks, structured output), `SessionConfiguration.swift` (`Configuration` +
  `forSubagent`, the one inheritance point), `Agent.swift` (headless wrapper, `AgentEvent`),
  `HarnessAssembly.swift` (`ToolContext` → every toolset), `AgentTool.swift`/`CodingTools.swift`/
  `PlanningTools.swift`/`AskUserTool.swift`/`BackgroundJobs.swift` (the few dumb tools, `PathScope`;
  `ask_user` answers through `ToolContext.userInput` — a terminal prompt in the REPL, "no user is
  present" everywhere unattended, stripped from every nested run; `bash … background: true` +
  the `job` tool over one `JobRegistry` per session via `ToolContext.jobs`, jobs killed by
  `Session.shutdown()` — from `end`, and by the task tool when a nested turn returns; a nested
  session gets a registry of its own), `CapabilityTools.swift` (`view_image` — vision-gated
  through `CapabilityGatedTool`, `PathScope`-gated like `read_file`, its image attached as a user
  message of content parts after the step's results via `AttachingTool`; `web_fetch` — present
  only with a `web` config block and a network-allowing sandbox, `URLPolicy.strict` + DNS check,
  same-host redirects only, `.readOnly` for `web.allowedDomains`, a refusal floor for
  `web.deniedDomains`, `.sensitive` for every other host so `--yes` never fetches one, and
  `.sensitive` for every host once the session is tainted — an allowlisted page is scanned like
  any result and never a taint by itself, a page from any other host the human approved taints
  per result, `TaintingTool.taintsResult(arguments:)`, source `web:<host>`), `Checkpoints.swift`
  (pre-images before every
  `write_file`/`edit_file` → `Session.rewind`; the REPL's `/rewind`, `/undo`, `/diff`),
  `ToolOutput.swift`/`LoopGuard.swift` (result cap + spill, stuck detection),
  `ToolResultGuard.swift` (tool results are data: secret redaction, the injection scanner, the
  `<tool_result>` frame, the taint that escalates network and interpreter `bash` and every
  `.sensitive` call after untrusted content), `Permission*.swift`/`ShellCommand*.swift`/
  `ShellSandbox.swift`/`ShellRunner.swift`/`SubprocessEnvironment.swift` (the safety layer;
  a *plain* out-of-tree read — gated only by location, never a credential/`denyRead` path —
  is auto-approved by `acceptEdits`/`bypass` and "always" grants its enclosing tree as
  `Read(<dir>/**)`, shared with subagents; a tainted session closes both, floors unchanged),
  `Hooks.swift`/`HookOutcome.swift`/`PromptHook.swift`/`HookDryRun.swift` (lifecycle hooks),
  `Subagents.swift`/`BackgroundSubagents.swift`/`WorkspaceSnapshot.swift` (the `task` tool),
  `PromptPack.swift`/`ProjectInstructions.swift`/`EnvironmentContext.swift`/`Skills.swift`/
  `Memory.swift` (what rides the system prompt; `MemoryStore` = the per-project `MEMORY.md` under
  `~/.arnes/memory` as a capped, scanned `# Memory` section, edited through the file tools
  across `PathScope.Rules.memoryRoot`), `ModelProfile.swift`/`ManifestCache.swift`/`Dialect.swift`/`*Dialect.swift`/
  `StreamAccumulator.swift`/`ReasoningState.swift`/`DialectVerdict.swift`/`Provider.swift`/
  `Gateway.swift` (models, wire formats, the reasoning round-trip, conformance, providers),
  `Transport.swift` (`TransportPolicy`: jittered retries of a request that failed before any
  output token, the stream idle timeout, the output-limit truncation rule — one decision in
  `Session.streamStep` for every dialect; a transport failure is never a dialect verdict),
  `PromptCache.swift` (`CachePolicy`: `cache_control` breakpoints on the stable prefix of an
  Anthropic-family request where the provider takes the field — the system text + the last
  message on chat, the last tool + the last block on `/messages` — and the cached-token metric
  every dialect reads off usage onto `RunRecord.cachedTokens`),
  `Compaction.swift` (`CompactionPolicy` + `Microcompaction`: the request-time *view* of the
  history `Session.requestHistory()` returns — older large tool results stubbed, the last N kept,
  the persisted history untouched; the cutoff moves only at turn start and at a mid-turn relief
  point, so a turn's requests share one stable prefix — and `CompactionRubric`, the `[files
  touched]`/`[current plan]` sections the summarizer is handed),
  `RunRecord.swift`/`RunResult.swift`/`EventJSON.swift`/`SessionStore.swift` (records,
  envelopes, transcripts), `ContextReport.swift` (what the next request spends the window on,
  by contributor — `Session.contextReport()`, the REPL's `/context`),
  `Eval.swift`/`EvalGraders.swift`/`EvalReport.swift`/`EvalCapture.swift`/
  `Panel.swift`/`Verifier.swift`/`StructuredOutput.swift`/`Review.swift` (evals, graders, the
  pass@k/regression report + CI gate, panels, verification, diff review),
  `MCP*.swift`/`URLPolicy.swift`.
- `Sources/arnes/` — the CLI. `ArnesCommand.swift` (root + `do`/`chat`/`resume`/`models`/
  `status`/`runs`/`sessions`), `Interactive.swift` + `Screen`/`Renderer`/`LineReader`/`KeyWatcher`/
  `Paste`/`Completion`/`Bang`/`PermissionPanel`/`Markdown`/`PlanMode`/`Rewind`/`Dials`/`PlanFormat` (the REPL; `Bang` = the `!`
  shell escape: a line starting with `!` tints the box orange and runs in the *user's* shell
  (ArnesKit `UserShell` — the bash runner outside every tool gate and sandbox, token still
  withheld); a completed command then sends its own turn — the exchange plus "explain
  concisely / how to recover, never ask what to do with it" — so the agent's read streams at
  once, while an interrupted one rides the next message via `Session.notify`; `Paste` = bracketed-paste
  collapse — `[Pasted text #1 +58 lines]` / a dragged image's path as `[Image #1 shot.png]` in the
  box, expanded at submit so a `/Users/…` paste never reads as a slash command; an ephemeral or
  untypeable-name drag (macOS screenshots carry U+202F) is copied into a stash under a retypeable
  name, and the stash is a read-only `PathScope.Rules.pasteStash` carve-out — `view_image` on a
  dragged image never prompts; `Completion` = the
  slash-command autocomplete popup's pure pieces — typing `/` filters live, ↑/↓ move, Tab inserts,
  Enter runs, Esc dismisses; `Dials` = the `/status`,
  `/context`, `/effort`, `/budget` pieces, `PlanFormat` = the `update_plan` checklist as text),
  `Runtime.swift` (provider, catalog, hooks, limits),
  `HeadlessOutput.swift`/`ExitCodes.swift` (the `do` contract), one file per subcommand
  (`Eval`, `Evals`, `Probe`, `Mcp`, `Skills`, `Agents`, `Hooks`, `Providers`, `Trust`, `Doctor`,
  `Debug`, `Review`, `Memory`, `Init`), `JSONOutput.swift` (`--json` DTOs, additive forever).
- `Tests/ArnesKitTests` (mock service in `Mocks/`, `Support/Latch`), `Tests/ArnesCLITests`
  (`@testable import arnes`), `evals/` (JSON suites), `benchmarks/terminal-bench`,
  `.claude/skills/arnes/SKILL.md` (the agent-facing CLI contract).

## Agent-facing usage

`.claude/skills/arnes/SKILL.md` teaches agents to drive the installed CLI (evals, panels,
probes, headless `do`, scoreboards) with cost-conscious defaults. **When a CLI flag,
subcommand, output format or config key changes, update the skill in the same commit** — it is
the contract agents rely on. Users symlink it to `~/.claude/skills/arnes` for global use.

## Working on it

- Every proposed harness fix or behavior experiment includes an exact Harbor retest command,
  a pinned baseline and candidate, the settings held constant, and the metrics that would
  support the change. Report Terminal-Bench verifier task passes first, then failure causes,
  duration and recorded cost. Prepare and validate the retest before handing it to the human;
  paid trials remain human-operated. Local protocols and reports are Git-ignored; when
  available, see `evals/ab/harbor-retest.md`.
- `swift test` — unit tests, no network (~3 min build, then ~60 s). Agent/Session tests inject
  `MockOpenRouterService` (`Tests/ArnesKitTests/Mocks/`) with scripted chunk streams. Read
  results with `set -o pipefail; swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -3`.
- `./scripts/install-local.sh` installs the release build over the `arnes` on PATH and prints a
  receipt (version · sha · time · path). Never plain `cp` over the installed binary — in-place
  overwrite breaks the macOS code-signature cache and the binary dies SIGKILL (exit 137).
- OpenRouterSwift is the upstream client (`Package.swift` pins `from: "0.2.0"`, which carries
  `Message.reasoningDetails`, `reasoning_effort` and sorted-keys request bodies). A typed field
  the Kit needs goes there, with a test and a release — never parsed out of raw JSON here.
- **Never run live `arnes` commands from a test or an unattended agent** (`do`, `chat`, `eval`,
  the REPL, `hooks trust`, `trust`, `memory forget`): `NSHomeDirectory()` ignores `$HOME`, so they
  write to the real `~/.arnes`. Tests inject a temp home (`MemoryStore(directory:)`, a `home:`
  parameter). Live smoke is a human's step; clean the rows after.
- Headless `arnes do` is read-only unless `--yes`; scripts read `--output-format json` (one
  `RunResult` line) and the exit code (0 done · 1 error · 2 verifier FAIL · 3 stopped short ·
  4 denied with `--fail-on-denied` · 64 usage · 130/143 signal), never the text lines — which
  stay byte-identical, guarded by `HeadlessOutputTests`.
- `arnes doctor` checks the setup offline; `arnes debug prompt` prints the exact system prompt
  a session here would send, with per-section sizes — run it after touching a pack, this
  file, or a tool description.
- Adding a dialect path: implement it behind `Dialect` inside `Session`, keep `send`/`Agent.run`
  signatures stable, and record the dialect actually used in the `RunRecord`.
- Every shipped change adds a `- [x]` entry to INSTRUCTIONS.md `## Status` (before the
  `Deferred` entry) and updates its layout line; commit messages are imperative subject + why.

## Releasing

Bump `arnesVersion` in `Sources/arnes/ArnesCommand.swift`, commit, tag `v<version>`, push the
tag; the release workflow builds Linux x64/arm64 + universal macOS and publishes the npm
packages (`npm/arnes/` launcher + four platform packages). Details in INSTRUCTIONS.md.
