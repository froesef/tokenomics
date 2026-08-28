import Foundation
import XCTest
@testable import Tokenomics

@MainActor
final class KeepAliveTrackerTests: XCTestCase {
    private let ttl: TimeInterval = 300

    override func setUp() async throws {
        try await super.setUp()
        // These tests only read/write in-memory KeepAliveTracker state, but shouldFire/maxPings also
        // read SettingsStore.shared — pin the fields they consult so results don't depend on whatever a
        // previous run (or the real app) last persisted to UserDefaults.
        await MainActor.run {
            SettingsStore.shared.keepAliveLeadSeconds = 30
            SettingsStore.shared.keepAliveMaxPings5m = 10
            SettingsStore.shared.keepAliveMaxPings60m = 3
        }
    }

    private func makeSession(
        id: String = "sess1", now: Date = Date(), cacheTouchTime: Date?,
        lastAssistantTurnTime: Date = .distantPast, activity: SessionActivity = .idle
    ) -> Session {
        Session(
            id: id,
            workingDirectory: "/Users/me/project",
            aiTitle: nil,
            lastTurnTime: cacheTouchTime ?? now,
            lastAssistantTurnTime: lastAssistantTurnTime,
            cacheTouchTime: cacheTouchTime,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalInputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            reasoningOutputTokens: nil,
            toolUsage: ToolUsage(),
            model: nil,
            effort: nil,
            version: nil,
            lastVisibleCharCount: nil,
            currentContextTokens: nil,
            activity: activity,
            compactionStartedAt: nil,
            detectedTTL: nil
        )
    }

    func testSetEnabledResetsPingBudget() {
        let tracker = KeepAliveTracker()
        let now = Date()
        let session = makeSession(now: now, cacheTouchTime: now)

        tracker.setEnabled(true, for: session)
        tracker.recordFireAttempted(for: session.id, now: now)
        tracker.recordFireSucceeded(for: session.id)
        XCTAssertEqual(tracker.info(for: session, settings: .shared).pingsUsed, 1)

        // Re-enabling gives a fresh budget, even though it was already on.
        tracker.setEnabled(true, for: session)
        XCTAssertEqual(tracker.info(for: session, settings: .shared).pingsUsed, 0)
    }

    /// `keepAliveAllActiveSessions` must never override a session the user has already toggled
    /// themselves, on or off — see KeepAliveTracker.autoEnableIfNeeded.
    func testAutoEnableSkipsSessionUserAlreadyToggledOff() {
        let tracker = KeepAliveTracker()
        let now = Date()
        let session = makeSession(now: now, cacheTouchTime: now)

        tracker.setEnabled(true, for: session)
        tracker.setEnabled(false, for: session) // user turns it off manually
        tracker.autoEnableIfNeeded(for: session)

        XCTAssertFalse(tracker.info(for: session, settings: .shared).enabled)
    }

    func testAutoEnableTurnsOnAUntouchedSession() {
        let tracker = KeepAliveTracker()
        let now = Date()
        let session = makeSession(now: now, cacheTouchTime: now)

        tracker.autoEnableIfNeeded(for: session)
        XCTAssertTrue(tracker.info(for: session, settings: .shared).enabled)
    }

    /// While a fired ping is awaiting its answer, transcript growth that's just the prompt echo (no new
    /// assistant turn yet) must not be mistaken for the user coming back — the budget must stand.
    func testObserveTurnDoesNotResetBudgetWhileAwaitingOwnPingEcho() {
        let tracker = KeepAliveTracker()
        let t0 = Date()
        var session = makeSession(now: t0, cacheTouchTime: t0)
        tracker.setEnabled(true, for: session)
        tracker.recordFireAttempted(for: session.id, now: t0)
        tracker.recordFireSucceeded(for: session.id)

        // Prompt echo landed (lastTurnTime advances) but no new assistant turn yet.
        let t1 = t0.addingTimeInterval(1)
        session = makeSession(id: session.id, now: t1, cacheTouchTime: t1, lastAssistantTurnTime: .distantPast)
        tracker.observeTurn(session: session, now: t1)

        XCTAssertEqual(tracker.info(for: session, settings: .shared).pingsUsed, 1)
        XCTAssertFalse(tracker.shouldFire(session: session, now: t1, settings: .shared)) // still awaiting
    }

    /// Once the ping's actual answer (a fresh assistant turn) is observed, the in-flight flag clears and
    /// the session can fire again next time it's due — but the ping still counts toward the cap.
    func testObserveTurnClearsAwaitingOnceAssistantAnswerLands() {
        let tracker = KeepAliveTracker()
        let t0 = Date()
        let session0 = makeSession(now: t0, cacheTouchTime: t0)
        tracker.setEnabled(true, for: session0)
        tracker.recordFireAttempted(for: session0.id, now: t0)
        tracker.recordFireSucceeded(for: session0.id)

        let t1 = t0.addingTimeInterval(2)
        let answered = makeSession(id: session0.id, now: t1, cacheTouchTime: t1, lastAssistantTurnTime: t1)
        tracker.observeTurn(session: answered, now: t1)

        XCTAssertEqual(tracker.info(for: answered, settings: .shared).pingsUsed, 1)
    }

