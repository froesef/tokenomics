import SwiftUI

/// The dropdown: the full session list (sorted by urgency), plus the footer (spec.md §3). Not wrapped in
/// a ScrollView on purpose — with realistically at most a couple dozen concurrent Claude Code sessions,
/// showing everything at once beats hiding rows behind a scroll the user has to discover.
struct MenuContentView: View {
    @ObservedObject var viewModel: SessionListViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Today's savings/waste meter, above the session list, with the manual refresh button inline
            // in its first row — only rendered when there's something to show (see MeterStripView /
            // SavingsMeter). Falls back to a bare refresh row when there's nothing to report.
            if viewModel.meter.hasLoss || viewModel.meter.hasSavings {
                MeterStripView(meter: viewModel.meter, onRefresh: { await viewModel.rescan() })
            } else {
                HStack {
                    Spacer()
                    RefreshButtonView(action: { await viewModel.rescan() })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()

            if viewModel.sessions.isEmpty {
                Text("No active coding sessions found")
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
                            onOpenInCodex: { viewModel.openInCodex(session) },
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
