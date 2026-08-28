import Foundation

/// Discovery/scan helpers shared by `TranscriptWatcher` (~/.claude, Claude Code) and
/// `CodexSessionWatcher` (~/.codex, Codex) — the two watchers differ in directory layout and
/// transcript shape, but "walk a bounded directory tree for `.jsonl` files that look like ours,
/// then parse only the ones still inside the recency window" is identical logic.
enum TranscriptDiscovery {
    /// Walks `root` (bounded depth, skipping hidden files) for `.jsonl` files satisfying `isMatch`.
    static func findJSONLFiles(under root: URL, maxDepth: Int, matching isMatch: (URL) -> Bool) -> [URL] {
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
                } else if entry.pathExtension == "jsonl" && isMatch(entry) {
                    results.append(entry)
                }
            }
        }
        walk(root, depth: 0)
        return results
    }

    /// Reads the first 4KB of `url` and tests it against `predicate` — both watchers use this to sniff
    /// a `.jsonl` file's content before committing to a full parse.
    static func headContains(_ url: URL, _ predicate: (String) -> Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return false }
        return predicate(text)
    }

    /// Discovers, then keeps only files modified within `recencyWindow`, then parses each via `load` —
    /// the `scanAll()` body shared by both watchers.
    static func scanRecent<Session>(
        discover: () -> [URL], recencyWindow: TimeInterval, load: (URL) -> Session?
    ) -> [Session] {
        let cutoff = Date().addingTimeInterval(-recencyWindow)
        return discover().compactMap { url -> Session? in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (mtime ?? .distantPast) >= cutoff else { return nil }
            return load(url)
        }
    }

    /// Parses `mcp__<server>__<tool>` tool names into the server name — used by both watchers when
    /// tallying `ToolUsage.mcpServers`.
    static func mcpServerName(from toolName: String) -> String? {
        let parts = toolName.components(separatedBy: "__")
        guard parts.count >= 3, parts.first == "mcp" else { return nil }
        return parts[1..<(parts.count - 1)].joined(separator: "__")
    }
}
