import SwiftUI

/// The savings/waste "meter" at the top of the dropdown: today's cold-cache waste and caching savings,
/// side by side. Shown only when there's something to report (otherwise the dropdown opens straight to the
/// session list). Tokens are the headline number (exact from transcripts); dollars are a labeled estimate
/// (see Pricing / SavingsMeter). Hover either figure for the breakdown.
struct MeterStripView: View {
    let meter: SavingsMeter
    /// Manual refresh action, rendered inline at the trailing edge of whichever row appears first —
    /// keeps it in the same row rather than opening a dedicated row just for the button.
    let onRefresh: () async -> Void

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
            Text("Lost (24h)")
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
            RefreshButtonView(action: onRefresh)
        }
        .help("Tokens re-written because a session's prompt cache went cold after sitting idle past its TTL. "
            + "Keep working in a session (or use Auto Keep-Alive) before it goes cold to avoid this. "
            + "Scoped to expirations in the trailing 24h. Token count is exact; the dollar figure is an estimate.")
    }

    private var savedRow: some View {
        HStack(spacing: 6) {
            Text("✅")
            Text("Saved (24h, caching)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text(Self.money(meter.savedCostUSD))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(Self.tokens(meter.savedTokens))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if !meter.hasLoss {
                RefreshButtonView(action: onRefresh)
            }
        }
        .help(savedBreakdown)
    }

    private var savedBreakdown: String {
        "Not money you got back — a comparison. These tokens were read from a warm prompt cache "
            + "(billed ~0.1× input price) instead of being resent at full price. \"Saved\" = what that "
            + "same traffic would have cost without caching, minus what it actually cost. Scoped to reads "
            + "in the trailing 24h, across sessions still open or recently active."
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
