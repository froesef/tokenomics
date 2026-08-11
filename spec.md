# Build Spec — Claude Session Monitor (macOS menu bar app)

**Target executor:** Claude Code
**Language / framework:** Swift 6, SwiftUI, `MenuBarExtra` (macOS 14+ deployment target)
**App type:** Menu bar (status item) app — no dock icon, no main window
**Purpose:** A single always-visible overview of every running Claude Code session on this machine — per-project prompt-cache TTL countdown, cost, and cache health — with an optional action to focus the corresponding Ghostty tab.

---

## 0. Context the executor needs

This app monitors [Claude Code](https://code.claude.com) sessions. Key facts that drive the design — treat these as requirements, not background:

- Claude Code writes a **JSONL transcript file per session** under `~/.claude` (in per-project subdirectories). Each line is one event; assistant-response events carry token usage. These files are the app's source of truth. **The app only ever reads them — never writes or locks them.**
- The prompt cache is **scoped per working directory**. Each project directory is an independent session with its own cache and its own TTL timer. Two sessions in different directories never share cache. This is why a per-project overview is meaningful: each row has its own independent countdown.
- **TTL** is either 5 minutes or 60 minutes, set by the `ENABLE_PROMPT_CACHING_1H` environment variable at Claude Code launch (5 min is the default on API-key/Bedrock auth; 60 min when the var is set). The transcript does not record which TTL was in effect, so the app takes the TTL as a **user setting** (default: 60 min) and may later refine it heuristically (see §6, optional).
- The cache stays warm as long as turns keep happening; **each turn resets the timer**. The countdown is therefore `(last_turn_time + TTL) − now`, where `last_turn_time` is the transcript file's last-modified time (or the timestamp of its last event — prefer the event timestamp if cheaply available, else mtime).
- When the countdown hits zero the cache is **cold**: the next turn reprocesses the full context uncached (expensive). Warning the user *before* this happens is the app's primary value.
- Cost math should be delegated to [`ccusage`](https://github.com/ryoppippi/ccusage) (`npx ccusage`), NOT reimplemented — pricing changes and differs between direct API and Bedrock. The app shells out to it.

**Do not** attempt to hook into the live Claude Code process, intercept the API, or parse the terminal. Everything is derived from files on disk plus `ccusage`.

---

## 1. Deliverable

A buildable Xcode project (or Swift Package with an app target) that compiles to a `.app` and runs as a menu bar app. Provide:

- Full Swift source, organized as in §7.
- A `README.md` with build/run instructions and how to grant the required permissions.
- The project must build cleanly with `xcodebuild` from the command line (state the exact command in the README).

---

## 2. Menu bar presentation

- Use `MenuBarExtra` with `.menuBarExtraStyle(.window)` so the dropdown can host a real SwiftUI view (list rows, colors, buttons), not just `NSMenu` items.
- **Bar title:** show the most urgent session's countdown as compact text next to the icon — e.g. `⏱ 4:12` (the soonest-to-expire warm session). If all sessions are cold or none exist, show just the icon. Keep it short; the menu bar is tight.
- **Icon:** an SF Symbol (e.g. `timer` or `brain`) with a tint that reflects the worst current status across all sessions (green/amber/red — see §4).

---

## 3. The dropdown — session list

A scrollable list, one row per detected session, sorted by countdown ascending (most urgent first). Each row shows:

- **Status dot** — green / amber / red per §4.
- **Project name** — the leaf of the working directory path (e.g. `my-api`), with the full path available on hover/as a tooltip.
- **Countdown** — `MM:SS` until cache goes cold, or `cold` if already expired, or `warm` if you choose not to show live seconds past a threshold. Live-updating (see §5).
- **Session cost** — from `ccusage`, formatted as currency. If `ccusage` is unavailable, show `—` and surface the reason in a footer, don't crash.
- **Cache hit ratio** — `cache_read / (cache_read + cache_creation)` as a percentage, computed from the transcript token counts. This is the signal for whether caching is actually working; a persistently low ratio means the prefix keeps invalidating.
- **Focus button** (optional action) — an arrow/target icon that, when clicked, focuses the matching Ghostty tab (see §8). If Ghostty control isn't available/authorized, hide or disable this control gracefully.

Footer of the dropdown:
- A gear/settings affordance (see §6).
- A "Quit" item.
- If any dependency is missing (`ccusage`, Ghostty automation permission), a single unobtrusive status line explaining what's degraded.

---

## 4. Status thresholds (color logic)

Per session, based on remaining time `r` against the active TTL:

- **Green (warm):** `r > 90s`
- **Amber (expiring soon):** `0 < r ≤ 90s`
- **Red (cold):** `r ≤ 0`

Make the amber threshold a named constant (`expiringSoonThreshold`, default 90s) so it's easy to tune. The bar icon tint = the worst status among all sessions (red if any red, else amber if any amber, else green; no sessions = neutral).

---

## 5. Data layer — transcript watching

- On launch and on a **timer (default 15s, configurable)**, enumerate session transcript files under `~/.claude`. Discover the correct subdirectory layout at runtime by scanning rather than hardcoding a brittle path; document in the README what layout you found and matched. Match files by extension (`.jsonl`) and skip anything unparseable.
- For each transcript, determine:
  - **Working directory** — from the transcript contents if present (preferred — some events record `cwd`), else infer from the directory structure. This is the key used to (a) display the project name and (b) map to a Ghostty tab.
  - **Last turn time** — timestamp of the last event, falling back to file mtime.
  - **Token totals** — sum `cache_creation_input_tokens` and `cache_read_input_tokens` across assistant events for the hit-ratio. Be defensive: field names may vary or be absent on some event types; missing → treat as 0, never crash.
- Prefer **event-driven refresh** via `DispatchSource` / `FSEvents` on `~/.claude` in addition to the polling timer, so countdowns feel live without a tight poll. The polling timer is the fallback and also drives the per-second countdown display (a UI tick separate from the file re-read is fine — re-reading files every second is unnecessary; recompute countdowns from cached `last_turn_time` each second and only re-parse on FS change or the 15s timer).
- Parsing must be resilient: transcripts are appended to live by another process. Read tolerantly (a half-written last line is normal — skip it). Never hold a lock.

**`ccusage` integration:** shell out via `Process` (e.g. `npx ccusage session --json` or the closest current flag — the executor should check `ccusage --help` output at build time and pick the invocation that yields per-session JSON). Parse its JSON. Cache the result and refresh on the 15s timer, not every second (it's heavier than a file read). Degrade gracefully if `npx`/`ccusage` is absent.

---

## 6. Settings

Minimal, persisted via `UserDefaults`:

- **TTL** — segmented choice: 5 min / 60 min (default 60). Drives every countdown.
- **Refresh interval** — default 15s.
- **Expiring-soon threshold** — default 90s.
- **Notify before cold** — toggle (default on) + lead time (default 30s): fire a `UNUserNotificationCenter` local notification when a warm session crosses into the lead-time window, so a forgotten session pings the user before it goes cold. Fire at most once per session per warm-period (don't re-notify every tick).
- **Enable Ghostty focus action** — toggle (default on if automation is authorized).

*(Optional, only if straightforward)* a heuristic TTL detector: if a turn shows a large `cache_creation` spike after a gap longer than 5 min but well under 60, that session is probably on 5-min TTL regardless of the global setting. If implemented, keep it advisory (adjust that row's countdown, note it), never override the user setting silently.

---

## 7. Suggested source layout

```
ClaudeSessionMonitor/
  App.swift                 // @main, MenuBarExtra, app lifecycle, LSUIElement
  Models/
    Session.swift           // struct: id, workingDir, projectName, lastTurn, tokens, cost, status
    CacheStatus.swift       // enum warm/expiringSoon/cold + color mapping
  Services/
    TranscriptWatcher.swift // FSEvents + polling, discovery, JSONL parsing
    UsageService.swift      // ccusage subprocess + JSON parsing
    NotificationService.swift
    GhosttyController.swift  // AppleScript focus-by-working-directory (see §8)
  ViewModels/
    SessionListViewModel.swift // @MainActor ObservableObject, holds [Session], drives timers
  Views/
    MenuContentView.swift   // the dropdown list
    SessionRowView.swift
    SettingsView.swift
    FooterView.swift
  Resources/
    // SF Symbols used inline; Info.plist keys per §9
  README.md
```

Use `@MainActor`, `ObservableObject`/`@Observable`, and structured concurrency (`async`/`await`, `Task`) idiomatically. No third-party dependencies unless one is clearly justified; prefer the standard library, `Foundation`, and `AppKit`/`SwiftUI` only.

---

## 8. Ghostty focus action (optional module — build behind a protocol)

Define a protocol so the terminal integration is a swappable backend and the rest of the app stays terminal-agnostic:

```swift
protocol TerminalController {
    var isAvailable: Bool { get }        // app present + automation authorized
    func focusTab(workingDirectory: String) async throws
}
```

Provide a `GhosttyController: TerminalController` implementation using **Ghostty's native AppleScript dictionary** (shipped in Ghostty 1.3, March 2026 — object model is `Ghostty > Window > Tab > Terminal`, each terminal exposes `working directory`, `title`, a stable id, and a `focus` command). The documented pattern is: find the terminal whose `working directory` matches (or contains) the target path, then `focus` it, then `activate` the app.

Implementation notes / requirements:
- Drive it via `NSAppleScript` or `Process`→`osascript`. Use the **native scripting dictionary**, NOT System Events keystroke injection (the old fragile pattern).
- Ghostty's AppleScript is a **preview** as of 1.3 and the maintainers expect breaking changes in 1.4 — isolate all AppleScript strings/logic in this one file so a future API change is a one-file fix. Reference: https://ghostty.org/docs/features/applescript
- It is gated by macOS **Automation permissions (TCC)**. On first use the OS prompts. Handle the not-yet-authorized and denied states without crashing: `isAvailable` returns false, the focus buttons hide/disable, and the footer explains how to grant it (System Settings → Privacy & Security → Automation).
- Matching: the working directory is the join key between a transcript and a Ghostty terminal. Match exact first, then suffix/contains as a fallback. If multiple terminals match, focus the first and don't error.
- If `activate application "Ghostty"` is needed to raise the app, do that too, so the tab is actually visible after focusing.

Keep this module fully optional: the app is fully functional (the read-only overview) with `GhosttyController.isAvailable == false`.

---

## 9. Packaging / permissions

- `Info.plist`: set `LSUIElement` = `true` (menu bar only, no dock icon).
- Deployment target macOS 14.0.
- For the Ghostty AppleScript control, add `NSAppleEventsUsageDescription` with a clear string, and document that the app must be granted Automation control of Ghostty.
- For notifications, request `UNUserNotificationCenter` authorization on first launch, handle denial gracefully.
- The app must run **unsigned/locally** for the user's own machine (developer will run from Xcode or a local build). Note in the README the Gatekeeper steps to run an unsigned local build. Do not require an Apple Developer account.

---

## 10. Acceptance criteria

The build is done when:

1. Launching the app shows a menu bar item with no dock icon.
2. With at least one active Claude Code session on the machine, the dropdown lists it with a live per-second countdown, correct project name, and a cache hit ratio derived from the transcript.
3. Countdowns are independent per project and update live; a session goes amber ~90s before, red at, cache expiry (relative to the configured TTL).
4. `ccusage` cost appears per session when `ccusage` is installed; its absence degrades to `—` plus a footer note, no crash.
5. A local notification fires once, ~30s (configurable) before a warm session would go cold, when that setting is on.
6. Settings persist across relaunch.
7. With Ghostty running and Automation authorized, clicking a row's focus control raises Ghostty and focuses the tab whose working directory matches that session. With Ghostty absent or unauthorized, the control is hidden/disabled and nothing crashes.
8. No file under `~/.claude` is ever written, locked, or modified. Parsing tolerates live-appended and partially-written transcripts.
9. `xcodebuild` (command in README) produces a runnable `.app`.

## 11. Non-goals (explicitly out of scope for v1)

- Sending commands / prompts into sessions (no tmux `send-keys`, no headless `-p`). Read-and-focus only.
- Historical charts, multi-day analytics, or anything `ccusage` already does well — link out mentally to `ccusage` rather than rebuild it.
- Windows/Linux support.
- Non-Ghostty terminals (but the `TerminalController` protocol should make adding iTerm2 later a new file, not a refactor).
- Code signing / notarization / distribution.

---

## 12. Notes for the executor

- Verify current specifics at build time rather than trusting this doc where it's checkable: run `ccusage --help` for the exact flag that yields per-session JSON; check the actual `~/.claude` transcript layout and JSON field names on this machine and adapt the parser to what's really there (this doc describes the shape, but field names should be confirmed against a real transcript). Read a real transcript file first and mirror its actual structure.
- Prefer clarity over cleverness; this is a personal tool that should be easy to modify. Comment the AppleScript and the transcript-parsing assumptions especially, since those are the parts most likely to drift.
- If any requirement here conflicts with what you observe on the machine (e.g. transcript layout differs), follow the machine and note the deviation in the README.
