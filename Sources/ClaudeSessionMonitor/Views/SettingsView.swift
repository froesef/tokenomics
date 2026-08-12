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
                LabeledContent("Refresh interval") {
                    Stepper(value: $settings.refreshIntervalSeconds, in: 5...60, step: 5) {
                        Text("\(Int(settings.refreshIntervalSeconds))s")
                    }
                }

                LabeledContent("Expiring-soon threshold") {
                    Stepper(value: $settings.expiringSoonThresholdSeconds, in: 15...300, step: 15) {
                        Text("\(Int(settings.expiringSoonThresholdSeconds))s")
                    }
                }
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

                Toggle(isOn: $settings.ghosttyFocusEnabled) {
                    SettingLabel(
                        title: "Enable Ghostty focus action",
                        description: "Let notifications focus the originating session's Ghostty window."
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
