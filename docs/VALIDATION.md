# Agentic-quality validation audit

Updated 2026-09-07; continues the 2026-09-06 audit. The objective is reliable agentic work before distribution.
This records implementation evidence and missing validation; it is not a benchmark score
or approval to promote experimental defaults. See [the implementation ledger](../ENHANCEMENTS.md).

## Requirement-by-requirement evidence

| Requirement | Current implementation and direct checks | Still unproven |
| --- | --- | --- |
| Reproducible Terminal-Bench | [Adapter and contract tests](../benchmarks/terminal-bench/): pinned executable digest, explicit model/effort, isolated config, pack fingerprint, event/transcript capture, failure classification and accounting; 22 offline Python tests pass | Actual Harbor installation, container execution, evidence retrieval and task-verifier integration |
| Model-adaptive prompts and tool descriptions | [ToolGuidanceTests](../Tests/ArnesKitTests/ToolGuidanceTests.swift) exercises actual Chat, Messages and Responses requests, forced Chat, model/family switching, capability gating, unchanged schemas and stable per-turn overrides. [PrefixStabilityTests](../Tests/ArnesKitTests/PrefixStabilityTests.swift) covers deferred effort/system-section changes and rejected active-turn model swaps | Real provider acceptance and independently measured benefit for each opt-in family proposal |
| Editing recovery | [EditRecoveryTests](../Tests/ArnesKitTests/EditRecoveryTests.swift) runs failed exact edit → reread → successful exact edit through Session over a real CRLF file, with error accounting and proof the failed edit wrote nothing. Location hints do not expose extra contents. Existing stale-read/checkpoint tests remain in the full suite | Whether the guidance reduces retries on development and held-out tasks |
| Long-task context | [TokenRetentionTests](../Tests/ArnesKitTests/TokenRetentionTests.swift) and [CommandEvidenceTests](../Tests/ArnesKitTests/CommandEvidenceTests.swift): optional estimated-token retention, bounded paired command evidence, clearing without deleting stored history, compaction and resume | Whether a real summarizer preserves objectives, constraints, edits and verification evidence; the integration test deliberately scripts its summary |
| Terminal reliability | [TerminalRecoveryTests](../Tests/ArnesKitTests/TerminalRecoveryTests.swift): real timeout/recovery, large failure tails, cancelled waits and registry restart. ACP tests cover concurrent MCP stop/restart with stubborn descendants; specialist tests combine cancellation, snapshots and background jobs while preserving a parent's live registry | Mac and Linux arm64 subprocess checks pass; installer behavior is untested. Mac sandbox enforcement passes |
| Executable diagnostics | [CommandDiagnosticsTests](../Tests/ArnesKitTests/CommandDiagnosticsTests.swift): bounded extraction from observed foreground bash output, no extra execution, denial/taint/redaction coverage, eval/panel propagation and inherited configuration | Completion/cost effect on real tasks; parsed command status is not a task verdict |
| ACP | [ACPTests](../Tests/ArnesKitTests/ACPTests.swift): protocol progress, approval/denial, cancellation before file execution, bounded pipe backpressure, joined shutdown and durable records. [Executable client](../scripts/test-acp.py): all 11 transport/HTTP cases pass on Mac and Linux arm64 | SwiftOpenAI 4.6.1 is resolved without an override. Real editor UI and provider compatibility remain separate checks |
| Bounded specialists | [SpecialistProposalTests](../Tests/ArnesKitTests/SpecialistProposalTests.swift): constrained tools/permissions, snapshot cancellation and job cleanup, remaining-budget checks at spawn and after queuing, parent-tree preservation. [ParallelTasksTests](../Tests/ArnesKitTests/ParallelTasksTests.swift) verifies cancelled waiters do not hold or steal slots. Existing nested budget/permission tests remain in the full suite | Whether delegation improves independent correctness after child cost and duplicate work. Budgets check observed usage; concurrent in-flight work can overshoot, with no reservation ledger |

All optional guidance/diagnostics/context/role treatments remain opt-in. A patch-editing
interface, PTY, LSP and native Linux sandbox are not implemented by this work. They remain
conditional follow-ups requiring failure evidence and a safety design; container isolation
is required for the current Linux benchmark adapter.

## Platform validation on 2026-09-07

The original uncommitted Arnes worktree was preserved. Validation used mock models, loopback
HTTP fixtures and temporary stores. No paid model calls, personal Arnes store writes or
installation over the existing executable were performed. SwiftOpenAI PR #199 supplies the
upstream correction and is now merged and released as 4.6.1. OpenRouterSwift required no changes.

