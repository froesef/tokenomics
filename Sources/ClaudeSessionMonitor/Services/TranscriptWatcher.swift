import Foundation
import CoreServices

/// Discovers and parses Claude Code session transcripts under `~/.claude`, and watches that tree for
/// changes via FSEvents. Read-only: never writes, locks, or truncates a transcript file (spec.md §0, §10.8).
///
/// Layout note (spec.md §12 — "follow the machine, note the deviation"): on this machine transcripts live
/// at `~/.claude/projects/<sanitized-absolute-cwd>/<session-uuid>.jsonl`, one directory per project, one
/// file per session. Rather than hardcode that "projects" path, `discoverTranscripts` walks `~/.claude`
/// (bounded depth) and sniffs each `.jsonl` file for a `"sessionId"` key so a future layout change doesn't
/// silently stop working.
@MainActor
final class TranscriptWatcher {
    /// Sessions dormant longer than this are skipped — cheaply, by file mtime, before the full parse.
    /// Not in spec.md — added because ~/.claude accumulates months of past-session transcripts. 24h is
    /// longer than an earlier 6h cutoff (per user feedback: "it's ok to have a longer list") while still
    /// landing in the same ballpark as "how many sessions could realistically still be open" (per user
    /// feedback: "no need for scrolling, unlikely more than 20 running") — verified on a real ~/.claude
    /// with months of history: 24h yielded 18 transcripts vs. 121 at 30 days. See README "Deviations".
    private let recencyWindow: TimeInterval = 24 * 3600

    private let claudeHome: URL
    private var fsEventStream: FSEventStreamRef?

    /// Called (on the main actor) whenever FSEvents observes a change under ~/.claude.
    var onChange: (@MainActor () -> Void)?

    init(claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeHome = claudeHome
    }

    // MARK: - Discovery + parsing

