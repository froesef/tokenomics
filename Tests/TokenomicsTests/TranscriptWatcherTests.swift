import Foundation
import XCTest
@testable import Tokenomics

final class TranscriptWatcherTests: XCTestCase {
    @MainActor
    func testLoadSessionParsesBasicFields() throws {
        let transcript = try makeTranscript(lines: [
            jsonLine([
                "type": "user", "cwd": "/Users/me/project", "timestamp": "2026-08-12T10:00:00.000Z",
                "message": ["content": "hi"]
            ]),
            jsonLine([
                "type": "assistant", "timestamp": "2026-08-12T10:00:01.000Z", "requestId": "r1",
                "version": "2.1.0", "effort": "high",
                "message": [
                    "model": "claude-sonnet-5",
                    "content": [["type": "text", "text": "hello back"]],
                    "usage": ["cache_creation_input_tokens": 500, "cache_read_input_tokens": 0]
                ]
            ]),
            jsonLine(["type": "system", "subtype": "turn_duration", "timestamp": "2026-08-12T10:00:02.000Z"]),
            jsonLine(["type": "ai-title", "aiTitle": "Fix login bug", "timestamp": "2026-08-12T10:00:02.500Z"])
        ])

        guard let session = TranscriptWatcher().loadSession(from: transcript) else {
            XCTFail("Expected transcript to parse into a Session")
            return
        }

        XCTAssertEqual(session.workingDirectory, "/Users/me/project")
        XCTAssertEqual(session.aiTitle, "Fix login bug")
        XCTAssertEqual(session.model, "claude-sonnet-5")
        XCTAssertEqual(session.effort, "high")
        XCTAssertEqual(session.version, "2.1.0")
        XCTAssertEqual(session.cacheCreationTokens, 500)
        XCTAssertEqual(session.cacheReadTokens, 0)
        XCTAssertEqual(session.currentContextTokens, 500)
        XCTAssertEqual(session.lastVisibleCharCount, "hello back".count)
        XCTAssertEqual(session.activity, .idle)
    }

    /// A user `/rename` (`custom-title`) always wins over Claude Code's own auto-generated `ai-title`,
    /// even one that arrives afterward — see TranscriptWatcher.ParseState.customTitle.
    @MainActor
    func testCustomTitleOverridesLaterAiTitle() throws {
        let transcript = try makeTranscript(lines: [
            jsonLine([
                "type": "user", "cwd": "/Users/me/project", "timestamp": "2026-08-12T10:00:00.000Z",
                "message": ["content": "hi"]
            ]),
            jsonLine(["type": "ai-title", "aiTitle": "auto title 1", "timestamp": "2026-08-12T10:00:01.000Z"]),
            jsonLine(["type": "custom-title", "customTitle": "My Name", "timestamp": "2026-08-12T10:00:02.000Z"]),
            jsonLine(["type": "ai-title", "aiTitle": "auto title 2", "timestamp": "2026-08-12T10:00:03.000Z"])
        ])

        let session = try XCTUnwrap(TranscriptWatcher().loadSession(from: transcript))
        XCTAssertEqual(session.aiTitle, "My Name")
    }

    /// Activity walks running -> waitingForInput (on an AskUserQuestion tool_use) -> running (once its
    /// tool_result answer lands) -> idle (turn_duration) — see TranscriptWatcher.updateActivity.
    @MainActor
    func testActivityTracksAskUserQuestionRoundTrip() throws {
        let userTurn = jsonLine([
            "type": "user", "cwd": "/Users/me/project", "timestamp": "2026-08-12T10:00:00.000Z",
            "message": ["content": "please do X"]
        ])
        let askQuestion = jsonLine([
            "type": "assistant", "timestamp": "2026-08-12T10:00:01.000Z",
            "message": ["content": [["type": "tool_use", "id": "tu1", "name": "AskUserQuestion"]]]
        ])
        let toolResultReply = jsonLine([
            "type": "user", "timestamp": "2026-08-12T10:00:02.000Z",
            "message": ["content": [["type": "tool_result", "tool_use_id": "tu1", "content": "yes"]]]
        ])
        let turnDuration = jsonLine(["type": "system", "subtype": "turn_duration", "timestamp": "2026-08-12T10:00:03.000Z"])

        let watcher = TranscriptWatcher()
        let afterUserTurn = try XCTUnwrap(watcher.loadSession(from: makeTranscript(lines: [userTurn])))
        XCTAssertEqual(afterUserTurn.activity, .running)

        let afterAskQuestion = try XCTUnwrap(watcher.loadSession(from: makeTranscript(lines: [userTurn, askQuestion])))
        XCTAssertEqual(afterAskQuestion.activity, .waitingForInput)

        let afterReply = try XCTUnwrap(watcher.loadSession(from: makeTranscript(lines: [userTurn, askQuestion, toolResultReply])))
        XCTAssertEqual(afterReply.activity, .running)

        let afterTurnDuration = try XCTUnwrap(watcher.loadSession(from: makeTranscript(lines: [userTurn, askQuestion, toolResultReply, turnDuration])))
        XCTAssertEqual(afterTurnDuration.activity, .idle)
    }

