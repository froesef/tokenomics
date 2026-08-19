import Foundation
import XCTest
@testable import Tokenomics

final class HookActivityWatcherTests: XCTestCase {
    @MainActor
    func testLastEventPerSessionWins() throws {
        let log = try makeLog(lines: [
            hookLine(session: "a", event: "UserPromptSubmit"),
            hookLine(session: "a", event: "PreToolUse"),
            hookLine(session: "b", event: "SessionStart"),
            hookLine(session: "a", event: "Stop"),
        ])

        let states = HookActivityWatcher(logFile: log).scanAll()

        XCTAssertEqual(states["a"]?.activity, .idle)
        XCTAssertEqual(states["b"]?.activity, .idle)
    }

    @MainActor
    func testPreCompactSetsCompactingAndTimestamp() throws {
        let log = try makeLog(lines: [
            hookLine(session: "a", event: "UserPromptSubmit"),
            hookLine(session: "a", event: "PreCompact", ts: 1_700_000_000),
        ])

        let states = HookActivityWatcher(logFile: log).scanAll()

        XCTAssertEqual(states["a"]?.activity, .compacting)
        XCTAssertEqual(states["a"]?.compactionStartedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    @MainActor
    func testCompactionStartedAtClearsOnNextEvent() throws {
        let log = try makeLog(lines: [
            hookLine(session: "a", event: "PreCompact", ts: 1_700_000_000),
            hookLine(session: "a", event: "SessionStart"),
        ])

        let states = HookActivityWatcher(logFile: log).scanAll()

        XCTAssertEqual(states["a"]?.activity, .idle)
        XCTAssertNil(states["a"]?.compactionStartedAt)
    }

    @MainActor
    func testNotificationMeansWaitingForInput() throws {
        let log = try makeLog(lines: [
            hookLine(session: "a", event: "UserPromptSubmit"),
            hookLine(session: "a", event: "Notification"),
        ])

        let states = HookActivityWatcher(logFile: log).scanAll()

        XCTAssertEqual(states["a"]?.activity, .waitingForInput)
    }

    @MainActor
    func testUnrecognizedOrMalformedLinesAreIgnored() throws {
        let log = try makeLog(lines: [
            "not json at all",
            hookLine(session: "a", event: "SomeFutureHookEvent"),
            "{\"payload\": {\"hook_event_name\": \"Stop\"}}",  // missing session_id
        ])

        let states = HookActivityWatcher(logFile: log).scanAll()

        XCTAssertTrue(states.isEmpty)
    }

    @MainActor
    func testMissingLogFileReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl")

        XCTAssertTrue(HookActivityWatcher(logFile: missing).scanAll().isEmpty)
    }

    @MainActor
    func testTrimsLogOnceOverThreshold() throws {
        var lines: [String] = []
        for i in 0..<10 {
            lines.append(hookLine(session: "a", event: i.isMultiple(of: 2) ? "UserPromptSubmit" : "Stop"))
        }
        let log = try makeLog(lines: lines)

        _ = HookActivityWatcher(logFile: log, trimThreshold: 5, trimKeepLines: 3).scanAll()

        let remaining = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(remaining.count, 3)
    }

    // MARK: - Helpers

    private func hookLine(session: String, event: String, ts: Int = 1_700_000_000) -> String {
        let payload: [String: Any] = ["session_id": session, "hook_event_name": event, "cwd": "/tmp/project"]
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadString = String(decoding: payloadData, as: UTF8.self)
        return "{\"tokenomics_ts\":\(ts),\"payload\":\(payloadString)}"
    }

    private func makeLog(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hook-events.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
