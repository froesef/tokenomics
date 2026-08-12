import Foundation

/// Today's cold-cache waste and caching/rtk savings, aggregated across all tracked sessions. Populated by
/// `SavingsMeter.compute` on every rescan and rendered by MeterStripView + the menu-bar title.
///
/// Tokens are exact (straight from the transcripts); dollar figures are estimates from `Pricing` and are
/// always shown as "~$X est." "Lost" is the quantified cost of letting prompt caches go cold; "Saved" is
/// what caching (cheap cache reads vs. full-price input) and `rtk` output-filtering avoided.
struct SavingsMeter: Equatable, Sendable {
    var lostTokens = 0
    var lostCostUSD = 0.0
    var expiryCount = 0

    var savedTokens = 0
    var savedCostUSD = 0.0
    /// Split of savedCostUSD for the detail breakdown, so the meter can explain where "saved" came from.
    var cacheSavingsUSD = 0.0
    var rtkSavingsUSD = 0.0

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

            // Caching savings: cache reads billed at ~0.1x instead of full input price. Tokens are exact;
            // priced at the session's latest model as an approximation for the whole read total.
            if session.cacheReadTokens > 0 {
                meter.savedTokens += session.cacheReadTokens
                if let cost = Pricing.warmReadSavingsUSD(
                    readTokens: session.cacheReadTokens, model: session.model
                ) {
                    meter.cacheSavingsUSD += cost
                }
            }

            // rtk output-filtering savings: tokens trimmed before they ever reached the model.
            if let rtk = session.rtkStats, rtk.totalSavedTokens > 0 {
                meter.savedTokens += rtk.totalSavedTokens
                if let cost = Pricing.filteredTokenSavingsUSD(
                    savedTokens: rtk.totalSavedTokens, model: session.model
                ) {
                    meter.rtkSavingsUSD += cost
                }
            }
        }

        meter.savedCostUSD = meter.cacheSavingsUSD + meter.rtkSavingsUSD
        return meter
    }
}
