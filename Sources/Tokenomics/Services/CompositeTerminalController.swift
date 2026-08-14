import Foundation

/// Fans the `TerminalController` protocol out across every installed terminal backend (Ghostty, iTerm2, …
/// see spec.md §8) so the rest of the app talks to "the terminal" without knowing which app is actually
/// running. Adding a new terminal is one new file conforming to `TerminalController` plus one line in the
/// default `controllers` list below — never a change to `SessionListViewModel` or any view.
@MainActor
final class CompositeTerminalController: TerminalController {
    private let controllers: [TerminalController]

    init(controllers: [TerminalController] = [GhosttyController(), ITermController()]) {
        self.controllers = controllers
    }

    let displayName = "Terminal"

    var isAvailable: Bool { controllers.contains { $0.isAvailable } }

    func hasOpenTab(workingDirectory: String) -> Bool {
        controllers.contains { $0.isAvailable && $0.hasOpenTab(workingDirectory: workingDirectory) }
    }

    func hasExactOpenTab(workingDirectory: String) -> Bool {
        controllers.contains { $0.isAvailable && $0.hasExactOpenTab(workingDirectory: workingDirectory) }
    }

    /// Overrides the protocol's single-backend default to name whichever backend actually has this
    /// directory open — this is what lets the info panel say "Ghostty" or "iTerm2" instead of "Terminal".
    func terminalName(for workingDirectory: String) -> String? {
        matchingController(for: workingDirectory, aiTitle: nil)?.displayName
    }

    func timeSinceLastActive(workingDirectory: String) -> TimeInterval? {
        controllers.compactMap { $0.timeSinceLastActive(workingDirectory: workingDirectory) }.min()
    }

    func focusTab(sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard let controller = backend(for: workingDirectory, aiTitle: aiTitle) else { throw TerminalControllerError.unavailable }
        try await controller.focusTab(sessionId: sessionId, workingDirectory: workingDirectory, aiTitle: aiTitle)
    }

    func pasteText(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws {
        guard let controller = backend(for: workingDirectory, aiTitle: aiTitle) else { throw TerminalControllerError.unavailable }
        try await controller.pasteText(text, sessionId: sessionId, workingDirectory: workingDirectory, aiTitle: aiTitle, activate: activate)
    }

    func pasteTextAndSubmit(_ text: String, sessionId: String, workingDirectory: String, aiTitle: String?) async throws {
        guard let controller = backend(for: workingDirectory, aiTitle: aiTitle) else { throw TerminalControllerError.unavailable }
        try await controller.pasteTextAndSubmit(text, sessionId: sessionId, workingDirectory: workingDirectory, aiTitle: aiTitle)
    }

    func refreshAvailability() async {
        for controller in controllers {
            await controller.refreshAvailability()
        }
    }

    /// Exact matches always outrank fuzzy (ancestor/descendant) ones, regardless of `controllers` order —
    /// see the doc comment on `TerminalController.hasExactOpenTab` for the bug this tiering fixes. Within
    /// the exact-match tier, `hasPlausibleExactOpenTab` (title-aware) is tried before the blind
    /// `hasExactOpenTab` — see `TerminalController.hasPlausibleExactOpenTab`'s doc comment for the
    /// cross-app forwarding bug that tiering fixes (a stray same-cwd tab in the first-listed backend always
    /// won over the real match in a different app).
    private func matchingController(for workingDirectory: String, aiTitle: String?) -> TerminalController? {
        controllers.first { $0.isAvailable && $0.hasPlausibleExactOpenTab(workingDirectory: workingDirectory, aiTitle: aiTitle) }
            ?? controllers.first { $0.isAvailable && $0.hasExactOpenTab(workingDirectory: workingDirectory) }
            ?? controllers.first { $0.isAvailable && $0.hasOpenTab(workingDirectory: workingDirectory) }
    }

    /// Prefers whichever backend actually has the directory open; falls back to the first available
    /// backend so a session with no confirmed tab yet still gets a best-effort focus/paste attempt.
    private func backend(for workingDirectory: String, aiTitle: String?) -> TerminalController? {
        matchingController(for: workingDirectory, aiTitle: aiTitle) ?? controllers.first { $0.isAvailable }
    }
}
