import SwiftUI

enum AgentIconStyle: Equatable, Sendable {
    case sunburst
    case chatGPTKnot
}

private extension AgentKind {
    var tint: Color {
        switch self {
        case .claudeCode:
            // Anthropic's "clay" brand tone, approximated — the mark reads correctly against both the
            // row's highlight background and the detail panel's material background without a separate
            // hover variant.
            return Color(red: 0.80, green: 0.47, blue: 0.34)
        case .codex:
            return Color(red: 0.12, green: 0.50, blue: 0.44)
        }
    }
}

extension AgentKind {
    var iconStyle: AgentIconStyle {
        switch self {
        case .claudeCode: return .sunburst
        case .codex: return .chatGPTKnot
        }
    }
}

/// A small vector mark identifying the agent behind a session, shown in `SessionRowView` and
/// `SessionDetailPanelView`. Drawn without bundled image assets: this SPM target has no asset catalog,
/// and vector marks stay crisp at both the row's compact size and the detail panel's larger one.
struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch kind.iconStyle {
            case .sunburst:
                SunburstShape(rayCount: 8)
                    .fill(kind.tint)
            case .chatGPTKnot:
                ChatGPTKnotMark(tint: kind.tint, size: size)
            }
        }
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

/// A compact ChatGPT-style knot made from six rounded loops. It is intentionally vector-drawn here
/// rather than shipped as a logo asset so the menu-bar package stays asset-free.
private struct ChatGPTKnotMark: View {
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: max(1.0, size * 0.085), lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: size * 0.48, height: size * 0.28)
                    .offset(y: -size * 0.18)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle()
                .stroke(tint, lineWidth: max(0.8, size * 0.06))
                .frame(width: size * 0.22, height: size * 0.22)
        }
        .frame(width: size, height: size)
    }
}
