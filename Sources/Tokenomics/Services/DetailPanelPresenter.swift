import AppKit
import SwiftUI

/// Shows `SessionDetailPanelView` in a floating panel beside the dropdown on hover — a hand-built stand-in
/// for a native flyout submenu (the Docker Desktop nested-menu pattern the user pointed to), chosen over
/// actually converting the dropdown to a native `.menu`-style `MenuBarExtra` so the existing custom row
/// styling (colored status dots, custom fonts) doesn't have to be given up.
///
/// `MenuBarExtra`'s `.window` style exposes no per-row screen coordinates, so this positions itself
/// against the dropdown window's screen frame (via WindowAccessor) at the right edge, top-aligned with
/// the dropdown (i.e. flush under the menu bar, like the dropdown itself) rather than centered on the
/// hovered row — the panel is taller than most rows, so row-centering pushed it above the screen top for
/// rows near the top of the list. Overlaps the dropdown's edge by a couple points rather than leaving a
/// gap, matching how native macOS submenus sit flush (very slightly overlapping) against the item they
/// flew out from instead of floating apart from it. Falls back to the left edge when the right side would
/// run off the anchor's screen, and clamps its bottom to the screen when taller than it.
@MainActor
final class DetailPanelPresenter {
    private var window: NSWindow?

    func show(
        session: Session, settings: SettingsStore, hasOpenTab: Bool, terminalName: String?, timeSinceLastActive: TimeInterval?,
        keepAliveInfo: KeepAliveInfo, anchorWindow: NSWindow?,
        onFocus: @escaping () -> Void, onPasteCommand: @escaping (String) -> Void,
        onPing: @escaping () -> Void, onOpenInCodex: @escaping () -> Void, onToggleKeepAlive: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        hide()

        let view = SessionDetailPanelView(
            session: session, settings: settings, hasOpenTab: hasOpenTab, terminalName: terminalName,
            timeSinceLastActive: timeSinceLastActive,
            keepAliveInfo: keepAliveInfo,
            onFocus: onFocus, onPasteCommand: onPasteCommand, onPing: onPing,
            onOpenInCodex: onOpenInCodex, onToggleKeepAlive: onToggleKeepAlive,
            onHoverChanged: onHoverChanged
        )
        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let anchorFrame = anchorWindow?.frame ?? NSScreen.main?.frame ?? .zero
        let screen = anchorWindow?.screen ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? anchorFrame
        let fitsOnRight = anchorFrame.maxX - 2 + size.width <= screenFrame.maxX
        let x = fitsOnRight
            ? anchorFrame.maxX - 2
            : max(screenFrame.minX, anchorFrame.minX + 2 - size.width)
        let topY = min(anchorFrame.maxY, screenFrame.maxY)
        let y = max(screenFrame.minY, topY - size.height)
        let origin = NSPoint(x: x, y: y)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
