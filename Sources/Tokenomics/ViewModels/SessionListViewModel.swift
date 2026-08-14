import AppKit
import Combine
import Foundation

/// Drives the session list: owns the transcript scan, the usage refresh, the per-second UI tick, and
/// the notification/banner triggers. Everything here is @MainActor per spec.md §7.
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var now: Date = .init()
    @Published private(set) var dependencyWarnings: [String] = []

    /// Today's savings/waste meter (see MeterStripView), recomputed from the transcripts on every rescan —
    /// no separate persistence, since the transcripts are the persistence. "Today" = the last 24h, matching
    /// the transcript scan window (TranscriptWatcher.recencyWindow).
    @Published private(set) var meter = SavingsMeter()

    let settings: SettingsStore
    let ghostty: TerminalController

    private let watcher: TranscriptWatcher
    private let codexWatcher: CodexSessionWatcher
    private let usage = UsageService()
    private let rtk = RTKService()
    private let notifications = NotificationService()
    private let banners = BannerPresenter()
    private let processMatcher = ProcessMatcher()
    private let keepAlive = KeepAliveTracker()
    let detailPanel = DetailPanelPresenter()

    /// Resolved once via WindowAccessor in MenuContentView — MenuBarExtra's `.window` style otherwise
    /// gives no handle on the dropdown's own NSWindow, which `detailPanel` needs to position itself.
    var hostWindow: NSWindow?

    private var tickTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var pointerOverRow = false
    private var pointerOverPanel = false
    /// Which session's detail panel is currently open, and what its cache-touch anchor looked like at the
    /// moment it opened — so a rescan can tell the shown snapshot went stale (a new turn landed, or the
    /// cache went cold via /compact or /clear) and close it rather than leave a popup reading numbers that
    /// no longer match the session underneath it.
    private var shownPanelSessionID: String?
    private var shownPanelCacheTouchTime: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Held for the app's entire lifetime, never ended: this is an `LSUIElement` accessory app with no
    /// Dock icon or visible window — the exact profile macOS's App Nap targets for background throttling,
    /// which coalesces/delays timers the longer the app sits unattended in the background. That's
    /// precisely when the automatic keep-alive (see KeepAliveTracker) most needs to fire — a session going
    /// cold while the user's away in a meeting is the whole point of the feature — so App Nap must stay
    /// disabled for this process the whole time it runs, not just while a window happens to be open.
    /// `.userInitiatedAllowingIdleSystemSleep` disables App Nap without also blocking the Mac's own idle
    /// system sleep, so this doesn't fight the user's own power/sleep settings.
    private let backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Keep per-second cache countdowns and automatic keep-alive pings on schedule while backgrounded"
    )

    init(settings: SettingsStore = .shared, ghostty: TerminalController = GhosttyController()) {
        self.settings = settings
        self.ghostty = ghostty
        self.watcher = TranscriptWatcher()
        self.codexWatcher = CodexSessionWatcher()

        notifications.requestAuthorizationIfNeeded()

        watcher.onChange = { [weak self] in
            Task { await self?.rescan() }
        }
        watcher.startWatching()
        codexWatcher.onChange = { [weak self] in
            Task { await self?.rescan() }
        }
        codexWatcher.startWatching()

        // Applied again on every `rescan()` too (so a session that later becomes active also picks it
        // up), but also here so switching the setting on takes effect right away rather than waiting for
        // the next 15s poll.
        settings.$keepAliveAllActiveSessions
            .filter { $0 }
            .sink { [weak self] _ in self?.enableKeepAliveForActiveSessions(now: Date()) }
            .store(in: &cancellables)

        startTicking()
        startPolling()
        Task { await rescan() }
    }

    deinit {
        tickTask?.cancel()
        pollTask?.cancel()
    }

    // MARK: - Timers

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.settings.refreshIntervalSeconds))
                await self.rescan()
            }
        }
    }

    /// The cheap per-second tick: recompute countdowns from already-cached lastTurnTime, no file I/O.
    private func tick() {
        now = Date()
        checkNotifications()
        checkKeepAlive()
        checkKeepAliveExhaustion()
    }

    // MARK: - Rescan (file watch / 15s timer)

    func rescan() async {
        let claudeScanned = watcher.scanAll()
        let codexScanned = codexWatcher.scanAll()
        let scanned = claudeScanned + codexScanned
        await usage.refresh()

        var withCost = scanned
        for i in withCost.indices {
            guard withCost[i].agentKind == .claudeCode else { continue }
            withCost[i].cost = await usage.cost(forSessionID: withCost[i].id)
        }

        await ghostty.refreshAvailability()
        await processMatcher.refresh()
        await rtk.refresh(workingDirectories: withCost.filter { $0.agentKind == .claudeCode }.map(\.workingDirectory))
        for i in withCost.indices {
            if withCost[i].agentKind == .claudeCode {
                withCost[i].livePIDs = await processMatcher.pids(forWorkingDirectory: withCost[i].workingDirectory)
                withCost[i].rtkStats = await rtk.stats(forWorkingDirectory: withCost[i].workingDirectory)
            }
        }

        // Drop sessions whose process has exited — requested directly: a transcript alone doesn't mean the
        // session is still reachable. Guarded on processMatcher actually having found *some* live `claude`
        // process at all: if `pgrep`/`lsof` failed outright (missing binary, unexpected sandboxing), every
        // session would read as "not running" and this filter would silently empty the whole list, which
        // is worse than the stale-but-visible status it replaces.
        let anyProcessDetected = withCost.contains { $0.agentKind == .claudeCode && $0.isProcessRunning }
        if anyProcessDetected {
            let codexSessions = withCost.filter { $0.agentKind == .codex }
            var claudeSessions = withCost.filter { $0.agentKind == .claudeCode && $0.isProcessRunning }

            // A live PID can't be attributed to a specific transcript (ProcessMatcher matches by working
            // directory only — see Session.livePIDs), so every session sharing a directory with a live
            // process passes the filter above, even a finished one from earlier today. Cap survivors per
            // directory to the number of live PIDs actually found there, keeping the most-recently-active
            // transcripts — the honest proxy for "which of these is the still-open tab" — so a stale
            // leftover doesn't show up as a second session (and, via GhosttyController's directory-only
            // matching, a second row that focuses the one real tab).
            var byDirectory: [String: [Session]] = [:]
            for session in claudeSessions {
                byDirectory[session.workingDirectory, default: []].append(session)
            }
            claudeSessions = byDirectory.values.flatMap { group -> [Session] in
                let liveCount = group[0].livePIDs.count
                guard group.count > liveCount else { return group }
                return Array(group.sorted { $0.lastTurnTime > $1.lastTurnTime }.prefix(liveCount))
            }
            withCost = claudeSessions + codexSessions
        }

        let ttlFallback = settings.ttl
        let currentNow = now
        // Warm/expiring-soon sessions always sort above cold ones, soonest-to-expire first. Within cold
        // sessions, sort by most-recently-active first — otherwise, once the list includes weeks of
        // history (see recencyWindow above), plain "remaining ascending" would put the *oldest* dead
        // session at the very top (its remaining time is the most negative), burying anything relevant.
        sessions = withCost.sorted { a, b in
            let aBucket = sortBucket(a, now: currentNow, ttlFallback: ttlFallback)
            let bBucket = sortBucket(b, now: currentNow, ttlFallback: ttlFallback)
            if aBucket != bBucket { return aBucket < bBucket }
            let aRemaining = a.remaining(now: currentNow, ttl: a.effectiveTTL(fallback: ttlFallback))
            let bRemaining = b.remaining(now: currentNow, ttl: b.effectiveTTL(fallback: ttlFallback))
            let aCold = aRemaining <= 0
            let bCold = bRemaining <= 0
            if !a.supportsCacheCountdown || !b.supportsCacheCountdown {
                return a.lastTurnTime > b.lastTurnTime
            }
            if aCold != bCold { return !aCold }
            return aCold ? a.lastTurnTime > b.lastTurnTime : aRemaining < bRemaining
        }

        for session in sessions {
            guard session.supportsCacheCountdown else { continue }
            keepAlive.observeTurn(session: session, now: currentNow)
        }
        enableKeepAliveForActiveSessions(now: currentNow)
        closeDetailPanelIfSessionReset()
        // Prune against the raw scan, not the process-filtered `sessions` list below: that filter relies
        // on flaky `pgrep`/`lsof` process detection (see the comment above), and a single missed scan
        // would otherwise wipe a session's keep-alive toggle for no reason the user did anything about.
        keepAlive.pruneStates(keeping: Set(scanned.map(\.id)))

        var warnings: [String] = []
        if await usage.isAvailable == false {
            warnings.append(await usage.unavailableReason ?? "ccusage unavailable")
        }
        if settings.ghosttyFocusEnabled && !ghostty.isAvailable {
            warnings.append("Ghostty automation not authorized — focus action disabled")
        }
        if sessions.contains(where: { $0.agentKind == .claudeCode }), await rtk.isAvailable == false {
            warnings.append("No token-savings CLI (e.g. rtk) found — consider installing one to track Bash token savings")
        }
        dependencyWarnings = warnings

        // Recompute today's savings/waste meter from the freshly-scanned sessions (transcripts are the
        // persistence — nothing extra is stored). Uses `currentNow` so it's consistent with this scan.
        meter = SavingsMeter.compute(sessions: sessions, now: currentNow)

        // No console/UI elsewhere surfaces this for a menu-bar-only app — run the built .app from
        // Terminal (see README "Debugging") to see per-scan session counts and warnings.
        FileHandle.standardError.write(
            "[Tokenomics] scan: \(sessions.count) session(s), warnings: \(warnings)\n".data(using: .utf8)!
        )
    }

    // MARK: - Notifications / banners

    /// How much extra runway to give a session before warning, on top of the user's base lead-time
    /// setting — requested directly, scaled by two signals: how much there was to read last time (more
    /// text → assume more reading time before the user could plausibly act) and how long it's been since
    /// the user was actually looking at this tab (longer away → they haven't started reading yet, so the
    /// warning needs to land early enough that there's still time once they do look back). Both are rough
    /// heuristics, not measured reading behavior, so each is capped to keep a huge response or a long-idle
    /// tab from blowing the lead time out to something absurd.
    private func adaptiveLeadTime(for session: Session) -> TimeInterval {
        let base = settings.notifyLeadTimeSeconds
        // ~15 chars/sec is a conservative skim-reading pace (well above the ~180-250wpm typical range).
        let readingSeconds = min(240, Double(session.lastVisibleCharCount ?? 0) / 15)
        let idleSeconds = ghostty.timeSinceLastActive(workingDirectory: session.workingDirectory) ?? 0
        let idleBuffer = min(120, idleSeconds / 10)
        return base + readingSeconds + idleBuffer
    }

    private func checkNotifications() {
        guard settings.notifyBeforeCold else { return }
        for session in sessions {
            guard session.supportsCacheCountdown else { continue }
            let ttl = session.effectiveTTL(fallback: settings.ttl)
            let remaining = session.remaining(now: now, ttl: ttl)
            let leadTime = adaptiveLeadTime(for: session)
            notifications.notifyIfNeeded(session: session, remaining: remaining, leadTime: leadTime)
            if remaining > 0 && remaining <= leadTime {
                banners.presentIfNeeded(
                    session: session, remaining: remaining,
                    keepWarmSummary: Self.keepWarmSummary(for: session, ttl: ttl),
                    onSwitch: { [weak self] in Task { await self?.focus(session) } },
                    onHandoff: { [weak self] in Task { await self?.pasteCommand("/handoff", into: session) } },
                    onPing: { [weak self] in Task { await self?.ping(session) } }
                )
            }
        }
    }

    // MARK: - Focus / paste actions

    func focus(_ session: Session) async {
        guard session.agentKind == .claudeCode else { return }
        guard settings.ghosttyFocusEnabled, ghostty.isAvailable else { return }
        // Close the dropdown right away rather than waiting on the AppleScript round-trip below: the
        // point is to jump straight into the terminal, so the menu shouldn't still be sitting on screen
        // once Ghostty comes forward. `orderOut` (not `close()`) since this is the same NSWindow instance
        // MenuBarExtra's `.window` style reuses every time the dropdown reopens — closing it outright risks
        // it being released.
        hostWindow?.orderOut(nil)
        try? await ghostty.focusTab(workingDirectory: session.workingDirectory, aiTitle: session.aiTitle)
    }

    func openInCodex(_ session: Session) {
        guard let url = session.codexThreadURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Pastes (never executes — see GhosttyController) a command like `/handoff` or `/compact` into the
    /// session's terminal and focuses it, so the user reviews and runs it themselves. `activate` defaults
    /// to true for these explicit paste actions; `ping` below calls through with `activate: false` since
    /// it's meant to stay quiet.
    func pasteCommand(_ text: String, into session: Session, activate: Bool = true) async {
        guard session.agentKind == .claudeCode else { return }
        guard settings.ghosttyFocusEnabled, ghostty.isAvailable else { return }
        try? await ghostty.pasteText(text, workingDirectory: session.workingDirectory, aiTitle: session.aiTitle, activate: activate)
    }

    /// "Ping" is a nop keep-alive: unlike /handoff (asks for a real summary) or /compact (does real work),
    /// this pastes a trivial question so the session's next turn just writes fresh cache without the LLM
    /// doing anything — for when all you want is to push the TTL back out, not actually continue the task.
    static let pingPrompt = "Are you still there? Answer yes/no."

    /// Unlike /handoff and /compact (explicit, deliberate actions the user expects to watch land), Ping is
    /// meant to be a quick "still there?" nudge fired from wherever the user currently is — it should never
    /// yank Ghostty to the front of their screen.
    func ping(_ session: Session) async {
        await pasteCommand(Self.pingPrompt, into: session, activate: false)
    }

    // MARK: - Automatic keep-alive

    /// The unattended keep-alive's own prompt — distinct from `pingPrompt` above since this one is
    /// submitted automatically (see `KeepAliveTracker`), so it's worded to make the model's answer as
    /// cheap and unambiguous as possible: one fixed word, nothing that could be read as a real request.
    static let autoKeepAlivePrompt = "If you are still there, ONLY answer: pong"

    func keepAliveInfo(for session: Session) -> KeepAliveInfo {
        keepAlive.info(for: session, settings: settings)
    }

    func setKeepAlive(_ enabled: Bool, for session: Session) {
        keepAlive.setEnabled(enabled, for: session)
    }

    /// When `settings.keepAliveAllActiveSessions` is on, switches Auto Keep-Alive on for every session
    /// that still has time left on its cache and hasn't been touched yet — both right now (see the
    /// `sink` in `init`) and for any session that becomes active later (called from every `rescan()`).
    /// `KeepAliveTracker.autoEnableIfNeeded` is the one that actually skips sessions the user has already
    /// toggled themselves (on or off), so a manual "turn off" sticks rather than being forced back on
    /// here every 15s.
    private func enableKeepAliveForActiveSessions(now: Date) {
        guard settings.keepAliveAllActiveSessions else { return }
        for session in sessions {
            guard session.supportsCacheCountdown else { continue }
            let ttl = session.effectiveTTL(fallback: settings.ttl)
            if session.remaining(now: now, ttl: ttl) > 0 {
                keepAlive.autoEnableIfNeeded(for: session)
            }
        }
    }

    /// Per-second check (see `tick`): fires an unattended keep-alive ping for any enabled session that's
    /// about to go cold, still has budget, and has an open tab to paste into. Gated on the same
    /// automation toggle/availability as every other Ghostty action — if the user turned that off, no
    /// automatic keystrokes should reach their terminal either.
    private func checkKeepAlive() {
        guard settings.ghosttyFocusEnabled, ghostty.isAvailable else { return }
        for session in sessions {
            guard session.supportsCacheCountdown else { continue }
            guard ghostty.hasOpenTab(workingDirectory: session.workingDirectory) else { continue }
            guard keepAlive.shouldFire(session: session, now: now, settings: settings) else { continue }
            let remaining = session.remaining(now: now, ttl: session.effectiveTTL(fallback: settings.ttl))
            fireKeepAlivePing(for: session, remaining: remaining)
        }
    }

    /// Per-second check (see `tick`): the first tick after an enabled session has spent its whole ping
    /// budget while still warm, raise the distinct "auto keep-alive is done — extend it yourself or it goes
    /// cold, at a cost of ~$Y" warning. The tracker gates this to once per warm period (see
    /// `KeepAliveTracker.consumeExhaustionWarning`); the `remaining > 0` guard here keeps the warning to
    /// sessions there's still time to save, so it never fires uselessly on an already-cold session.
    private func checkKeepAliveExhaustion() {
        for session in sessions {
            guard session.supportsCacheCountdown else { continue }
            let ttl = session.effectiveTTL(fallback: settings.ttl)
            let remaining = session.remaining(now: now, ttl: ttl)
            guard remaining > 0 else { continue }
            guard keepAlive.consumeExhaustionWarning(for: session, settings: settings) else { continue }
            let info = keepAlive.info(for: session, settings: settings)
            banners.presentMaxExtensions(
                session: session, remaining: remaining, used: info.pingsUsed, cap: info.maxPings,
                coldCostSummary: Self.coldCostSummary(for: session, ttl: ttl),
                onSwitch: { [weak self] in Task { await self?.focus(session) } },
                onHandoff: { [weak self] in Task { await self?.pasteCommand("/handoff", into: session) } },
                onPing: { [weak self] in Task { await self?.ping(session) } }
            )
        }
    }

    private func fireKeepAlivePing(for session: Session, remaining: TimeInterval) {
        keepAlive.recordFireAttempted(for: session.id, now: now)
        // Log the runway left at fire time: if a cache still goes cold, this says whether the ping was
        // issued too late (fired with only a second or two left — the failure this lead time guards against)
        // versus landing on time but the reply never arriving.
        FileHandle.standardError.write(
            "[Tokenomics] keep-alive: firing for \(session.projectName) (\(Int(remaining))s left)\n".data(using: .utf8)!
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ghostty.pasteTextAndSubmit(Self.autoKeepAlivePrompt, workingDirectory: session.workingDirectory, aiTitle: session.aiTitle)
                self.keepAlive.recordFireSucceeded(for: session.id)
                FileHandle.standardError.write(
                    "[Tokenomics] keep-alive: succeeded for \(session.projectName)\n".data(using: .utf8)!
                )
            } catch {
                self.keepAlive.recordFireFailed(for: session.id)
                FileHandle.standardError.write(
                    "[Tokenomics] keep-alive: failed for \(session.projectName): \(error)\n".data(using: .utf8)!
                )
            }
        }
    }

    // MARK: - Hover detail panel

    /// Debounced like a native submenu: a brief hover-intent delay before showing (so passing the mouse
    /// over several rows on the way to one doesn't flash a panel per row).
    ///
    /// The panel sits a few points to the right of the row with a gap of "dead space" the mouse has to
    /// cross to reach it. An earlier version scheduled a hide purely from the row's own hover-exit, which
    /// fired — and won — the moment the mouse left the row on its way toward the panel, so the buttons
    /// inside (Focus Tab / Paste /handoff / Paste /compact) were never reachable. Fixed by tracking
    /// `pointerOverRow` and `pointerOverPanel` (the latter reported by the panel itself, see
    /// DetailPanelPresenter/SessionDetailPanelView) independently and only hiding once *neither* is true.
    func rowHoverChanged(_ session: Session, isHovering: Bool, hasOpenTab: Bool) {
        pointerOverRow = isHovering
        if isHovering {
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, self.pointerOverRow else { return }
                // A turn already in flight (Claude working or a /compact running) needs no user action and
                // no keep-alive ping — nothing in the panel would be useful, so don't show it at all.
                guard session.activity != .running, session.activity != .compacting else { return }
                self.shownPanelSessionID = session.id
                self.shownPanelCacheTouchTime = session.cacheTouchTime
                self.detailPanel.show(
                    session: session, settings: self.settings, hasOpenTab: hasOpenTab,
                    timeSinceLastActive: self.ghostty.timeSinceLastActive(workingDirectory: session.workingDirectory),
                    keepAliveInfo: self.keepAliveInfo(for: session),
                    anchorWindow: self.hostWindow,
                    onFocus: { Task { await self.focus(session) } },
                    onPasteCommand: { text in Task { await self.pasteCommand(text, into: session) } },
                    onPing: { Task { await self.ping(session) } },
                    onOpenInCodex: { self.openInCodex(session) },
                    onToggleKeepAlive: { [weak self] in
                        guard let self else { return }
                        self.setKeepAlive(!self.keepAliveInfo(for: session).enabled, for: session)
                    },
                    onHoverChanged: { [weak self] hovering in self?.panelHoverChanged(hovering) }
                )
            }
        } else {
            scheduleHideIfUnhovered()
        }
    }

    private func panelHoverChanged(_ isHovering: Bool) {
        pointerOverPanel = isHovering
        if isHovering {
            hoverTask?.cancel()
        } else {
            scheduleHideIfUnhovered()
        }
    }

    private func scheduleHideIfUnhovered() {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            guard !self.pointerOverRow, !self.pointerOverPanel else { return }
            self.detailPanel.hide()
            self.shownPanelSessionID = nil
            self.shownPanelCacheTouchTime = nil
        }
    }

    /// Closes the open detail panel if the session it belongs to just had its cache-touch anchor change —
    /// a fresh assistant turn landed (counter reset to full) or the cache went cold via /compact or /clear
    /// — or just started a turn (`.running`/`.compacting`), so the panel never sits open showing a stale
    /// snapshot, or offering actions with nothing useful to do, while a reply is already in flight. Called
    /// once per rescan.
    private func closeDetailPanelIfSessionReset() {
        guard let id = shownPanelSessionID else { return }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let staleSnapshot = session.cacheTouchTime != shownPanelCacheTouchTime
        let nowInFlight = session.activity == .running || session.activity == .compacting
        guard staleSnapshot || nowInFlight else { return }
        hoverTask?.cancel()
        pointerOverRow = false
        pointerOverPanel = false
        detailPanel.hide()
        shownPanelSessionID = nil
        shownPanelCacheTouchTime = nil
    }

    // MARK: - Menu bar presentation

    private func sortBucket(_ session: Session, now: Date, ttlFallback: TimeInterval) -> Int {
        guard session.supportsCacheCountdown else { return 1 }
        return session.remaining(now: now, ttl: session.effectiveTTL(fallback: ttlFallback)) > 0 ? 0 : 2
    }

    var barTitle: String? {
        // "Lost today" mode shows the waste figure when there's any to show; with nothing lost yet it
        // falls back to the countdown rather than a bare "🔻 0", so the bar is never uninformative.
        if settings.menuBarMode == .lostToday, meter.hasLoss {
            return "🔻 " + Self.compactTokens(meter.lostTokens) + " lost"
        }
        return nextExpiryTitle
    }

    /// The soonest-to-expire session's countdown, or nil if nothing is warm — the original bar behavior.
    private var nextExpiryTitle: String? {
        guard let soonest = sessions.first(where: { $0.supportsCacheCountdown }) else { return nil }
        let ttl = soonest.effectiveTTL(fallback: settings.ttl)
        let remaining = soonest.remaining(now: now, ttl: ttl)
        guard remaining > 0 else { return nil }
        return "⏱ " + Self.format(remaining)
    }

    /// The most attention-worthy activity across current sessions — the menu bar's fallback (see
    /// MenuBarLabel) for when `barTitle` is nil. Reported directly: a tool call regularly runs longer
    /// than a session's cache TTL (5 min is the common default), and once every session is cold,
    /// `barTitle` goes blank — a bare, textless timer icon at that point reads as "nothing is running"
    /// even though a session is still actively working or blocked on a question. `.waitingForInput` beats
    /// `.compacting` beats `.running` since it's the one state that needs the user to actually do
    /// something, not just wait.
    var busiestActivity: SessionActivity? {
        let byUrgency: [SessionActivity] = [.waitingForInput, .compacting, .running]
        return byUrgency.first { activity in sessions.contains { $0.activity == activity } }
    }

    /// Compact token count for tight spaces: 128_400 → "128k", 2_100_000 → "2.1M", 950 → "950".
    static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return "\(count / 1_000)k"
        }
        return "\(count)"
    }

    /// A dollar estimate formatted for display — always approximate (these are `Pricing` estimates, never
    /// exact costs), with a `<$0.01` floor so a tiny-but-nonzero figure never renders as `~$0.00`.
    static func formatUSDEstimate(_ usd: Double) -> String {
        usd < 0.005 ? "<$0.01" : String(format: "~$%.2f", usd)
    }

    /// What keeping this session's cache warm is worth right now: the warm prefix that a cold rewrite would
    /// have to re-create (`currentContextTokens`), and the dollars that rewrite would cost over a cheap warm
    /// read (see `Pricing.coldRewriteCostUSD`). This is the *projected* save from acting before the cache
    /// expires, not a realized total. Nil when no turn has usage yet; `costText` is nil for an unpriced model
    /// (the token figure still stands — it's exact, the dollars are the estimate).
    static func keepWarmSaving(for session: Session, ttl: TimeInterval) -> (tokens: Int, costText: String?)? {
        guard let tokens = session.currentContextTokens, tokens > 0 else { return nil }
        let costText = Pricing.coldRewriteCostUSD(wastedTokens: tokens, model: session.model, ttl: ttl)
            .map(formatUSDEstimate)
        return (tokens, costText)
    }

    /// One-line "keeping it alive saves …" summary for the expiry banner, or nil when there's nothing to
    /// quantify yet. Tokens lead (exact); the dollar estimate trails in parentheses when the model is priced.
    static func keepWarmSummary(for session: Session, ttl: TimeInterval) -> String? {
        guard let save = keepWarmSaving(for: session, ttl: ttl) else { return nil }
        let tokens = "~\(compactTokens(save.tokens)) tokens"
        guard let cost = save.costText else { return "Keeping it alive saves \(tokens)" }
        return "Keeping it alive saves \(tokens) (\(cost))"
    }

    /// The cost framing of the same figure, for the max-extensions warning banner: what letting this cache
    /// go cold now would cost to rewrite on the next turn. Nil when no turn has usage yet; the dollar
    /// estimate is dropped for an unpriced model, leaving the exact token figure.
    static func coldCostSummary(for session: Session, ttl: TimeInterval) -> String? {
        guard let save = keepWarmSaving(for: session, ttl: ttl) else { return nil }
        let tokens = "~\(compactTokens(save.tokens)) tokens"
        guard let cost = save.costText else { return "Going cold now re-costs \(tokens)" }
        return "Going cold now costs \(cost) (\(tokens)) to rewrite"
    }

    /// How far back a session's last turn can be and still count toward the menu bar icon's tint. Needed
    /// because the session list spans up to 24h (see TranscriptWatcher.recencyWindow): without this, a
    /// project untouched for hours would keep painting the icon red, which isn't useful "worst current
    /// status" information — it's just old news.
    private let overallStatusRelevanceWindow: TimeInterval = 3600

    var overallStatus: CacheStatus? {
        let relevant = sessions.filter {
            $0.supportsCacheCountdown && now.timeIntervalSince($0.lastTurnTime) < overallStatusRelevanceWindow
        }
        guard !relevant.isEmpty else { return nil }
        let statuses = relevant.map {
            $0.status(now: now, ttl: $0.effectiveTTL(fallback: settings.ttl), expiringSoonThreshold: settings.expiringSoonThresholdSeconds)
        }
        if statuses.contains(where: { $0 == .cold }) { return .cold }
        if statuses.contains(where: { $0 == .expiringSoon }) { return .expiringSoon }
        return .warm
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