    /// A turn following an idle gap longer than the TTL, with zero cache read and a substantial cache
    /// write, is a cold-cache rewrite — but never the session's unavoidable first write. See
    /// TranscriptWatcher.ParseState.processAssistantTurn.
    @MainActor
    func testCacheExpiryDetectedOnlyAfterEarlierCacheActivity() throws {
        func assistantTurn(timestamp: String, requestId: String, creation: Int, read: Int) -> String {
            jsonLine([
                "type": "assistant", "timestamp": timestamp, "requestId": requestId,
                "message": [
                    "model": "claude-sonnet-5",
                    "usage": ["cache_creation_input_tokens": creation, "cache_read_input_tokens": read]
                ]
            ])
        }
        let firstWrite = assistantTurn(timestamp: "2026-08-12T10:00:00.000Z", requestId: "r1", creation: 2000, read: 0)
        let coldRewrite = assistantTurn(timestamp: "2026-08-12T10:05:10.000Z", requestId: "r2", creation: 3000, read: 0)
        let warmRead = assistantTurn(timestamp: "2026-08-12T10:05:15.000Z", requestId: "r3", creation: 50, read: 1500)
        let cwdLine = jsonLine(["type": "user", "cwd": "/Users/me/project", "timestamp": "2026-08-12T09:59:59.000Z", "message": ["content": "start"]])

        let transcript = try makeTranscript(lines: [cwdLine, firstWrite, coldRewrite, warmRead])
        let session = try XCTUnwrap(TranscriptWatcher().loadSession(from: transcript))

        XCTAssertEqual(session.expiryEvents.count, 1)
        XCTAssertEqual(session.expiryEvents.first?.wastedTokens, 3000)
        XCTAssertEqual(session.expiryEvents.first?.ttl, 300)
        XCTAssertEqual(session.cacheReadEvents.count, 1)
        XCTAssertEqual(session.cacheReadEvents.first?.tokens, 1500)
    }

    @MainActor
    func testScanAllFiltersByRecencyWindowAndContentSniff() throws {
        let claudeHome = try temporaryDirectory()
        let projectDir = claudeHome.appendingPathComponent("projects/-Users-me-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let freshLine = jsonLine([
            "type": "user", "sessionId": "fresh-1", "cwd": "/Users/me/project",
            "timestamp": "2026-08-12T10:00:00.000Z", "message": ["content": "hi"]
        ])
        let freshTranscript = projectDir.appendingPathComponent("fresh-1.jsonl")
        try freshLine.write(to: freshTranscript, atomically: true, encoding: .utf8)

        let staleLine = jsonLine([
            "type": "user", "sessionId": "stale-1", "cwd": "/Users/me/project",
            "timestamp": "2026-08-11T00:00:00.000Z", "message": ["content": "old"]
        ])
        let staleTranscript = projectDir.appendingPathComponent("stale-1.jsonl")
        try staleLine.write(to: staleTranscript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: staleTranscript.path
        )

        let notATranscript = projectDir.appendingPathComponent("notes.jsonl")
        try "{\"unrelated\": true}".write(to: notATranscript, atomically: true, encoding: .utf8)

        let scanned = TranscriptWatcher(claudeHome: claudeHome).scanAll()
        XCTAssertEqual(scanned.map(\.id), ["fresh-1"])
    }

    private func makeTranscript(lines: [String]) throws -> URL {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
