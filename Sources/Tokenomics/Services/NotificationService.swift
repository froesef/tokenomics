import Foundation
import UserNotifications

/// Fires a local notification once per warm period, ~leadTime before a session goes cold (spec.md §6).
@MainActor
final class NotificationService {
    /// sessionID -> the lastTurnTime we already notified for. Keying on lastTurnTime (not a simple
    /// "already notified" bool) means a fresh turn — which resets the cache timer — also re-arms the
    /// notification for the next warm period, without re-notifying on every tick within the same one.
    private var notifiedTurns: [String: Date] = [:]

    /// UNUserNotificationCenter hard-crashes (NSInternalInconsistencyException) if the process has no
    /// CFBundleIdentifier — i.e. when running the bare executable directly instead of a real .app
    /// bundle (see README "Running without Xcode"). Guard on that rather than let it take the app down.
    private var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorizationIfNeeded() {
        guard isSupported else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(session: Session, remaining: TimeInterval, leadTime: TimeInterval) {
        guard isSupported else { return }
        guard remaining > 0, remaining <= leadTime else { return }
        guard notifiedTurns[session.id] != session.lastTurnTime else { return }
        notifiedTurns[session.id] = session.lastTurnTime

        let content = UNMutableNotificationContent()
        content.title = "\(session.projectName) cache expiring"
        content.body = "Cache goes cold in \(Int(remaining))s. Switch to this session to keep it warm."
        content.sound = .default
        content.userInfo = ["workingDirectory": session.workingDirectory]

        let request = UNNotificationRequest(identifier: "cache-expiring-\(session.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Fired once, right before the system sleeps (see `SessionListViewModel`'s `NSWorkspace.willSleepNotification`
    /// observer). While asleep the CPU is halted — no countdown tick or keep-alive ping can run — so this is
    /// the user's one chance to see, before the Mac goes dark, which session will need attention soonest.
    func notifySleepSummary(sessions: [Session], settings: SettingsStore) {
        guard isSupported else { return }
        let now = Date()
        let warm = sessions
            .filter(\.supportsCacheCountdown)
            .map { ($0, $0.remaining(now: now, ttl: $0.effectiveTTL(fallback: settings.ttl))) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 < $1.1 }
        guard let (soonest, remaining) = warm.first else { return }

        let content = UNMutableNotificationContent()
        content.title = warm.count == 1 ? "Going to sleep — 1 active session" : "Going to sleep — \(warm.count) active sessions"
        var body = "\(soonest.projectName) needs attention first — cache expires in \(Int(remaining))s."
        if warm.count > 1 {
            body += " \(warm.count - 1) more session(s) still warm."
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "sleep-summary-\(now.timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
