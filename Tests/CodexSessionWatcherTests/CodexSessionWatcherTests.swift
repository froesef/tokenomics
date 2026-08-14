import Foundation
import XCTest
@testable import Tokenomics

final class CodexSessionWatcherTests: XCTestCase {
    @MainActor
    func testLoadSessionParsesCodexTokenCounts() throws {
        let transcript = try makeTranscript(lines: [
            jsonLine([
                "timestamp": "2026-08-12T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "thr_123",
                    "session_id": "thr_123",
                    "cwd": "/Users/me/project",
                    "cli_version": "0.144.2",
                    "timestamp": "2026-08-12T10:00:00.000Z"
                ]
            ]),
            jsonLine([
                "timestamp": "2026-08-12T10:00:01.000Z",
                "type": "turn_context",
                "payload": [
                    "cwd": "/Users/me/project",
                    "model": "gpt-5.6-terra",
                    "effort": "high"
                ]
            ]),
            jsonLine([
                "timestamp": "2026-08-12T10:00:02.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "agent_message",
                    "message": "Readable answer"
                ]
            ]),
            jsonLine([
                "timestamp": "2026-08-12T10:00:03.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 1_000,
                            "cached_input_tokens": 750,
                            "output_tokens": 120,
                            "reasoning_output_tokens": 40,
                            "total_tokens": 1_120
                        ]
                    ]
                ]
            ])
        ])

        guard let session = CodexSessionWatcher().loadSession(from: transcript) else {
            XCTFail("Expected Codex transcript to parse into a Session")
            return
        }

        XCTAssertEqual(session.agentKind, .codex)
        XCTAssertEqual(session.id, "thr_123")
        XCTAssertEqual(session.workingDirectory, "/Users/me/project")
        XCTAssertEqual(session.projectName, "project")
        XCTAssertEqual(session.model, "gpt-5.6-terra")
        XCTAssertEqual(session.effort, "high")
        XCTAssertEqual(session.version, "0.144.2")
        XCTAssertEqual(session.totalInputTokens, 1_000)
        XCTAssertEqual(session.cachedInputTokens, 750)
        XCTAssertEqual(session.outputTokens, 120)
        XCTAssertEqual(session.reasoningOutputTokens, 40)
        XCTAssertEqual(session.cacheHitRatio ?? 0, 0.75, accuracy: 0.001)
        XCTAssertFalse(session.supportsCacheCountdown)
        XCTAssertNil(session.detectedTTL)
    }

    @MainActor
    func testScanAllDiscoversCodexSessionRollouts() throws {
        let codexHome = try temporaryDirectory()
        let sessions = codexHome.appendingPathComponent("sessions/2026/08/12", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let transcript = sessions.appendingPathComponent("rollout-2026-08-12T10-00-00-thr_abc.jsonl")
        try [
            jsonLine([
                "timestamp": "2026-08-12T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "thr_abc",
                    "cwd": "/Users/me/other",
                    "cli_version": "0.144.2"
                ]
            ]),
            jsonLine([
                "timestamp": "2026-08-12T10:00:01.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 200,
                            "cached_input_tokens": 50,
                            "output_tokens": 25,
                            "reasoning_output_tokens": 5
                        ]
                    ]
                ]
            ])
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let scanned = CodexSessionWatcher(codexHome: codexHome).scanAll()

        XCTAssertEqual(scanned.map(\.id), ["thr_abc"])
        XCTAssertEqual(scanned.first?.agentKind, .codex)
        XCTAssertEqual(scanned.first?.cacheHitRatio ?? 0, 0.25, accuracy: 0.001)
    }

    @MainActor
    func testCodexAgentUsesChatGPTKnotIconStyle() {
        XCTAssertEqual(AgentKind.codex.iconStyle, .chatGPTKnot)
    }

    private func makeTranscript(lines: [String]) throws -> URL {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("rollout-test.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
