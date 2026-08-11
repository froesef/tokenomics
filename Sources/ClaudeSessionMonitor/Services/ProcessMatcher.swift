import Foundation

/// Correlates a session's working directory with currently-running `claude` OS processes, using only
/// PID and working directory — never environment variables. That distinction matters: an earlier
/// investigation into reading a process's `ENABLE_PROMPT_CACHING_1H` via `ps eww <pid>` found that doing
/// so exposes that process's *entire* environment, including live credentials (verified directly against
/// a real process). `lsof -p <pid> -d cwd` reads only the cwd file-descriptor entry, the same category of
/// information Ghostty's own AppleScript already exposes for terminals — no secrets in reach.
///
/// This is a narrow, explicit exception to spec.md §0 ("do not hook into the live Claude Code process"),
/// added directly at the user's request: two sessions in the same directory looked like duplicates in
/// the UI, and spec.md's TTL-only "warm" status can't distinguish "still warm by cache math" from
/// "process already exited". Confirmed there's no way to do this from the transcript alone — grepped
/// real transcripts for a "pid" field; Claude Code doesn't log its own PID anywhere in them.
///
/// Read-only and best-effort throughout: `pgrep`/`lsof` failing (missing binary, sandboxed environment,
/// permission denied) degrades to an empty result, never a crash — this is supplementary detail, not
/// something any core countdown/cost logic depends on.
actor ProcessMatcher {
    private(set) var pidsByWorkingDirectory: [String: [Int32]] = [:]

    func pids(forWorkingDirectory workingDirectory: String) -> [Int32] {
        pidsByWorkingDirectory[workingDirectory] ?? []
    }

    func refresh() async {
        let pids = await Self.runningClaudePIDs()
        var mapping: [String: [Int32]] = [:]
        for pid in pids {
            guard let cwd = await Self.workingDirectory(ofPID: pid) else { continue }
            mapping[cwd, default: []].append(pid)
        }
        pidsByWorkingDirectory = mapping
    }

    private static func runningClaudePIDs() async -> [Int32] {
        guard let data = await run("/usr/bin/pgrep", ["-x", "claude"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { Int32($0) }
    }

    private static func workingDirectory(ofPID pid: Int32) async -> String? {
        guard let data = await run("/usr/sbin/lsof", ["-p", "\(pid)", "-a", "-d", "cwd", "-Fn"]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // `-Fn` field output: the line holding the path is prefixed with "n".
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> Data? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
            return data.isEmpty ? nil : data
        }.value
    }
}