    /// Real user activity (lastTurnTime advances while *not* mid-ping) resets the budget — the user is
    /// back, so the unattended assumption no longer holds.
    func testObserveTurnResetsBudgetOnRealUserActivity() {
        let tracker = KeepAliveTracker()
        let t0 = Date()
        let session0 = makeSession(now: t0, cacheTouchTime: t0)
        tracker.setEnabled(true, for: session0)
        tracker.recordFireAttempted(for: session0.id, now: t0)
        tracker.recordFireSucceeded(for: session0.id)
        // Ping answered and cleared.
        let t1 = t0.addingTimeInterval(2)
        tracker.observeTurn(session: makeSession(id: session0.id, now: t1, cacheTouchTime: t1, lastAssistantTurnTime: t1), now: t1)

        // Later, the user genuinely comes back and starts a new turn.
        let t2 = t1.addingTimeInterval(120)
        let userReturned = makeSession(id: session0.id, now: t2, cacheTouchTime: t2, lastAssistantTurnTime: t2)
        tracker.observeTurn(session: userReturned, now: t2)

        XCTAssertEqual(tracker.info(for: userReturned, settings: .shared).pingsUsed, 0)
    }

    func testShouldFireOnlyWithinLeadWindowAndBudget() {
        let tracker = KeepAliveTracker()
        let now = Date()
        // 20s of runway left on a 300s TTL cache, lead time is 30s — inside the firing window.
        let dueSoon = makeSession(now: now, cacheTouchTime: now.addingTimeInterval(-(ttl - 20)))
        tracker.setEnabled(true, for: dueSoon)
        XCTAssertTrue(tracker.shouldFire(session: dueSoon, now: now, settings: .shared))

        // Plenty of runway left — not due yet.
        let notDueYet = makeSession(id: "sess2", now: now, cacheTouchTime: now)
        tracker.setEnabled(true, for: notDueYet)
        XCTAssertFalse(tracker.shouldFire(session: notDueYet, now: now, settings: .shared))

        // Disabled sessions never fire regardless of runway.
        let disabled = makeSession(id: "sess3", now: now, cacheTouchTime: now.addingTimeInterval(-(ttl - 20)))
        XCTAssertFalse(tracker.shouldFire(session: disabled, now: now, settings: .shared))
    }

    /// A turn already in flight (`.running`/`.compacting`) will touch the cache on its own — pasting a
    /// ping on top would just queue uselessly behind it.
    func testShouldFireSkipsSessionsWithATurnInFlight() {
        let tracker = KeepAliveTracker()
        let now = Date()
        let running = makeSession(now: now, cacheTouchTime: now.addingTimeInterval(-(ttl - 20)), activity: .running)
        tracker.setEnabled(true, for: running)
        XCTAssertFalse(tracker.shouldFire(session: running, now: now, settings: .shared))
    }

    /// Fires exactly once per warm period once the ping budget is spent, and stays quiet until the
    /// budget resets.
    func testConsumeExhaustionWarningFiresOncePerWarmPeriod() {
        let tracker = KeepAliveTracker()
        var now = Date()
        var session = makeSession(now: now, cacheTouchTime: now)
        tracker.setEnabled(true, for: session)

        // Fire the full 10-ping budget (5m-TTL cap, pinned in setUp), clearing the in-flight flag after
        // each one lands (an assistant answer) so the next fire attempt isn't blocked by it.
        for _ in 0..<10 {
            tracker.recordFireAttempted(for: session.id, now: now)
            tracker.recordFireSucceeded(for: session.id)
            now = now.addingTimeInterval(1)
            let answered = makeSession(id: session.id, now: now, cacheTouchTime: now, lastAssistantTurnTime: now)
            tracker.observeTurn(session: answered, now: now)
        }
        session = makeSession(id: session.id, now: now, cacheTouchTime: now)

        XCTAssertEqual(tracker.info(for: session, settings: .shared).pingsUsed, 10)
        XCTAssertTrue(tracker.consumeExhaustionWarning(for: session, settings: .shared))
        XCTAssertFalse(tracker.consumeExhaustionWarning(for: session, settings: .shared))
    }

    /// "Let Expire" disables keep-alive and suppresses further expiry banners for this session, until
    /// real user activity is observed again.
    func testRequestExpireDisablesAndSuppressesUntilUserReturns() {
        let tracker = KeepAliveTracker()
        let t0 = Date()
        let session0 = makeSession(now: t0, cacheTouchTime: t0)
        tracker.setEnabled(true, for: session0)

        tracker.requestExpire(for: session0)
        XCTAssertFalse(tracker.info(for: session0, settings: .shared).enabled)
        XCTAssertTrue(tracker.isExpireRequested(for: session0))

        let t1 = t0.addingTimeInterval(60)
        let userReturned = makeSession(id: session0.id, now: t1, cacheTouchTime: t1, lastAssistantTurnTime: t1)
        tracker.observeTurn(session: userReturned, now: t1)
        XCTAssertFalse(tracker.isExpireRequested(for: userReturned))
    }
}
