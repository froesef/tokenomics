import AppKit
import Foundation

enum GhosttyError: Error {
    case unavailable
    case scriptFailed(String)
}

/// Focuses (and optionally pastes into) a Ghostty tab by working directory, using Ghostty's *real*
/// AppleScript dictionary — read directly from `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`
/// on this machine rather than trusted from spec.md's summary. spec.md §8 described only `working
/// directory`, `title`, an id, and `focus`; the actual .sdef also has a full `window > tab > terminal`
/// hierarchy and, notably, `input text "..." to terminal` — "Input text to a terminal as if it was
/// pasted." That command is what makes `pasteText` possible without System Events keystroke injection or
/// an Accessibility permission: it's a first-class scripting command gated by the same Automation
/// permission as `focus`, and "as if pasted" means it never sends Return on its own.
///
/// All AppleScript strings live in this one file on purpose: Ghostty's scripting dictionary is a preview
/// as of 1.3 and the maintainers expect it to change in 1.4, so a future break should be a one-file fix.
///
/// Every `NSAppleScript.executeAndReturnError` call below runs inside `Task.detached`, never directly on
/// the main actor. This isn't optional polish: `tell application "Ghostty"` dispatches a real Apple
/// Event and, while waiting for the reply, re-enters the run loop (visible in a crash log as
/// `AEDefaultActiveProc` / `UASRemoteSend` on the main thread). If that happens while SwiftUI's
/// AttributeGraph is mid-transaction — which it was here, because `isAvailable` used to run the script
/// synchronously and got read straight from a View's `body` — the reentrant run-loop pump corrupts the
/// graph and the process aborts (`AG::Graph::value_set` precondition failure). Caught by actually running
/// the built app: the dropdown appeared empty and the process died a few seconds later. `isAvailable` and
/// `hasOpenTab` are now plain cached reads; only `refreshAvailability()`, `focusTab()`, and `pasteText()`
/// touch AppleScript, and all three do it off the main thread.
///
/// Gated by macOS Automation (TCC) permission. `isAvailable` is false whenever Ghostty isn't running or
/// automation isn't authorized yet; callers must hide/disable focus controls rather than surface errors.
@MainActor
final class GhosttyController: TerminalController {
    private var cachedAvailability = false
    private var cachedWorkingDirectories: Set<String> = []
    /// Working directory -> every currently-open terminal's title at that exact directory, refreshed
    /// alongside `cachedWorkingDirectories` in the same poll/AppleScript round-trip. Backs
    /// `hasPlausibleExactOpenTab` — see its doc comment on `TerminalController` for why title, not just
    /// cwd, matters when picking *which app* actually has the real matching terminal.
    private var cachedTerminalTitles: [String: [String]] = [:]
    private var lastActiveAt: [String: Date] = [:]
    /// `Session.id` -> the Ghostty-assigned `id` (a stable per-terminal-surface string; see Ghostty.sdef,
    /// `<property name="id" code="ID  ">` on the `terminal` class) of the terminal surface last matched to
    /// that session. Populated the first time `runMatchAndAct` resolves a session by working-directory/
    /// title-hint search; every subsequent call tries this id directly first (`terminal id "X"`), which is
    /// unambiguous and immune to a *new* tab later opening at the same working directory (the bug that
    /// motivated this cache: opening a 3rd tab for a session in a repo already open in tab 1 used to focus
    /// tab 1, because cwd+title matching can't tell two same-directory tabs apart until Claude Code's
    /// `ai-title` event gives the new tab a distinct title). Cleared for a session whenever an id lookup
    /// comes back empty (the cached terminal closed), so the next call re-resolves from scratch.
    private var resolvedTerminalIds: [String: String] = [:]

    let displayName = "Ghostty"

    var isAvailable: Bool { cachedAvailability }

