import Foundation
import SQLite3
import XCTest
@testable import Tokenomics

final class CopilotSessionStoreTests: XCTestCase {
    func testLoadReadsOnlyAllowlistedUsageFields() throws {
        let home = try makeStore()
        defer { try? FileManager.default.removeItem(at: home) }
        try insertFixture(into: home)

        let result = CopilotSessionStore(copilotHome: home).load()

        guard case let .success(snapshot) = result else {
            return XCTFail("Expected compatible Copilot store")
        }
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].sessionID, "session-1")
        XCTAssertEqual(snapshot.events[0].model, "gpt-5.6-terra")
        XCTAssertEqual(snapshot.events[0].inputTokens, 100)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 40)
        XCTAssertEqual(snapshot.events[0].cacheWriteTokens, 20)
        XCTAssertEqual(snapshot.events[0].workingDirectory, "/tmp/project")
        XCTAssertFalse(CopilotSessionStore.usageQuery.contains("summary"))
        XCTAssertFalse(CopilotSessionStore.usageQuery.contains("token_details_json"))
        XCTAssertFalse(CopilotSessionStore.usageQuery.contains("turns"))
        XCTAssertFalse(CopilotSessionStore.usageQuery.contains("session_files"))
        XCTAssertFalse(CopilotSessionStore.usageQuery.contains("forge_trajectory_events"))
    }

    func testLoadPreservesNullableUsageValues() throws {
        let home = try makeStore()
        defer { try? FileManager.default.removeItem(at: home) }
        try insertFixture(into: home, nullableValues: true)

        let result = CopilotSessionStore(copilotHome: home).load()

        guard case let .success(snapshot) = result, let event = snapshot.events.first else {
            return XCTFail("Expected compatible Copilot store")
        }
        XCTAssertNil(event.inputTokens)
        XCTAssertNil(event.cacheReadTokens)
        XCTAssertNil(event.reasoningTokens)
    }

    func testLoadReportsMissingRequiredColumn() throws {
        let home = try makeStore(includeCacheWriteColumn: false)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = CopilotSessionStore(copilotHome: home).load()

        XCTAssertEqual(result, .failure(.columnMissing(table: "assistant_usage_events", column: "cache_write_tokens")))
    }

    func testReadOnlyFlagsNeverRequestWriteAccess() {
        XCTAssertNotEqual(CopilotSessionStore.openFlags & SQLITE_OPEN_READONLY, 0)
        XCTAssertEqual(CopilotSessionStore.openFlags & SQLITE_OPEN_READWRITE, 0)
        XCTAssertEqual(CopilotSessionStore.openFlags & SQLITE_OPEN_CREATE, 0)
    }

    func testDefaultHomeHonorsCopilotHome() {
        XCTAssertEqual(
            CopilotSessionStore.defaultHome(environment: ["COPILOT_HOME": "/tmp/copilot-home"]).path,
            "/tmp/copilot-home"
        )
    }

    private func makeStore(includeCacheWriteColumn: Bool = true) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let databaseURL = home.appendingPathComponent("session-store.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                cwd TEXT,
                summary TEXT
            );
            """,
            database: database
        )
        let cacheWriteColumn = includeCacheWriteColumn ? "cache_write_tokens INTEGER," : ""
        try execute(
            """
            CREATE TABLE assistant_usage_events (
                id INTEGER PRIMARY KEY,
                session_id TEXT NOT NULL,
                turn_index INTEGER,
                model TEXT NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                \(cacheWriteColumn)
                reasoning_tokens INTEGER,
                duration_ms INTEGER,
                reasoning_effort TEXT,
                created_at TEXT NOT NULL,
                token_details_json TEXT
            );
            """,
            database: database
        )
        return home
    }

    private func insertFixture(into home: URL, nullableValues: Bool = false) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("session-store.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        try execute("INSERT INTO sessions (id, cwd, summary) VALUES ('session-1', '/tmp/project', 'private summary');", database: database)
        try execute(
            """
            INSERT INTO assistant_usage_events (
                id, session_id, turn_index, model, input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, reasoning_tokens, duration_ms,
                reasoning_effort, created_at, token_details_json
            ) VALUES (
                1, 'session-1', 2, 'gpt-5.6-terra',
                \(nullableValues ? "NULL" : "100"), 12,
                \(nullableValues ? "NULL" : "40"), 20,
                \(nullableValues ? "NULL" : "3"), 250,
                'high', '2026-09-07T12:00:00.000Z', '{\"private\":\"do not read\"}'
            );
            """,
            database: database
        )
    }

    private func execute(_ sql: String, database: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw NSError(domain: "CopilotSessionStoreTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "Unknown SQLite error"
            ])
        }
    }
}
