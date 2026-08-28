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

/// How a session's idle/running/compacting/needs-input badge is computed. See HookActivityWatcher and
/// TranscriptWatcher.updateActivity's doc comments for what each mode can and can't see — most notably,
/// hooks carry zero token/cost/cache data (confirmed against the official hooks reference), so cost/cache/
/// TTL accounting always comes from the transcript regardless of which mode is selected here; only the
/// activity badge itself switches.
enum ActivitySource: String, CaseIterable {
    /// Infer activity from transcript event order (TranscriptWatcher.updateActivity). Works for every
    /// session with no setup, but relies on `system/turn_duration` to close an ordinary turn — an event
    /// that's absent in at least some non-interactive invocations (e.g. Agent-SDK-driven sessions,
    /// confirmed by inspecting a real transcript with zero `turn_duration` lines across 1,451 events), so
    /// those sessions can get stuck showing "running" indefinitely.
    case jsonl
    /// Read activity from Claude Code hooks (HookInstaller/HookActivityWatcher) instead. Needs hook entries
    /// installed in `~/.claude/settings.json` (done automatically when this mode is selected — see
    /// HookInstaller) and only reports state for sessions that have fired at least one hook event since
    /// install; a session with no hook data yet falls back to the JSONL-inferred activity.
    case hooks
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
    @Published var terminalFocusEnabled: Bool {
        didSet { UserDefaults.standard.set(terminalFocusEnabled, forKey: Keys.terminalFocusEnabled) }
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
    /// How many seconds before a cache would go cold to fire the automatic keep-alive ping (see
    /// `KeepAliveTracker.shouldFire`). Generous by default: the ping must survive the AppleScript round
    /// trip, the model answering, and the occasional retry after a ping that didn't land — too small a
    /// value issues the ping right as the timer runs out and the cache goes cold anyway. Exposed as a text
    /// field mainly so it can be set high for debugging (watch a ping fire long before expiry).
    @Published var keepAliveLeadSeconds: Double {
        didSet { UserDefaults.standard.set(keepAliveLeadSeconds, forKey: Keys.keepAliveLeadSeconds) }
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

    /// Feature flag for the activity badge's data source — see ActivitySource. Switching this is what
    /// drives HookInstaller.install()/uninstall() (see SessionListViewModel's `$activitySource` sink), not
    /// this store itself: SettingsStore only persists the choice.
    @Published var activitySource: ActivitySource {
        didSet { UserDefaults.standard.set(activitySource.rawValue, forKey: Keys.activitySource) }
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
        static let terminalFocusEnabled = "terminalFocusEnabled"
        static let keepAliveMaxPings5m = "keepAliveMaxPings5m"
        static let keepAliveMaxPings60m = "keepAliveMaxPings60m"
        static let keepAliveLeadSeconds = "keepAliveLeadSeconds"
        static let keepAliveAllActiveSessions = "keepAliveAllActiveSessions"
        static let menuBarMode = "menuBarMode"
        static let activitySource = "activitySource"
    }

    private init() {
        let d = UserDefaults.standard
        refreshIntervalSeconds = (d.object(forKey: Keys.refreshInterval) as? Double) ?? 10
        expiringSoonThresholdSeconds = (d.object(forKey: Keys.expiringSoonThreshold) as? Double) ?? 90
        notifyBeforeCold = (d.object(forKey: Keys.notifyBeforeCold) as? Bool) ?? true
        notifyLeadTimeSeconds = (d.object(forKey: Keys.notifyLeadTime) as? Double) ?? 60
        terminalFocusEnabled = (d.object(forKey: Keys.terminalFocusEnabled) as? Bool) ?? true
        keepAliveMaxPings5m = (d.object(forKey: Keys.keepAliveMaxPings5m) as? Double) ?? 10
        keepAliveMaxPings60m = (d.object(forKey: Keys.keepAliveMaxPings60m) as? Double) ?? 3
        keepAliveLeadSeconds = (d.object(forKey: Keys.keepAliveLeadSeconds) as? Double) ?? 30
        keepAliveAllActiveSessions = (d.object(forKey: Keys.keepAliveAllActiveSessions) as? Bool) ?? false
        menuBarMode = (d.string(forKey: Keys.menuBarMode)).flatMap(MenuBarMode.init(rawValue:)) ?? .nextExpiry
        activitySource = (d.string(forKey: Keys.activitySource)).flatMap(ActivitySource.init(rawValue:)) ?? .jsonl
    }
}
