import AppKit
import SwiftUI

/// Captures the `NSWindow` hosting this SwiftUI view. `MenuBarExtra`'s `.window` style gives no other
/// way to get at that window, but `DetailPanelPresenter` needs its screen frame to position the hover
/// flyout panel against the dropdown's right edge.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
