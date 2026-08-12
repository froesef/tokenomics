import AppKit
import Foundation

/// Swappable terminal-focus backend so the rest of the app stays terminal-agnostic (spec.md §8). Adding
/// iTerm2 later means a new file conforming to this protocol, not a refactor of the app.
@MainActor
protocol TerminalController: AnyObject {
    /// App-level availability: Ghostty is running and Automation is authorized. Must be a cheap,
    /// non-blocking read — see `refreshAvailability()` for why.
    var isAvailable: Bool { get }
    /// Whether a terminal is currently open at (or under) this working directory. Also must be cheap and
    /// non-blocking — it's read from view bodies to decide whether a row's focus affordance is live. This
    /// is the per-session cross-reference: `isAvailable` alone only says "Ghostty is reachable at all".
    func hasOpenTab(workingDirectory: String) -> Bool
    /// Best-effort: seconds since this app last observed Ghostty's frontmost window/tab focused on this
    /// directory, sampled once per `refreshAvailability()` call — resolution is the refresh interval, not
    /// exact. Nil if never observed (e.g. just launched, or this directory's tab has never been frontmost
    /// while this app was running).
    func timeSinceLastActive(workingDirectory: String) -> TimeInterval?
    /// `aiTitle`, when non-nil, disambiguates between several terminals that all report the same working
    /// directory (e.g. one pane running the Claude Code session, a plain idle shell twin sitting at the
    /// same path in another split) — see the deviation note on `findTerminalScript`. Pass
    /// `Session.aiTitle` here whenever it's available; a caller with no session context can omit it.
    func focusTab(workingDirectory: String, aiTitle: String?) async throws
    /// Pastes text into the matching terminal — via Ghostty's native `input text ... to terminal`
    /// command, which its own dictionary describes as "as if it was pasted": it does **not** press
    /// Return. The text lands in the terminal's input line for the user to review and run themselves.
    /// Never used for anything that executes on its own — see spec.md §11 ("read-and-focus only") and
    /// the deviation note on `GhosttyController` for why this stays a manual last step.
    func pasteText(_ text: String, workingDirectory: String, aiTitle: String?) async throws
    /// Pastes text into the matching terminal, then submits it with a Return key event — unlike
    /// `pasteText`, this one *does* execute whatever was pasted, with no user step in between. This is a
    /// deliberate, narrow exception to the "read-and-focus only" rule above: used exclusively by the
    /// automatic keep-alive feature (see `KeepAliveTracker`) for its one fixed, harmless prompt, for when
    /// the user is genuinely away (a meeting, lunch) and there's no one to press Enter before the cache
    /// goes cold. No other caller in this app should use this.
    func pasteTextAndSubmit(_ text: String, workingDirectory: String, aiTitle: String?) async throws
    /// Re-probes availability and re-fetches the set of open working directories. Availability and open
    /// tabs both change while the app runs, so callers should call this periodically (the ViewModel does,
    /// on its regular refresh) rather than caching either forever.
    func refreshAvailability() async
}

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
    private var lastActiveAt: [String: Date] = [:]

    var isAvailable: Bool { cachedAvailability }

    func hasOpenTab(workingDirectory: String) -> Bool {
        cachedWorkingDirectories.contains(workingDirectory)
            || cachedWorkingDirectories.contains { $0.hasPrefix(workingDirectory) || workingDirectory.hasPrefix($0) }
    }

    func timeSinceLastActive(workingDirectory: String) -> TimeInterval? {
        guard let date = lastActiveAt[workingDirectory] else { return nil }
        return Date().timeIntervalSince(date)
    }

    func refreshAvailability() async {
        guard Self.isGhosttyRunning() else {
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
        cachedWorkingDirectories = Set(await Self.fetchTerminalWorkingDirectories())

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
    /// selected tab's focused terminal. Distinct from `fetchTerminalWorkingDirectories`, which lists every
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

    /// Lists every open terminal's working directory in one round trip, so per-session matching
    /// (`hasOpenTab`) is a local Set lookup instead of one AppleScript call per session.
    private static func fetchTerminalWorkingDirectories() async -> [String] {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "Ghostty"
                set dirs to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with term in terminals of t
                            try
                                set end of dirs to (working directory of term as text)
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
    /// sitting at the same path (confirmed live: a real tab here had two terminals both reporting the same
    /// `cwd`, one whose Ghostty-visible title was still the ai-generated session title from `ai-title`
    /// events, `name of term`, and the other showing the default abbreviated-path title Ghostty falls back
    /// to at an idle shell prompt). Directory alone can't tell those apart. When `titleHint` (the session's
    /// `aiTitle`) is non-empty, prefer whichever exact-directory match's title contains it; only fall back
    /// to "first exact match found" when no terminal's title matches (e.g. `aiTitle` not generated yet).
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
                            if fallbackTerminal is missing value then set fallbackTerminal to term
                            if titleHint is not "" and targetTerminal is missing value then
                                try
                                    if (name of term as text) contains titleHint then set targetTerminal to term
                                end try
                            end if
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        if targetTerminal is missing value then set targetTerminal to fallbackTerminal
        if targetTerminal is missing value then
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        try
                            set termDir to (working directory of term as text)
                            if termDir ends with "/" and (length of termDir) > 1 then
                                set termDir to text 1 thru -2 of termDir
                            end if
                            if termDir starts with (targetDir & "/") or targetDir starts with (termDir & "/") then
                                set targetTerminal to term
                                exit repeat
                            end if
                        end try
                    end repeat
                    if targetTerminal is not missing value then exit repeat
                end repeat
                if targetTerminal is not missing value then exit repeat
            end repeat
        end if
        """
    }

    /// Runs a script built around `findTerminalScript`, returning the AppleScript error description (if
    /// any). `bodyIfFound` is the AppleScript run when a match exists (e.g. `focus targetTerminal`),
    /// inserted inside the `tell` block; `activate application "Ghostty"` always runs afterward so the
    /// window is actually visible once found (spec.md §8).
    private static func runMatchAndAct(workingDirectory: String, aiTitle: String?, bodyIfFound: String) async -> String? {
        let dir = Self.escape(workingDirectory)
        let hint = Self.escape(aiTitle ?? "")
        let script = """
        tell application "Ghostty"
            \(Self.findTerminalScript(escapedWorkingDirectory: dir, escapedTitleHint: hint))
            if targetTerminal is not missing value then
                \(bodyIfFound)
            end if
        end tell
        if targetTerminal is not missing value then activate application "Ghostty"
        """
        return await Task.detached(priority: .utility) {
            var errorDict: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
            return errorDict?.description
        }.value
    }

    func focusTab(workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw GhosttyError.unavailable }
        // Match the first terminal and don't error if several share a working directory (spec.md §8).
        if let error = await Self.runMatchAndAct(workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: "focus targetTerminal") {
            throw GhosttyError.scriptFailed(error)
        }
    }

    func pasteText(_ text: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw GhosttyError.unavailable }
        let escapedText = Self.escape(text)
        let body = """
        focus targetTerminal
        input text "\(escapedText)" to targetTerminal
        """
        if let error = await Self.runMatchAndAct(workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body) {
            throw GhosttyError.scriptFailed(error)
        }
    }

    /// `send key "enter"` is Ghostty's own scripting command (from the same .sdef as `input text` /
    /// `focus`) for a real keyboard event, gated by the same Automation permission — not a System Events
    /// keystroke-injection workaround, which would need a separate Accessibility grant.
    func pasteTextAndSubmit(_ text: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw GhosttyError.unavailable }
        let escapedText = Self.escape(text)
        let body = """
        focus targetTerminal
        input text "\(escapedText)" to targetTerminal
        send key "enter" to targetTerminal
        """
        if let error = await Self.runMatchAndAct(workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body) {
            throw GhosttyError.scriptFailed(error)
        }
    }
}
