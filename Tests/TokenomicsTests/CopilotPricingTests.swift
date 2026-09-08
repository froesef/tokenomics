import XCTest
@testable import Tokenomics

final class CopilotPricingTests: XCTestCase {
    func testEstimatesCreditsFromAllTokenBuckets() {
        let credits = CopilotPricing.estimatedAICredits(
            model: "gpt-5.6-terra",
            inputTokens: 1_000,
            cachedInputTokens: 1_000,
            cacheWriteTokens: 1_000,
            outputTokens: 1_000
        )

        XCTAssertEqual(credits ?? 0, 1.67, accuracy: 0.0001)
    }

    func testUsesLongContextRatesAboveDocumentedThreshold() {
        let credits = CopilotPricing.estimatedAICredits(
            model: "gpt-5.6-luna",
            inputTokens: 200_001,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 0
        )

        XCTAssertEqual(credits ?? 0, 8.00004, accuracy: 0.00001)
    }

    func testRejectsUnknownModelsAndIncompleteUsage() {
        XCTAssertNil(CopilotPricing.estimatedAICredits(
            model: "future-model",
            inputTokens: 1,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 1
        ))
        XCTAssertNil(CopilotPricing.estimatedAICredits(
            model: "claude-sonnet-5",
            inputTokens: 1,
            cachedInputTokens: nil,
            cacheWriteTokens: 0,
            outputTokens: 1
        ))
    }

    func testRejectsCacheWriteForModelsWithoutAWriteRate() {
        XCTAssertNil(CopilotPricing.estimatedAICredits(
            model: "gpt-5.4-mini",
            inputTokens: 1,
            cachedInputTokens: 0,
            cacheWriteTokens: 1,
            outputTokens: 1
        ))
    }
}
