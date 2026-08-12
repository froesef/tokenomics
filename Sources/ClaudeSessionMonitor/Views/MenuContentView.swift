import SwiftUI

/// The dropdown: the full session list (sorted by urgency), plus the footer (spec.md §3). Not wrapped in
/// a ScrollView on purpose — with realistically at most a couple dozen concurrent Claude Code sessions,
/// showing everything at once beats hiding rows behind a scroll the user has to discover.
struct MenuContentView: View {
    @ObservedObject var viewModel: SessionListViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.sessions.isEmpty {
                Text("No active Claude Code sessions found")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.sessions) { session in
                        SessionRowView(
                            session: session,
                            now: viewModel.now,
                            settings: viewModel.settings,
                            hasOpenTab: viewModel.settings.ghosttyFocusEnabled
                                && viewModel.ghostty.isAvailable
                                && viewModel.ghostty.hasOpenTab(workingDirectory: session.workingDirectory),
                            keepAliveInfo: viewModel.keepAliveInfo(for: session),
                            onFocus: { Task { await viewModel.focus(session) } },
                            onPasteCommand: { text in Task { await viewModel.pasteCommand(text, into: session) } },
                            onPing: { Task { await viewModel.ping(session) } },
                            onToggleKeepAlive: {
                                let current = viewModel.keepAliveInfo(for: session).enabled
                                viewModel.setKeepAlive(!current, for: session)
                            },
                            onHoverChanged: { hovering in
                                viewModel.rowHoverChanged(
                                    session, isHovering: hovering,
                                    hasOpenTab: viewModel.settings.ghosttyFocusEnabled
                                        && viewModel.ghostty.isAvailable
                                        && viewModel.ghostty.hasOpenTab(workingDirectory: session.workingDirectory)
                                )
                            }
                        )
                        Divider()
                    }
                }
            }
            FooterView(viewModel: viewModel)
        }
        .frame(width: 380)
        .background(WindowAccessor { viewModel.hostWindow = $0 })
    }
}
