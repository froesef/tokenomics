import AppKit
import Foundation

enum CmuxError: Error {
    case unavailable
    case scriptFailed(String)
}

/// Focuses (and optionally pastes into) a cmux terminal by working directory, using cmux's own AppleScript
/// dictionary — read directly from `/Applications/cmux.app/Contents/Resources/cmux.sdef` on this machine.
/// cmux is built on Ghostty's terminal core and its scripting dictionary mirrors Ghostty's object model
/// almost exactly: `window > tab > terminal`, with `working directory`, `name` (title), `id`, `selected tab`,
/// `focused terminal`, `front window`, `focus`, and `input text "..." to terminal` all present under the
/// same names — see `GhosttyController`'s doc comment for why `input text` needs no Accessibility grant and
/// why every AppleScript call here runs inside `Task.detached`, off the main actor.
///
/// One real difference: cmux's `.sdef` has no `send key "enter"` command. In its place it exposes `perform
/// action "<Ghostty action string>" on <terminal>` — a passthrough to Ghostty-core's own keybind-action
/// system. Verified live against a running cmux (marker-file test: paste `touch marker`, confirm the file
/// is absent, then run `perform action "text:\n" on term`, confirm the file now exists) that `text:\n` is
/// the equivalent of Ghostty's `send key "enter"` — it submits the pasted line, unlike `input text`, which
/// only lands it in the input line "as if pasted".
///
/// Gated by macOS Automation (TCC) permission, same as Ghostty/iTerm2. `isAvailable` is false whenever cmux
/// isn't running or automation isn't authorized yet; callers must hide/disable focus controls rather than
/// surface errors.
@MainActor
final class CmuxController: TerminalController {
    private var cachedAvailability = false
    private var cachedWorkingDirectories: Set<String> = []
    /// Working directory -> every currently-open terminal's title at that exact directory — see
    /// `GhosttyController.cachedTerminalTitles`. Backs `hasPlausibleExactOpenTab`.
    private var cachedTerminalTitles: [String: [String]] = [:]
    private var lastActiveAt: [String: Date] = [:]
    /// `Session.id` -> the cmux-assigned `id` (a stable per-terminal-panel string; see cmux.sdef, `<property
    /// name="id" code="ID  ">` on the `terminal` class) of the terminal last matched to that session — same
    /// reasoning as `GhosttyController.resolvedTerminalIds`.
    private var resolvedTerminalIds: [String: String] = [:]

    let displayName = "cmux"

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
        guard Self.isCmuxRunning() else {
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

        // cmux being frontmost is a plain NSWorkspace read (no AppleScript, no reentrancy risk) — only
        // bother asking *which* terminal is focused when that's actually true.
        if Self.isCmuxFrontmost(), let focused = await Self.fetchFocusedTerminalWorkingDirectory() {
            lastActiveAt[focused] = Date()
        }
    }

