import Foundation
import CoreServices

/// Discovers and parses local Codex session rollouts under `~/.codex`. Read-only by design: this never
/// writes to Codex transcripts or metadata, and it never opens `auth.json`.
@MainActor
final class CodexSessionWatcher {
    /// Keep the same default horizon as Claude transcripts: recent enough to represent sessions a user
    /// may care about today, bounded enough not to turn old local history into a giant menu.
    private let recencyWindow: TimeInterval = 24 * 3600

    private let codexHome: URL
    private var fsEventStream: FSEventStreamRef?

    var onChange: (@MainActor () -> Void)?

    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
    }

    // MARK: - Discovery + parsing

    func discoverTranscripts(maxDepth: Int = 6) -> [URL] {
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
                } else if entry.pathExtension == "jsonl" && looksLikeCodexTranscript(entry) {
                    results.append(entry)
                }
            }
        }

        walk(codexHome, depth: 0)
        return results
    }

    private func looksLikeCodexTranscript(_ url: URL) -> Bool {
        guard !url.lastPathComponent.contains("auth"),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return false }
        return text.contains("\"session_meta\"") || text.contains("\"token_count\"")
    }

    /// Parses one Codex JSONL rollout. The local format differs from Claude Code's transcript shape:
    /// session metadata lives in `session_meta.payload`, per-turn model/cwd in `turn_context.payload`,
    /// and usage in `event_msg.payload.type == "token_count"`.
    func loadSession(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var threadID: String?
        var workingDirectory: String?
        var lastTimestamp: Date?
        var lastModel: String?
        var lastEffort: String?
        var lastVersion: String?
        var lastVisibleCharCount: Int?
        var totalInputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        var reasoningOutputTokens: Int?
        var toolUsage = ToolUsage()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let timestamp = Self.date(from: obj["timestamp"] as? String) {
                lastTimestamp = timestamp
            }

            guard let type = obj["type"] as? String else { continue }
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                threadID = stringValue(payload?["id"]) ?? stringValue(payload?["session_id"]) ?? threadID
                workingDirectory = stringValue(payload?["cwd"]) ?? workingDirectory
                lastVersion = stringValue(payload?["cli_version"]) ?? lastVersion
                if let timestamp = Self.date(from: stringValue(payload?["timestamp"])) {
                    lastTimestamp = timestamp
                }
            case "turn_context":
                workingDirectory = stringValue(payload?["cwd"]) ?? workingDirectory
                lastModel = stringValue(payload?["model"]) ?? lastModel
                lastEffort = stringValue(payload?["effort"]) ?? lastEffort
            case "event_msg":
                parseEventPayload(
                    payload,
                    lastVisibleCharCount: &lastVisibleCharCount,
                    totalInputTokens: &totalInputTokens,
                    cachedInputTokens: &cachedInputTokens,
                    outputTokens: &outputTokens,
                    reasoningOutputTokens: &reasoningOutputTokens
                )
            case "response_item":
                accumulateToolUsage(from: payload, into: &toolUsage)
            default:
                break
            }
        }

        guard let resolvedCwd = workingDirectory else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let resolvedID = threadID ?? Self.threadIDFallback(from: url)

        return Session(
            id: resolvedID,
            agentKind: .codex,
            workingDirectory: resolvedCwd,
            aiTitle: nil,
            lastTurnTime: lastTimestamp ?? mtime ?? .distantPast,
            cacheCreationTokens: 0,
            cacheReadTokens: cachedInputTokens ?? 0,
            totalInputTokens: totalInputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            toolUsage: toolUsage,
            model: lastModel,
            effort: lastEffort,
            version: lastVersion,
            lastVisibleCharCount: lastVisibleCharCount,
            currentContextTokens: totalInputTokens,
            activity: .idle,
            compactionStartedAt: nil,
            detectedTTL: nil,
            cost: nil
        )
    }

    func scanAll() -> [Session] {
        let cutoff = Date().addingTimeInterval(-recencyWindow)
        return discoverTranscripts().compactMap { url -> Session? in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (mtime ?? .distantPast) >= cutoff else { return nil }
            return loadSession(from: url)
        }
    }

    private func parseEventPayload(
        _ payload: [String: Any]?,
        lastVisibleCharCount: inout Int?,
        totalInputTokens: inout Int?,
        cachedInputTokens: inout Int?,
        outputTokens: inout Int?,
        reasoningOutputTokens: inout Int?
    ) {
        guard let payload, let eventType = payload["type"] as? String else { return }
        if eventType == "agent_message", let message = payload["message"] as? String, !message.isEmpty {
            lastVisibleCharCount = message.count
        } else if eventType == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = (info["total_token_usage"] as? [String: Any])
                    ?? (info["last_token_usage"] as? [String: Any]) {
            totalInputTokens = intValue(usage["input_tokens"])
            cachedInputTokens = intValue(usage["cached_input_tokens"])
            outputTokens = intValue(usage["output_tokens"])
            reasoningOutputTokens = intValue(usage["reasoning_output_tokens"])
        }
    }

    private func accumulateToolUsage(from payload: [String: Any]?, into usage: inout ToolUsage) {
        guard let payload,
              payload["type"] as? String == "function_call",
              let name = payload["name"] as? String else { return }
        if name.hasPrefix("mcp__"), let server = mcpServerName(from: name) {
            usage.mcpServers.insert(server)
        } else {
            usage.builtInTools[name, default: 0] += 1
        }
    }

    private func mcpServerName(from toolName: String) -> String? {
        let parts = toolName.components(separatedBy: "__")
        guard parts.count >= 3, parts.first == "mcp" else { return nil }
        return parts[1..<(parts.count - 1)].joined(separator: "__")
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func threadIDFallback(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - FSEvents

    func startWatching() {
        stopWatching()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let pathsToWatch = [codexHome.path] as CFArray
        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<CodexSessionWatcher>.fromOpaque(info).takeUnretainedValue()
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
