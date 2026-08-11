import SwiftUI

/// Cache health for a session, derived from remaining time against its active TTL. See §4 of spec.md.
enum CacheStatus: Sendable, Equatable {
    case warm
    case expiringSoon
    case cold

    var color: Color {
        switch self {
        case .warm: return .green
        case .expiringSoon: return .orange
        case .cold: return .red
        }
    }
}
