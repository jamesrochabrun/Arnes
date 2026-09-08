# Agentic-quality implementation plan

The goal is reliable task completion, measured on executable checks before wider
distribution. This is an implementation ledger, not a claim of benchmark performance.

| Workstream | Acceptance criteria | State |
| --- | --- | --- |
| Reproducible Terminal-Bench | Pinned binary and checksum, explicit model/settings, complete event log, install/run failure classification, repeatable comparison instructions | Implemented; 22 offline tests; live container validation pending |
| Model-adaptive guidance | Pack-driven tool guidance on every dialect, unchanged schemas/permissions, stable per-turn prefix, two opt-in experiment packs | Implemented; focused tests pass; live A/B pending |
| Editing recovery | Actionable failed-match diagnostics; exact-match, stale-read, atomicity and checkpoint protections remain tested | Implemented; focused regressions pass |
| Context retention | Token-budgeted recent context; preserve goals, constraints, changes and verification through compaction; long-task regression coverage | Optional token budget and recent command-evidence appendix implemented; mock multi-turn compaction/resume coverage; live quality evidence pending |
| Terminal reliability | Exercise long jobs, bounded logs, cancellation and installation failures; document container isolation | Mac and Linux arm64 full suites and subprocess checks pass; Linux uses direct-child process supervision; installer validation pending |
| Executable diagnostics | Structured, bounded test/typecheck/lint feedback using the existing subprocess and permission paths | Opt-in foreground bash extraction implemented; no extra execution or task verdict; live A/B pending |
| ACP | Thin stdio protocol adapter over Session, initialization, sessions, streaming, cancellation, permission responses and run records; executable tests with isolated stores | All 11 executable transport/HTTP tests pass on Mac and Linux arm64 with the correction released in SwiftOpenAI 4.6.1; live editor validation pending |
| Specialized delegation | Opt-in bounded role guidance and behavioral probes; no forced delegation or expanded permissions | Explicit eval role sets and investigator/verifier proposal implemented; correctness probes and scope tests; live A/B pending |

Prompt and tool-interface changes remain experiments until paired evaluations justify
adopting them. A patch editing interface, PTY, LSP and a native Linux sandbox remain
failure-analysis follow-ups: assess the evidence and safety requirements before
implementation, and do not count them as completed. Container-based benchmarking does
not require a native Linux sandbox.

Live model evaluations are a human-run step under this repository's standing rules.
Offline tests verify contracts and failure recovery, not model-quality improvements.
The [validation audit](docs/VALIDATION.md) maps each requirement to direct evidence and
describes the automated platform checks separately from human-run compatibility and
quality evaluations. Required Mac and Linux arm64 build, full-suite and executable HTTP gates pass with
the correction released in SwiftOpenAI 4.6.1; release artifacts and live quality checks remain separate. Experimental options stay opt-in pending measured benefit.

## Verification so far

- Release adoption (2026-09-07): SwiftOpenAI 4.6.1 is the merged correction from PR #199;
  its source tree is identical to the validated PR commit. Arnes now resolves the release
  without a local override. The Mac suite passes **1,891 tests, one expected skip, zero
  failures**, plus **11/11 ACP** and **22/22 benchmark tests**. The earlier Linux arm64
  receipt remains valid for the identical dependency source; hosted CI runs the same
  automated checks for the release-based worktree. See [the audit](docs/VALIDATION.md).

