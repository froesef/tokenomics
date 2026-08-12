import SwiftUI

/// What a session is doing *right now*, inferred from transcript structure rather than any explicit
/// "in progress" flag (Claude Code doesn't write one — see TranscriptWatcher.parseActivity). Distinct
/// from CacheStatus, which is about cache TTL health, not liveness.
enum SessionActivity: Sendable, Equatable {
    /// No turn open: the last thing in the transcript is a completed turn (`turn_duration`), a finished
    /// slash command, or the session hasn't started yet.
    case idle
    /// A user turn is open (a real message was submitted) and no `turn_duration` has closed it yet —
    /// the CLI is thinking, calling tools, or streaming a reply.
    case running
    /// A `/compact` was submitted and its `compact_boundary` hasn't landed yet. Compaction blocks the
    /// transcript file entirely while it runs (see TranscriptWatcher), so this can be the only new
    /// information a poll picks up for minutes at a time.
    case compacting
    /// The open turn's most recent tool call was an `AskUserQuestion` or `ExitPlanMode` — Claude Code is
    /// blocked on a human decision, not doing any work, until a `tool_result` answers it. Worth
    /// distinguishing from `.running`: a long wait here means "go answer Claude," not "let it keep
    /// working." See TranscriptWatcher.updateActivity for how this is detected.
    case waitingForInput

    var label: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .compacting: return "compacting"
        case .waitingForInput: return "needs input"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .blue
        case .compacting: return .purple
        case .waitingForInput: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return ""
        case .running: return "bolt.fill"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .waitingForInput: return "questionmark.circle.fill"
        }
    }
}
