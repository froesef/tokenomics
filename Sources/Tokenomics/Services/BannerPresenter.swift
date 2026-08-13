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
        session: Session, remaining: TimeInterval, keepWarmSummary: String?,
        onSwitch: @escaping () -> Void, onHandoff: @escaping () -> Void, onPing: @escaping () -> Void
    ) {
        guard shownForTurn[session.id] != session.lastTurnTime else { return }
        shownForTurn[session.id] = session.lastTurnTime
        present(
            session: session, remaining: remaining, keepWarmSummary: keepWarmSummary,
            onSwitch: onSwitch, onHandoff: onHandoff, onPing: onPing
        )
    }

    private func present(
        session: Session, remaining: TimeInterval, keepWarmSummary: String?,
        onSwitch: @escaping () -> Void, onHandoff: @escaping () -> Void, onPing: @escaping () -> Void
    ) {
        let id = session.id
        let view = BannerView(
            projectName: session.projectName,
            expiry: Date().addingTimeInterval(remaining),
            keepWarmSummary: keepWarmSummary,
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
}

private struct BannerView: View {
    let projectName: String
    /// The moment this session's cache is projected to go cold, fixed when the banner opened. The
    /// countdown text is derived from it live (see the `TimelineView` below) rather than pre-formatted,
    /// so it ticks down second by second while the banner is up instead of freezing at its open-time
    /// value — this banner is its own borderless window with no tie to the view model's per-second tick,
    /// so it has to drive its own clock.
    let expiry: Date
    /// "Keeping it alive saves ~N tokens (~$X)" — the projected cost of letting this cache go cold, shown
    /// under the countdown to make the Ping/Handoff buttons' payoff concrete. A fixed snapshot from open
    /// time (unlike the countdown, it doesn't need to tick). Nil when there's nothing to quantify yet.
    let keepWarmSummary: String?
    let onSwitch: () -> Void
    let onHandoff: () -> Void
    let onPing: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = expiry.timeIntervalSince(context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: "timer")
                        .foregroundStyle(.orange)
                    Text(message(remaining: remaining))
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let keepWarmSummary {
                    HStack(spacing: 4) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(keepWarmSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
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

    private func message(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "\(projectName) cache went cold" }
        let total = Int(remaining)
        return "\(projectName) cache expiring in \(String(format: "%d:%02d", total / 60, total % 60))"
    }
}
