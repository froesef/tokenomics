import AppKit
import SwiftUI

@main
struct ClaudeSessionMonitorApp: App {
    @StateObject private var viewModel = SessionListViewModel()

    init() {
        // Belt-and-suspenders for running as a bare `swift run` executable without a real .app bundle /
        // Info.plist: keeps the app out of the Dock even then. See README "Running without Xcode".
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        // A real window (opened from FooterView), not a sheet — see FooterView.swift. `.contentSize`
        // resizability locks the window to SettingsView's natural size: without it, the window was
        // resizable below that size and Form clips rather than wraps its labels — reported directly, with
        // a screenshot showing "Expiring-soon threshold" and "Enable Ghostty focus action" cut off.
        Settings {
            SettingsView(settings: viewModel.settings)
        }
        .windowResizability(.contentSize)

        // Opened from FooterView via `openWindow(id: "token-tips")`, same activate-then-open
        // pattern as Settings above. Scrollable content (TokenTipsView), so no .contentSize here.
        Window("Token Optimization", id: "token-tips") {
            TokenTipsView()
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var viewModel: SessionListViewModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .foregroundStyle(tintColor)
            if let title = viewModel.barTitle {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
    }

    private var tintColor: Color {
        viewModel.overallStatus?.color ?? .secondary
    }
}
