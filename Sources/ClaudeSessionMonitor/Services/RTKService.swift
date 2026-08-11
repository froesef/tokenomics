import Foundation

/// Token-savings stats for one project directory, as reported by `rtk gain` — see RTKService.
struct RTKStats: Equatable, Sendable {
    let totalCommands: Int
    let totalSavedTokens: Int
    let avgSavingsPercent: Double
}

/// Wraps `rtk gain` (the user's own "Rust Token Killer" CLI proxy — see ~/.claude/RTK.md) for real
/// per-project token-savings numbers, the same way UsageService wraps `ccusage` for cost. An actor
/// because it shells out; never call from the main actor.
///
/// `rtk gain`'s `-p`/`--project` flag is a boolean that scopes to the *process's current working
/// directory*, not a path argument (confirmed via `rtk gain --help` and by actually running it: zero
/// counts from an unrelated directory, real counts from a directory with rtk history) — so getting
/// per-session numbers means setting `Process.currentDirectoryURL` and shelling out once per unique
/// session directory, not one call for everything.
actor RTKService {
    private(set) var isAvailable = false
    private var statsByWorkingDirectory: [String: RTKStats] = [:]

    func stats(forWorkingDirectory workingDirectory: String) -> RTKStats? {
        statsByWorkingDirectory[workingDirectory]
    }

    /// Re-runs `rtk gain -p -f json` once per unique directory in `workingDirectories`. Call on the
    /// refresh timer, not every second.
    func refresh(workingDirectories: [String]) async {
        var result: [String: RTKStats] = [:]
        var anySucceeded = false
        for directory in Set(workingDirectories) {
            guard let data = await Self.run(inDirectory: directory) else { continue }
            anySucceeded = true
            if let parsed = Self.parse(data) {
                result[directory] = parsed
            }
        }
        statsByWorkingDirectory = result
        // A directory with genuinely zero rtk history still returns well-formed zero-valued JSON
        // (verified directly), so any successful run at all — even all-zero — means rtk is installed.
        // Guard on a non-empty input so an empty session list (nothing to check) doesn't flip this false.
        if !workingDirectories.isEmpty {
            isAvailable = anySucceeded
        }
    }

    private static func run(inDirectory directory: String) async -> Data? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["rtk", "gain", "-p", "-f", "json"]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        }.value
    }

    /// Shape confirmed by running `rtk gain -p -f json` directly in this repo:
    /// `{"summary": {"total_commands", "total_input", "total_output", "total_saved", "avg_savings_pct",
    /// "total_time_ms", "avg_time_ms"}}`.
    private static func parse(_ data: Data) -> RTKStats? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = json["summary"] as? [String: Any],
              let totalCommands = summary["total_commands"] as? Int,
              let totalSaved = summary["total_saved"] as? Int,
              let avgPct = summary["avg_savings_pct"] as? Double else { return nil }
        return RTKStats(totalCommands: totalCommands, totalSavedTokens: totalSaved, avgSavingsPercent: avgPct)
    }
}
