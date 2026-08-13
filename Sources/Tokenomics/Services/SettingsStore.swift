import Foundation
import Combine

/// Minimal settings, persisted via UserDefaults (spec.md §6). Not in spec.md's suggested file layout
/// (§7) — added because @AppStorage doesn't propagate change notifications out of an ObservableObject,
/// so the ViewModel needs a small published store instead.
/// What the menu-bar title shows when at least one session is being tracked.
enum MenuBarMode: String, CaseIterable {
    /// The soonest-to-expire session's live countdown (the app's original behavior).
    case nextExpiry
    /// Today's cold-cache waste ("🔻 128k lost") — the quantified cost of letting caches go cold.
    case lostToday
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var refreshIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(refreshIntervalSeconds, forKey: Keys.refreshInterval) }
    }
    @Published var expiringSoonThresholdSeconds: Double {
        didSet { UserDefaults.standard.set(expiringSoonThresholdSeconds, forKey: Keys.expiringSoonThreshold) }
    }
    @Published var notifyBeforeCold: Bool {
        didSet { UserDefaults.standard.set(notifyBeforeCold, forKey: Keys.notifyBeforeCold) }
    }
    @Published var notifyLeadTimeSeconds: Double {
        didSet { UserDefaults.standard.set(notifyLeadTimeSeconds, forKey: Keys.notifyLeadTime) }
    }
    @Published var ghosttyFocusEnabled: Bool {
        didSet { UserDefaults.standard.set(ghosttyFocusEnabled, forKey: Keys.ghosttyFocusEnabled) }
    }
    /// Cap on automatic keep-alive pings (see KeepAliveTracker) for a session whose TTL is the 5-minute
    /// bucket — higher than the 1h bucket's cap because each ping only buys 5 minutes of runway, so
    /// covering a comparable stretch of "user is away" needs proportionally more of them.
    @Published var keepAliveMaxPings5m: Double {
        didSet { UserDefaults.standard.set(keepAliveMaxPings5m, forKey: Keys.keepAliveMaxPings5m) }
    }
    /// Same cap, for the 1-hour TTL bucket.
    @Published var keepAliveMaxPings60m: Double {
        didSet { UserDefaults.standard.set(keepAliveMaxPings60m, forKey: Keys.keepAliveMaxPings60m) }
    }
    /// When on, every session with time left on its cache gets its per-session Auto Keep-Alive switched
    /// on automatically — requested directly, so a session doesn't go cold for lack of a manual toggle
    /// just because the user forgot, or a new session was never touched. See
    /// `SessionListViewModel.enableKeepAliveForActiveSessions`, which applies this both immediately when
    /// switched on and on every rescan thereafter (so a session that later becomes active also picks it
    /// up), while still respecting each session's own ping cap above.
    @Published var keepAliveAllActiveSessions: Bool {
        didSet { UserDefaults.standard.set(keepAliveAllActiveSessions, forKey: Keys.keepAliveAllActiveSessions) }
    }

    /// Whether the menu-bar title shows the next-expiry countdown or today's cold-cache waste — the
    /// "menu-bar savings mode" toggle. Stored as the enum's raw value.
    @Published var menuBarMode: MenuBarMode {
        didSet { UserDefaults.standard.set(menuBarMode.rawValue, forKey: Keys.menuBarMode) }
    }

    /// Fallback TTL used only when a session has no per-turn `detectedTTL` yet (see
    /// `Session.effectiveTTL`) — e.g. before its first cache-writing turn. Not a user-facing setting: the
    /// real TTL is a property of how Claude Code was launched (`ENABLE_PROMPT_CACHING_1H`), not something
    /// this app controls, and `detectedTTL` reads the real value straight off the transcript's own
    /// `usage.cache_creation` fields once available — ground truth, not a guess. Removed from the Settings
    /// UI after direct feedback that presenting it as a togglable setting was misleading. 5 min matches
    /// the actual default TTL on API-key/Bedrock auth (spec.md §0) — the more common case absent detection.
    let ttl: TimeInterval = 300

    private enum Keys {
        static let refreshInterval = "refreshIntervalSeconds"
        static let expiringSoonThreshold = "expiringSoonThresholdSeconds"
        static let notifyBeforeCold = "notifyBeforeCold"
        static let notifyLeadTime = "notifyLeadTimeSeconds"
        static let ghosttyFocusEnabled = "ghosttyFocusEnabled"
        static let keepAliveMaxPings5m = "keepAliveMaxPings5m"
        static let keepAliveMaxPings60m = "keepAliveMaxPings60m"
        static let keepAliveAllActiveSessions = "keepAliveAllActiveSessions"
        static let menuBarMode = "menuBarMode"
    }

    private init() {
        let d = UserDefaults.standard
        refreshIntervalSeconds = (d.object(forKey: Keys.refreshInterval) as? Double) ?? 10
        expiringSoonThresholdSeconds = (d.object(forKey: Keys.expiringSoonThreshold) as? Double) ?? 90
        notifyBeforeCold = (d.object(forKey: Keys.notifyBeforeCold) as? Bool) ?? true
        notifyLeadTimeSeconds = (d.object(forKey: Keys.notifyLeadTime) as? Double) ?? 60
        ghosttyFocusEnabled = (d.object(forKey: Keys.ghosttyFocusEnabled) as? Bool) ?? true
        keepAliveMaxPings5m = (d.object(forKey: Keys.keepAliveMaxPings5m) as? Double) ?? 10
        keepAliveMaxPings60m = (d.object(forKey: Keys.keepAliveMaxPings60m) as? Double) ?? 3
        keepAliveAllActiveSessions = (d.object(forKey: Keys.keepAliveAllActiveSessions) as? Bool) ?? false
        menuBarMode = (d.string(forKey: Keys.menuBarMode)).flatMap(MenuBarMode.init(rawValue:)) ?? .nextExpiry
    }
}
