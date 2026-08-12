import SwiftUI

/// Tiny manual-refresh affordance at the top of the dropdown, next to the savings meter: re-scans agent
/// sessions and processes on demand instead of waiting for the poll interval (see
/// `SessionListViewModel.rescan()`).
struct RefreshButtonView: View {
    let action: () async -> Void

    @State private var isRefreshing = false
    @State private var isHovering = false

    var body: some View {
        Button {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                await action()
                isRefreshing = false
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default,
                    value: isRefreshing
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("Refresh sessions and processes")
    }
}
