import SwiftUI

/// The savings/waste "meter" at the top of the dropdown: today's cold-cache waste and caching/rtk savings,
/// side by side. Shown only when there's something to report (otherwise the dropdown opens straight to the
/// session list). Tokens are the headline number (exact from transcripts); dollars are a labeled estimate
/// (see Pricing / SavingsMeter). Hover either figure for the breakdown.
struct MeterStripView: View {
    let meter: SavingsMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if meter.hasLoss {
                lostRow
            }
            if meter.hasSavings {
                savedRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var lostRow: some View {
        HStack(spacing: 6) {
            Text("🔻")
            Text("Lost today")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text(Self.tokens(meter.lostTokens))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
            Text(Self.money(meter.lostCostUSD))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(meter.expiryCount == 1 ? "1 expiration" : "\(meter.expiryCount) expirations")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .help("Tokens re-written because a session's prompt cache went cold after sitting idle past its TTL. "
            + "Keep working in a session (or use Auto Keep-Alive) before it goes cold to avoid this. "
            + "Token count is exact; the dollar figure is an estimate.")
    }

    private var savedRow: some View {
        HStack(spacing: 6) {
            Text("✅")
            Text("Saved today")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text(Self.money(meter.savedCostUSD))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(Self.tokens(meter.savedTokens))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .help(savedBreakdown)
    }

    private var savedBreakdown: String {
        var parts = ["Estimated savings today:"]
        if meter.cacheSavingsUSD > 0 {
            parts.append("• \(Self.money(meter.cacheSavingsUSD)) from warm-cache reads (billed ~0.1× vs. full input price)")
        }
        if meter.rtkSavingsUSD > 0 {
            parts.append("• \(Self.money(meter.rtkSavingsUSD)) from rtk trimming shell output before it reached the model")
        }
        return parts.joined(separator: "\n")
    }

    /// "128,400 tokens" with a thousands separator, singular/plural aware.
    static func tokens(_ count: Int) -> String {
        let formatted = tokenFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(formatted) token" + (count == 1 ? "" : "s")
    }

    /// "~$0.42 est" — never presents the estimate as exact. Rounds-to-zero-but-positive shows "<$0.01 est".
    static func money(_ usd: Double) -> String {
        if usd > 0 && usd < 0.005 { return "<$0.01 est" }
        return String(format: "~$%.2f est", usd)
    }

    private static let tokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
