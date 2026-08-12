import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@main
struct CodexSessionWatcherTestRunner {
    @MainActor
    static func main() throws {
        try testLoadSessionParsesCodexTokenCounts()
        try testScanAllDiscoversCodexSessionRollouts()
        try testCodexAgentUsesChatGPTKnotIconStyle()
        print("CodexSessionWatcherTests: 3 passed")
    }

    @MainActor
    private static func testLoadSessionParsesCodexTokenCounts() throws {
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
            throw TestFailure.assertion("Expected Codex transcript to parse into a Session")
        }

        try expect(session.agentKind == .codex, "agentKind")
        try expect(session.id == "thr_123", "id")
        try expect(session.workingDirectory == "/Users/me/project", "workingDirectory")
        try expect(session.projectName == "project", "projectName")
        try expect(session.model == "gpt-5.6-terra", "model")
        try expect(session.effort == "high", "effort")
        try expect(session.version == "0.144.2", "version")
        try expect(session.totalInputTokens == 1_000, "totalInputTokens")
        try expect(session.cachedInputTokens == 750, "cachedInputTokens")
        try expect(session.outputTokens == 120, "outputTokens")
        try expect(session.reasoningOutputTokens == 40, "reasoningOutputTokens")
        try expect(abs((session.cacheHitRatio ?? 0) - 0.75) < 0.001, "cacheHitRatio")
        try expect(session.supportsCacheCountdown == false, "supportsCacheCountdown")
        try expect(session.detectedTTL == nil, "detectedTTL")
    }

    @MainActor
    private static func testScanAllDiscoversCodexSessionRollouts() throws {
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

        try expect(scanned.map(\.id) == ["thr_abc"], "scanAll ids")
        try expect(scanned.first?.agentKind == .codex, "scanAll agentKind")
        try expect(abs((scanned.first?.cacheHitRatio ?? 0) - 0.25) < 0.001, "scanAll cacheHitRatio")
    }

    @MainActor
    private static func testCodexAgentUsesChatGPTKnotIconStyle() throws {
        try expect(AgentKind.codex.iconStyle == .chatGPTKnot, "Codex icon style")
    }

    private static func makeTranscript(lines: [String]) throws -> URL {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("rollout-test.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func expect(_ condition: Bool, _ label: String) throws {
        if !condition {
            throw TestFailure.assertion("Expectation failed: \(label)")
        }
    }
}
