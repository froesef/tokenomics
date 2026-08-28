import Foundation
import XCTest
@testable import Tokenomics

/// Exercises HookInstaller's JSON merge/prune logic only via its pure `applyingHooks`/`removingHooks`
/// functions and a throwaway settings file — never the real `~/.claude/settings.json` (see
/// `defaultSettingsURL`'s doc comment: it's overridable specifically so tests never touch it).
final class HookInstallerTests: XCTestCase {
    @MainActor
    func testApplyingHooksAddsEverySlotToAnEmptyDocument() {
        let result = HookInstaller.applyingHooks(to: [:])

        guard let hooks = result["hooks"] as? [String: Any] else {
            XCTFail("expected a hooks key")
            return
        }
        let expectedEvents = Set(HookInstaller.hookSlots.map(\.event))
        XCTAssertEqual(Set(hooks.keys), expectedEvents)

        // Notification is the one event registered under multiple matchers — confirm all four landed.
        guard let notificationGroups = hooks["Notification"] as? [[String: Any]] else {
            XCTFail("expected Notification groups")
            return
        }
        let matchers = Set(notificationGroups.compactMap { $0["matcher"] as? String })
        XCTAssertEqual(matchers, ["permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"])
    }

    @MainActor
    func testApplyingHooksPreservesUnrelatedExistingEntries() {
        let existing: [String: Any] = [
            "model": "claude-sonnet-5",
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]
                ]
            ],
        ]

        let result = HookInstaller.applyingHooks(to: existing)

        XCTAssertEqual(result["model"] as? String, "claude-sonnet-5")
        guard let preToolUse = (result["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] else {
            XCTFail("expected PreToolUse groups")
            return
        }
        // The pre-existing rtk hook, untouched, plus our own "*" group.
        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertTrue(preToolUse.contains { ($0["matcher"] as? String) == "Bash" })
        XCTAssertTrue(preToolUse.contains { ($0["matcher"] as? String) == "*" })
    }

    @MainActor
    func testApplyingHooksIsIdempotent() {
        let once = HookInstaller.applyingHooks(to: [:])
        let twice = HookInstaller.applyingHooks(to: once)

        for slot in HookInstaller.hookSlots {
            let groups = ((twice["hooks"] as? [String: Any])?[slot.event] as? [[String: Any]]) ?? []
            let matches = groups.filter { ($0["matcher"] as? String) == slot.matcher }
            XCTAssertEqual(matches.count, 1, "slot \(slot.event)/\(slot.matcher ?? "nil") should not duplicate")
        }
    }

    @MainActor
    func testRemovingHooksStripsOnlyOurEntriesAndPrunesEmptyGroups() {
        let installed = HookInstaller.applyingHooks(to: [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]
                ]
            ]
        ])

        let (result, changed) = HookInstaller.removingHooks(from: installed)

        XCTAssertTrue(changed)
        guard let hooks = result["hooks"] as? [String: Any] else {
            XCTFail("expected hooks to remain (the unrelated rtk entry survives)")
            return
        }
        // Every one of our own event arrays (Stop, SessionStart, ...) should be fully pruned away.
        XCTAssertNil(hooks["Stop"])
        XCTAssertNil(hooks["Notification"])
        // The pre-existing, unrelated rtk hook under PreToolUse must survive untouched...
        guard let preToolUse = hooks["PreToolUse"] as? [[String: Any]] else {
            XCTFail("expected PreToolUse to survive")
            return
        }
        XCTAssertEqual(preToolUse.count, 1)
        XCTAssertEqual(preToolUse.first?["matcher"] as? String, "Bash")
    }

    @MainActor
    func testRemovingHooksOnUntouchedDocumentReportsNoChange() {
        let (result, changed) = HookInstaller.removingHooks(from: ["model": "claude-sonnet-5"])

        XCTAssertFalse(changed)
        XCTAssertEqual(result["model"] as? String, "claude-sonnet-5")
    }

    @MainActor
    func testInstallThenUninstallRoundTripsThroughARealFileWithoutTouchingTheRealSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        try #"{"model": "claude-sonnet-5"}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        try HookInstaller.install(settingsURL: settingsURL)
        XCTAssertTrue(HookInstaller.isInstalled(settingsURL: settingsURL))

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.json.tokenomics-backup-") }
        XCTAssertEqual(backups.count, 1, "install() over an existing file should leave exactly one backup")

        try HookInstaller.uninstall(settingsURL: settingsURL)
        XCTAssertFalse(HookInstaller.isInstalled(settingsURL: settingsURL))

        let data = try Data(contentsOf: settingsURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "claude-sonnet-5")
        XCTAssertNil(root?["hooks"])
    }
}
