import SwiftUI

/// The app's Settings window (spec.md §6), opened via the footer's "Settings…" row.
///
/// No TTL control here — reported directly that offering "Prompt cache TTL" as a setting was misleading,
/// since the app doesn't control it: the real TTL is fixed by how Claude Code itself was launched
/// (`ENABLE_PROMPT_CACHING_1H`) and is read straight off the transcript per session (`Session.detectedTTL`)
/// rather than configured here. See `SettingsStore.ttl` for the (non-editable) fallback used only before
/// a session's TTL has been detected.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// Wide enough that the longest row title never clips against the trailing stepper/toggle control —
    /// an explicit width fixed a real clipping bug (reported directly, with a screenshot) where `Form`'s
    /// default alignment sized the label column past a too-narrow frame. Combined with
    /// `.windowResizability(.contentSize)` on the Settings scene (App.swift) so the window can't be
    /// resized back below this width either. Widened again to fit the grouped-style rows'
    /// title-plus-description layout, matching System Settings' own detail-pane width.
    private let contentWidth: CGFloat = 520

    var body: some View {
        Form {
            Section("Session Monitoring") {
                LabeledContent {
                    Stepper(value: $settings.refreshIntervalSeconds, in: 5...60, step: 5) {
                        Text("\(Int(settings.refreshIntervalSeconds))s")
                    }
                } label: {
                    SettingLabel(
                        title: "Refresh interval",
                        description: "How often to re-scan transcripts on the polling timer, as a backup to the file watcher that normally picks up changes right away."
                    )
                }

                LabeledContent {
                    Stepper(value: $settings.expiringSoonThresholdSeconds, in: 15...300, step: 15) {
                        Text("\(Int(settings.expiringSoonThresholdSeconds))s")
                    }
                } label: {
                    SettingLabel(
                        title: "Expiring-soon threshold",
                        description: "Mark a session's cache status \"expiring soon\" (orange) once its countdown drops below this many seconds, instead of staying \"warm\" (green) until the moment it goes cold."
                    )
                }
            }

            Section("Menu Bar") {
                Picker(selection: $settings.menuBarMode) {
                    Text("Next expiry countdown").tag(MenuBarMode.nextExpiry)
                    Text("Tokens lost today").tag(MenuBarMode.lostToday)
                } label: {
                    SettingLabel(
                        title: "Menu bar shows",
                        description: "Show the soonest cache countdown, or today's tokens lost to cold caches (\"🔻 128k lost\"). Falls back to the countdown when nothing's been lost yet."
                    )
                }
                .pickerStyle(.menu)
            }

            Section("Notifications") {
                Toggle(isOn: $settings.notifyBeforeCold) {
                    SettingLabel(
                        title: "Notify before cold",
                        description: "Send a notification shortly before a session's prompt cache goes cold."
                    )
                }

                if settings.notifyBeforeCold {
                    LabeledContent("Lead time") {
                        Stepper(value: $settings.notifyLeadTimeSeconds, in: 10...120, step: 10) {
                            Text("\(Int(settings.notifyLeadTimeSeconds))s")
                        }
                    }
                }

                Toggle(isOn: $settings.terminalFocusEnabled) {
                    SettingLabel(
                        title: "Enable terminal focus action",
                        description: "Let notifications focus the originating session's terminal window (Ghostty or iTerm2)."
                    )
                }
            }

            Section("Auto Keep-Alive") {
                Toggle(isOn: $settings.keepAliveAllActiveSessions) {
                    SettingLabel(
                        title: "Keep every active session alive",
                        description: "Automatically turns on Auto Keep-Alive for any session whose cache is still hot, so you don't have to switch it on per session."
                    )
                }

                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("", value: $settings.keepAliveLeadSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("s").foregroundStyle(.secondary)
                    }
                } label: {
                    SettingLabel(
                        title: "Lead time",
                        description: "Fire the keep-alive ping this many seconds before a session's cache would go cold. Higher is safer — it leaves runway for the paste, the reply, and a retry if one is needed; too low and the ping lands right as the cache expires. Set it high to watch pings fire early while debugging. Default 30s."
                    )
                }

                LabeledContent {
                    Stepper(value: $settings.keepAliveMaxPings5m, in: 1...30, step: 1) {
                        Text("\(Int(settings.keepAliveMaxPings5m))×")
                    }
                } label: {
                    SettingLabel(
                        title: "Cap for 5-minute TTL sessions",
                        description: "Max automatic keep-alive pings before it stops, for sessions on the 5-minute cache TTL."
                    )
                }

                LabeledContent {
                    Stepper(value: $settings.keepAliveMaxPings60m, in: 1...30, step: 1) {
                        Text("\(Int(settings.keepAliveMaxPings60m))×")
                    }
                } label: {
                    SettingLabel(
                        title: "Cap for 1-hour TTL sessions",
                        description: "Max automatic keep-alive pings before it stops, for sessions on the 1-hour cache TTL."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A two-line row label (bold title + secondary description) matching System Settings' own
/// detail-pane rows, e.g. the "Hover Text" toggle rows in System Settings → Accessibility.
private struct SettingLabel: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