    func hasOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
            || cachedWorkingDirectories.contains { $0.hasPrefix(workingDirectory) || workingDirectory.hasPrefix($0) }
    }

    func hasExactOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
    }

    func hasPlausibleExactOpenTab(workingDirectory: String, aiTitle: String?) -> Bool {
        guard let titles = cachedTerminalTitles[workingDirectory], !titles.isEmpty else { return false }
        if let aiTitle, !aiTitle.isEmpty {
            return titles.contains { $0.contains(aiTitle) }
        }
        return titles.contains { !($0.hasPrefix("/") || $0.hasPrefix("~") || $0.hasPrefix("…")) }
    }

    func timeSinceLastActive(workingDirectory: String) -> TimeInterval? {
        guard let date = lastActiveAt[workingDirectory] else { return nil }
        return Date().timeIntervalSince(date)
    }

    func refreshAvailability() async {
        guard Self.isGhosttyRunning() else {
            cachedAvailability = false
            cachedWorkingDirectories = []
            cachedTerminalTitles = [:]
            return
        }
        let authorized = await Self.probeAutomationAuthorized()
        cachedAvailability = authorized
        guard authorized else {
            cachedWorkingDirectories = []
            cachedTerminalTitles = [:]
            return
        }
        let entries = await Self.fetchTerminalEntries()
        cachedWorkingDirectories = Set(entries.map(\.workingDirectory))
        cachedTerminalTitles = Dictionary(grouping: entries, by: \.workingDirectory)
            .mapValues { $0.map(\.title) }

        // Ghostty being frontmost is a plain NSWorkspace read (no AppleScript, no reentrancy risk) — only
        // bother asking *which* terminal is focused when that's actually true.
        if Self.isGhosttyFrontmost(), let focused = await Self.fetchFocusedTerminalWorkingDirectory() {
            lastActiveAt[focused] = Date()
        }
    }

    private static func isGhosttyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.mitchellh.ghostty" }
    }

    private static func isGhosttyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty"
    }

    /// The one terminal the user is actually looking at right now, if any — Ghostty's frontmost window's
    /// selected tab's focused terminal. Distinct from `fetchTerminalEntries`, which lists every
    /// open terminal regardless of focus.
    private static func fetchFocusedTerminalWorkingDirectory() async -> String? {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "Ghostty"
                set ft to focused terminal of (selected tab of front window)
                return (working directory of ft as text)
            end tell
            """
            var errorDict: NSDictionary?
            guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&errorDict),
                  errorDict == nil else { return nil }
            return descriptor.stringValue
        }.value
    }

    /// A harmless probe: if Automation isn't authorized yet, AppleScript raises -1743 (not authorized)
    /// or a similar error rather than returning a count. Treat any error as "unavailable" instead of
    /// crashing or repeatedly prompting.
    private static func probeAutomationAuthorized() async -> Bool {
        await Task.detached(priority: .utility) {
            let script = "tell application \"Ghostty\" to count windows"
            var errorDict: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
            return errorDict == nil && result != nil
        }.value
    }

    /// Lists every open terminal's working directory and title in one round trip, so per-session matching
    /// (`hasOpenTab`, `hasPlausibleExactOpenTab`) is a local lookup instead of one AppleScript call per
    /// session. Dir and title are joined with U+001F (Unit Separator) — a character that can't come from
    /// either a real path or a Ghostty-rendered title — so a single flat string list survives the
    /// NSAppleEventDescriptor round trip without needing to parse nested AppleScript records.
    private static func fetchTerminalEntries() async -> [(workingDirectory: String, title: String)] {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "Ghostty"
                set entries to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with term in terminals of t
                            try
                                set end of entries to ((working directory of term as text) & (ASCII character 31) & (name of term as text))
                            end try
                        end repeat
                    end repeat
                end repeat
                return entries
            end tell
            """
            var errorDict: NSDictionary?
            guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&errorDict),
                  errorDict == nil else { return [] }
            return Self.stringList(from: descriptor).compactMap { line in
                let parts = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (workingDirectory: String(parts[0]), title: String(parts[1]))
            }
        }.value
    }

    private nonisolated static func stringList(from descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.numberOfItems > 0 else {
            if let single = descriptor.stringValue { return [single] }
            return []
        }
        var result: [String] = []
        for i in 1...descriptor.numberOfItems {
            if let item = descriptor.atIndex(i), let value = item.stringValue {
                result.append(value)
            }
        }
        return result
    }

    /// AppleScript string-literal escaping shared by every script below: backslashes first, then quotes.
    private nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The shared "find the matching terminal" fragment: match exact working directory first (after
    /// trimming a trailing slash from both sides, since Claude Code's recorded `cwd` and Ghostty's live
    /// `working directory` don't always agree on one), then fall back to the same bidirectional,
    /// path-boundary-aware prefix check `hasOpenTab` uses in Swift — never a raw substring `contains`.
    ///
    /// A raw `contains` was the original bug (see git history): with two splits in one tab, one at a repo
    /// root and one `cd`'d into a subdirectory (or worktree) of it — this project's own layout — `contains`
    /// only ever tested "terminal dir contains target dir", so any exact-match miss (e.g. a trailing-slash
    /// mismatch) fell through to matching whichever split's directory happened to *start with* the target
    /// path, even when that was the wrong split.
    ///
    /// A second, distinct ambiguity survives even with an exact directory match: two splits can share the
    /// literal same working directory — one running the Claude Code session, the other a plain idle shell
    /// sitting at the same path. Directory alone can't tell those apart, so two title-based signals are
    /// tried in order:
    ///
    /// 1. `titleHint` (the session's `aiTitle`), when non-empty: prefer whichever exact-directory match's
    ///    title contains it.
    /// 2. When that doesn't resolve it (`aiTitle` not generated yet, common right after opening a
    ///    brand-new tab/split): prefer a match whose title does NOT look like a plain working-directory
    ///    path. Confirmed live against a running Ghostty with several same-cwd split pairs: the split
    ///    actually running Claude Code always carries one of its status-icon title prefixes (`✳`, `◐`,
    ///    etc. — Claude Code's own terminal-title protocol), while an idle shell twin's title is always
    ///    just Ghostty's default abbreviated-path fallback, which starts with `/`, `~`, or the truncation
    ///    ellipsis `…`. That's a signal present on essentially every idle-twin case, unlike `aiTitle`
    ///    substring matching, which only helps once Claude Code has actually generated a title.
    ///
    /// Only when *neither* signal resolves it does this fall back to "most recently enumerated exact
    /// match" — enumeration order tracks creation order, so the newest tab/split wins over the oldest one
    /// sharing that same working directory, which is still a better guess than the first one seen.
    /// Leaves the result in `targetTerminal` (missing value if none found). Assumes it's inlined inside a
    /// `tell application "Ghostty" ... end tell` block.
    private nonisolated static func findTerminalScript(escapedWorkingDirectory dir: String, escapedTitleHint hint: String) -> String {
        """
        set targetDir to "\(dir)"
        if targetDir ends with "/" and (length of targetDir) > 1 then
            set targetDir to text 1 thru -2 of targetDir
        end if
        set titleHint to "\(hint)"
        set targetTerminal to missing value
        set nonPathTerminal to missing value
        set fallbackTerminal to missing value
        repeat with w in windows
            repeat with t in tabs of w
                repeat with term in terminals of t
                    try
                        set termDir to (working directory of term as text)
                        if termDir ends with "/" and (length of termDir) > 1 then
                            set termDir to text 1 thru -2 of termDir
                        end if
                        if termDir is targetDir then
                            set fallbackTerminal to term
                            try
                                set termTitle to (name of term as text)
                                if titleHint is not "" and targetTerminal is missing value and termTitle contains titleHint then
                                    set targetTerminal to term
                                end if
                                if not (termTitle starts with "/" or termTitle starts with "~" or termTitle starts with "…") then
                                    set nonPathTerminal to term
                                end if
                            end try
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        if targetTerminal is missing value then set targetTerminal to nonPathTerminal
        if targetTerminal is missing value then set targetTerminal to fallbackTerminal
        if targetTerminal is missing value then
            -- No exact-cwd match at all (a stale/symlink/trailing mismatch between the session's recorded
            -- cwd and Ghostty's live one) — search ancestor/descendant matches instead. Same tie-break
            -- priority as the exact-match pass above (title hint, then non-path-looking title), scanning
            -- every candidate rather than stopping at the first one found, so this fallback isn't blind to
            -- the same same-cwd-family split ambiguity the exact-match pass already handles.
            set prefixTitleMatch to missing value
            set prefixNonPath to missing value
            set prefixFirst to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        try
                            set termDir to (working directory of term as text)
                            if termDir ends with "/" and (length of termDir) > 1 then
                                set termDir to text 1 thru -2 of termDir
                            end if
                            if termDir starts with (targetDir & "/") or targetDir starts with (termDir & "/") then
                                if prefixFirst is missing value then set prefixFirst to term
                                try
                                    set termTitle to (name of term as text)
                                    if titleHint is not "" and prefixTitleMatch is missing value and termTitle contains titleHint then
                                        set prefixTitleMatch to term
                                    end if
                                    if prefixNonPath is missing value and not (termTitle starts with "/" or termTitle starts with "~" or termTitle starts with "…") then
                                        set prefixNonPath to term
                                    end if
                                end try
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            if prefixTitleMatch is not missing value then
                set targetTerminal to prefixTitleMatch
            else if prefixNonPath is not missing value then
                set targetTerminal to prefixNonPath
            else
                set targetTerminal to prefixFirst
            end if
        end if
        """
    }

    /// Runs a script that first tries `cachedTerminalId` (if any) via `terminal id "..."` — a direct,
    /// unambiguous lookup by Ghostty's own stable id — and only falls back to `findTerminalScript`'s cwd/
    /// title search when there's no cached id or the cached one no longer resolves (terminal closed).
    /// `bodyIfFound` is the AppleScript run once a terminal is found (e.g. `focus targetTerminal`),
    /// inserted inside the `tell` block. When `activate` is true (the default), `activate application
    /// "Ghostty"` runs afterward so the window is actually visible once found (spec.md §8) — callers that
    /// need to stay quiet in the background (the unattended keep-alive ping) pass `activate: false` so the
    /// user's current window/app keeps focus.
    ///
    /// Returns the resolved terminal's own id alongside any AppleScript error, so callers can update
    /// `resolvedTerminalIds` — nil id means either an error occurred or no terminal matched at all (a
    /// stale/closed cached id should be dropped in that case, not kept around to fail the same way again).
    private static func runMatchAndAct(cachedTerminalId: String?, workingDirectory: String, aiTitle: String?, bodyIfFound: String, activate: Bool = true) async -> (resolvedId: String?, error: String?) {
        let dir = Self.escape(workingDirectory)
        let hint = Self.escape(aiTitle ?? "")
        let cachedId = Self.escape(cachedTerminalId ?? "")
        let activateLine = activate ? "if targetTerminal is not missing value then activate application \"Ghostty\"" : ""
        let script = """
        tell application "Ghostty"
            set targetTerminal to missing value
            if "\(cachedId)" is not "" then
                try
                    set targetTerminal to terminal id "\(cachedId)"
                end try
            end if
            if targetTerminal is missing value then
                \(Self.findTerminalScript(escapedWorkingDirectory: dir, escapedTitleHint: hint))
            end if
            if targetTerminal is not missing value then
                \(bodyIfFound)
            end if
        end tell
        set resultId to ""
        if targetTerminal is not missing value then
            tell application "Ghostty"
                try
                    set resultId to (id of targetTerminal) as text
                end try
            end tell
        end if
        \(activateLine)
        resultId
        """
        return await Task.detached(priority: .utility) {
            var errorDict: NSDictionary?
            let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
            guard errorDict == nil else { return (nil, errorDict?.description) }
            let resolvedId = descriptor?.stringValue
            return (resolvedId?.isEmpty == false ? resolvedId : nil, nil)
        }.value
    }

    /// Updates (or clears) `resolvedTerminalIds[sessionId]` after a match attempt, so the next call for
    /// this session tries the resolved id directly instead of re-running the cwd/title search.
    private func rememberResolvedId(_ resolvedId: String?, for sessionId: String) {
        if let resolvedId {
            resolvedTerminalIds[sessionId] = resolvedId
        } else {
            resolvedTerminalIds.removeValue(forKey: sessionId)
        }
    }

    func focusTab(sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw GhosttyError.unavailable }
        let (resolvedId, error) = await Self.runMatchAndAct(cachedTerminalId: resolvedTerminalIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: "focus targetTerminal")
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw GhosttyError.scriptFailed(error)
        }
    }

    func pasteText(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws {
        guard isAvailable else { throw GhosttyError.unavailable }
        let escapedText = Self.escape(text)
        // `focus targetTerminal` only selects the tab within Ghostty's own window(s); it doesn't bring the
        // app forward on its own, so it's safe to keep even when `activate` is false — the terminal ends
        // up showing the pasted text whenever the user does switch to Ghostty, without this call stealing
        // focus from whatever window they're on right now.
        let body = """
        focus targetTerminal
        input text "\(escapedText)" to targetTerminal
        """
        let (resolvedId, error) = await Self.runMatchAndAct(cachedTerminalId: resolvedTerminalIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: activate)
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw GhosttyError.scriptFailed(error)
        }
    }

    /// `send key "enter"` is Ghostty's own scripting command (from the same .sdef as `input text` /
    /// `focus`) for a real keyboard event, gated by the same Automation permission — not a System Events
    /// keystroke-injection workaround, which would need a separate Accessibility grant.
    ///
    /// Deliberately skips both `focus targetTerminal` and `activate application "Ghostty"`: `input text`
    /// and `send key` both take `targetTerminal` explicitly, so neither needs the terminal selected or the
    /// app frontmost to work. This is the unattended path (see the protocol doc comment above) — it should
    /// never steal focus from whatever window/app the user is actually looking at.
    func pasteTextAndSubmit(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw GhosttyError.unavailable }
        let escapedText = Self.escape(text)
        let body = """
        input text "\(escapedText)" to targetTerminal
        send key "enter" to targetTerminal
        """
        let (resolvedId, error) = await Self.runMatchAndAct(cachedTerminalId: resolvedTerminalIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: false)
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw GhosttyError.scriptFailed(error)
        }
    }
}