### Released dependency: SwiftOpenAI 4.6.1

[SwiftOpenAI 4.6.1](https://github.com/jamesrochabrun/SwiftOpenAI/releases/tag/4.6.1) points to
merge commit `03360ef74e2eb093de6fdb38240a63c371390782`. Its complete source tree is identical
to `bbdef8a04e68ff1cf7246fc4b76fa921b79d2e08`, which passed the clean Linux validation below.
Arnes's manifest now requires 4.6.1 or newer, and `Package.resolved` selects that release.
The local editable override was removed, and only the SwiftOpenAI entry changed in the lock.

Release-checkout validation on this Mac: actual executable build passes; **1,891 Swift
tests, one expected skip, zero failures** (130.220 seconds); **11/11 executable ACP cases**
(4.650 seconds); **22/22 offline benchmark tests** (0.026 seconds). The earlier Linux arm64
run tested the identical dependency source, not a different implementation. The hosted CI
workflow also runs clean Linux x86_64 checks, universal/static builds and packaging checks;
results are attached to the main commit rather than inferred from this Mac run.

Release evidence lives in `.build/validation/release-4.6.1/` (ignored): `resolve.log`,
`build.log`, `swift-test.log`, `acp.log`, `benchmark.log` and `provenance.json`.
The released lockfile SHA-256 is
`e0dbbde78276e6470dfe1a0f60a65f06892b3479e9317999aa716ae7c0c79632`.

### Prior continuation: both Linux blockers resolved

[SwiftOpenAI PR #199](https://github.com/jamesrochabrun/SwiftOpenAI/pull/199) declares the
Linux adapter's existing SwiftNIO imports in its manifest. It keeps the existing minimum
Swift tools version and adds clean Linux CI for locked and freshly resolved dependencies.
Current-formatter corrections in three files let the full lint job pass. Local upstream
validation passed 94 tests on Mac and 92 on Linux, both Swift 6.0.1 with its checked-in
lockfile and Swift 6.2.4 with freshly resolved dependencies.

That continuation pinned the PR's immutable commit
`bbdef8a04e68ff1cf7246fc4b76fa921b79d2e08`. Its Mac checkout used SwiftPM editable mode pointing
at `../SwiftOpenAI`; both were superseded by the release adoption above. Its final Linux gate used the remote commit
in a clean source copy, with no editable override or modified dependency checkout. This
also checks OpenRouterSwift's transitive dependency against the same SwiftOpenAI version.

`LinuxProcess` and the small `CArnesProcess` C target replace Foundation process
supervision inside `ShellRunner` on Linux. They use `posix_spawn` and nonblocking `waitpid`
for the direct child, independently of inherited pipe EOF. A shared dispatch queue handles
exit notifications without blocking Swift's cooperative executor or installing a process-wide
SIGCHLD handler. Reaping and root signaling share a lock, preventing a recycled child PID
from being signaled. Child setup closes every descriptor above stderr, sets cwd without
changing the parent's cwd, resets inherited signal masks/dispositions, and retains the
existing environment filter, output cap, timeout/cancellation and process-tree kill logic.
Requested unsupported sandboxes still fail closed. Linux requires glibc 2.34+ for child-side
`closefrom` spawn actions; the validated Ubuntu 22.04 image supplies glibc 2.35.

The three original timing regressions pass. Eight Linux-specific regressions additionally
cover blocking completion with a surviving child, exact child reaping, concurrent exit
statuses/output, concurrent cwd isolation, failed launches, invalid C-string inputs,
descriptor isolation and child signal defaults. The Mac implementation continues to use
Foundation. No native Linux sandbox was added and no failed check was disabled.

Completed continuation runs: **1,891 Mac tests, one expected skip, zero failures**;
**1,899 Linux arm64 tests, ten expected platform skips, zero failures**. Both actual
executables pass **11/11 ACP transport/HTTP/subprocess cases**, and both platforms pass
**22/22 offline benchmark tests**. Final runs against `bbdef8a04e68ff1cf7246fc4b76fa921b79d2e08`:

| Gate | Exact final result |
| --- | --- |
| Mac Swift suite | 1,891 tests, one expected skip, zero failures; 129.870 seconds |
| Mac executable ACP | 11/11; 4.548 seconds |
| Linux arm64 clean build and Swift suite | Build passes; 1,899 tests, ten expected platform skips, zero failures; 133.772 seconds |
| Linux arm64 executable ACP | 11/11; 4.122 seconds |
| Offline benchmark adapter | 22/22 on each platform |
| C process shim | Compiles with `-std=c11 -Wall -Wextra -Werror` on Linux |
| SwiftOpenAI hosted CI | All four checks pass: Mac (94 tests), Linux x86_64 locked/latest (92 tests each), and full lint |

The [upstream CI run](https://github.com/jamesrochabrun/SwiftOpenAI/actions/runs/34188938399)
is green at the exact tested commit; PR #199 subsequently merged and shipped in 4.6.1. The source files for
the Linux process backend and its regressions match the validated container byte for byte.
The remote lockfile SHA-256 is
`91169841c070303671f304983c89840facd5fd99a4d5c0edc1bedd8ac32cdcfa`.
Final logs and digests are retained under `.build/validation/continuation/` (ignored):
`arnes-macos-final-suite.log`, `arnes-macos-final-build.log`, `arnes-macos-final-acp.log`,
`arnes-macos-benchmark.log`, `arnes-linux-final-gates.log`, `linux-final-provenance.log`,
`linux-source-sha256.txt`, `swiftopenai-pr-checks.json`, `swiftopenai-ci-*.log`, and
`provenance.json`. Earlier continuation logs include the local editable dependency checks.
The final Linux run used a fresh source copy and `swift package clean`; its SwiftOpenAI
checkout is clean at the pinned revision, with no `Packages/` editable directory. The
continuation VM, containers and temporary runtime were removed after collecting evidence;
`cleanup.log` records the shutdown and empty instance list. No validation runtime remains running.

Local development override (requires the sibling SwiftOpenAI checkout):

```bash
swift package resolve
swift package edit swiftopenai --path ../SwiftOpenAI
```

To return to the reproducible remote revision, use `swift package unedit swiftopenai` followed
by `swift package resolve`. SwiftPM can remove the remote pin from `Package.resolved` while
editable mode is active; keep the resolved remote lockfile for CI. `Packages/` is ignored.
The temporary revision requirement was replaced by 4.6.1 once that release became available.

### Earlier Mac validation: applicable automated checks pass

Host: macOS 26.4 arm64, Apple Swift 6.3 (`swiftlang-6.3.0.123.5`). The initial unchanged
worktree ran **1,885 tests, one skip, zero failures**. After six new regressions and the
portability fixes below, the full suite ran **1,891 tests, one skip, zero failures** in
129.294 seconds. A subsequent focused rerun after the final output-fixture correction
and MCP cleanup passed **68/68** tests on Mac. The sole skip is
`SandboxV2Tests.testFailIfUnavailableDegradesOnlyForInteractiveRuns`, because this Mac has
an available sandbox backend. All six formerly failing sandbox tests pass, with no test
excluded and no sandbox or permission policy relaxed.

`swift build --product arnes --force-resolved-versions` built the actual executable.
`scripts/test-acp.py` passed **11/11** against it (4.923 seconds), including all seven formerly
blocked HTTP cases. The benchmark adapter passed **22/22** offline Python tests.

Host probes establish distinct boundaries:

- Loopback bind, connect, accept and data exchange pass.
- A direct sandbox allows an in-root write and denies an out-of-root write; the denied file
  does not exist afterward. All repository sandbox integration tests pass too.
- An explicit `sandbox-exec` inside a second `sandbox-exec` still fails with exit 71 and
  `sandbox_apply: Operation not permitted`. This extra nested invocation is unsupported in
  this session; it is not required by the repository's passing Mac tests.

### Earlier Linux diagnosis: blockers resolved by the continuation above

A temporary Lima 2.2.0 VM used Apple Virtualization on this Mac, Ubuntu 24.04 arm64 and kernel
`6.8.0-134-generic`. No host home directory was mounted. A source archive containing the
tracked and untracked worktree files was copied into a container's `/workspace`; the Mac
build directory, git metadata and personal configuration were excluded. Container stores
and mock-server state were disposable.

The original CI image `swift:6.0-jammy` (Swift 6.0.3) fails both build and `swift test` because
locked dependency manifests require Swift 6.1/6.2. CI and the matching Linux release build
now select `swift:6.2-jammy`; the test jobs explicitly build `arnes` and enforce the lockfile.
Mac CI selects the latest installed Xcode, consistent with the existing universal job.
The tested Linux image supplied Swift 6.2.4 and Ubuntu 22.04 (Jammy), OCI index digest
`sha256:194964e01e2d1ad9bb51f547fb7edf91c01c48be6c7a16cd62ec7f1e1ef16b36`.

**The original SwiftOpenAI 4.6.0 dependency graph fails a clean build.** SwiftOpenAI 4.6.0 imports
`NIOFoundationCompat` on Linux without declaring its product dependency. An isolated,
unpublished diagnostic patch adds SwiftNIO and its `NIOCore`, `NIOFoundationCompat` and
`NIOHTTP1` products to SwiftOpenAI's manifest. That initial diagnostic patch did not change a dependency source in the Mac checkout or
sibling repository. The later continuation moved the correction into SwiftOpenAI PR #199
and pinned its commit, enabling a clean build without waiting for a release.
Restoring only the manifest after a patched build can appear to pass because its cached NIO
module remains available; clean builds are required to check this blocker.

With that temporary patch, the actual Linux executable builds and passes **11/11 ACP
transport/HTTP/subprocess cases** (6.197 seconds). The Linux benchmark adapter passes
**22/22**. These are diagnostic results, not a successful build of the unchanged dependency.
The last complete diagnostic Linux suite executed **1,891 tests, 10 expected platform
skips and six failed assertions across four tests** in 266.785 seconds. Five assertions are
the three Foundation timing tests below. The sixth was the 20 MB fixture's assumption that
GNU `yes` emits no broken-pipe diagnostic; that fixture was subsequently made deterministic
and the final focused rerun passed **97/97** (35.645 seconds), including that fixture,
MCP/ACP, HTTP and review-diff regressions. No native Linux sandbox support is implied by
the platform skips, and no failed sandbox test was converted into a skip.

The second original blocker was reproduced independently of Arnes: Swift 6.2.4 Foundation's
`Process.waitUntilExit()` reports a direct shell exit in 0.056 seconds, but takes 3.040 seconds
when that shell leaves a three-second descendant, even with stdout/stderr redirected to
`/dev/null`. Inspection of the stopped test process showed its shell already a zombie while
Foundation still considered it running. The [Foundation Process implementation](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.2.4-RELEASE/Sources/Foundation/Process.swift)
waits for an inherited supervision socket to close before calling `waitpid`; descendants
retain that socket. These regression checks exposed the delay and stay enabled:

- `HooksTests.testHookReturnsWhenShellExitsEvenIfAChildKeepsRunning`
- `ShellRunnerTests.testBackgroundChildHoldingThePipeItselfDoesNotBlock`
- `ShellRunnerTests.testReturnsWhenBashExitsEvenIfAGrandchildKeepsThePipe`

They exposed a real Linux timing limitation rather than a loopback or container permission
denial. The continuation above supplies Linux process supervision inside ShellRunner, and
these checks now pass. Foundation itself was not modified. Timeout/cancellation still kills
process trees; executable cancel/restart checks pass.

### Fixes and retained evidence

Targeted fixes made during validation:

- Import `FoundationNetworking` where Linux needs it. Replace unavailable
  `URLSession.bytes` with a cancellable data-delegate drain that retains only the byte cap.
  Five real-loopback regressions cover overflow without EOF, exact/empty/zero caps,
  redirects, active cancellation and cancellation before startup.
- Refuse MCP HTTP redirects through a session delegate. The Linux implementation did not
  honor the previous per-task async delegate; the real HTTP regression detects forwarding.
- Drain subprocess pipes nonblockingly through EOF/EAGAIN, joining trailing shell output
  before collecting it. This fixes the Linux MCP EOF hang and truncated review-diff
  collection. Add a 2,000-line MCP exit regression and bound the existing cwd/EOF regression.
  Pipe draining alone did not resolve the Foundation process-exit delay; LinuxProcess does.
- Use deterministic byte-count fixtures instead of GNU `yes`'s additional broken-pipe
  diagnostic. Job-kill assertions accept the documented SIGKILL escalation as well as
  SIGTERM while retaining deadlines and checks that the shell and descendants have exited.

Local evidence is retained under `.build/validation/` (ignored by git):
`host-probes.json`, `macos-complete.log`, `macos-delivery-build.log`,
`macos-delivery-acp.log`, `macos-last-focused.log`, `macos-benchmark-tests.log`, `linux-ci-6.0.log`,
`linux-build.log`, `linux-unpatched-clean-build.log`, `linux-complete-diagnostic.log`,
`linux-delivery-acp-diagnostic.log`, `linux-last-focused-diagnostic.log`,
`linux-benchmark-tests.log`, `linux-foundation-process-probe.log`,
`FoundationProcessProbe.swift`, `SwiftOpenAI-linux-dependencies.patch`, and `provenance.json`.
The dependency lock SHA-256 is
`65304f33b165639520353a28130f56180816caa72db20e83f066ff7d29a3d0a5`.
Earlier logs retain the original failures and intermediate focused checks. The original
SwiftOpenAI manifest was restored and the missing-module failure reproduced after
`swift package clean`. The initial temporary VM and containers were stopped and removed after collecting evidence.
The continuation used a new isolated VM with the same toolchain image.

## Automated integration gates and reproduction

The required local Mac and Linux arm64 build, full-suite and executable gates **pass** with
SwiftOpenAI 4.6.1, whose source matches the tested PR commit. The local continuation did
not execute Linux x86_64 Arnes or universal/static release artifacts; those are additional
hosted CI jobs. Installer behavior and real provider/editor behavior remain separate checks.
Hosted SwiftOpenAI CI is separate from Arnes CI.

```bash
swift build --product arnes --force-resolved-versions
swift test --force-resolved-versions
python3 scripts/test-acp.py --binary .build/debug/arnes
python3 -m unittest discover -s benchmarks/terminal-bench -p 'test_*.py'
```

To reproduce the Linux gate without personal stores, use a fresh container, copy source
files without `.build`/`.git`, install Python 3, then run the same commands. For example,
from the repository root with Docker available:

```bash
validation_archive=$(mktemp /tmp/arnes-source.XXXXXX)
git ls-files -z --cached --others --exclude-standard |
  tar --null -T - -cf "$validation_archive"
docker run --rm --init \
  --mount "type=bind,source=$validation_archive,target=/source.tar,readonly" \
  swift:6.2-jammy bash -lc '
    set -e
    apt-get update && apt-get install -y python3
    mkdir /workspace && tar -xf /source.tar -C /workspace
    cd /workspace
    swift build --product arnes --force-resolved-versions
    swift test --force-resolved-versions
    python3 scripts/test-acp.py --binary .build/debug/arnes
    python3 -m unittest discover -s benchmarks/terminal-bench -p "test_*.py"
  '
rm -f "$validation_archive"
```

This uses the released SwiftOpenAI dependency declared by Arnes; no dependency editing
is needed. Linux has no native Arnes sandbox; container isolation is required.

## Separate compatibility and quality evaluations

These establish product quality or additional integrations; they are not prerequisites for
keeping unmeasured controls opt-in or for running the automated engineering checks above.

1. **One pinned container smoke trial:** follow the [benchmark guide](../benchmarks/terminal-bench/README.md) with an explicit model, binary
   digest, Harbor version and task identity. Check installation, independent verifier outcome,
   exit classification, event stream, transcript, model routing and usage accounting. Retain
   incomplete/failed runs as evidence. A smoke pass establishes integration, not competitive quality.
2. **One editor integration session:** follow the [ACP contract](ACP.md). Exercise a read,
   approve and deny separate mutations, cancel a running operation, then close/disconnect.
   Check correlated tool IDs, no writes after denial, stopped processes and a durable run
   record. Also check approved MCP startup if that integration will be used.
3. **Paired model evaluations:** use the [guidance](../evals/ab/packs-tool-guidance/README.md)
   and [specialist](../evals/ab/agents-specialists/README.md) protocols. Freeze model, effort,
   budgets and task identity; change one treatment at a time, alternate arm order, and use
   at least three repetitions. Evaluate OpenAI- and Anthropic-family guidance separately.
   Diagnostics and context-retention controls need their own comparisons. Confirm on
   held-out tasks, retaining independent pass/fail, all infrastructure failures, total cost,
   tool calls, elapsed time and redacted trajectories. No default promotion without review.

Live evaluations consume provider resources and write real Arnes stores. Under this repo's
standing rules they are human-operated, not unattended agent actions. Share reviewed,
redacted evidence—not provider keys or unreviewed transcripts. Once evidence is available,
use its failures to decide the next code changes; more speculative features do not substitute
for these gates.

## Change organization

The validated changes cover four related areas:

1. Model-adaptive guidance, exact-edit recovery, optional diagnostics and context retention.
2. Loop permission/prefix/cancellation fixes, specialist/eval inheritance and process cleanup.
3. ACP protocol/progress, isolated state, bounded transport and executable client tests.
4. Benchmark adapter/probes, platform CI, the released dependency and reconciled documentation.
