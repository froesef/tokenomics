import AppKit
import SwiftUI

/// Footer of the dropdown: settings affordance, Quit, and a degraded-dependency status line (spec.md §3).
/// "Settings…" opens the app's real `Settings` scene (`SettingsLink`, macOS 14+) — a separate window, the
/// same pattern Docker Desktop's menu bar icon uses for its Preferences — rather than a sheet cramped
/// into this 380pt-wide dropdown. Written out as full-width text rows rather than a gear icon, per direct
/// feedback: a plain icon-only affordance doesn't read as a menu item the way spelled-out "Settings…" /
/// "Quit" rows do in a standard macOS menu bar dropdown.
struct FooterView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var hoveringSettings = false
    @State private var hoveringTokenTips = false
    @State private var hoveringAbout = false
    @State private var hoveringQuit = false

    var body: some View {
        VStack(spacing: 0) {
            if let warning = viewModel.dependencyWarnings.first {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .lineLimit(2)
            }
            Divider()

            // Not a plain SettingsLink: on an accessory-policy app (no Dock icon) the Settings window can
            // open without ever becoming key/frontmost, which looks exactly like "nothing happened" —
            // reported directly. Activating first forces it to the front.
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                MenuRowLabel(title: "Settings…", isHovering: hoveringSettings)
            }
            .buttonStyle(.plain)
            .onHover { hoveringSettings = $0 }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "token-tips")
            } label: {
                MenuRowLabel(title: "Token optimization…", isHovering: hoveringTokenTips)
            }
            .buttonStyle(.plain)
            .onHover { hoveringTokenTips = $0 }

            // AboutView reads CFBundleShortVersionString / CFBundleVersion straight from Info.plist —
            // CFBundleVersion is the short git commit hash, stamped at build time by
            // Scripts/build_app.sh (see CONTRIBUTING.md#versioning).
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "about")
            } label: {
                MenuRowLabel(title: "About Tokenomics", isHovering: hoveringAbout)
            }
            .buttonStyle(.plain)
            .onHover { hoveringAbout = $0 }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                MenuRowLabel(title: "Quit", isHovering: hoveringQuit)
            }
            .buttonStyle(.plain)
            .onHover { hoveringQuit = $0 }
        }
        .padding(.bottom, 4)
    }
}
