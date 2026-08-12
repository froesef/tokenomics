import Foundation

/// Per-model token pricing and cache multipliers — used *only* to turn the exact token
/// counts read from a transcript into a **dollar estimate** for the savings/waste meter.
///
/// This deliberately does not replace `ccusage` (see UsageService): the per-session cost
/// column still delegates cost math wholesale to `ccusage`, which does not expose per-token
/// rates or per-turn cost (confirmed — it reports computed totals only). The waste/savings
/// meter needs a per-token rate, so it keeps this small self-contained table instead. Every
/// figure derived here is surfaced as "~$X est.", never as an exact cost.
///
/// SOURCE OF TRUTH is the token count (exact, straight from the transcript); the dollar
/// figure is secondary. Base input $/Mtok are Anthropic first-party API list prices as of
/// `ratesAsOf`; the cache multipliers are Anthropic's standard prompt-cache economics
/// (see TOKEN_TIPS.md §1) and rarely change. Re-verify the base rates if the estimates
/// look off — TOKEN_TIPS.md notes pricing drifts over time.
enum Pricing {
    /// When the base rates below were last checked against Anthropic's published pricing.
    static let ratesAsOf = "2026-08-12"

    /// Base **input** price in dollars per 1M tokens, by model-id prefix. Output price isn't
    /// needed: cold-cache waste and warm-cache savings are both entirely input-side. Matched
    /// by prefix against `Session.model` (e.g. "claude-opus-5", "claude-sonnet-5",
    /// "claude-haiku-4-5-20251001"). Most-specific/first match wins, so order matters only if
    /// prefixes overlap (they don't here).
    private static let inputUSDPerMTok: [(prefix: String, usd: Double)] = [
        ("claude-opus", 5.0),
        // Sonnet 5 has a $2 intro rate through 2026-08-31; using the standard $3 keeps the
        // estimate durable past that date rather than silently changing on Sept 1.
        ("claude-sonnet", 3.0),
        ("claude-haiku", 1.0),
    ]

    /// A cache *write* costs this multiple of the base input price, by the TTL actually in
    /// effect: ~1.25× at the 5-minute TTL, ~2× at the 1-hour TTL.
    static func writeMultiplier(ttl: TimeInterval?) -> Double {
        (ttl ?? 300) >= 3600 ? 2.0 : 1.25
    }

    /// A cache *read* costs ~0.1× the base input price — the ~90% discount caching buys.
    static let readMultiplier = 0.1

    /// Base input price per single token for `model`, or nil if the model id is unrecognized
    /// (e.g. "<synthetic>" sentinel turns, or a model added after this table was written).
    static func inputUSDPerToken(model: String?) -> Double? {
        guard let model else { return nil }
        for entry in inputUSDPerMTok where model.hasPrefix(entry.prefix) {
            return entry.usd / 1_000_000
        }
        return nil
    }

    /// The *extra* dollars a cold-cache rewrite cost versus what a warm cache read would have:
    /// the whole prefix was re-written at cache-write price instead of served at cache-read
    /// price, so the waste is `wastedTokens × (writeMult − readMult) × baseInput`. Nil when the
    /// model is unknown (the tokens are still counted — see the meter's token-primary display).
    static func coldRewriteCostUSD(wastedTokens: Int, model: String?, ttl: TimeInterval?) -> Double? {
        guard let perToken = inputUSDPerToken(model: model) else { return nil }
        return Double(wastedTokens) * (writeMultiplier(ttl: ttl) - readMultiplier) * perToken
    }

    /// Dollars saved by serving `readTokens` from a warm cache instead of paying full,
    /// uncached input price for them: `readTokens × (1 − readMult) × baseInput`. The positive
    /// mirror of `coldRewriteCostUSD`.
    static func warmReadSavingsUSD(readTokens: Int, model: String?) -> Double? {
        guard let perToken = inputUSDPerToken(model: model) else { return nil }
        return Double(readTokens) * (1.0 - readMultiplier) * perToken
    }

    /// Dollars saved by a token-filtering CLI proxy (`rtk`) trimming shell output before it
    /// ever reached the model: those tokens never entered context, so they're valued at full
    /// uncached input price (1×). Nil when the model is unknown.
    static func filteredTokenSavingsUSD(savedTokens: Int, model: String?) -> Double? {
        guard let perToken = inputUSDPerToken(model: model) else { return nil }
        return Double(savedTokens) * perToken
    }
}
