import Foundation
import SQLite3
import XCTest
@testable import Tokenomics

final class CopilotSessionWatcherTests: XCTestCase {
    private struct FixtureEvent {
        let id: Int
        let model: String
        let inputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let durationMS: Int
        let reasoningEffort: String?
        let createdAt: String
    }

    @MainActor
    func testScanAllAggregatesRecentEventsBySession() throws {
        let home = try makeStore()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try insert(
            into: home,
            sessionID: "session-1",
            cwd: "/tmp/project",
            events: [
                FixtureEvent(
                    id: 1, model: "gpt-5.6-luna", inputTokens: 100, cacheWriteTokens: 10,
                    cacheReadTokens: 20, outputTokens: 5, reasoningTokens: 2, durationMS: 100,
                    reasoningEffort: "low", createdAt: "2027-01-15T08:00:00.000Z"
                ),
                FixtureEvent(
                    id: 2, model: "gpt-5.6-terra", inputTokens: 200, cacheWriteTokens: 30,
                    cacheReadTokens: 40, outputTokens: 15, reasoningTokens: 4, durationMS: 200,
                    reasoningEffort: "high", createdAt: "2027-01-15T08:01:00.000Z"
                )
            ]
        )

        let sessions = CopilotSessionWatcher(copilotHome: home).scanAll(now: now)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "session-1")
        XCTAssertEqual(sessions[0].agentKind, .githubCopilot)
        XCTAssertEqual(sessions[0].workingDirectory, "/tmp/project")
        XCTAssertEqual(sessions[0].model, "gpt-5.6-terra")
        XCTAssertEqual(sessions[0].effort, "high")
        XCTAssertEqual(sessions[0].totalInputTokens, 300)
        XCTAssertEqual(sessions[0].cachedInputTokens, 60)
        XCTAssertEqual(sessions[0].cacheWriteTokens, 40)
        XCTAssertEqual(sessions[0].outputTokens, 20)
        XCTAssertEqual(sessions[0].reasoningOutputTokens, 6)
        XCTAssertEqual(sessions[0].latestRequestDurationMS, 200)
        XCTAssertEqual(sessions[0].estimatedAICredits ?? 0, 0.06919, accuracy: 0.0001)
        XCTAssertEqual(sessions[0].lastTurnTime, ISO8601DateFormatter().date(from: "2027-01-15T08:01:00Z"))
        XCTAssertFalse(sessions[0].supportsCacheCountdown)
    }

    @MainActor
    func testScanAllSkipsOldEventsAndMissingWorkingDirectory() throws {
        let home = try makeStore()
        defer { try? FileManager.default.removeItem(at: home) }
        try insert(
            into: home,
            sessionID: "old",
            cwd: "/tmp/old",
            events: [
                FixtureEvent(
                    id: 1, model: "gpt-5.6-sol", inputTokens: 1, cacheWriteTokens: 0,
                    cacheReadTokens: 0, outputTokens: 1, reasoningTokens: 0, durationMS: 1,
                    reasoningEffort: nil, createdAt: "2026-01-01T00:00:00.000Z"
                )
            ]
        )
        try insert(
            into: home,
            sessionID: "no-cwd",
            cwd: nil,
            events: [
                FixtureEvent(
                    id: 2, model: "gpt-5.6-sol", inputTokens: 1, cacheWriteTokens: 0,
                    cacheReadTokens: 0, outputTokens: 1, reasoningTokens: 0, durationMS: 1,
                    reasoningEffort: nil, createdAt: "2027-01-15T08:00:00.000Z"
                )
            ]
        )

        let sessions = CopilotSessionWatcher(copilotHome: home).scanAll(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertTrue(sessions.isEmpty)
    }

    @MainActor
    func testScanAllReportsUnavailableStoreWithoutSessions() throws {
        let missingHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watcher = CopilotSessionWatcher(copilotHome: missingHome)

        XCTAssertTrue(watcher.scanAll().isEmpty)
        XCTAssertEqual(watcher.unavailableReason, "Copilot data directory is unavailable at \(missingHome.path)")
    }

    @MainActor
    func testCopilotAgentUsesSparklesIconStyle() {
        XCTAssertEqual(AgentKind.githubCopilot.iconStyle, .sparkles)
    }

    private func makeStore() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("session-store.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        try execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT);", database: database)
        try execute(
            """
            CREATE TABLE assistant_usage_events (
                id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, turn_index INTEGER,
                model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER,
                duration_ms INTEGER, reasoning_effort TEXT, created_at TEXT NOT NULL
            );
            """,
            database: database
        )
        return home
    }

    private func insert(
        into home: URL,
        sessionID: String,
        cwd: String?,
        events: [FixtureEvent]
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("session-store.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let escapedCWD = cwd.map { "'\($0)'" } ?? "NULL"
        try execute("INSERT INTO sessions (id, cwd) VALUES ('\(sessionID)', \(escapedCWD));", database: database)
        for event in events {
            let effort = event.reasoningEffort.map { "'\($0)'" } ?? "NULL"
            try execute(
                """
                INSERT INTO assistant_usage_events (
                    id, session_id, turn_index, model, input_tokens, output_tokens,
                    cache_read_tokens, cache_write_tokens, reasoning_tokens, duration_ms,
                    reasoning_effort, created_at
                ) VALUES (
                    \(event.id), '\(sessionID)', \(event.id), '\(event.model)', \(event.inputTokens), \(event.outputTokens),
                    \(event.cacheReadTokens), \(event.cacheWriteTokens), \(event.reasoningTokens), \(event.durationMS),
                    \(effort), '\(event.createdAt)'
                );
                """,
                database: database
            )
        }
    }

    private func execute(_ sql: String, database: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw NSError(domain: "CopilotSessionWatcherTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "Unknown SQLite error"
            ])
        }
    }
}
