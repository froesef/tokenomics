import SwiftUI

/// The content of the hover flyout panel (see DetailPanelPresenter) — session facts plus categorized
/// tool/plugin/skill usage, and the same paste/focus actions that used to live only in the row's
/// right-click menu. Requested directly, modeled on Docker Desktop's nested container menu: hovering an
/// item reveals more detail and its actions in a panel beside it, rather than a plain tooltip string.
struct SessionDetailPanelView: View {
    let session: Session
    let settings: SettingsStore
    let hasOpenTab: Bool
    /// Best-effort seconds since Ghostty's frontmost tab last pointed at this directory — see
    /// GhosttyController.timeSinceLastActive. Nil if never observed.
    let timeSinceLastActive: TimeInterval?
    let onFocus: () -> Void
    let onPasteCommand: (String) -> Void
    let onPing: () -> Void
    /// Reports whether the pointer is over this panel, so SessionListViewModel can keep it open while the
    /// pointer crosses from the row to here — see the doc comment on `rowHoverChanged`.
    let onHoverChanged: (Bool) -> Void

    @State private var hoveringFocus = false
    @State private var hoveringHandoff = false
    @State private var hoveringCompact = false
    @State private var hoveringPing = false

    private var ttl: TimeInterval { session.effectiveTTL(fallback: settings.ttl) }

    /// The action rows below deliberately span the panel's full width edge-to-edge, matching how a
    /// native menu's blue selection bar has no side margin — everything above them (info/usage sections)
    /// stays inset with its own padding instead of one uniform outer padding.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            sessionInfoSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if !session.toolUsage.isEmpty {
                Divider()
                usageSections
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            Divider()
            actions
                .padding(.vertical, 4)
        }
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial)
        .onHover(perform: onHoverChanged)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.projectName)
                .font(.system(size: 13, weight: .semibold))
            if let aiTitle = session.aiTitle {
                Text(aiTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(session.workingDirectory)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.head)
        }
    }

    private var sessionInfoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Session")
            if let model = session.model {
                infoRow("Model", model)
            }
            if let effort = session.effort {
                infoRow("Effort", effort.capitalized)
            }
            if let version = session.version {
                infoRow("CLI version", version)
            }
            infoRow("TTL", "\(Int(ttl / 60)) min (\(session.detectedTTL != nil ? "detected" : "global"))")
            infoRow("Last turn", Self.lastTurnFormatter.string(from: session.lastTurnTime))
            infoRow("Cache", "\(session.cacheCreationTokens) created / \(session.cacheReadTokens) read")
            if let ratio = session.cacheHitRatio {
                infoRow("Hit ratio", String(format: "%.0f%%", ratio * 100))
            }
            if let cost = session.cost {
                infoRow("Cost", String(format: "$%.2f", cost))
            }
            infoRow("Ghostty tab", hasOpenTab ? "open" : "not found")
            infoRow("Process", processDescription)
            if let rtkStats = session.rtkStats {
                infoRow("RTK savings", rtkSavingsText(rtkStats))
            }
            if let charCount = session.lastVisibleCharCount {
                infoRow("Last output", "\(charCount) chars")
            }
            infoRow("Last active", lastActiveText)
        }
    }

    private func rtkSavingsText(_ stats: RTKStats) -> String {
        guard stats.totalCommands > 0 else { return "no commands tracked yet" }
        return "\(stats.totalCommands) cmds, \(stats.totalSavedTokens) tok saved (\(String(format: "%.0f%%", stats.avgSavingsPercent)) avg)"
    }

    /// Surfaces the raw signal behind SessionListViewModel's adaptive lead time, rather than the computed
    /// lead time itself — showing the derived number here too would mean keeping that formula in sync in
    /// two places.
    private var lastActiveText: String {
        guard let seconds = timeSinceLastActive else { return "not observed yet" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    /// Categories `TranscriptWatcher.accumulateToolUsage` tallies from the transcript: MCP/plugin servers
    /// (e.g. `graphify`, `code-review-graph`) and Skills are the "saving mechanisms" the user asked to see
    /// grouped separately from plain built-in tool calls. Hooks are a different mechanism again — they
    /// run transparently around a tool call (e.g. `rtk` rewriting a Bash command) rather than being
    /// something the model chose to invoke, so they get their own category next to Plugins/MCP.
    private var usageSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.toolUsage.mcpServers.isEmpty {
                categorySection(title: "Plugins / MCP", items: session.toolUsage.mcpServers.sorted())
            }
            if !session.toolUsage.hooks.isEmpty {
                let byCount = session.toolUsage.hooks.sorted { $0.value > $1.value }
                categorySection(title: "Hooks", items: byCount.map { "\($0.key) ×\($0.value)" })
            }
            if !session.toolUsage.skills.isEmpty {
                categorySection(title: "Skills", items: session.toolUsage.skills.sorted())
            }
            if !session.toolUsage.builtInTools.isEmpty {
                let byCount = session.toolUsage.builtInTools.sorted { $0.value > $1.value }
                categorySection(title: "Tools", items: byCount.map { "\($0.key) ×\($0.value)" })
            }
        }
    }

    private func categorySection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle(title)
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow("Focus Tab", isHovering: $hoveringFocus, action: onFocus)
            actionRow("Paste /handoff", isHovering: $hoveringHandoff) { onPasteCommand("/handoff") }
            actionRow("Paste /compact", isHovering: $hoveringCompact) { onPasteCommand("/compact") }
            actionRow("Ping (\"still there?\")", isHovering: $hoveringPing, action: onPing)
        }
    }

    private func actionRow(_ title: String, isHovering: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MenuRowLabel(title: title, isHovering: isHovering.wrappedValue, isEnabled: hasOpenTab)
        }
        .buttonStyle(.plain)
        .disabled(!hasOpenTab)
        .onHover { isHovering.wrappedValue = $0 }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
        }
    }

    private static let lastTurnFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Same honest hedge as before: a PID means *some* claude process is running in this directory, not
    /// proof it's *this* transcript's process (see ProcessMatcher).
    private var processDescription: String {
        switch session.livePIDs.count {
        case 0: return "not detected — likely exited"
        case 1: return "running (PID \(session.livePIDs[0]))"
        default: return "\(session.livePIDs.count) running (PIDs \(session.livePIDs.map(String.init).joined(separator: ", ")))"
        }
    }
}
