import SwiftUI

/// One row in the dropdown (spec.md §3). Double-clicking a row focuses the matching Ghostty tab when
/// available and closes the dropdown (see `SessionListViewModel.focus`) — this is also how the "switch
/// windows/tabs to that session" behavior is exposed from the dropdown, not just from the expiry banner.
/// Single click is deliberately a no-op here: it's the same click a user makes just skimming down the
/// list to read rows, and firing Ghostty's AppleScript `activate` on every one of those would yank focus
/// away from whatever the user's looking at. Hovering shows a flyout detail panel beside the dropdown
/// (see DetailPanelPresenter) with categorized tool/plugin usage, session facts, and the same paste/focus
/// actions; right-click keeps a plain context menu as a redundant fast path for the same actions.
///
/// `hasOpenTab` is a real per-session cross-reference against Ghostty's currently open terminals (see
/// GhosttyController.hasOpenTab), not just "is Ghostty running" — a session with no matching tab shows no
/// focus affordance rather than a button that would silently no-op.
struct SessionRowView: View {
    let session: Session
    let now: Date
    let settings: SettingsStore
    let hasOpenTab: Bool
    let keepAliveInfo: KeepAliveInfo
    let onFocus: () -> Void
    let onPasteCommand: (String) -> Void
    let onPing: () -> Void
    let onOpenInCodex: () -> Void
    let onToggleKeepAlive: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isHighlighted = false

    private var ttl: TimeInterval { session.effectiveTTL(fallback: settings.ttl) }
    private var remaining: TimeInterval { session.remaining(now: now, ttl: ttl) }
    private var status: CacheStatus {
        session.status(now: now, ttl: ttl, expiringSoonThreshold: settings.expiringSoonThresholdSeconds)
    }
    private var canOpenInCodex: Bool { session.agentKind == .codex && session.codexThreadURL != nil }

