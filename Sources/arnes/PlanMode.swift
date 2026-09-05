import ArnesKit
import Foundation

// MARK: - PlanReview

/// The answer to the "plan ready" question the REPL asks after a plan-mode turn.
enum PlanReview: Equatable {
  /// Leave plan mode and tell the model to carry the plan out.
  case approve
  /// Stay in plan mode; the next typed line is feedback on the plan.
  case revise
  /// Leave plan mode without executing anything.
  case cancel

  /// One keypress → an answer. `a`/`r`/`c` (either case); Esc, EOF and anything else
  /// cancel — the safe reading of a stray key is "do nothing", never "run it".
  static func parse(key: String?) -> PlanReview {
    switch key?.lowercased() {
    case "a": return .approve
    case "r": return .revise
    default: return .cancel
    }
  }
}

// MARK: - PlanModeController

/// The propose → approve → execute cycle over the session's permission mode, kept apart
/// from the terminal so it can be tested without one.
///
/// `/plan <task>` (or `/permissions plan`) enters plan mode remembering where to come back
/// to; after each turn that ran read-only the REPL asks `question`; `resolve` turns the
/// answer into what happens next — restore the mode and send `approvalPrompt`, stay and
/// wait for a revision, or restore the mode and send nothing. Plan mode set at startup has
/// no "before", so approving or cancelling from it lands on `default`.
///
/// Shared between the REPL loop and its slash handlers (all on one task, but captured by
/// async code), so the one piece of state sits behind a lock like `StatusInfo`'s.
final class PlanModeController: @unchecked Sendable {
  private let lock = NSLock()
  private var remembered: PermissionMode = .default

  /// The mode approve/cancel return to. `.default` until plan mode is entered from
  /// something else (a `--permission-mode plan` session has nothing to go back to).
  var previousMode: PermissionMode {
    lock.withLock { remembered }
  }

  /// What the REPL asks once a plan-mode turn has finished.
  static let question = "plan ready — [a]pprove · [r]evise · [c]ancel"

  /// The harness-authored user turn sent on approval. One sentence, family-neutral: it is
  /// UI text the user chose to send, not model tuning, so it lives here and not in a pack.
  static let approvalPrompt = "[arnes] Plan approved. Execute it, verifying each step."

  /// The input-box hint while a revision is expected.
  static let revisePlaceholder = "describe the revision · the plan stays read-only until approved"

  /// `/plan` usage, when no task follows it.
  static let usage = "usage: /plan <task> — propose in read-only plan mode, then [a]pprove · [r]evise · [c]ancel"

  /// What the REPL does with an answer.
  enum Resolution: Equatable {
    /// Switch to `mode` and send `prompt` as the next turn.
    case execute(mode: PermissionMode, prompt: String)
    /// Stay in plan mode; the next typed line is the revision.
    case revise
    /// Switch to `mode`; nothing is sent.
    case cancelled(mode: PermissionMode)
  }

  /// Entering plan mode from `current` remembers it as the mode to restore. Entering from
  /// plan mode itself (a revise cycle, or plan set at startup) changes nothing — the
  /// remembered mode, or `.default`, still stands.
  func enter(from current: PermissionMode) {
    guard current != .plan else { return }
    lock.withLock { remembered = current }
  }

  /// Forgets the remembered mode. For the ways out of plan mode that bypass the review —
  /// `/permissions <mode>` by hand, or `/resume` into another session — so a cycle started
  /// under one mode can't restore it into an unrelated one later.
  func reset() {
    lock.withLock { remembered = .default }
  }

  /// Whether a plan-mode turn that ended with `stopReason` is a plan to review. A turn the
  /// model finished on its own is (`completed`, or `planProposed` when the session records
  /// it that way); an interrupted, errored or cut-off turn has no finished plan to approve.
  static func isReviewable(_ stopReason: StopReason?) -> Bool {
    switch stopReason {
    case .completed, .planProposed: return true
    default: return false
    }
  }

  /// Applies the answer. Approve and cancel hand back the remembered mode and reset it to
  /// `.default`, so a later `/plan` from the restored mode remembers that one afresh.
  func resolve(_ review: PlanReview) -> Resolution {
    switch review {
    case .approve:
      return .execute(mode: takeRemembered(), prompt: Self.approvalPrompt)
    case .revise:
      return .revise
    case .cancel:
      return .cancelled(mode: takeRemembered())
    }
  }

  private func takeRemembered() -> PermissionMode {
    lock.withLock {
      defer { remembered = .default }
      return remembered
    }
  }
}
