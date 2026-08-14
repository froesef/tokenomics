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
    private var lastActiveAt: [String: Date] = [:]

    let displayName = "iTerm2"

    var isAvailable: Bool { cachedAvailability }

    func hasOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
            || cachedWorkingDirectories.contains { $0.hasPrefix(workingDirectory) || workingDirectory.hasPrefix($0) }
    }

    func hasExactOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
    }

    func timeSinceLastActive(workingDirectory: String) -> TimeInterval? {
        guard let date = lastActiveAt[workingDirectory] else { return nil }
        return Date().timeIntervalSince(date)
    }

    func refreshAvailability() async {
        guard Self.isITermRunning() else {
            cachedAvailability = false
            cachedWorkingDirectories = []
            return
        }
        let authorized = await Self.probeAutomationAuthorized()
        cachedAvailability = authorized
        guard authorized else {
            cachedWorkingDirectories = []
            return
        }
        cachedWorkingDirectories = Set(await Self.fetchSessionWorkingDirectories())

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
    /// current tab's current session. Distinct from `fetchSessionWorkingDirectories`, which lists every
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

    /// Lists every open session's working directory in one round trip, so per-session matching
    /// (`hasOpenTab`) is a local Set lookup instead of one AppleScript call per session.
    private static func fetchSessionWorkingDirectories() async -> [String] {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "iTerm2"
                set dirs to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                set end of dirs to ((variable named "session.path") of s)
                            end try
                        end repeat
                    end repeat
                end repeat
                return dirs
            end tell
            """
            var errorDict: NSDictionary?
            guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&errorDict),
                  errorDict == nil else { return [] }
            return Self.stringList(from: descriptor)
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
    /// `GhosttyController.findTerminalScript` (exact directory match preferred, title-hint tiebreak among
    /// exact matches, prefix fallback), adapted to iTerm2's `session.path` variable and `name of session`.
    /// Leaves the result in `targetSession` (missing value if none found). Assumes it's inlined inside a
    /// `tell application "iTerm2" ... end tell` block.
    private nonisolated static func findSessionScript(escapedWorkingDirectory dir: String, escapedTitleHint hint: String) -> String {
        """
        set targetDir to "\(dir)"
        if targetDir ends with "/" and (length of targetDir) > 1 then
            set targetDir to text 1 thru -2 of targetDir
        end if
        set titleHint to "\(hint)"
        set targetSession to missing value
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
                            if fallbackSession is missing value then set fallbackSession to s
                            if titleHint is not "" and targetSession is missing value then
                                try
                                    if (name of s as text) contains titleHint then set targetSession to s
                                end try
                            end if
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        if targetSession is missing value then set targetSession to fallbackSession
        if targetSession is missing value then
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set sessDir to ((variable named "session.path") of s)
                            if sessDir ends with "/" and (length of sessDir) > 1 then
                                set sessDir to text 1 thru -2 of sessDir
                            end if
                            if sessDir starts with (targetDir & "/") or targetDir starts with (sessDir & "/") then
                                set targetSession to s
                                exit repeat
                            end if
                        end try
                    end repeat
                    if targetSession is not missing value then exit repeat
                end repeat
                if targetSession is not missing value then exit repeat
            end repeat
        end if
        """
    }

    /// Runs a script built around `findSessionScript`, returning the AppleScript error description (if
    /// any). `bodyIfFound` is the AppleScript run when a match exists (e.g. `tell targetSession to select`),
    /// inserted inside the `tell` block. When `activate` is true (the default), `activate application
    /// "iTerm2"` runs afterward so the window is actually visible once found — callers that need to stay
    /// quiet in the background (the unattended keep-alive ping) pass `activate: false`.
    private static func runMatchAndAct(workingDirectory: String, aiTitle: String?, bodyIfFound: String, activate: Bool = true) async -> String? {
        let dir = Self.escape(workingDirectory)
        let hint = Self.escape(aiTitle ?? "")
        let activateLine = activate ? "if targetSession is not missing value then activate application \"iTerm2\"" : ""
        let script = """
        tell application "iTerm2"
            \(Self.findSessionScript(escapedWorkingDirectory: dir, escapedTitleHint: hint))
            if targetSession is not missing value then
                \(bodyIfFound)
            end if
        end tell
        \(activateLine)
        """
        return await Task.detached(priority: .utility) {
            var errorDict: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
            return errorDict?.description
        }.value
    }

    func focusTab(workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw ITermError.unavailable }
        if let error = await Self.runMatchAndAct(workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: "tell targetSession to select") {
            throw ITermError.scriptFailed(error)
        }
    }

    func pasteText(_ text: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws {
        guard isAvailable else { throw ITermError.unavailable }
        let escapedText = Self.escape(text)
        // `select` only selects the session within iTerm2's own window(s); it doesn't bring the app
        // forward on its own, so it's safe to keep even when `activate` is false.
        let body = """
        tell targetSession to select
        tell targetSession to write text "\(escapedText)" newline no
        """
        if let error = await Self.runMatchAndAct(workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: activate) {
            throw ITermError.scriptFailed(error)
        }
    }

    /// Deliberately skips both `select` and `activate application "iTerm2"` — this is the unattended path
    /// (see the protocol doc comment on `TerminalController.pasteTextAndSubmit`), it should never steal
    /// focus from whatever window/app the user is actually looking at. `write text` defaults to `newline
    /// yes`, which is iTerm2's own way of pressing Return after the text — no separate key-event command
    /// needed, unlike Ghostty's `send key "enter"`.
    func pasteTextAndSubmit(_ text: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw ITermError.unavailable }
        let escapedText = Self.escape(text)
        let body = "tell targetSession to write text \"\(escapedText)\""
        if let error = await Self.runMatchAndAct(workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: false) {
            throw ITermError.scriptFailed(error)
        }
    }
}
