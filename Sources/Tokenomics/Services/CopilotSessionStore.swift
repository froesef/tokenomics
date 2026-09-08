import Foundation
import SQLite3

/// Scalar telemetry read from Copilot's local session store. This deliberately
/// excludes all conversation, tool, file, configuration, and credential content.
struct CopilotUsageEvent: Equatable, Sendable {
    let id: Int64
    let sessionID: String
    let turnIndex: Int?
    let model: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let reasoningTokens: Int?
    let durationMS: Int?
    let reasoningEffort: String?
    let createdAt: Date
    let workingDirectory: String?
}

struct CopilotStoreSnapshot: Equatable, Sendable {
    let schemaFingerprint: String
    let events: [CopilotUsageEvent]
}

enum CopilotStoreError: Error, Equatable, LocalizedError {
    case homeMissing(URL)
    case databaseMissing(URL)
    case tableMissing(String)
    case columnMissing(table: String, column: String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .homeMissing(url):
            "Copilot data directory is unavailable at \(url.path)"
        case let .databaseMissing(url):
            "Copilot session store is unavailable at \(url.path)"
        case let .tableMissing(table):
            "Copilot session store is missing required table \(table)"
        case let .columnMissing(table, column):
            "Copilot session store is missing required column \(table).\(column)"
        case let .sqlite(message):
            "Couldn't read Copilot session store: \(message)"
        }
    }
}

/// Reads the documented Copilot CLI session database without modifying its schema,
/// data, journal, or WAL. The SQLite schema itself is an observed compatibility
/// surface, so every read starts with capability detection.
final class CopilotSessionStore {
    static let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX

    static let usageQuery = """
        SELECT
            e.id,
            e.session_id,
            e.turn_index,
            e.model,
            e.input_tokens,
            e.output_tokens,
            e.cache_read_tokens,
            e.cache_write_tokens,
            e.reasoning_tokens,
            e.duration_ms,
            e.reasoning_effort,
            e.created_at,
            s.cwd
        FROM assistant_usage_events AS e
        INNER JOIN sessions AS s ON s.id = e.session_id
        ORDER BY e.created_at ASC, e.id ASC
        """

    private static let requiredColumns = [
        "sessions": ["id", "cwd"],
        "assistant_usage_events": [
            "id", "session_id", "turn_index", "model", "input_tokens",
            "output_tokens", "cache_read_tokens", "cache_write_tokens",
            "reasoning_tokens", "duration_ms", "reasoning_effort", "created_at"
        ]
    ]

    private let copilotHome: URL
    private let fileManager: FileManager

    init(
        copilotHome: URL = CopilotSessionStore.defaultHome(),
        fileManager: FileManager = .default
    ) {
        self.copilotHome = copilotHome
        self.fileManager = fileManager
    }

    var homeURL: URL { copilotHome }

    static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configuredHome = environment["COPILOT_HOME"], !configuredHome.isEmpty {
            return URL(fileURLWithPath: configuredHome, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot", isDirectory: true)
    }

    func load() -> Result<CopilotStoreSnapshot, CopilotStoreError> {
        guard fileManager.fileExists(atPath: copilotHome.path) else {
            return .failure(.homeMissing(copilotHome))
        }

        let databaseURL = copilotHome.appendingPathComponent("session-store.db", isDirectory: false)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return .failure(.databaseMissing(databaseURL))
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &database, Self.openFlags, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(database)
            return .failure(.sqlite(message))
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 250)

        switch validateSchema(database) {
        case let .success(fingerprint):
            return readUsageEvents(from: database).map { CopilotStoreSnapshot(schemaFingerprint: fingerprint, events: $0) }
        case let .failure(error):
            return .failure(error)
        }
    }

    private func validateSchema(_ database: OpaquePointer) -> Result<String, CopilotStoreError> {
        var fingerprintParts: [String] = []
        for table in Self.requiredColumns.keys.sorted() {
            switch tableColumns(table, database: database) {
            case let .success(columns):
                guard !columns.isEmpty else {
                    return .failure(.tableMissing(table))
                }
                if let missingColumn = Self.requiredColumns[table, default: []].first(where: { !columns.contains($0) }) {
                    return .failure(.columnMissing(table: table, column: missingColumn))
                }
                fingerprintParts.append("\(table):\(columns.sorted().joined(separator: ","))")
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(fingerprintParts.joined(separator: "|"))
    }

    private func tableColumns(_ table: String, database: OpaquePointer) -> Result<Set<String>, CopilotStoreError> {
        let query = "PRAGMA table_info(\(table))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .failure(.sqlite(String(cString: sqlite3_errmsg(database))))
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            return .failure(.sqlite(String(cString: sqlite3_errmsg(database))))
        }
        return .success(columns)
    }

    private func readUsageEvents(from database: OpaquePointer) -> Result<[CopilotUsageEvent], CopilotStoreError> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.usageQuery, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .failure(.sqlite(String(cString: sqlite3_errmsg(database))))
        }
        defer { sqlite3_finalize(statement) }

        var events: [CopilotUsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let sessionID = string(at: 1, in: statement),
                let model = string(at: 3, in: statement),
                let timestamp = string(at: 11, in: statement),
                let createdAt = Self.date(from: timestamp)
            else {
                continue
            }

            events.append(CopilotUsageEvent(
                id: sqlite3_column_int64(statement, 0),
                sessionID: sessionID,
                turnIndex: integer(at: 2, in: statement),
                model: model,
                inputTokens: integer(at: 4, in: statement),
                outputTokens: integer(at: 5, in: statement),
                cacheReadTokens: integer(at: 6, in: statement),
                cacheWriteTokens: integer(at: 7, in: statement),
                reasoningTokens: integer(at: 8, in: statement),
                durationMS: integer(at: 9, in: statement),
                reasoningEffort: string(at: 10, in: statement),
                createdAt: createdAt,
                workingDirectory: string(at: 12, in: statement)
            ))
        }

        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            return .failure(.sqlite(String(cString: sqlite3_errmsg(database))))
        }
        return .success(events)
    }

    private func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func integer(at index: Int32, in statement: OpaquePointer) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, index)
        guard value >= Int64(Int.min), value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
