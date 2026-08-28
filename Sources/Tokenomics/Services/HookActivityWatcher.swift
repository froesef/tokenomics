import Foundation
import CoreServices

/// Reads `~/.claude/tokenomics/hook-events.jsonl` — the log HookInstaller's hook entries append to — and
/// derives each session's current activity from it, as an alternative to TranscriptWatcher's transcript-
/// order heuristic (see `ActivitySource`).
///
/// Line format: `{"tokenomics_ts": <unix seconds>, "payload": <the hook's own stdin JSON>}`, one hook
/// firing per line. `payload` always carries Claude Code's own `session_id`, `cwd`, and `hook_event_name`
/// (confirmed against the hooks reference) — everything this watcher needs, since every hook slot
/// HookInstaller registers runs the identical shell command, so `hook_event_name` alone (not which
/// matcher fired it) is what distinguishes them here.
///
/// Ordering: lines are appended in firing order by a `printf ... >>` shell command per hook invocation.
/// macOS `write()` in O_APPEND mode is atomic for writes under `PIPE_BUF` (4,096 bytes on Darwin), which
/// every line here comfortably fits (hook payloads are small control-flow JSON, not tool output) — so two
/// concurrent sessions' hooks interleave by line, never mid-line, and file order is a reliable proxy for
/// firing order. Same "trust append order, not timestamps" stance TranscriptWatcher takes for the same
/// reason.
///
/// Gaps vs. the JSONL heuristic (see ActivitySource.hooks and the design notes this shipped with):
/// - No token/cost/cache data at all — hooks are pure control-flow signals (confirmed against the official
///   hooks reference). Cost/cache/TTL accounting must keep coming from the transcript regardless of mode.
/// - A session only has hook data from the moment install() ran onward — no backfill for turns that
///   already happened. `SessionListViewModel` falls back to the JSONL-inferred activity for any session
///   this watcher has no entry for yet.
/// - `Stop` fires at the end of every turn, including a turn that's just one step of a longer unattended
///   task — same coarseness `system/turn_duration` already has in the JSONL heuristic, not a regression.
/// - No hook fires for "still idle, waiting on the next prompt" with any precision better than
///   `Notification`'s `idle_prompt` variant, which has a ~60s built-in delay — not registered here (`Stop`
///   already gives an immediate, if slightly more conservative, idle signal).
@MainActor
final class HookActivityWatcher {
    /// One session's hook-derived state, as of the last line seen for it.
    struct State {
        var activity: SessionActivity
        var compactionStartedAt: Date?
    }

    /// Log lines beyond this count get trimmed on the next scan (keep the most recent `trimKeepLines`) —
    /// otherwise a long-running machine accumulates this file forever, since (unlike a transcript) nothing
    /// else ever rotates or scopes it. Best-effort: a failed trim just means the file grows a bit more, not
    /// a crash.
    private let trimThreshold: Int
    private let trimKeepLines: Int

    private let logFile: URL
    private var fsEventStream: FSEventStreamRef?

    /// Called (on the main actor) whenever FSEvents observes a change to the hook log's directory.
    var onChange: (@MainActor () -> Void)?

    init(logFile: URL = HookInstaller.logFile, trimThreshold: Int = 20_000, trimKeepLines: Int = 5_000) {
        self.logFile = logFile
        self.trimThreshold = trimThreshold
        self.trimKeepLines = trimKeepLines
    }

    /// Hook event name -> resulting activity. `SessionEnd` and `Stop` both close the open turn (see the
    /// type's own doc comment for why `PreCompact`/`PostCompact`'s manual/auto split and `SessionStart`'s
    /// five variants don't need distinguishing here). `PostCompact` closes `.compacting` the same way
    /// `PreCompact` opens it — see `HookInstaller.hookSlots`'s doc comment for why both are wired up
    /// instead of just relying on `SessionStart`'s `compact` variant as the closing signal.
    private static let stateByEvent: [String: SessionActivity] = [
        "SessionStart": .idle,
        "SessionEnd": .idle,
        "Stop": .idle,
        "UserPromptSubmit": .running,
        "PreToolUse": .running,
        "PreCompact": .compacting,
        "PostCompact": .idle,
        "Notification": .waitingForInput,
        "PermissionRequest": .waitingForInput
    ]

    func scanAll() -> [String: State] {
        guard let data = try? Data(contentsOf: logFile), let text = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var states: [String: State] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let sessionID = payload["session_id"] as? String,
                  let eventName = payload["hook_event_name"] as? String,
                  let activity = Self.stateByEvent[eventName]
            else { continue }

            let ts = (obj["tokenomics_ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            var state = states[sessionID] ?? State(activity: .idle, compactionStartedAt: nil)
            state.activity = activity
            state.compactionStartedAt = eventName == "PreCompact" ? (ts ?? Date()) : nil
            states[sessionID] = state
        }

        if lines.count > trimThreshold {
            trim(keepLast: trimKeepLines)
        }

        return states
    }

    /// Rewrites the log keeping only its last `keepLast` lines. Failure here (permissions, disk full,
    /// concurrent write) just skips this round's trim — never worth crashing over, and the next scan tries
    /// again once the file's grown further.
    private func trim(keepLast: Int) {
        guard let data = try? Data(contentsOf: logFile), let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > keepLast else { return }
        let trimmed = lines.suffix(keepLast).joined(separator: "\n") + "\n"
        try? trimmed.data(using: .utf8)?.write(to: logFile, options: .atomic)
    }

    // MARK: - FSEvents

    func startWatching() {
        stopWatching()
        try? FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let pathsToWatch = [logFile.deletingLastPathComponent().path] as CFArray
        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<HookActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.onChange?() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stopWatching() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }
}
