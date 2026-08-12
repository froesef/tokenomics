import SwiftUI

/// Which coding agent produced a session. Every session today is a Claude Code session, but the point of
/// making this a first-class enum now — rather than just hardcoding a Claude mark everywhere — is that
/// this app is meant to grow into tracking other coding agents' sessions too; a session's `agentKind`
/// (Models/Session.swift) is where that distinction will live once there's more than one case.
enum AgentKind: Equatable, Sendable {
    case claudeCode

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        }
    }

    /// Anthropic's "clay" brand tone, approximated — the mark reads correctly against both the row's
    /// highlight background and the detail panel's material background without a separate hover variant.
    var tint: Color {
        switch self {
        case .claudeCode: return Color(red: 0.80, green: 0.47, blue: 0.34)
        }
    }
}

/// A small sunburst mark identifying the agent behind a session, shown in `SessionRowView` and
/// `SessionDetailPanelView` — requested directly, so agents stay visually distinguishable at a glance once
/// the app supports more than Claude Code. Drawn as a vector shape rather than a bundled image asset: this
/// SPM target has no asset catalog, and a vector mark stays crisp at both the row's compact size and the
/// detail panel's larger one.
struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 12

    var body: some View {
        SunburstShape(rayCount: 8)
            .fill(kind.tint)
            .frame(width: size, height: size)
            .help(kind.displayName)
    }
}

/// The geometric shape behind the Claude logomark: rays tapering from a small center hub out to rounded
/// tips, evenly spaced around a full circle.
private struct SunburstShape: Shape {
    let rayCount: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.18
        let rayHalfWidth = outerRadius * 0.17

        var path = Path()
        for i in 0..<rayCount {
            let angle = (Double(i) / Double(rayCount)) * 2 * .pi
            let dx = cos(angle)
            let dy = sin(angle)
            // Perpendicular to the ray's direction, used to give each ray width at its base.
            let px = -dy
            let py = dx

            let base1 = CGPoint(
                x: center.x + dx * innerRadius + px * rayHalfWidth,
                y: center.y + dy * innerRadius + py * rayHalfWidth
            )
            let base2 = CGPoint(
                x: center.x + dx * innerRadius - px * rayHalfWidth,
                y: center.y + dy * innerRadius - py * rayHalfWidth
            )
            let tip = CGPoint(x: center.x + dx * outerRadius, y: center.y + dy * outerRadius)

            var ray = Path()
            ray.move(to: base1)
            ray.addQuadCurve(to: tip, control: CGPoint(
                x: (base1.x + tip.x) / 2 + px * rayHalfWidth * 0.3,
                y: (base1.y + tip.y) / 2 + py * rayHalfWidth * 0.3
            ))
            ray.addQuadCurve(to: base2, control: CGPoint(
                x: (tip.x + base2.x) / 2 - px * rayHalfWidth * 0.3,
                y: (tip.y + base2.y) / 2 - py * rayHalfWidth * 0.3
            ))
            ray.addQuadCurve(to: base1, control: center)
            path.addPath(ray)
        }
        return path
    }
}
