import AppKit
import SwiftUI

/// Shows `SessionDetailPanelView` in a floating panel beside the dropdown on hover — a hand-built stand-in
/// for a native flyout submenu (the Docker Desktop nested-menu pattern the user pointed to), chosen over
/// actually converting the dropdown to a native `.menu`-style `MenuBarExtra` so the existing custom row
/// styling (colored status dots, custom fonts) doesn't have to be given up.
///
/// `MenuBarExtra`'s `.window` style exposes no per-row screen coordinates, so this positions itself
/// against the dropdown window's screen frame (via WindowAccessor) at the right edge, vertically centered
/// on the current mouse position — an approximation of "beside the hovered row" that holds up because the
/// mouse is necessarily over that row's vertical span when the hover fires. Overlaps the dropdown's edge
/// by a couple points rather than leaving a gap, matching how native macOS submenus sit flush (very
/// slightly overlapping) against the item they flew out from instead of floating apart from it.
@MainActor
final class DetailPanelPresenter {
    private var window: NSWindow?

    func show(
        session: Session, settings: SettingsStore, hasOpenTab: Bool, timeSinceLastActive: TimeInterval?,
        anchorWindow: NSWindow?,
        onFocus: @escaping () -> Void, onPasteCommand: @escaping (String) -> Void,
        onPing: @escaping () -> Void, onHoverChanged: @escaping (Bool) -> Void
    ) {
        hide()

        let view = SessionDetailPanelView(
            session: session, settings: settings, hasOpenTab: hasOpenTab, timeSinceLastActive: timeSinceLastActive,
            onFocus: onFocus, onPasteCommand: onPasteCommand, onPing: onPing, onHoverChanged: onHoverChanged
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
        let mouseY = NSEvent.mouseLocation.y
        let minY = anchorFrame.minY
        let maxY = max(minY, anchorFrame.maxY - size.height)
        let origin = NSPoint(
            x: anchorFrame.maxX - 2,
            y: min(max(mouseY - size.height / 2, minY), maxY)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
