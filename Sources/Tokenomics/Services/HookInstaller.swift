import Foundation

/// Adds/removes the Claude Code hook entries that feed HookActivityWatcher, in `~/.claude/settings.json`.
///
/// This is a second, more invasive exception to spec.md §0 ("do not hook into the live Claude Code
/// process") — on top of ProcessMatcher's read-only PID lookup, this one actually *writes* to a config
/// file every Claude Code session on the machine reads, at the user's explicit request (a Settings toggle,
/// not something done silently on launch). Kept as narrow and reversible as possible:
///
/// - Every hook entry this installs runs the exact same shell command (`hookCommand`, below) regardless of
///   which event/matcher fired it — the command just appends whatever JSON Claude Code piped to its stdin
///   onto a log file, tagged with our own timestamp. `HookActivityWatcher` recovers *which* event fired
///   from the JSON payload's own `hook_event_name` field, so there's nothing event-specific to hardcode
///   here beyond the (event, matcher) pairs to register it under.
/// - Because the command string is identical everywhere, uninstall is exact-match-and-remove: find every
///   hook object anywhere in the tree whose `command` equals `hookCommand`, drop it, then drop any matcher
///   group or event array that's now empty. Every *other* hook the user already had configured (confirmed
///   against a real machine: this one had `SessionStart`/`PreToolUse` entries for unrelated tools already)
///   is left byte-for-byte alone in content, though the file as a whole is still re-serialized (see below).
/// - A timestamped backup is written next to the settings file before every install/uninstall, since
///   `JSONSerialization` round-trips the whole document (sorted keys, pretty-printed) rather than doing a
///   surgical text edit — the safest correctness trade-off available without a JSON-with-comments/formatting
///   preserving parser, but it does mean the file's overall formatting changes even though its content
///   doesn't. The backup makes that reversible by hand if the reformat itself is unwanted.
@MainActor
enum HookInstaller {
    /// Where HookActivityWatcher reads from — see its doc comment for the line format.
    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude").appendingPathComponent("tokenomics")
    static let logFile = logDirectory.appendingPathComponent("hook-events.jsonl")

    /// Overridable only so tests can point at a throwaway file instead of the real, shared
    /// `~/.claude/settings.json` — every call site in the app uses the default.
    static let defaultSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude").appendingPathComponent("settings.json")

    /// Absolute paths baked in at build/run time rather than left as `$HOME` for the hook's own shell to
    /// expand — cheap insurance against a hook execution environment (e.g. an Agent-SDK-driven session)
    /// that doesn't inherit a normal interactive shell's env. `mkdir -p` makes this safe to run before the
    /// directory exists (first hook fire after install); `printf` (not `echo`) sidesteps shells whose
    /// builtin `echo` interprets backslashes differently.
    static var hookCommand: String {
        "mkdir -p '\(logDirectory.path)' && "
            + "printf '{\"tokenomics_ts\":%s,\"payload\":%s}\\n' \"$(date +%s)\" \"$(cat)\" >> '\(logFile.path)'"
    }