- Blocker resolution (2026-09-07): SwiftOpenAI [PR #199](https://github.com/jamesrochabrun/SwiftOpenAI/pull/199)
  declares the existing Linux NIO imports and checks clean locked/latest dependency builds.
  That run pinned its immutable commit and used the sibling checkout in local editable mode,
  superseded by the release adoption above.
  LinuxProcess/CArnesProcess supervises each direct child using POSIX APIs while retaining
  the runner's permission, environment, timeout, cancellation and output guarantees.
  All three former timing failures pass, along with eight additional Linux regressions.
  Mac: **1,891 tests, one expected skip, zero failures**. Linux arm64: **1,899 tests,
  ten expected platform skips, zero failures**. Both actual executables pass **11/11 ACP**
  cases and both platforms pass **22/22 benchmark tests**. Exact final runs and provenance
  are in [the audit](docs/VALIDATION.md). Historical entries below retain prior blockers.

- Initial platform continuation (2026-09-07, before the blocker resolution above): Mac full suite **1,891 tests, one expected skip,
  zero failures**; actual executable ACP **11/11**; offline benchmark adapter **22/22**.
  All formerly failing Mac sandbox tests pass. Explicit sandbox-exec nesting remains
  unsupported but does not block the repository's Mac checks. Linux arm64 was exercised in
  an isolated VM/container. Swift 6.0 cannot load the lockfile's manifests, so CI and the
  matching release configuration now use 6.2. SwiftOpenAI's undeclared NIO dependency still
  prevents an unpatched Linux build. With a temporary upstream manifest patch, executable
  ACP passes 11/11 and benchmark tests pass 22/22. The last complete diagnostic Swift run
  executed 1,891 tests with 10 platform skips and six failed assertions; a subsequent
  deterministic output-fixture correction addresses one, while five Foundation timing
  assertions across three tests remain blocked. The independent Foundation reproduction,
  final focused checks and artifact paths are recorded in [the audit](docs/VALIDATION.md).
  Linux EOF, HTTP redirect and bounded-output failures were fixed with regressions;
  permissions and sandbox behavior were not relaxed. Historical entries below retain
  their original counts and host restrictions.

- Review of the existing worktree (2026-09-06): full suite expanded to 1,885 tests; two
  skips and the same 14 assertions in six sandbox tests fail because this host cannot apply
  the OS sandbox. The review fixed model/prefix mutation during active turns, stale plan-mode
  approvals, post-observer cancellation, queued specialist cancellation/budgets, MCP cleanup
  races and ACP output/shutdown blocking. Actual request-builder tests cover all dialects.
  Four executable transport tests and all 22 benchmark tests pass. The HTTP executable
  fixture cannot bind loopback here; Mac/Linux CI wiring is present but unrun. See the
  validation audit for commands and limits. Earlier entries below retain their original counts.

- 80 focused Swift tests pass across guidance, prefix stability, editing, compaction,
  token retention, delegation packs and context reports.
- 22 Python benchmark configuration/orchestration tests pass without Harbor installed;
  experiment controls match provenance and isolated runtime configuration. Source audit
  against Harbor v0.16.1 covers the adapter API and CLI syntax. Tests also cover per-agent
  environment precedence, credential-free shell text, default-null metadata, cached-token
  accounting, signal exits, bounded pack loading and environment failures. An isolated
  Harbor installation attempt was blocked by network/DNS access; real integration remains
  unverified.
- 17 new Swift diagnostics/context tests pass, including eval/panel propagation,
  denied execution, pre-truncation secret scrubbing and multi-turn compaction/resume.
- 162 focused specialist/delegation/terminal-recovery tests pass. They include actual eval
  snapshot spawning, live remaining-budget inheritance, parent-tree preservation, timeout
  recovery without automatic retries, large-log tails, cancelled waits and registry restart.
  The new quality checks reject untouched code, smoke-only repairs and fixture tampering;
  they accept complete repairs without requiring delegation. CLI help confirms `eval --agents`;
  file-input tests reject links, FIFOs, oversized files and invalid UTF-8.
- ACP/MCP protocol, CLI and background-job coverage: 68 focused tests pass, plus an executable stdio
  initialization handshake without provider credentials or a model request. ACP allocates
  the session ID before the first prompt materializes providers/MCP, so startup permissions
  refer to a session the client already knows.
- Correlated ACP tool progress: all 20 ACP tests pass, including five added lifecycle/error
  regressions and stronger permission/cancellation assertions. A preceding 60-test focused
  run also covers unchanged headless/event output, parallel tools and prompt-prefix stability.
  Tool updates use an optional awaited Session observer, not new legacy AgentEvent cases;
  IDs and preview text never enter model prompts or grant permissions.
- Full Swift run after ACP tool-progress integration: 1,871 tests, two skipped,
  14 assertion failures across six existing
  OS-sandbox integration tests. This environment refuses `sandbox-exec` itself with
  `sandbox_apply: Operation not permitted` (also reproduced with a trivial command).
  These integration tests still need a host run with OS-sandbox support.
- No live model evaluation, container benchmark, installation, commit or push performed.