    /// Native menus paint every row's text solid white the moment it's the highlighted (blue) row,
    /// regardless of that text's usual hierarchy — no dimmed "secondary" tone survives the highlight.
    private func fg(_ base: Color) -> Color {
        isHighlighted ? .white : base
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            AgentIcon(kind: session.agentKind, size: 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(fg(.primary))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let aiTitle = session.aiTitle {
                        Text(aiTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(fg(.secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    activityBadge
                }

                HStack(spacing: 6) {
                    Text(countdownText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(fg(.secondary))
                    if session.supportsCacheCountdown && session.detectedTTL != nil {
                        Text("auto")
                            .font(.system(size: 9))
                            .foregroundStyle(fg(.secondary))
                            .help("TTL detected from this session's own cache_creation usage, not the global setting")
                    }
                    keepWarmSaveBadge
                    Text(hitRatioText)
                        .font(.system(size: 11))
                        .foregroundStyle(fg(.secondary))
                    if session.supportsCacheCountdown && keepAliveInfo.enabled {
                        keepAliveBadge
                    }
                    if session.hasBigContext {
                        bigContextBadge
                    }
                }
            }

            Spacer()

            Text(costText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(fg(.primary))

            if hasOpenTab || canOpenInCodex {
                Image(systemName: canOpenInCodex ? "arrow.up.forward.app" : "arrow.forward.circle")
                    .foregroundStyle(fg(.secondary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor : Color.clear)
        .onHover { hovering in
            isHighlighted = hovering
            onHoverChanged(hovering)
        }
        .onTapGesture(count: 2) {
            if canOpenInCodex {
                onOpenInCodex()
            } else if hasOpenTab {
                onFocus()
            }
        }
        .contextMenu {
            if canOpenInCodex {
                Button("Open in Codex", action: onOpenInCodex)
            } else {
                Button("Focus Tab", action: onFocus)
                    .disabled(!hasOpenTab)
                Divider()
                Button("Paste /handoff") { onPasteCommand("/handoff") }
                    .disabled(!hasOpenTab)
                Button("Paste /compact") { onPasteCommand("/compact") }
                    .disabled(!hasOpenTab)
                Button("Ping (\"still there?\")", action: onPing)
                    .disabled(!hasOpenTab)
                Divider()
                Button(keepAliveMenuTitle, action: onToggleKeepAlive)
                    .disabled(!hasOpenTab)
            }
        }
    }

    private var statusColor: Color {
        session.supportsCacheCountdown ? status.color : .blue
    }

    /// Shown for every row, including idle — requested directly, so all three states read at a glance
    /// without needing to hover for the detail panel. Idle has no icon (nothing is happening), just the
    /// muted label, so it doesn't visually compete with the running/compacting badges.
    private var activityBadge: some View {
        HStack(spacing: 2) {
            if !session.activity.symbolName.isEmpty {
                Image(systemName: session.activity.symbolName)
                    .font(.system(size: 8))
            }
            Text(session.activity.label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(isHighlighted ? .white : session.activity.color)
    }

    /// Shown only while on, next to the hit-ratio text — requested directly, so which sessions are being
    /// kept alive automatically is visible at a glance in the list itself, not just via right-click or
    /// the hover detail panel.
    private var keepAliveBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
            Text("\(keepAliveInfo.remainingPings)")
                .font(.system(size: 9))
        }
        .foregroundStyle(isHighlighted ? .white : .blue)
        .help("Auto Keep-Alive on — \(keepAliveInfo.pingsUsed)/\(keepAliveInfo.maxPings) pings used")
    }

    /// Shown when total context — regardless of what put it there, one big tool dump or many small
    /// turns — has crossed `Session.bigContextWarnRatio` of the assumed context window. Every turn
    /// re-sends the whole thing, so this is a direct per-message cost multiplier either way. The hover
    /// detail panel breaks down what's in there and offers the `/compact` paste action.
    private var bigContextBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text("big context")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(isHighlighted ? .white : .orange)
        .help("~\(SessionListViewModel.compactTokens(session.currentContextTokens ?? 0)) tokens (\(Int((session.contextWindowUsageRatio ?? 0) * 100))% of a \(SessionListViewModel.compactTokens(session.effectiveContextWindowTokens))-token context window) are loaded and re-sent every turn — consider /compact.")
    }

    /// Automatic keep-alive stays available to switch on even with a full budget used up — the counter
    /// resets the moment it's (re-)enabled, see `KeepAliveTracker.setEnabled`.
    private var keepAliveMenuTitle: String {
        keepAliveInfo.enabled
            ? "Auto Keep-Alive: On (\(keepAliveInfo.pingsUsed)/\(keepAliveInfo.maxPings) used) — turn off"
            : "Auto Keep-Alive: Off — turn on"
    }

    private var countdownText: String {
        guard session.supportsCacheCountdown else { return "last \(ageText)" }
        return remaining > 0 ? SessionListViewModel.format(remaining) : "cold"
    }

    /// The projected save from keeping this session's cache warm (see
    /// `SessionListViewModel.keepWarmSaving`) — nil for a cold session (nothing warm left to protect), a
    /// Codex row (no cache countdown), or before the first turn with usage.
    private var keepWarmSave: (tokens: Int, costText: String?)? {
        guard session.supportsCacheCountdown, remaining > 0 else { return nil }
        return SessionListViewModel.keepWarmSaving(for: session, ttl: ttl)
    }

    /// Shown next to the countdown while a session is still warm: the tokens (and, when the model is priced,
    /// the dollars) a cold-cache rewrite would cost on the next turn — i.e. what pinging/handing off before
    /// expiry saves. Requested directly, so the cost of letting it go cold is visible at a glance, not just
    /// in the aggregate meter.
    @ViewBuilder
    private var keepWarmSaveBadge: some View {
        if let save = keepWarmSave {
            HStack(spacing: 2) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 8))
                Text(save.costText.map { "\(SessionListViewModel.compactTokens(save.tokens)) · \($0)" }
                    ?? SessionListViewModel.compactTokens(save.tokens))
                    .font(.system(size: 9))
            }
            .foregroundStyle(isHighlighted ? .white : .green)
            .help("Keeping this cache warm avoids re-writing ~\(SessionListViewModel.compactTokens(save.tokens)) tokens at cache-write price on the next turn\(save.costText.map { " — about \($0)" } ?? "").")
        }
    }

    private var hitRatioText: String {
        guard let ratio = session.cacheHitRatio else { return "—" }
        return String(format: session.agentKind == .codex ? "%.0f%% cached" : "%.0f%% hit", ratio * 100)
    }

    private var costText: String {
        guard session.agentKind == .claudeCode else { return "" }
        guard let cost = session.cost else { return "—" }
        return String(format: "$%.2f", cost)
    }

    private var ageText: String {
        let seconds = max(0, Int(now.timeIntervalSince(session.lastTurnTime)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