    func discoverTranscripts(maxDepth: Int = 4) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                  ) else { return }
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    walk(entry, depth: depth + 1)
                } else if entry.pathExtension == "jsonl" && looksLikeTranscript(entry) {
                    results.append(entry)
                }
            }
        }
        walk(claudeHome, depth: 0)
        return results
    }

    private func looksLikeTranscript(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return false }
        return text.contains("\"sessionId\"")
    }

    /// Parses one transcript. Tolerant by design: transcripts are appended to live by another process,
    /// so a half-written last line is normal and must be skipped, never treated as an error.
    func loadSession(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var cacheCreation = 0
        var cacheRead = 0
        var lastTimestamp: Date?
        var workingDirectory: String?
        var lastDetectedTTL: TimeInterval?
        var aiTitle: String?
        var toolUsage = ToolUsage()
        var lastModel: String?
        var lastEffort: String?
        var lastVersion: String?
        var lastVisibleCharCount: Int?
        var activity: SessionActivity = .idle
        var compactionStartedAt: Date?
        // Name of the slash command currently in flight (parsed from a "<command-name>/x</command-name>"
        // echo), so that when its closing `local_command` event arrives we know *which* command just
        // finished — only `/clear` resets the accumulators below.
        var pendingCommandName: String?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let cwd = obj["cwd"] as? String {
                workingDirectory = cwd
            }
            if let ts = obj["timestamp"] as? String, let date = iso.date(from: ts) {
                lastTimestamp = date
            }
            // Present on every event, not just assistant turns — keep overwriting so this ends up as the
            // version that wrote the transcript's last line (i.e. the CLI currently running it).
            if let version = obj["version"] as? String {
                lastVersion = version
            }
            // Same short label Claude Code uses as the Ghostty tab title — see Session.aiTitle.
            if obj["type"] as? String == "ai-title", let title = obj["aiTitle"] as? String {
                aiTitle = title
            }

            // Hooks run transparently around a tool call rather than being chosen by the model, so they
            // never appear as a `tool_use` block — only here, as their own attachment event. Confirmed
            // shape from a real transcript: {"type": "attachment", "attachment": {"type": "hook_success",
            // "hookName": "PreToolUse:Bash", "command": "rtk hook claude", ...}}. The hook binary's own
            // name is the first word of `command` ("rtk"), not `hookName` (a lifecycle label like
            // "PreToolUse:Bash", the same for every hook regardless of which binary ran).
            if obj["type"] as? String == "attachment", let attachment = obj["attachment"] as? [String: Any] {
                let attachmentType = attachment["type"] as? String
                if attachmentType == "hook_success" || attachmentType == "hook_error",
                   let command = attachment["command"] as? String,
                   let name = command.split(separator: " ").first {
                    toolUsage.hooks[String(name), default: 0] += 1
                }
            }

            Self.updateActivity(
                for: obj, lastTimestamp: lastTimestamp,
                activity: &activity, compactionStartedAt: &compactionStartedAt, pendingCommandName: &pendingCommandName,
                cacheCreation: &cacheCreation, cacheRead: &cacheRead,
                toolUsage: &toolUsage, lastVisibleCharCount: &lastVisibleCharCount
            )

            guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any] else { continue }

            // Read straight off the event, not inferred: which model/effort actually answered this turn.
            // Keeps overwriting so the session ends up with its *latest* turn's values.
            if let model = message["model"] as? String {
                lastModel = model
            }
            if let effort = obj["effort"] as? String {
                lastEffort = effort
            }

            if let content = message["content"] as? [[String: Any]] {
                Self.accumulateToolUsage(from: content, into: &toolUsage)

                // Only overwrite on a turn that actually said something — a later turn that's pure
                // tool_use (e.g. mid-tool-round-trip) shouldn't erase what the user last had to read.
                let charCount = content
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .reduce(0) { $0 + $1.count }
                if charCount > 0 {
                    lastVisibleCharCount = charCount
                }
            }

            guard let usage = message["usage"] as? [String: Any] else { continue }

            cacheCreation += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            cacheRead += (usage["cache_read_input_tokens"] as? Int) ?? 0

            // Ground truth for the TTL in effect on this turn, when Claude Code reports it.
            if let creation = usage["cache_creation"] as? [String: Any] {
                let oneHour = (creation["ephemeral_1h_input_tokens"] as? Int) ?? 0
                let fiveMin = (creation["ephemeral_5m_input_tokens"] as? Int) ?? 0
                if oneHour > 0 {
                    lastDetectedTTL = 3600
                } else if fiveMin > 0 {
                    lastDetectedTTL = 300
                }
            }
        }

        let resolvedCwd = workingDirectory ?? Self.inferWorkingDirectory(from: url)
        guard let resolvedCwd else { return nil }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let lastTurnTime = lastTimestamp ?? mtime ?? .distantPast

        return Session(
            id: url.deletingPathExtension().lastPathComponent,
            workingDirectory: resolvedCwd,
            aiTitle: aiTitle,
            lastTurnTime: lastTurnTime,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            toolUsage: toolUsage,
            model: lastModel,
            effort: lastEffort,
            version: lastVersion,
            lastVisibleCharCount: lastVisibleCharCount,
            activity: activity,
            compactionStartedAt: compactionStartedAt,
            detectedTTL: lastDetectedTTL,
            cost: nil
        )
    }

    /// Infers idle/running/compacting purely from event *order* in the file (not timestamp order — a
    /// finished `/compact` flushes several events at once, backdated to when each logically happened, so
    /// the boundary-closing event isn't always the last-timestamped one). Confirmed against real
    /// transcripts: a plain user turn opens on the `user` message and closes on `system/turn_duration`;
    /// `/compact` opens on a bare `"/compact"` user message (written the instant it's submitted, before
    /// compaction starts) and closes on `system/compact_boundary` — the file receives *nothing* in
    /// between, for the entire compaction duration, since Claude Code batches the boundary, the
    /// continuation summary, and the command echo/stdout together once it's done. `/clear` (and every
    /// other slash command) opens on its `<command-name>` echo and closes near-instantly on
    /// `system/local_command`.
    private static func updateActivity(
        for obj: [String: Any], lastTimestamp: Date?,
        activity: inout SessionActivity, compactionStartedAt: inout Date?, pendingCommandName: inout String?,
        cacheCreation: inout Int, cacheRead: inout Int,
        toolUsage: inout ToolUsage, lastVisibleCharCount: inout Int?
    ) {
        guard let type = obj["type"] as? String else { return }

        if type == "system" {
            switch obj["subtype"] as? String {
            case "turn_duration":
                activity = .idle
                compactionStartedAt = nil
            case "compact_boundary":
                activity = .idle
                compactionStartedAt = nil
                // The old cache prefix no longer reflects what's actually loaded post-compaction.
                cacheCreation = 0
                cacheRead = 0
            case "local_command":
                activity = .idle
                compactionStartedAt = nil
                if pendingCommandName == "/clear" {
                    cacheCreation = 0
                    cacheRead = 0
                    toolUsage = ToolUsage()
                    lastVisibleCharCount = nil
                }
                pendingCommandName = nil
            default:
                break
            }
        } else if type == "user", let message = obj["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "/compact" {
                    activity = .compacting
                    compactionStartedAt = lastTimestamp
                } else if let name = commandName(from: trimmed) {
                    pendingCommandName = name
                    activity = .running
                } else {
                    activity = .running
                }
            } else if let blocks = message["content"] as? [[String: Any]] {
                // A message made only of tool_result blocks is Claude Code feeding a tool's output back
                // mid-turn, not a new user turn — leave the existing (running) state alone.
                let isPureToolResult = !blocks.isEmpty && blocks.allSatisfy { ($0["type"] as? String) == "tool_result" }
                if !isPureToolResult {
                    activity = .running
                }
            }
        }
    }

    private static func commandName(from content: String) -> String? {
        guard let start = content.range(of: "<command-name>")?.upperBound,
              let end = content.range(of: "</command-name>")?.lowerBound,
              start < end else { return nil }
        return String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort fallback when no event in the transcript carries a `cwd` field: reverses the
    /// "-Users-me-project" directory-name sanitization. Lossy for paths that contain literal hyphens —
    /// in practice `cwd` is always present on this machine's transcripts, so this rarely triggers.
    private static func inferWorkingDirectory(from transcriptURL: URL) -> String? {
        let dirName = transcriptURL.deletingLastPathComponent().lastPathComponent
        guard dirName.hasPrefix("-") else { return nil }
        return "/" + dirName.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    /// Scans one assistant message's `content` blocks for `tool_use` and tallies what it finds.
    /// Confirmed by inspecting real transcripts: MCP/plugin tools are named `mcp__<server>__<tool>`
    /// (e.g. `mcp__plugin_playwright_playwright__browser_evaluate`), and the Skill tool records which
    /// skill it invoked in `input.skill` (e.g. `{"name": "Skill", "input": {"skill": "dataviz"}}`) — the
    /// generic tool name alone wouldn't say *which* plugin or skill was actually used.
    private static func accumulateToolUsage(from content: [[String: Any]], into usage: inout ToolUsage) {
        for block in content {
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { continue }
            if name.hasPrefix("mcp__") {
                if let server = mcpServerName(from: name) {
                    usage.mcpServers.insert(server)
                }
            } else if name == "Skill" {
                if let input = block["input"] as? [String: Any], let skill = input["skill"] as? String {
                    usage.skills.insert(skill)
                }
            } else {
                usage.builtInTools[name, default: 0] += 1
            }
        }
    }

    private static func mcpServerName(from toolName: String) -> String? {
        let parts = toolName.components(separatedBy: "__")
        guard parts.count >= 3, parts.first == "mcp" else { return nil }
        return parts[1..<(parts.count - 1)].joined(separator: "__")
    }

    /// Deliberately does NOT collapse/dedupe sessions that share a working directory. An earlier version
    /// of this did (keeping only the most-recently-active session per directory), reasoning that a
    /// second same-directory session was probably a stale leftover. Verified against real `ps`/`lsof`
    /// output during review: two *live* `claude` processes can genuinely share one directory (e.g. two
    /// terminal tabs both cd'd into the same repo) — collapsing would have hidden a real running session.
    /// See ProcessMatcher/Session.livePIDs for the honest way to answer "is this one actually live".
    func scanAll() -> [Session] {
        let cutoff = Date().addingTimeInterval(-recencyWindow)
        return discoverTranscripts().compactMap { url -> Session? in
            // Cheap mtime check before paying for a full read + line-by-line JSON parse.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (mtime ?? .distantPast) >= cutoff else { return nil }
            return loadSession(from: url)
        }
    }

    // MARK: - FSEvents

    func startWatching() {
        stopWatching()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let pathsToWatch = [claudeHome.path] as CFArray
        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
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
