import Foundation

/// What the UI needs to render a session's keep-alive affordance.
struct KeepAliveInfo: Equatable {
    var enabled: Bool
    var pingsUsed: Int
    var maxPings: Int
    var remainingPings: Int { max(0, maxPings - pingsUsed) }
}

/// One session's automatic-keep-alive bookkeeping.
private struct KeepAliveState {
    var enabled = false
    var pingsUsed = 0
    var lastSeenTurnTime: Date
    /// True from the moment a ping is fired until either its reply is observed in the transcript or
    /// `ackTimeout` elapses — blocks firing again while one is already in flight.
    var awaitingOwnPingResponse = false
    var pingFiredAt: Date?
}

/// Drives the "unattended keep-alive" feature: requested directly for when the user is away (a meeting,
/// lunch) and hasn't manually pinged or replied before a session's cache would otherwise go cold. Per
/// session, when switched on, this auto-pastes-and-submits a trivial "still there?" prompt shortly before
/// the TTL would expire, up to a capped number of times, so an unattended session's cache stays warm
/// without the user touching anything — see `GhosttyController.pasteTextAndSubmit` for the one narrow
/// exception this carves out of the app's otherwise strict "paste, never execute" rule.
///
/// The cap exists so a session nobody's coming back to doesn't get auto-pinged forever; it resets the
/// moment the user's own activity (a real turn, not our own ping's reply) is observed in the transcript,
/// since that means they're back and the unattended assumption no longer holds.
@MainActor
final class KeepAliveTracker {
    /// How long before a cache would go cold to fire the ping — long enough for the AppleScript round
    /// trip (focus + paste + Return) to land before the TTL clock actually runs out, short enough that it
    /// doesn't fire while there's still plenty of runway left (which would burn budget for nothing).
    private static let leadSeconds: TimeInterval = 15
    /// If a fired ping's reply never shows up in the transcript (paste silently failed, tab closed,
    /// etc.), stop waiting for it after this long so the session doesn't get stuck permanently unable to
    /// fire again.
    private static let ackTimeout: TimeInterval = 30

    private var states: [String: KeepAliveState] = [:]

    func isEnabled(_ sessionID: String) -> Bool {
        states[sessionID]?.enabled ?? false
    }

    func setEnabled(_ enabled: Bool, for session: Session) {
        var state = states[session.id] ?? KeepAliveState(lastSeenTurnTime: session.lastTurnTime)
        state.enabled = enabled
        if enabled {
            // Fresh budget every time it's switched on, including re-enabling after it ran out.
            state.pingsUsed = 0
            state.awaitingOwnPingResponse = false
            state.pingFiredAt = nil
            state.lastSeenTurnTime = session.lastTurnTime
        }
        states[session.id] = state
    }

    func info(for session: Session, settings: SettingsStore) -> KeepAliveInfo {
        let state = states[session.id]
        return KeepAliveInfo(
            enabled: state?.enabled ?? false,
            pingsUsed: state?.pingsUsed ?? 0,
            maxPings: maxPings(for: session.effectiveTTL(fallback: settings.ttl), settings: settings)
        )
    }

    /// Called once per rescan for every session: reconciles the transcript's actual `lastTurnTime` against
    /// what this tracker last saw. A change observed while awaiting our own ping's reply is assumed to
    /// *be* that reply (cleared, budget stands); any other change is real user activity (budget resets —
    /// they're back). Also clears a stuck `awaitingOwnPingResponse` past `ackTimeout`.
    func observeTurn(session: Session, now: Date) {
        guard var state = states[session.id] else { return }
        if session.lastTurnTime > state.lastSeenTurnTime {
            if state.awaitingOwnPingResponse {
                state.awaitingOwnPingResponse = false
                state.pingFiredAt = nil
            } else {
                state.pingsUsed = 0
            }
            state.lastSeenTurnTime = session.lastTurnTime
        }
        if state.awaitingOwnPingResponse, let firedAt = state.pingFiredAt,
           now.timeIntervalSince(firedAt) > Self.ackTimeout {
            state.awaitingOwnPingResponse = false
            state.pingFiredAt = nil
        }
        states[session.id] = state
    }

    /// Drops bookkeeping for sessions no longer in the list, so a closed-out session doesn't linger here
    /// forever.
    func pruneStates(keeping validIDs: Set<String>) {
        states = states.filter { validIDs.contains($0.key) }
    }

    func shouldFire(session: Session, now: Date, settings: SettingsStore) -> Bool {
        guard let state = states[session.id], state.enabled, !state.awaitingOwnPingResponse else { return false }
        let ttl = session.effectiveTTL(fallback: settings.ttl)
        let remaining = session.remaining(now: now, ttl: ttl)
        guard remaining > 0, remaining <= Self.leadSeconds else { return false }
        return state.pingsUsed < maxPings(for: ttl, settings: settings)
    }

    func recordFireAttempted(for sessionID: String, now: Date) {
        guard var state = states[sessionID] else { return }
        state.awaitingOwnPingResponse = true
        state.pingFiredAt = now
        states[sessionID] = state
    }

    func recordFireSucceeded(for sessionID: String) {
        guard var state = states[sessionID] else { return }
        state.pingsUsed += 1
        states[sessionID] = state
    }

    func recordFireFailed(for sessionID: String) {
        guard var state = states[sessionID] else { return }
        state.awaitingOwnPingResponse = false
        state.pingFiredAt = nil
        states[sessionID] = state
    }

    private func maxPings(for ttl: TimeInterval, settings: SettingsStore) -> Int {
        ttl >= 3600 ? Int(settings.keepAliveMaxPings60m) : Int(settings.keepAliveMaxPings5m)
    }
}
