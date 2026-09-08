import Foundation
import SQLite3
import XCTest
@testable import Tokenomics

final class CopilotSessionWatcherTests: XCTestCase {
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
                (1, "gpt-5.6-luna", 100, 20, 10, 5, 2, 100, "low", "2027-01-15T08:00:00.000Z"),
                (2, "gpt-5.6-terra", 200, 40, 30, 15, 4, 200, "high", "2027-01-15T08:01:00.000Z")
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
            events: [(1, "gpt-5.6-sol", 1, 0, 0, 1, 0, 1, nil, "2026-01-01T00:00:00.000Z")]
        )
        try insert(
            into: home,
            sessionID: "no-cwd",
            cwd: nil,
            events: [(2, "gpt-5.6-sol", 1, 0, 0, 1, 0, 1, nil, "2027-01-15T08:00:00.000Z")]
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
        events: [(Int, String, Int, Int, Int, Int, Int, Int, String?, String)]
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("session-store.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let escapedCWD = cwd.map { "'\($0)'" } ?? "NULL"
        try execute("INSERT INTO sessions (id, cwd) VALUES ('\(sessionID)', \(escapedCWD));", database: database)
        for event in events {
            let effort = event.8.map { "'\($0)'" } ?? "NULL"
            try execute(
                """
                INSERT INTO assistant_usage_events (
                    id, session_id, turn_index, model, input_tokens, output_tokens,
                    cache_read_tokens, cache_write_tokens, reasoning_tokens, duration_ms,
                    reasoning_effort, created_at
                ) VALUES (
                    \(event.0), '\(sessionID)', \(event.0), '\(event.1)', \(event.2), \(event.5),
                    \(event.3), \(event.4), \(event.6), \(event.7), \(effort), '\(event.9)'
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
