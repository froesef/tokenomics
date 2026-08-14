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
        matchingController(for: workingDirectory)?.displayName
    }

    func timeSinceLastActive(workingDirectory: String) -> TimeInterval? {
        controllers.compactMap { $0.timeSinceLastActive(workingDirectory: workingDirectory) }.min()
    }

    func focusTab(workingDirectory: String, aiTitle: String?) async throws {
        guard let controller = backend(for: workingDirectory) else { throw TerminalControllerError.unavailable }
        try await controller.focusTab(workingDirectory: workingDirectory, aiTitle: aiTitle)
    }

    func pasteText(_ text: String, workingDirectory: String, aiTitle: String?, activate: Bool) async throws {
        guard let controller = backend(for: workingDirectory) else { throw TerminalControllerError.unavailable }
        try await controller.pasteText(text, workingDirectory: workingDirectory, aiTitle: aiTitle, activate: activate)
    }

    func pasteTextAndSubmit(_ text: String, workingDirectory: String, aiTitle: String?) async throws {
        guard let controller = backend(for: workingDirectory) else { throw TerminalControllerError.unavailable }
        try await controller.pasteTextAndSubmit(text, workingDirectory: workingDirectory, aiTitle: aiTitle)
    }

    func refreshAvailability() async {
        for controller in controllers {
            await controller.refreshAvailability()
        }
    }

    /// Exact matches always outrank fuzzy (ancestor/descendant) ones, regardless of `controllers` order —
    /// see the doc comment on `TerminalController.hasExactOpenTab` for the bug this tiering fixes.
    private func matchingController(for workingDirectory: String) -> TerminalController? {
        controllers.first { $0.isAvailable && $0.hasExactOpenTab(workingDirectory: workingDirectory) }
            ?? controllers.first { $0.isAvailable && $0.hasOpenTab(workingDirectory: workingDirectory) }
    }

    /// Prefers whichever backend actually has the directory open; falls back to the first available
    /// backend so a session with no confirmed tab yet still gets a best-effort focus/paste attempt.
    private func backend(for workingDirectory: String) -> TerminalController? {
        matchingController(for: workingDirectory) ?? controllers.first { $0.isAvailable }
    }
}
