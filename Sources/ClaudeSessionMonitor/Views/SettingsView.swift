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

    /// Wide enough that the longest label ("Expiring-soon threshold: 300s") never clips against the
    /// trailing stepper/toggle control — an explicit width fixed a real clipping bug (reported directly,
    /// with a screenshot) where `Form`'s default alignment sized the label column past a too-narrow frame.
    /// Combined with `.windowResizability(.contentSize)` on the Settings scene (App.swift) so the window
    /// can't be resized back below this width either. Widened again per direct follow-up feedback (from
    /// 340 to 440) after the first width still left text clipped.
    private let contentWidth: CGFloat = 440

    var body: some View {
        Form {
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

            Toggle("Notify before cold", isOn: $settings.notifyBeforeCold)
            if settings.notifyBeforeCold {
                LabeledContent("Lead time") {
                    Stepper(value: $settings.notifyLeadTimeSeconds, in: 10...120, step: 10) {
                        Text("\(Int(settings.notifyLeadTimeSeconds))s")
                    }
                }
            }

            Toggle("Enable Ghostty focus action", isOn: $settings.ghosttyFocusEnabled)
        }
        .padding(20)
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
