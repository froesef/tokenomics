import Foundation

/// Persists auto-keep-alive fire attempts to disk, at `~/Library/Logs/Tokenomics/keepalive.log` — the
/// standard macOS per-user log location, mirroring how `claude-code-cache-keepalive` logs its own hook
/// fires to `~/.claude/cache-keepalive/cache-keepalive.log` for post-hoc debugging. Added because the
/// existing stderr-only logging (see `SessionListViewModel.fireKeepAlivePing`) only survives while the
/// app happens to be run attached to a console — useless for diagnosing the known Ghostty-splits
/// keep-alive bug after the fact, since by the time it's noticed the app's stderr is long gone.
enum KeepAliveFileLogger {
    private static let logURL: URL = {
        let logsDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Tokenomics", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("keepalive.log")
    }()

    // Only ever touched from `log(_:)`, which itself only runs on the main actor (called from
    // SessionListViewModel) — safe to opt out of Swift 6's Sendable check for this shared formatter.
    private static nonisolated(unsafe) let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
