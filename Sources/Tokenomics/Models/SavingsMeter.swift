import Foundation

/// Today's cold-cache waste and caching savings, aggregated across all tracked sessions. Populated by
/// `SavingsMeter.compute` on every rescan and rendered by MeterStripView + the menu-bar title.
///
/// Tokens are exact (straight from the transcripts); dollar figures are estimates from `Pricing` and are
/// always shown as "~$X est." "Lost" is the quantified cost of letting prompt caches go cold; "Saved" is
/// a comparison, not money that changed hands: what those same input tokens would have cost at full
/// (uncached) price, versus the ~0.1x a warm cache read is actually billed at. rtk's own output-filtering
/// savings are tracked separately (see RTKStats / SessionDetailPanelView) — this meter doesn't fold them in.
struct SavingsMeter: Equatable, Sendable {
    var lostTokens = 0
    var lostCostUSD = 0.0
    var expiryCount = 0

    var savedTokens = 0
    var savedCostUSD = 0.0
    /// Split of savedCostUSD for the detail breakdown, so the meter can explain where "saved" came from.
    var cacheSavingsUSD = 0.0

    var hasLoss: Bool { lostTokens > 0 }
    var hasSavings: Bool { savedTokens > 0 || savedCostUSD > 0 }

    /// Recompute the meter from the current session list. `now` is passed in (never read from the clock
    /// here) so the result is deterministic for a given scan — the same discipline the rest of the app uses
    /// for its per-second tick. Only Claude Code sessions contribute (Codex exposes no cache-expiry data).
    static func compute(sessions: [Session], now: Date) -> SavingsMeter {
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        var meter = SavingsMeter()

        for session in sessions where session.agentKind == .claudeCode {
            // Cold-cache waste: only events that happened "today" (within the scan window).
            for event in session.expiryEvents where event.time > dayAgo {
                meter.lostTokens += event.wastedTokens
                meter.expiryCount += 1
                if let cost = Pricing.coldRewriteCostUSD(
                    wastedTokens: event.wastedTokens, model: event.model, ttl: event.ttl
                ) {
                    meter.lostCostUSD += cost
                }
            }

            // Caching savings: cache reads billed at ~0.1x instead of full input price, scoped to reads
            // that happened "today" like expiryEvents above — not the session's lifetime read total, which
            // would keep counting a long-lived session's oldest reads forever. Priced at the session's
            // latest model as an approximation for the whole read total.
            let readTokensToday = session.cacheReadEvents
                .filter { $0.time > dayAgo }
                .reduce(0) { $0 + $1.tokens }
            if readTokensToday > 0 {
                meter.savedTokens += readTokensToday
                if let cost = Pricing.warmReadSavingsUSD(
                    readTokens: readTokensToday, model: session.model
                ) {
                    meter.cacheSavingsUSD += cost
                }
            }
        }

        meter.savedCostUSD = meter.cacheSavingsUSD
        return meter
    }
}
