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
    /// True from the moment a ping is fired until either its answer is observed in the transcript or
    /// `ackTimeout` elapses — blocks firing again while one is already in flight, and marks the window
    /// during which transcript growth is our own ping's round-trip (prompt echo + answer) rather than the
    /// user's activity, so it must not reset the ping budget.
    var awaitingOwnPingResponse = false
    var pingFiredAt: Date?
    /// True once the user has explicitly switched this session's keep-alive on or off themselves (row
    /// menu, detail panel). Once set, `autoEnableIfNeeded` leaves this session alone — otherwise a manual
    /// "turn off" while `SettingsStore.keepAliveAllActiveSessions` is on got silently forced back on at
    /// the next rescan, which is exactly the bug reported directly (screenshot showing a session the user
    /// had just turned off still reading "on" moments later).
    var setByUser = false
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
    // How long before a cache would go cold to fire the ping is user-configurable — see
    // `SettingsStore.keepAliveLeadSeconds` (default 30s) and its use in `shouldFire`. It's deliberately
    // generous: the ping has to survive the AppleScript round trip (focus + paste + Return), the model
    // actually answering, *and* the occasional retry after a ping that didn't land — a retry only clears
    // after `ackTimeout`, so the last possible fire in the window is at `leadSeconds − ackTimeout` seconds
    // of runway. Too small a value (the original hardcoded 15s) issued the retry with ~5s left and, plus
    // the round trip, landed *at* expiry — the reported case where the cache went cold anyway.
    /// If a fired ping's answer never shows up in the transcript (paste silently failed, tab busy or
    /// closed, etc.), stop waiting for it after this long so the session isn't wedged unable to fire
    /// again. Kept *below* `leadSeconds` on purpose: an unanswered ping's in-flight flag then clears while
    /// there's still runway left in the same firing window, so a single silent miss can be retried instead
    /// of stranding the session cold until the next full TTL cycle. A ping that actually lands clears the
    /// flag the moment its answer is observed (see `observeTurn`), well before this fallback matters.
    private static let ackTimeout: TimeInterval = 10

    private var states: [String: KeepAliveState] = [:]

    func setEnabled(_ enabled: Bool, for session: Session) {
        apply(enabled, for: session, setByUser: true)
    }

    /// Used only by `SessionListViewModel.enableKeepAliveForActiveSessions` (the
    /// `keepAliveAllActiveSessions` global setting) — switches keep-alive on for a session it's never
    /// touched before, but leaves alone any session the user has already toggled themselves, on or off,
    /// so a manual "turn off" sticks instead of being forced back on at the next rescan.
    func autoEnableIfNeeded(for session: Session) {
        if let state = states[session.id], state.setByUser || state.enabled { return }
        apply(true, for: session, setByUser: false)
    }

    private func apply(_ enabled: Bool, for session: Session, setByUser: Bool) {
        var state = states[session.id] ?? KeepAliveState(lastSeenTurnTime: session.lastTurnTime)
        state.enabled = enabled
        if setByUser { state.setByUser = true }
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

    /// Called once per rescan for every session: reconciles the transcript against what this tracker last
    /// saw, and decides whether the ping budget should reset.
    ///
    /// While awaiting our own ping's answer, everything the transcript grows by is that ping's round-trip —
    /// its echoed prompt (a *user* event) followed by the model's reply (an *assistant* turn). Only the
    /// assistant turn counts as the answer: seeing `lastAssistantTurnTime` advance past when we fired means
    /// the ping landed, so we clear the in-flight flag but keep the budget (this ping still counts toward
    /// the cap). Crucially we do *not* treat that same growth as user activity — an earlier version keyed
    /// off `lastTurnTime` alone and, when the prompt echo and the answer arrived on separate rescans,
    /// cleared the flag on the echo and then misread the answer as the user returning, silently resetting
    /// the budget and defeating the cap. A ping that never gets an answer clears via `ackTimeout` so the
    /// session isn't wedged. Only once we're *not* mid-ping does a fresh `lastTurnTime` mean the user is
    /// actually back — that, and only that, resets the budget.
    func observeTurn(session: Session, now: Date) {
        guard var state = states[session.id] else { return }
        if state.awaitingOwnPingResponse {
            let firedAt = state.pingFiredAt ?? .distantPast
            if session.lastAssistantTurnTime > firedAt {
                // The ping's answer landed — done waiting, budget stands.
                state.awaitingOwnPingResponse = false
                state.pingFiredAt = nil
                state.lastSeenTurnTime = session.lastTurnTime
            } else if now.timeIntervalSince(firedAt) > Self.ackTimeout {
                // No answer ever showed up; stop waiting so a later window can try again.
                state.awaitingOwnPingResponse = false
                state.pingFiredAt = nil
                state.lastSeenTurnTime = session.lastTurnTime
            } else {
                // Still mid-ping (e.g. only the prompt echo has landed) — absorb the growth without
                // mistaking it for the user, so the budget is untouched.
                state.lastSeenTurnTime = session.lastTurnTime
            }
        } else if session.lastTurnTime > state.lastSeenTurnTime {
            // Real user activity while we're not mid-ping: they're back, so the unattended assumption no
            // longer holds and the budget resets.
            state.pingsUsed = 0
            state.lastSeenTurnTime = session.lastTurnTime
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
        guard remaining > 0, remaining <= settings.keepAliveLeadSeconds else { return false }
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
