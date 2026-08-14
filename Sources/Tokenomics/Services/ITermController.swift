import AppKit
import Foundation

enum ITermError: Error {
    case unavailable
    case scriptFailed(String)
}

/// Focuses (and optionally pastes into) an iTerm2 session by working directory, using iTerm2's own
/// AppleScript scripting dictionary — a different object model from Ghostty's (`window > tab > session`,
/// not `window > tab > terminal`), and a different working-directory API: iTerm2 has no `working directory`
/// property, it exposes the session's cwd as a session *variable*: `(variable named "session.path") of s`
/// — note the parens around the command itself; `(variable named "session.path" of s)` (i.e. `of s` inside
/// the parens) raises -1723 "Access not allowed", verified live against a running iTerm2.
/// Focusing a session is `select`, not `focus`; submitting text is the `write text` command, whose
/// `newline` parameter (default true, i.e. it presses Return) doubles as both `pasteText` (`newline no`)
/// and `pasteTextAndSubmit` (default) — Ghostty needed a separate `send key "enter"` for the same job.
///
/// All AppleScript strings live in this one file, same reasoning as `GhosttyController`: each terminal's
/// scripting dictionary is that terminal's own concern, isolated so a future API change is a one-file fix.
///
/// Every `NSAppleScript.executeAndReturnError` call below runs inside `Task.detached`, never directly on
/// the main actor — see the deviation note on `GhosttyController` for why a synchronous Apple Event on the
/// main thread while SwiftUI is mid-transaction corrupts AttributeGraph and aborts the process. `isAvailable`
/// and `hasOpenTab` are plain cached reads; only `refreshAvailability()`, `focusTab()`, and `pasteText()`
/// touch AppleScript, and all three do it off the main thread.
///
/// Gated by macOS Automation (TCC) permission, same as Ghostty. `isAvailable` is false whenever iTerm2
/// isn't running or automation isn't authorized yet; callers must hide/disable focus controls rather than
/// surface errors.
@MainActor
final class ITermController: TerminalController {
    private var cachedAvailability = false
    private var cachedWorkingDirectories: Set<String> = []
    /// Working directory -> every currently-open session's title at that exact directory — see
    /// `GhosttyController.cachedTerminalTitles`. Backs `hasPlausibleExactOpenTab`.
    private var cachedSessionTitles: [String: [String]] = [:]
    private var lastActiveAt: [String: Date] = [:]
    /// `Session.id` -> the iTerm2-assigned session guid (`<property name="id" ... cocoa key="guid">` on the
    /// `session` class) last matched to that session. Same reasoning as `GhosttyController.resolvedTerminalIds`
    /// — once resolved, target the exact session by id instead of re-running the cwd/title search, which
    /// can't tell two same-cwd sessions apart until `aiTitle` is set.
    private var resolvedSessionIds: [String: String] = [:]

    let displayName = "iTerm2"

    var isAvailable: Bool { cachedAvailability }

