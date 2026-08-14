import AppKit
import SwiftUI

/// Floating top-of-screen banner shown once per warm period when a session is about to go cold, with
/// "Switch to Session" and "Handoff" actions. Not part of spec.md (which only calls for a
/// UNUserNotificationCenter alert in §6) — added because the user explicitly asked for an on-screen
/// dialog offering to jump to the expiring session and paste a `/handoff`, in addition to the system
/// notification.
///
/// "Handoff" pastes `/handoff` into the terminal via `TerminalController.pasteText` — a paste with no
/// Return press, into whichever supported terminal (Ghostty, iTerm2) has the session's tab open — then
/// focuses it. The user still runs it themselves; nothing here executes on its own, per spec.md §11
/// ("read-and-focus only").
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
            windowKey: session.id, session: session, remaining: remaining, kind: .expiringSoon,
            detailSummary: keepWarmSummary,
            onSwitch: onSwitch, onHandoff: onHandoff, onPing: onPing
        )
    }

    /// The distinct "auto keep-alive has spent its whole budget" warning — a session it was keeping warm
    /// won't get any more automatic pings, so it goes cold unless the user extends it by hand. Deduped by
    /// the tracker (see `KeepAliveTracker.consumeExhaustionWarning`), which only lets this fire once per
    /// warm period, so there's no per-turn guard here. Shown in its own window keyed apart from the ordinary
    /// expiry banner so both can be on screen at once for the same session.
    func presentMaxExtensions(
        session: Session, remaining: TimeInterval, used: Int, cap: Int, coldCostSummary: String?,
        onSwitch: @escaping () -> Void, onHandoff: @escaping () -> Void, onPing: @escaping () -> Void
    ) {
        present(
            windowKey: session.id + ":maxext", session: session, remaining: remaining,
            kind: .maxExtensionsReached(used: used, cap: cap), detailSummary: coldCostSummary,
            onSwitch: onSwitch, onHandoff: onHandoff, onPing: onPing
        )
    }

    private func present(
        windowKey: String, session: Session, remaining: TimeInterval, kind: BannerKind,
        detailSummary: String?,
        onSwitch: @escaping () -> Void, onHandoff: @escaping () -> Void, onPing: @escaping () -> Void
    ) {
        dismiss(windowKey)
        let id = windowKey
        let view = BannerView(
            projectName: session.projectName,
            expiry: Date().addingTimeInterval(remaining),
            kind: kind,
            detailSummary: detailSummary,
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

/// Which flavor of banner is on screen — an ordinary "about to go cold" nudge, or the louder warning that
/// automatic keep-alive has spent its whole budget for this warm period and the session will go cold unless
/// the user extends it by hand. Drives the header icon/tint and the headline wording.
enum BannerKind: Equatable {
    case expiringSoon
    /// Carries the used/cap ping counts for the "N/N extensions used" line.
    case maxExtensionsReached(used: Int, cap: Int)
}

private struct BannerView: View {
    let projectName: String
    /// The moment this session's cache is projected to go cold, fixed when the banner opened. The
    /// countdown text is derived from it live (see the `TimelineView` below) rather than pre-formatted,
    /// so it ticks down second by second while the banner is up instead of freezing at its open-time
    /// value — this banner is its own borderless window with no tie to the view model's per-second tick,
    /// so it has to drive its own clock.
    let expiry: Date
    let kind: BannerKind
    /// The secondary money/token line under the headline — "Keeping it alive saves ~N tokens (~$X)" for
    /// the expiring-soon nudge, or "Going cold now would cost ~$X …" for the max-extensions warning. A fixed
    /// snapshot from open time (unlike the countdown, it doesn't need to tick). Nil when there's nothing to
    /// quantify yet.
    let detailSummary: String?
    let onSwitch: () -> Void
    let onHandoff: () -> Void
    let onPing: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = expiry.timeIntervalSince(context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: headerSymbol)
                        .foregroundStyle(headerColor)
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
                if let detailSummary {
                    HStack(spacing: 4) {
                        Image(systemName: detailSymbol)
                            .font(.system(size: 10))
                            .foregroundStyle(detailColor)
                        Text(detailSummary)
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

    private var headerSymbol: String {
        switch kind {
        case .expiringSoon: return "timer"
        case .maxExtensionsReached: return "bolt.slash.fill"
        }
    }

    private var headerColor: Color {
        switch kind {
        case .expiringSoon: return .orange
        case .maxExtensionsReached: return .red
        }
    }

    private var detailSymbol: String {
        switch kind {
        case .expiringSoon: return "leaf.fill"
        case .maxExtensionsReached: return "dollarsign.circle.fill"
        }
    }

    private var detailColor: Color {
        switch kind {
        case .expiringSoon: return .green
        case .maxExtensionsReached: return .orange
        }
    }

    private func message(remaining: TimeInterval) -> String {
        let clock = String(format: "%d:%02d", max(0, Int(remaining)) / 60, max(0, Int(remaining)) % 60)
        switch kind {
        case .expiringSoon:
            guard remaining > 0 else { return "\(projectName) cache went cold" }
            return "\(projectName) cache expiring in \(clock)"
        case .maxExtensionsReached(let used, let cap):
            guard remaining > 0 else {
                return "\(projectName) went cold — auto keep-alive was exhausted (\(used)/\(cap) extensions used)"
            }
            return "\(projectName): auto keep-alive used all \(used)/\(cap) extensions — cache goes cold in \(clock) unless you extend it manually"
        }
    }
}