    private static func isCmuxRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.cmuxterm.app" }
    }

    private static func isCmuxFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app"
    }

    /// The one terminal the user is actually looking at right now, if any — cmux's frontmost window's
    /// selected tab's focused terminal. Distinct from `fetchTerminalEntries`, which lists every open
    /// terminal regardless of focus.
    private static func fetchFocusedTerminalWorkingDirectory() async -> String? {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "cmux"
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
            let script = "tell application \"cmux\" to count windows"
            var errorDict: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
            return errorDict == nil && result != nil
        }.value
    }

    /// Lists every open terminal's working directory and title in one round trip — see
    /// `GhosttyController.fetchTerminalEntries` for why the U+001F join and this shape.
    private static func fetchTerminalEntries() async -> [(workingDirectory: String, title: String)] {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "cmux"
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

    /// The shared "find the matching terminal" fragment — identical matching strategy to
    /// `GhosttyController.findTerminalScript` (exact cwd match first, title-hint/non-path-title tie-break,
    /// then ancestor/descendant prefix fallback). See that doc comment for the full rationale. Assumes it's
    /// inlined inside a `tell application "cmux" ... end tell` block.
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
            -- No exact-cwd match at all — search ancestor/descendant matches instead. Same tie-break
            -- priority as the exact-match pass above.
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

    /// Runs a script that first tries `cachedTerminalId` (if any) via `terminal id "..."`, falling back to
    /// `findTerminalScript`'s cwd/title search — same shape as `GhosttyController.runMatchAndAct`. When
    /// `activate` is true (the default), a plain `activate` runs afterward — every Cocoa app (cmux included)
    /// answers this standard AppKit command even though it isn't declared in `cmux.sdef`, same as Ghostty's
    /// `activate application "Ghostty"`; `focus targetTerminal` already selected the right window/tab, so
    /// this just brings the app forward. Callers that need to stay quiet in the background pass
    /// `activate: false`.
    private static func runMatchAndAct(cachedTerminalId: String?, workingDirectory: String, aiTitle: String?, bodyIfFound: String, activate: Bool = true) async -> (resolvedId: String?, error: String?) {
        let dir = Self.escape(workingDirectory)
        let hint = Self.escape(aiTitle ?? "")
        let cachedId = Self.escape(cachedTerminalId ?? "")
        let activateLine = activate ? "if targetTerminal is not missing value then activate application \"cmux\"" : ""
        let script = """
        tell application "cmux"
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
            tell application "cmux"
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

    /// Updates (or clears) `resolvedTerminalIds[sessionId]` after a match attempt — same as
    /// `GhosttyController.rememberResolvedId`.
    private func rememberResolvedId(_ resolvedId: String?, for sessionId: String) {
        if let resolvedId {
            resolvedTerminalIds[sessionId] = resolvedId
        } else {
            resolvedTerminalIds.removeValue(forKey: sessionId)
        }
    }

    func focusTab(sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw CmuxError.unavailable }
        let (resolvedId, error) = await Self.runMatchAndAct(cachedTerminalId: resolvedTerminalIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: "focus targetTerminal")
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw CmuxError.scriptFailed(error)
        }
    }

    func pasteText(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws {
        guard isAvailable else { throw CmuxError.unavailable }
        let escapedText = Self.escape(text)
        let body = """
        focus targetTerminal
        input text "\(escapedText)" to targetTerminal
        """
        let (resolvedId, error) = await Self.runMatchAndAct(cachedTerminalId: resolvedTerminalIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: activate)
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw CmuxError.scriptFailed(error)
        }
    }

    /// `perform action "text:\n" on targetTerminal` is cmux's stand-in for Ghostty's `send key "enter"` —
    /// see this file's top doc comment for the marker-file test that confirmed it actually submits the
    /// pasted line rather than just landing another literal newline in the input buffer.
    ///
    /// The `delay 0.3` between `input text` and `perform action` is load-bearing, not decoration: `input
    /// text`'s Apple Event reply comes back — confirmed via `NSAppleScript` (not just `osascript`, which
    /// has enough inherent process-launch latency to mask this) — before cmux has actually finished writing
    /// the pasted bytes into the terminal. Fire `perform action "text:\n"` immediately after and it
    /// reliably submits an empty/partial line instead of the pasted text: reproduced with a marker-file
    /// test (paste `touch marker`, immediately send the enter-action, marker never appears) and fixed by
    /// inserting this delay (marker reliably appears across repeated runs). No such race exists for
    /// Ghostty's `send key "enter"`, which is why `GhosttyController` needs no equivalent delay.
    ///
    /// Deliberately skips both `focus targetTerminal` and window activation: `input text` and `perform
    /// action` both take `targetTerminal` explicitly, so neither needs the terminal selected or the window
    /// frontmost to work. This is the unattended path (see the protocol doc comment on
    /// `TerminalController.pasteTextAndSubmit`) — it should never steal focus from whatever window/app the
    /// user is actually looking at.
    func pasteTextAndSubmit(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard isAvailable else { throw CmuxError.unavailable }
        let escapedText = Self.escape(text)
        let body = """
        input text "\(escapedText)" to targetTerminal
        delay 0.3
        perform action "text:\\n" on targetTerminal
        """
        let (resolvedId, error) = await Self.runMatchAndAct(cachedTerminalId: resolvedTerminalIds[sessionId], workingDirectory: workingDirectory, aiTitle: aiTitle, bodyIfFound: body, activate: false)
        rememberResolvedId(resolvedId, for: sessionId)
        if let error {
            throw CmuxError.scriptFailed(error)
        }
    }
}
