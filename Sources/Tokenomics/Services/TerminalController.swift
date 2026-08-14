import Foundation

/// Swappable terminal-focus backend so the rest of the app stays terminal-agnostic (spec.md §8). Each
/// supported terminal app (Ghostty, iTerm2, …) gets its own file conforming to this protocol; adding one
/// more terminal is a new file plus one line in `CompositeTerminalController`, never a change to any
/// caller or to the other terminals' files.
@MainActor
protocol TerminalController: AnyObject {
    /// User-facing name of this backend, e.g. "Ghostty" or "iTerm2" — shown in the info panel so the user
    /// can tell which terminal a session's tab was found in.
    var displayName: String { get }
    /// App-level availability: the terminal app is running and Automation is authorized. Must be a cheap,
    /// non-blocking read — see `refreshAvailability()` for why.
    var isAvailable: Bool { get }
    /// Whether a terminal is currently open at (or under) this working directory. Also must be cheap and
    /// non-blocking — it's read from view bodies to decide whether a row's focus affordance is live. This
    /// is the per-session cross-reference: `isAvailable` alone only says "this terminal app is reachable at
    /// all".
    ///
    /// True on an exact match OR an ancestor/descendant one (see `hasExactOpenTab` for why the ancestor
    /// case exists and why it's dangerous to rank equally against an exact match).
    func hasOpenTab(workingDirectory: String) -> Bool
    /// True only when this backend has a tab open at exactly this directory — no ancestor/descendant
    /// fuzziness. `CompositeTerminalController` checks this across every backend before falling back to
    /// `hasOpenTab`'s fuzzier match on any backend, so an exact match in one terminal always outranks a
    /// same-directory-family match in another. Without that tiering, a session run from a git worktree
    /// (nested under its own repo checkout) would false-match a stale tab merely sitting at the checkout
    /// root in a *different* terminal app than the one actually running the session — confirmed live: an
    /// idle Ghostty tab at the repo root outranked the real, exact-match iTerm2 session simply because
    /// Ghostty came first in `CompositeTerminalController`'s backend list.
    func hasExactOpenTab(workingDirectory: String) -> Bool
    /// This backend's display name when it has a matching tab open at `workingDirectory`, nil otherwise —
    /// what the info panel shows. The default below is right for any single-backend controller;
    /// `CompositeTerminalController` overrides it to name whichever backend actually matched.
    func terminalName(for workingDirectory: String) -> String?
    /// Best-effort: seconds since this app last observed this terminal's frontmost window/tab focused on
    /// this directory, sampled once per `refreshAvailability()` call — resolution is the refresh interval,
    /// not exact. Nil if never observed (e.g. just launched, or this directory's tab has never been
    /// frontmost while this app was running).
    func timeSinceLastActive(workingDirectory: String) -> TimeInterval?
    /// `aiTitle`, when non-nil, disambiguates between several terminals that all report the same working
    /// directory (e.g. one pane running the Claude Code session, a plain idle shell twin sitting at the
    /// same path in another split). Pass `Session.aiTitle` here whenever it's available; a caller with no
    /// session context can omit it.
    func focusTab(workingDirectory: String, aiTitle: String?) async throws
    /// Pastes text into the matching terminal — lands in the terminal's input line for the user to review
    /// and run themselves, never executed on its own. See spec.md §11 ("read-and-focus only"). `activate`
    /// controls whether the terminal app is brought forward afterward: true for /handoff, /compact, and
    /// other explicit paste actions the user expects to see land; false for the manual Ping button, which
    /// pastes its keep-alive question quietly without stealing focus from whatever window the user is on.
    func pasteText(_ text: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws
    /// Pastes text into the matching terminal, then submits it — unlike `pasteText`, this one *does*
    /// execute whatever was pasted, with no user step in between. This is a deliberate, narrow exception to
    /// the "read-and-focus only" rule above: used exclusively by the automatic keep-alive feature (see
    /// `KeepAliveTracker`) for its one fixed, harmless prompt, for when the user is genuinely away (a
    /// meeting, lunch) and there's no one to press Enter before the cache goes cold. No other caller in
    /// this app should use this. Unlike every other action here, this one never focuses the tab or
    /// activates the terminal app — being unattended is exactly why it must stay quiet and not steal focus
    /// from whatever the user is doing right now.
    func pasteTextAndSubmit(_ text: String, workingDirectory: String, aiTitle: String?) async throws
    /// Re-probes availability and re-fetches the set of open working directories. Availability and open
    /// tabs both change while the app runs, so callers should call this periodically (the ViewModel does,
    /// on its regular refresh) rather than caching either forever.
    func refreshAvailability() async
}

extension TerminalController {
    func terminalName(for workingDirectory: String) -> String? {
        hasOpenTab(workingDirectory: workingDirectory) ? displayName : nil
    }
}

/// Thrown by `CompositeTerminalController` when no backend is available at all. Individual backends throw
/// their own error type (e.g. `GhosttyError`, `ITermError`) so a script failure keeps its origin.
enum TerminalControllerError: Error {
    case unavailable
}
