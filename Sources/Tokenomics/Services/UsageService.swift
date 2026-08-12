import Foundation

/// Wraps `ccusage` (https://github.com/ryoppippi/ccusage) for per-session cost. Cost math is delegated
/// entirely to it — pricing changes and differs between direct API and Bedrock, so this app never
/// reimplements it (spec.md §0). An actor because it shells out (blocking `Process` calls) and should
/// never run on the main actor.
actor UsageService {
    private(set) var isAvailable = true
    private(set) var unavailableReason: String?
    private var costBySessionID: [String: Double] = [:]

    func cost(forSessionID id: String) -> Double? {
        costBySessionID[id]
    }

    /// Re-runs `ccusage` and refreshes the cost cache. Call on the refresh timer, not every second — it's
    /// a subprocess, not a file read.
    func refresh() {
        // Try a real `ccusage` on PATH first (fast), fall back to `npx` (slower, always works if Node
        // is installed). Both invoked via `env` so PATH resolution matches an interactive shell.
        let candidates: [[String]] = [
            ["ccusage", "claude", "session", "--json"],
            ["npx", "--yes", "ccusage@latest", "claude", "session", "--json"],
        ]
        for arguments in candidates {
            if let data = run(arguments), let parsed = parse(data) {
                costBySessionID = parsed
                isAvailable = true
                unavailableReason = nil
                return
            }
        }
        isAvailable = false
        unavailableReason = "ccusage not found (checked PATH and npx) — session cost shows as \"—\""
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 10) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe() // discard npm/npx notices
        do {
            try process.run()
        } catch {
            return nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// Shape confirmed by running `ccusage claude session --json` directly: `{"sessions": [{"sessionId",
    /// "projectPath", "totalCost", ...}]}`. sessionId matches the transcript filename stem, which is what
    /// TranscriptWatcher uses as Session.id — that's the join key.
    private func parse(_ data: Data) -> [String: Double]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]] else { return nil }
        var result: [String: Double] = [:]
        for entry in sessions {
            guard let id = entry["sessionId"] as? String,
                  let cost = entry["totalCost"] as? Double else { continue }
            result[id] = cost
        }
        return result
    }
}
