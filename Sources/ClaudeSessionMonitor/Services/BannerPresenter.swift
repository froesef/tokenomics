import AppKit
import SwiftUI

/// Floating top-of-screen banner shown once per warm period when a session is about to go cold, with
/// "Switch to Session" and "Handoff" actions. Not part of spec.md (which only calls for a
/// UNUserNotificationCenter alert in §6) — added because the user explicitly asked for an on-screen
/// dialog offering to jump to the expiring session and paste a `/handoff`, in addition to the system
/// notification.
///
/// "Handoff" pastes `/handoff` into the terminal via `GhosttyController.pasteText` — Ghostty's native
/// "as if pasted" semantics, which never presses Return — then focuses it. The user still runs it
/// themselves; nothing here executes on its own, per spec.md §11 ("read-and-focus only").
@MainActor
final class BannerPresenter {
    private var shownForTurn: [String: Date] = [:]
    private var activeWindows: [String: NSWindow] = [:]

    func presentIfNeeded(
        session: Session, remaining: TimeInterval,
        onSwitch: @escaping () -> Void, onHandoff: @escaping () -> Void, onPing: @escaping () -> Void
    ) {
        guard shownForTurn[session.id] != session.lastTurnTime else { return }
        shownForTurn[session.id] = session.lastTurnTime
        present(session: session, remaining: remaining, onSwitch: onSwitch, onHandoff: onHandoff, onPing: onPing)
    }

    private func present(
        session: Session, remaining: TimeInterval,
        onSwitch: @escaping () -> Void, onHandoff: @escaping () -> Void, onPing: @escaping () -> Void
    ) {
        let id = session.id
        let view = BannerView(
            projectName: session.projectName,
            remainingText: formatCountdown(remaining),
            onSwitch: { [weak self] in
                onSwitch()
                self?.dismiss(id)
            },
            onHandoff: { [weak self] in
                onHandoff()
                self?.dismiss(id)
            },
            onPing: { [weak self] in
                onPing()
                self?.dismiss(id)
            },
            onDismiss: { [weak self] in self?.dismiss(id) }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 108),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        if let screen = NSScreen.main {
            let stackOffset = CGFloat(activeWindows.count) * 116
            let x = screen.visibleFrame.midX - 180
            let y = screen.visibleFrame.maxY - 40 - stackOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.orderFrontRegardless()
        activeWindows[id] = window

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.dismiss(id)
        }
    }

    private func dismiss(_ id: String) {
        activeWindows[id]?.close()
        activeWindows[id] = nil
    }

    private func formatCountdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct BannerView: View {
    let projectName: String
    let remainingText: String
    let onSwitch: () -> Void
    let onHandoff: () -> Void
    let onPing: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
                Text("\(projectName) cache expiring in \(remainingText)")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Ping", action: onPing)
                    .controlSize(.small)
                    .help("Pastes a trivial \"still there?\" question — a nop keep-alive, not a real handoff")
                Button("Handoff", action: onHandoff)
                    .controlSize(.small)
                    .help("Pastes /handoff into the terminal — doesn't run it for you")
                Button("Switch to Session", action: onSwitch)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
