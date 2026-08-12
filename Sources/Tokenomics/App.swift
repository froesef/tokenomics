import AppKit
import SwiftUI

@main
struct TokenomicsApp: App {
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
            Image(systemName: symbolName)
                .foregroundStyle(tintColor)
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
    }

    /// The cache countdown wins when there is one. Otherwise, rather than going blank the moment every
    /// session's cache has expired, fall back to whatever activity is happening — see
    /// `SessionListViewModel.busiestActivity` for why a bare timer icon at that point is misleading.
    private var text: String? {
        viewModel.barTitle ?? viewModel.busiestActivity?.label
    }

    private var symbolName: String {
        guard viewModel.barTitle == nil, let activity = viewModel.busiestActivity, !activity.symbolName.isEmpty else {
            return "timer"
        }
        return activity.symbolName
    }

    private var tintColor: Color {
        guard viewModel.barTitle == nil, let activity = viewModel.busiestActivity else {
            return viewModel.overallStatus?.color ?? .secondary
        }
        return activity.color
    }
}
