# Codex Session Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track local Codex sessions alongside Claude Code sessions in the Tokenomics menu bar app.

**Architecture:** Add a read-only `CodexSessionWatcher` that scans `~/.codex` JSONL session rollouts and converts them into the existing `Session` row model with an explicit `agent` discriminator. Keep Claude Code TTL countdowns, notifications, Ghostty actions, and keep-alive behavior scoped to Claude sessions; Codex rows show last activity and cached-input usage without claiming an exact cache TTL.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, Foundation JSON parsing, CoreServices FSEvents, SwiftUI.

## Global Constraints

- Read local Codex transcripts only; never write to `~/.codex` session files or `auth.json`.
- Do not auto-pin, rename, archive, or otherwise mutate Codex sessions.
- Codex cache display is usage-based: show cached input ratio and token totals, not a precise expiry countdown.
- Keep existing Claude Code behavior intact, including `ccusage`, Ghostty focus/paste, notifications, and Auto Keep-Alive.
- Add regression tests before production parser code.

---

### Task 1: Codex Parser

**Files:**
- Modify: `Package.swift`
- Create: `Tests/TokenomicsTests/CodexSessionWatcherTests.swift`
- Create: `Sources/Tokenomics/Services/CodexSessionWatcher.swift`
- Modify: `Sources/Tokenomics/Models/Session.swift`
- Modify: `Sources/Tokenomics/Services/TranscriptWatcher.swift`

**Interfaces:**
- Produces: `CodexSessionWatcher.init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))`
- Produces: `CodexSessionWatcher.loadSession(from url: URL) -> Session?`
- Produces: `CodexSessionWatcher.scanAll() -> [Session]`
- Produces: `AgentKind` with `.claudeCode` and `.codex`
- Produces on `Session`: `agent`, `totalInputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningOutputTokens`, `supportsCacheCountdown`

- [ ] **Step 1: Write the failing parser test**

```swift
func testLoadSessionParsesCodexTokenCounts() throws {
    let transcript = makeTranscript([
        sessionMeta(threadID: "thr_123", cwd: "/Users/me/project", version: "0.144.2"),
        turnContext(model: "gpt-5.6-terra", effort: "high", cwd: "/Users/me/project"),
        agentMessage("Readable answer"),
        tokenCount(input: 1_000, cached: 750, output: 120, reasoning: 40)
    ])
    let session = CodexSessionWatcher().loadSession(from: transcript)
    XCTAssertEqual(session?.agentKind, .codex)
    XCTAssertEqual(session?.id, "thr_123")
    XCTAssertEqual(session?.workingDirectory, "/Users/me/project")
    XCTAssertEqual(session?.model, "gpt-5.6-terra")
    XCTAssertEqual(session?.effort, "high")
    XCTAssertEqual(session?.version, "0.144.2")
    XCTAssertEqual(session?.totalInputTokens, 1_000)
    XCTAssertEqual(session?.cachedInputTokens, 750)
    XCTAssertEqual(session?.outputTokens, 120)
    XCTAssertEqual(session?.reasoningOutputTokens, 40)
    XCTAssertEqual(session?.cacheHitRatio, 0.75, accuracy: 0.001)
    XCTAssertEqual(session?.supportsCacheCountdown, false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --filter CodexSessionWatcherTests`
Expected: FAIL because `CodexSessionWatcher` and Codex session fields do not exist.

- [ ] **Step 3: Implement minimal parser**

Parse only structural Codex rollout records:
- `session_meta.payload.id` or `session_id` for the row id.
- `session_meta.payload.cwd` or latest `turn_context.payload.cwd` for working directory.
- `session_meta.payload.cli_version` for version.
- latest `turn_context.payload.model` and `.effort`.
- latest `event_msg.payload.type == "agent_message"` text length.
- latest `event_msg.payload.type == "token_count"` `info.total_token_usage`.

- [ ] **Step 4: Run parser tests**

Run: `env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --filter CodexSessionWatcherTests`
Expected: PASS.

### Task 2: App Integration

**Files:**
- Modify: `Sources/Tokenomics/ViewModels/SessionListViewModel.swift`
- Modify: `Sources/Tokenomics/Views/MenuContentView.swift`
- Modify: `Sources/Tokenomics/Views/SessionRowView.swift`
- Modify: `Sources/Tokenomics/Views/SessionDetailPanelView.swift`
- Modify: `Sources/Tokenomics/App.swift`

**Interfaces:**
- Consumes: `CodexSessionWatcher.scanAll() -> [Session]`
- Consumes: `Session.supportsCacheCountdown`

- [ ] **Step 1: Merge Codex sessions into the ViewModel scan**

Add a `CodexSessionWatcher`, register its `onChange`, and concatenate its scan results with Claude results.

- [ ] **Step 2: Keep Claude-only behaviors Claude-only**

Apply `UsageService`, `ProcessMatcher` filtering, notifications, banners, Ghostty actions, and Auto Keep-Alive only when `session.agentKind == .claudeCode`.

- [ ] **Step 3: Render Codex rows honestly**

Show a `Codex` badge, last activity age, cached input ratio, model/effort/version, and token totals. Hide TTL, cold countdowns, Ghostty paste actions, and keep-alive for Codex rows.

- [ ] **Step 4: Build**

Run: `env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build`
Expected: PASS.

### Task 3: Documentation

**Files:**
- Modify: `README.md`
- Modify: `TOKEN_TIPS.md`
- Modify: `Sources/Tokenomics/Views/TokenTipsView.swift`
- Modify: `DEVELOPMENT.md`

**Interfaces:**
- Consumes: implemented Codex tracking behavior.

- [ ] **Step 1: Document Codex tracking**

State that Tokenomics reads local Codex JSONL session rollouts and shows cached-input usage but not an exact prompt-cache TTL countdown.

- [ ] **Step 2: Update Codex cache tips**

Describe GPT-5.6+ cache TTL as at least 30 minutes, older model in-memory cache as roughly 5-10 minutes up to one hour, and cached-input pricing as distinct from fresh input.

- [ ] **Step 3: Full verification**

Run: `env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test`
Run: `env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build`
Expected: both PASS.
