import Foundation

/// GitHub Copilot's published token rates, converted to estimated AI credits.
/// An AI credit equals $0.01; this is a local token-rate estimate, never billed
/// account usage. Source: https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
enum CopilotPricing {
    static let ratesAsOf = "2026-09-07"
    private static let creditsPerUSD = 100.0

    private struct Rate {
        let prefix: String
        let defaultTier: TokenRates
        let longContextTier: TokenRates?
        let longContextThreshold: Int?
    }

    private struct TokenRates {
        let inputUSDPerMTok: Double
        let cachedInputUSDPerMTok: Double
        let cacheWriteUSDPerMTok: Double?
        let outputUSDPerMTok: Double
    }

    private static let rates: [Rate] = [
        Rate(
            prefix: "gpt-5.6-sol",
            defaultTier: TokenRates(inputUSDPerMTok: 4, cachedInputUSDPerMTok: 0.4, cacheWriteUSDPerMTok: 5, outputUSDPerMTok: 20),
            longContextTier: TokenRates(inputUSDPerMTok: 8, cachedInputUSDPerMTok: 0.8, cacheWriteUSDPerMTok: 10, outputUSDPerMTok: 30),
            longContextThreshold: 272_000
        ),
        Rate(
            prefix: "gpt-5.6-terra",
            defaultTier: TokenRates(inputUSDPerMTok: 2, cachedInputUSDPerMTok: 0.2, cacheWriteUSDPerMTok: 2.5, outputUSDPerMTok: 12),
            longContextTier: TokenRates(inputUSDPerMTok: 4, cachedInputUSDPerMTok: 0.4, cacheWriteUSDPerMTok: 5, outputUSDPerMTok: 18),
            longContextThreshold: 272_000
        ),
        Rate(
            prefix: "gpt-5.6-luna",
            defaultTier: TokenRates(inputUSDPerMTok: 0.2, cachedInputUSDPerMTok: 0.02, cacheWriteUSDPerMTok: 0.25, outputUSDPerMTok: 1.2),
            longContextTier: TokenRates(inputUSDPerMTok: 0.4, cachedInputUSDPerMTok: 0.04, cacheWriteUSDPerMTok: 0.5, outputUSDPerMTok: 1.8),
            longContextThreshold: 200_000
        ),
        Rate(
            prefix: "gpt-5.4-mini",
            defaultTier: TokenRates(inputUSDPerMTok: 0.75, cachedInputUSDPerMTok: 0.075, cacheWriteUSDPerMTok: nil, outputUSDPerMTok: 4.5),
            longContextTier: nil,
            longContextThreshold: nil
        ),
        Rate(
            prefix: "gpt-5.4",
            defaultTier: TokenRates(inputUSDPerMTok: 2.5, cachedInputUSDPerMTok: 0.25, cacheWriteUSDPerMTok: nil, outputUSDPerMTok: 15),
            longContextTier: TokenRates(inputUSDPerMTok: 5, cachedInputUSDPerMTok: 0.5, cacheWriteUSDPerMTok: nil, outputUSDPerMTok: 22.5),
            longContextThreshold: 272_000
        ),
        Rate(
            prefix: "claude-opus-4.8",
            defaultTier: TokenRates(inputUSDPerMTok: 5, cachedInputUSDPerMTok: 0.5, cacheWriteUSDPerMTok: 6.25, outputUSDPerMTok: 25),
            longContextTier: nil,
            longContextThreshold: nil
        ),
        Rate(
            prefix: "claude-sonnet-5",
            defaultTier: TokenRates(inputUSDPerMTok: 2, cachedInputUSDPerMTok: 0.2, cacheWriteUSDPerMTok: 2.5, outputUSDPerMTok: 10),
            longContextTier: nil,
            longContextThreshold: nil
        ),
        Rate(
            prefix: "claude-haiku-4.5",
            defaultTier: TokenRates(inputUSDPerMTok: 1, cachedInputUSDPerMTok: 0.1, cacheWriteUSDPerMTok: 1.25, outputUSDPerMTok: 5),
            longContextTier: nil,
            longContextThreshold: nil
        )
    ]

    static func estimatedAICredits(
        model: String?,
        inputTokens: Int?,
        cachedInputTokens: Int?,
        cacheWriteTokens: Int?,
        outputTokens: Int?
    ) -> Double? {
        guard
            let model,
            let rate = rates.first(where: { model.hasPrefix($0.prefix) }),
            let inputTokens, inputTokens >= 0,
            let cachedInputTokens, cachedInputTokens >= 0,
            let cacheWriteTokens, cacheWriteTokens >= 0,
            let outputTokens, outputTokens >= 0
        else {
            return nil
        }

        let tier = rate.longContextThreshold.map { inputTokens > $0 } == true
            ? rate.longContextTier
            : rate.defaultTier
        guard let tier else { return nil }
        guard tier.cacheWriteUSDPerMTok != nil || cacheWriteTokens == 0 else { return nil }

        let usd = Double(inputTokens) * tier.inputUSDPerMTok / 1_000_000
            + Double(cachedInputTokens) * tier.cachedInputUSDPerMTok / 1_000_000
            + Double(cacheWriteTokens) * (tier.cacheWriteUSDPerMTok ?? 0) / 1_000_000
            + Double(outputTokens) * tier.outputUSDPerMTok / 1_000_000
        return usd * creditsPerUSD
    }
}