    func hasOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
            || cachedWorkingDirectories.contains { $0.hasPrefix(workingDirectory) || workingDirectory.hasPrefix($0) }
    }

    func hasExactOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
    }

    func hasPlausibleExactOpenTab(workingDirectory: String, aiTitle: String?) -> Bool {
        guard let titles = cachedSessionTitles[workingDirectory], !titles.isEmpty else { return false }
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
        guard Self.isITermRunning() else {
            cachedAvailability = false
            cachedWorkingDirectories = []
            cachedSessionTitles = [:]
            return
        }
        let authorized = await Self.probeAutomationAuthorized()
        cachedAvailability = authorized
        guard authorized else {
            cachedWorkingDirectories = []
            cachedSessionTitles = [:]
            return
        }
        let entries = await Self.fetchSessionEntries()
        cachedWorkingDirectories = Set(entries.map(\.workingDirectory))
        cachedSessionTitles = Dictionary(grouping: entries, by: \.workingDirectory)
            .mapValues { $0.map(\.title) }

        if Self.isITermFrontmost(), let focused = await Self.fetchFocusedSessionWorkingDirectory() {
            lastActiveAt[focused] = Date()
        }
    }

    private static func isITermRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
    }

    private static func isITermFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2"
    }

    /// The one session the user is actually looking at right now, if any — iTerm2's frontmost window's
    /// current tab's current session. Distinct from `fetchSessionEntries`, which lists every
    /// open session regardless of focus.
    private static func fetchFocusedSessionWorkingDirectory() async -> String? {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "iTerm2"
                set s to current session of current tab of current window
                return ((variable named "session.path") of s)
            end tell
            """
            var errorDict: NSDictionary?
            guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&errorDict),
                  errorDict == nil else { return nil }
            return descriptor.stringValue
        }.value
    }

    /// A harmless probe: if Automation isn't authorized yet, AppleScript raises an error rather than
    /// returning a count. Treat any error as "unavailable" instead of crashing or repeatedly prompting.
    private static func probeAutomationAuthorized() async -> Bool {
        await Task.detached(priority: .utility) {
            let script = "tell application \"iTerm2\" to count windows"
            var errorDict: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
            return errorDict == nil && result != nil
        }.value
    }

    /// Lists every open session's working directory and title in one round trip, so per-session matching
    /// (`hasOpenTab`, `hasPlausibleExactOpenTab`) is a local lookup instead of one AppleScript call per
    /// session — see `GhosttyController.fetchTerminalEntries` for why the two are joined with U+001F.
    private static func fetchSessionEntries() async -> [(workingDirectory: String, title: String)] {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "iTerm2"
                set entries to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                set end of entries to (((variable named "session.path") of s) & (ASCII character 31) & (name of s as text))
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

    private nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The shared "find the matching session" fragment — same matching strategy as
    /// `GhosttyController.findTerminalScript` (exact directory match preferred, then a title-hint
    /// tiebreak, then a non-path-looking-title tiebreak, then prefix fallback — see that function's doc
    /// comment for why the non-path-title check exists), adapted to iTerm2's `session.path` variable and
    /// `name of session`. Leaves the result in `targetSession` (missing value if none found). Assumes it's
    /// inlined inside a `tell application "iTerm2" ... end tell` block.
    private nonisolated static func findSessionScript(escapedWorkingDirectory dir: String, escapedTitleHint hint: String) -> String {
        """
        set targetDir to "\(dir)"
        if targetDir ends with "/" and (length of targetDir) > 1 then
            set targetDir to text 1 thru -2 of targetDir
        end if
        set titleHint to "\(hint)"
        set targetSession to missing value
        set nonPathSession to missing value
        set fallbackSession to missing value
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    try
                        set sessDir to ((variable named "session.path") of s)
                        if sessDir ends with "/" and (length of sessDir) > 1 then
                            set sessDir to text 1 thru -2 of sessDir
                        end if
                        if sessDir is targetDir then
                            set fallbackSession to s
                            try
                                set sessTitle to (name of s as text)
                                if titleHint is not "" and targetSession is missing value and sessTitle contains titleHint then
                                    set targetSession to s
                                end if
                                if not (sessTitle starts with "/" or sessTitle starts with "~" or sessTitle starts with "…") then
                                    set nonPathSession to s
                                end if
                            end try
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        if targetSession is missing value then set targetSession to nonPathSession
        if targetSession is missing value then set targetSession to fallbackSession
        if targetSession is missing value then
            -- No exact-cwd match at all — search ancestor/descendant matches instead, same tie-break
            -- priority as the exact-match pass above (title hint, then non-path-looking title), scanning
            -- every candidate rather than stopping at the first one found — see
            -- `GhosttyController.findTerminalScript`'s matching prefix-fallback comment.
            set prefixTitleMatch to missing value
            set prefixNonPath to missing value
            set prefixFirst to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set sessDir to ((variable named "session.path") of s)
                            if sessDir ends with "/" and (length of sessDir) > 1 then
                                set sessDir to text 1 thru -2 of sessDir
                            end if
                            if sessDir starts with (targetDir & "/") or targetDir starts with (sessDir & "/") then
                                if prefixFirst is missing value then set prefixFirst to s
                                try
                                    set sessTitle to (name of s as text)
                                    if titleHint is not "" and prefixTitleMatch is missing value and sessTitle contains titleHint then
                                        set prefixTitleMatch to s
                                    end if
                                    if prefixNonPath is missing value and not (sessTitle starts with "/" or sessTitle starts with "~" or sessTitle starts with "…") then
                                        set prefixNonPath to s
                                    end if
                                end try
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            if prefixTitleMatch is not missing value then
                set targetSession to prefixTitleMatch
            else if prefixNonPath is not missing value then
                set targetSession to prefixNonPath
            else
                set targetSession to prefixFirst
            end if
        end if
        """
    }

    /// Runs a script that first tries `cachedSessionId` (if any) via `session id "..."` — a direct,
    /// unambiguous lookup by iTerm2's own stable guid — and only falls back to `findSessionScript`'s cwd/
    /// title search when there's no cached id or the cached one no longer resolves (session closed).
    /// `bodyIfFound` is the AppleScript run when a match exists (e.g. `tell targetSession to select`),
    /// inserted inside the `tell` block. When `activate` is true (the default), `activate application
    /// "iTerm2"` runs afterward so the window is actually visible once found — callers that need to stay
    /// quiet in the background (the unattended keep-alive ping) pass `activate: false`.
    ///
    /// Returns the resolved session's own id alongside any AppleScript error, so callers can update
    /// `resolvedSessionIds`.
    private static func runMatchAndAct(cachedSessionId: String?, workingDirectory: String, aiTitle: String?, bodyIfFound: String, activate: Bool = true) async -> (resolvedId: String?, error: String?) {
        let dir = Self.escape(workingDirectory)
        let hint = Self.escape(aiTitle ?? "")
        let cachedId = Self.escape(cachedSessionId ?? "")
        let activateLine = activate ? "if targetSession is not missing value then activate application \"iTerm2\"" : ""
        let script = """
        tell application "iTerm2"
            set targetSession to missing value
            if "\(cachedId)" is not "" then
                try
                    set targetSession to session id "\(cachedId)"
                end try
            end if
            if targetSession is missing value then
                \(Self.findSessionScript(escapedWorkingDirectory: dir, escapedTitleHint: hint))
            end if
            if targetSession is not missing value then
                \(bodyIfFound)
            end if
        end tell
        set resultId to ""
        if targetSession is not missing value then
            tell application "iTerm2"
                try
                    set resultId to (id of targetSession) as text
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

    /// Updates (or clears) `resolvedSessionIds[sessionId]` after a match attempt — see
    /// `GhosttyController.rememberResolvedId`.
    private func rememberResolvedId(_ resolvedId: String?, for sessionId: String) {
        if let resolvedId {
            resolvedSessionIds[sessionId] = resolvedId
        } else {
            resolvedSessionIds.removeValue(forKey: sessionId)
        }
    }

    func focusTab(sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw ITermError.unavailable }
        let (resolvedId, error) = await Self.runMatchAndAct(cachedSessionId: resolvedSessionIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: "tell targetSession to select")
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw ITermError.scriptFailed(error)
        }
    }

    func pasteText(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws {
        guard isAvailable else { throw ITermError.unavailable }
        let escapedText = Self.escape(text)
        // `select` only selects the session within iTerm2's own window(s); it doesn't bring the app
        // forward on its own, so it's safe to keep even when `activate` is false.
        let body = """
        tell targetSession to select
        tell targetSession to write text "\(escapedText)" newline no
        """
        let (resolvedId, error) = await Self.runMatchAndAct(cachedSessionId: resolvedSessionIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: activate)
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw ITermError.scriptFailed(error)
        }
    }

    /// Deliberately skips both `select` and `activate application "iTerm2"` — this is the unattended path
    /// (see the protocol doc comment on `TerminalController.pasteTextAndSubmit`), it should never steal
    /// focus from whatever window/app the user is actually looking at. `write text` defaults to `newline
    /// yes`, which is iTerm2's own way of pressing Return after the text — no separate key-event command
    /// needed, unlike Ghostty's `send key "enter"`.
    func pasteTextAndSubmit(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw ITermError.unavailable }
        let escapedText = Self.escape(text)
        let body = "tell targetSession to write text \"\(escapedText)\""
        let (resolvedId, error) = await Self.runMatchAndAct(cachedSessionId: resolvedSessionIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: false)
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw ITermError.scriptFailed(error)
        }
    }
}
