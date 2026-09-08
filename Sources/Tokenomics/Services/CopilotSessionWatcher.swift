import Foundation

/// Aggregates recent scalar usage telemetry from Copilot's local session database.
/// It never falls back to session-state JSONL because those files contain work content.
@MainActor
final class CopilotSessionWatcher {
    private let recencyWindow: TimeInterval = 24 * 3600
    private let store: CopilotSessionStore
    private var fsWatcher: FSEventsWatcher?

    var onChange: (@MainActor () -> Void)?
    private(set) var unavailableReason: String?

    init(copilotHome: URL = CopilotSessionStore.defaultHome()) {
        self.store = CopilotSessionStore(copilotHome: copilotHome)
    }

    func scanAll(now: Date = Date()) -> [Session] {
        switch store.load() {
        case let .failure(error):
            unavailableReason = error.localizedDescription
            return []
        case let .success(snapshot):
            unavailableReason = nil
            let cutoff = now.addingTimeInterval(-recencyWindow)
            return aggregate(snapshot.events.filter { $0.createdAt >= cutoff })
        }
    }

    func startWatching() {
        let watcher = FSEventsWatcher(path: store.homeURL.path) { [weak self] in self?.onChange?() }
        fsWatcher = watcher
        watcher.start()
    }

    func stopWatching() {
        fsWatcher?.stop()
        fsWatcher = nil
    }

    private func aggregate(_ events: [CopilotUsageEvent]) -> [Session] {
        let groupedEvents = Dictionary(grouping: events, by: \.sessionID)
        var sessions: [Session] = []
        for sessionEvents in groupedEvents.values {
            let sorted = sessionEvents.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
            }
            guard let latest = sorted.last,
                  let workingDirectory = latest.workingDirectory ?? sorted.compactMap(\.workingDirectory).last,
                  !workingDirectory.isEmpty else {
                continue
            }

            var session = Session(
                id: latest.sessionID,
                agentKind: .githubCopilot,
                workingDirectory: workingDirectory,
                aiTitle: nil,
                lastTurnTime: latest.createdAt,
                lastAssistantTurnTime: latest.createdAt,
                cacheTouchTime: nil,
                cacheCreationTokens: 0,
                cacheReadTokens: Self.sum(sorted.map(\.cacheReadTokens)) ?? 0,
                totalInputTokens: Self.sum(sorted.map(\.inputTokens)),
                cachedInputTokens: Self.sum(sorted.map(\.cacheReadTokens)),
                cacheWriteTokens: Self.sum(sorted.map(\.cacheWriteTokens)),
                outputTokens: Self.sum(sorted.map(\.outputTokens)),
                reasoningOutputTokens: Self.sum(sorted.map(\.reasoningTokens)),
                latestRequestDurationMS: latest.durationMS,
                toolUsage: ToolUsage(),
                model: latest.model,
                effort: latest.reasoningEffort,
                version: nil,
                lastVisibleCharCount: nil,
                currentContextTokens: latest.inputTokens,
                activity: .idle,
                compactionStartedAt: nil,
                detectedTTL: nil,
                cost: nil
            )
            session.estimatedAICredits = Self.estimatedAICredits(for: sorted)
            sessions.append(session)
        }
        return sessions
    }

    private static func estimatedAICredits(for events: [CopilotUsageEvent]) -> Double? {
        var total = 0.0
        for event in events {
            guard let credits = CopilotPricing.estimatedAICredits(
                model: event.model,
                inputTokens: event.inputTokens,
                cachedInputTokens: event.cacheReadTokens,
                cacheWriteTokens: event.cacheWriteTokens,
                outputTokens: event.outputTokens
            ) else {
                return nil
            }
            total += credits
        }
        return total
    }

    private static func sum(_ values: [Int?]) -> Int? {
        var total = 0
        var foundValue = false
        for value in values {
            guard let value else { continue }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
            foundValue = true
        }
        return foundValue ? total : nil
    }
}