    /// (event name, matcher) pairs the command is registered under. No matcher means "fire for every
    /// variant of this event" (Claude Code's own convention — confirmed in the hooks reference for events
    /// like `Stop`/`UserPromptSubmit` that don't support matchers at all, and by omission for events that
    /// do). `PreCompact`/`PostCompact`'s manual-vs-auto and `SessionStart`'s startup/resume/clear/compact/
    /// fork variants all map to the same activity state on our side (see HookActivityWatcher), so neither
    /// needs splitting by matcher — only `Notification` does, since only some of its subtypes mean "needs
    /// a human," and there's no confirmed payload field to tell them apart after the fact.
    ///
    /// `PostCompact` closes the `.compacting` state `PreCompact` opens — the direct hooks equivalent of
    /// the JSONL heuristic's `compact_boundary` (confirmed as a regular command-type hook, not an
    /// SDK-only callback, against the official hooks reference). `SessionStart`'s `compact` matcher
    /// variant (already covered by the no-matcher registration above) fires around the same time as a
    /// secondary signal, so compaction ending is doubly covered.
    ///
    /// `PermissionRequest` fires when a tool call needs a permission decision — a more direct "needs a
    /// human" signal than inferring it from `Notification`'s `permission_prompt` variant, which the hooks
    /// reference notes fires only after a several-second delay.
    static let hookSlots: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PermissionRequest", "*"),
        ("Stop", nil),
        ("PreCompact", nil),
        ("PostCompact", nil),
        ("Notification", "permission_prompt"),
        ("Notification", "agent_needs_input"),
        ("Notification", "elicitation_dialog"),
        ("Notification", "elicitation_url_dialog"),
        ("SessionEnd", nil)
    ]

    enum InstallError: Error, LocalizedError {
        case malformedSettings

        var errorDescription: String? {
            switch self {
            case .malformedSettings:
                return "~/.claude/settings.json exists but isn't a JSON object — refusing to overwrite it."
            }
        }
    }

    /// Adds our hook entries (idempotent: safe to call when already installed — matching entries aren't
    /// duplicated). Creates `~/.claude/settings.json` if it doesn't exist yet. Doesn't create
    /// `logDirectory` itself — deliberately, so this function (and its tests) never touch anything under
    /// the real `~/.claude` besides `settingsURL`. `HookActivityWatcher.startWatching()` creates it (needed
    /// there regardless of mode, to watch a directory that exists), and the hook command's own `mkdir -p`
    /// covers the case where a hook fires before the app has run at all this session.
    static func install(settingsURL: URL = defaultSettingsURL) throws {
        let root = try readSettings(from: settingsURL)
        try backupAndWrite(applyingHooks(to: root), to: settingsURL)
    }

    /// Removes every hook object whose command matches ours, then prunes matcher groups and event arrays
    /// left empty by that removal. Leaves the file alone entirely if we were never installed (no backup
    /// written, no-op) — nothing to make reversible when nothing changed.
    static func uninstall(settingsURL: URL = defaultSettingsURL) throws {
        let root = try readSettings(from: settingsURL)
        let (updated, changed) = removingHooks(from: root)
        guard changed else { return }
        try backupAndWrite(updated, to: settingsURL)
    }

    /// Pure transform: adds any of `hookSlots` not already present under `root["hooks"]`. Split out from
    /// `install()` so it's testable without touching any real file — the only thing that needs a temp
    /// directory is the read/write round trip, not this merge logic.
    static func applyingHooks(to root: [String: Any]) -> [String: Any] {
        var root = root
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for slot in hookSlots {
            var groups = (hooks[slot.event] as? [[String: Any]]) ?? []
            let alreadyPresent = groups.contains { group in
                matcher(of: group) == slot.matcher && containsOurCommand(group)
            }
            if !alreadyPresent {
                var group: [String: Any] = ["hooks": [["type": "command", "command": hookCommand]]]
                if let matcher = slot.matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[slot.event] = groups
        }

        root["hooks"] = hooks
        return root
    }

    /// Pure transform, mirroring `applyingHooks(to:)` above: strips every hook object whose command
    /// matches ours, then prunes matcher groups and event arrays left empty by that removal. `changed`
    /// tells the caller whether anything was actually there to remove.
    static func removingHooks(from root: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return (root, false) }
        var changed = false

        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            let before = groups.count
            groups = groups.compactMap { group -> [String: Any]? in
                guard var inner = group["hooks"] as? [[String: Any]] else { return group }
                let innerBefore = inner.count
                inner.removeAll { ($0["type"] as? String) == "command" && ($0["command"] as? String) == hookCommand }
                if inner.count != innerBefore { changed = true }
                guard !inner.isEmpty else { return nil }
                var updated = group
                updated["hooks"] = inner
                return updated
            }
            if groups.count != before { changed = true }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        guard changed else { return (root, false) }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return (root, true)
    }

    /// Whether every one of our hook slots is currently present — used by SettingsView to show install
    /// state without re-deriving it from `SettingsStore.activitySource` alone (which only reflects intent,
    /// not whether the write actually landed).
    static func isInstalled(settingsURL: URL = defaultSettingsURL) -> Bool {
        guard let root = try? readSettings(from: settingsURL), let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return hookSlots.allSatisfy { slot in
            guard let groups = hooks[slot.event] as? [[String: Any]] else { return false }
            return groups.contains { matcher(of: $0) == slot.matcher && containsOurCommand($0) }
        }
    }

    private static func matcher(of group: [String: Any]) -> String? { group["matcher"] as? String }

    private static func containsOurCommand(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["type"] as? String) == "command" && ($0["command"] as? String) == hookCommand }
    }

    private static func readSettings(from settingsURL: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedSettings
        }
        return object
    }

    /// Timestamped backup, then an atomic write (temp file + rename) so a crash mid-write can never leave
    /// `settings.json` half-written — every other Claude Code session on the machine reads this file too.
    private static func backupAndWrite(_ root: [String: Any], to settingsURL: URL) throws {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupURL = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.tokenomics-backup-\(stamp)")
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        } else {
            try? FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tempURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(".tokenomics-settings-\(UUID().uuidString).tmp")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tempURL)
    }
}
