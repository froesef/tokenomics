# Development notes

Implementation notes, verification details, and deviations from [`spec.md`](spec.md) that don't belong
in the user-facing [README](README.md). Read `spec.md` first for the original design rationale — this
file covers what changed or was learned on contact with a real machine.

## Build environment note

This repo was built in an environment with only Xcode Command Line Tools installed, not full Xcode
(`xcodebuild -version` reports "requires Xcode"), so the `xcodebuild` invocation in the README could not
be executed there. It follows Apple's documented Swift-package-as-Xcode-project support and should work
as-is once you have full Xcode — if the scheme name differs, `xcodebuild -list` from this directory will
show the generated scheme name to use instead. `swift build -c release` was verified end-to-end: it
compiles cleanly, and the packaged `.app` launched, ran a full transcript-scan + `ccusage` refresh cycle,
and quit cleanly.

## Transcript layout (confirmed against a real machine)

`spec.md` describes the layout as needing runtime discovery rather than a hardcoded path. Confirmed
layout: `~/.claude/projects/<sanitized-absolute-cwd>/<session-uuid>.jsonl` — one directory per project
(dashes standing in for `/`), one file per session. `TranscriptWatcher` doesn't hardcode `projects/`; it
walks `~/.claude` (bounded depth) and only treats a `.jsonl` file as a transcript if it contains a
`"sessionId"` key, so a layout change wouldn't silently produce zero results.

Confirmed transcript field shapes (`spec.md` §12 asked for this to be verified against a real file, not
assumed):
- Each event line carries top-level `type`, `timestamp`, and — on most event types — `cwd` (the working
  directory, used directly; the directory-name-reversal fallback in `TranscriptWatcher` is best-effort
  and rarely needed).
- Assistant events carry `message.usage.cache_creation_input_tokens` and `.cache_read_input_tokens`,
  exactly as spec'd.
- **Not in spec.md, found while inspecting a real transcript:** `message.usage.cache_creation` also
  carries `ephemeral_1h_input_tokens` and `ephemeral_5m_input_tokens`. Whichever is non-zero on a turn
  *is* the TTL Claude Code actually used for that turn — ground truth, not a guess. `spec.md` §0 states
  "the transcript does not record which TTL was in effect" and proposes an inference heuristic in §6;
  that turned out to be unnecessary. `Session.detectedTTL` uses this field directly and, when present,
  drives that row's countdown instead of the global setting (rows show a small "auto" tag when this is
  active) — consistent with §6's instruction to keep any such refinement advisory and visible, never a
  silent override.

## `ccusage` integration (confirmed)

Verified by actually running it (`npx ccusage@latest --help`, then `... claude session --json`):
`ccusage claude session --json` returns `{"sessions": [{"sessionId", "projectPath", "totalCost", ...}]}`.
`sessionId` matches the transcript filename stem, which is exactly what `TranscriptWatcher` uses as
`Session.id` — so cost is joined by session ID, not by working directory. `UsageService` tries a bare
`ccusage` on `PATH` first, then falls back to `npx ccusage@latest`; either failing degrades to `—` per
row plus a footer note, never a crash. (Aside, unrelated to this app: on the machine this was built on,
`npx` itself failed until `npm_config_cache` pointed at a writable directory, because `~/.npm` had
root-owned cache files — a pre-existing local `npm` issue, not something this app should paper over.)

## Deviations from spec.md

1. **Recency window: 24h, not unbounded, no scroll.** `spec.md` doesn't bound how far back to look for
   transcripts. On a machine with months of Claude Code history, showing every past session forever would
   mean either an unusable multi-hundred-row dropdown or a scrollbar hiding most of it. Tuned by measuring
   the real machine: 24h landed at 18 transcripts (30 days would have been 121) — comfortably inside "no
   need for scrolling, unlikely more than 20 running" without the arbitrary feel of a hardcoded row cap.
   `TranscriptWatcher.recencyWindow`; the check happens on file mtime *before* the full parse, so raising
   it later is cheap. Sessions are sorted with warm/expiring-soon always above cold, and cold sessions by
   most-recently-active first — otherwise a 24h-old dead session would outrank a session expiring in 10s.
2. **Detected-TTL tag.** An "auto" tag replaces the optional heuristic in §6 with an exact per-turn signal
   already in the transcript (`cache_creation.ephemeral_{1h,5m}_input_tokens`) — see above.
3. **AI-generated session title, shown next to the project name.** Not in spec.md's row layout (§3),
   requested directly: Claude Code writes an `ai-title` event per session (the same text it uses as the
   Ghostty tab title) — `Session.aiTitle` captures it and `SessionRowView` shows it next to the folder
   name, truncated, full text in the hover tooltip.
4. **Real per-session Ghostty cross-reference, not just app-level availability.** Originally a row showed
   its focus control whenever Ghostty was reachable *at all*; clicking one with no actual matching tab
   silently did nothing. `GhosttyController.hasOpenTab(workingDirectory:)` now fetches every open
   terminal's working directory in one batched AppleScript call per refresh and each row checks against
   that set, so the arrow/tap-to-focus only appears when a real match exists.
5. **Fixed a real crash: synchronous AppleScript on the main thread during a SwiftUI view update.**
   `GhosttyController.isAvailable` used to run `NSAppleScript` synchronously and was read directly from
   `MenuContentView.body`. The Apple Event round trip re-enters the run loop while SwiftUI's own
   AttributeGraph is mid-transaction, corrupting it and aborting the process (confirmed from a real crash
   report: `isAvailable.getter → probeAutomationAuthorized → NSAppleScript → AEDefaultActiveProc`, called
   from the view body) — this is exactly why the dropdown looked empty and the app quit after a few
   seconds. Fixed: `isAvailable`/`hasOpenTab` are now plain cached reads; all AppleScript execution moved
   into `Task.detached` and only runs from `refreshAvailability()`/`focusTab()`, never a view body.
6. **Top-of-screen banner.** Requested directly, not in spec.md: in addition to the §6 system notification,
   a small floating panel appears near the top of the screen with a "Switch to Session" button,
   auto-dismissing after 20s. It only offers *switch* and *dismiss*.
7. **Paste (never run) `/handoff` and `/compact` — via a real Ghostty command spec.md didn't document.**
   Requested directly, and spec.md §11 explicitly rules out sending anything into a session ("no tmux
   `send-keys`, no headless `-p`... read-and-focus only"). The resolution: dumped Ghostty's *actual*
   scripting dictionary directly from `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef` (spec.md
   §8 only described `working directory`/`title`/`focus`) and found `input text "..." to terminal` —
   "Input text to a terminal as if it was pasted." Its own semantics never send Return, so it's not
   "sending a command into a session" the way `-p` or `send-keys` are — it's the same physical action as
   the user pasting text themselves, gated by the same Automation permission `focus` already needs (no
   System Events keystroke injection, no Accessibility permission). Verified live: opened a disposable
   Ghostty window via AppleScript, ran `input text ... to terminal`, confirmed the text landed without
   executing, closed the window. `GhosttyController.pasteText`, exposed via a row's right-click menu and
   the expiry banner's "Handoff" button. Separately investigated and declined: OS-level env-var TTL
   detection. `ps eww <pid>` *can* read another process's `ENABLE_PROMPT_CACHING_1H` on macOS without
   root, but only by reading that process's *entire* environment — verified directly against a real
   `claude` process, which printed several live API tokens into this conversation. The transcript-based
   per-turn detection in #2 already answers the same question without that exposure.
8. **Settings is a separate window, not a sheet.** Requested directly, matching Docker Desktop's menu bar
   pattern: `SettingsLink` + a SwiftUI `Settings` scene in `App.swift`, replacing the original `.sheet`
   that was cramped into the 340–380pt-wide dropdown.
9. **`SettingsStore` isn't in the §7 file layout.** Added under `Services/` because `@AppStorage` doesn't
   propagate change notifications out of an `ObservableObject`; a small published store was needed
   instead of scattering `UserDefaults` reads across views.
10. **Not verified live: Ghostty AppleScript `focusTab`.** Ghostty *is* installed and running on the
    machine this was built on and `hasOpenTab`/`refreshAvailability` were exercised for real (confirmed
    via the debug scan log — no dependency warnings, meaning the automation probe succeeded), but clicking
    a row to actually focus a tab was not clicked through interactively during this build. Treat
    `focusTab` itself as the least-tested path until you've clicked a focus arrow against a real Ghostty
    window.
11. **Tool/plugin/skill usage in the hover tooltip.** Requested directly, not in spec.md. Claude Code logs
    every tool call as a `tool_use` block in the transcript's assistant messages; `TranscriptWatcher`
    tallies them into `Session.toolUsage`, splitting MCP/plugin tool names (`mcp__<server>__<tool>`) into
    their server name and Skill invocations (`{"name": "Skill", "input": {"skill": "..."}}`) into the
    actual skill name, rather than just counting the generic "Skill" tool. Shown in the row tooltip.
12. **Live-process correlation per session — and a wrong first attempt that got corrected.** Requested
    directly, after two sessions in the same directory looked like on-screen duplicates. First attempt:
    collapse same-directory sessions down to the most-recently-active one, on the assumption a second one
    was probably a stale leftover. That assumption was checked against real `ps`/`lsof` output before
    shipping it and turned out to be **wrong** — the machine genuinely had two live `claude` processes in
    that exact directory at once (two terminal tabs in the same repo). Collapsing would have hidden a real
    running session, so it was reverted. Replaced with `ProcessMatcher`: matches `pgrep -x claude` PIDs to
    their cwd via `lsof -p <pid> -d cwd` — deliberately never reads environment variables (see #7's `ps
    eww` finding) — and exposes `Session.livePIDs` per working directory. Every session is still shown;
    the tooltip now says whether a `claude` process was actually found running in that directory. Honest
    limit, stated in the tooltip: Claude Code doesn't log its own PID to the transcript (grepped real
    transcripts for a "pid" field — nothing), so a PID can be attributed to a *directory*, not to one
    specific session UUID when several share it.
13. **Hover flyout panel instead of a plain tooltip, modeled on Docker Desktop's nested container menu.**
    Requested directly, with a screenshot of Docker Desktop's menu bar dropdown as the reference: hovering
    an item should reveal more detail *and its actions* in a panel beside it, categorized (plugins/MCP,
    Skills, built-in tools), not a single-string OS tooltip. Docker's version is a true native NSMenu
    flyout submenu; matching that exactly would have meant converting the whole dropdown from
    `MenuBarExtra`'s custom `.window` style to `.menu` style, losing the existing custom row styling
    (colored status dots, custom fonts/layout) in favor of plain system menu rows. Given the choice
    directly, the alternative was chosen instead: keep the dropdown's current visual design, and add
    `DetailPanelPresenter`, a small borderless `NSWindow` (same pattern as `BannerPresenter`) that appears
    beside the dropdown's right edge on a 300ms hover-intent delay (so passing over several rows doesn't
    flash a panel per row) and hides on a 200ms grace delay (so moving toward the panel itself doesn't
    dismiss it first). `SessionDetailPanelView` renders the same session facts as the old tooltip plus the
    Focus Tab / Paste /handoff / Paste /compact buttons that used to be right-click-only.
    `MenuBarExtra(.window)` exposes no per-row screen coordinates, so positioning uses `WindowAccessor` (an
    `NSViewRepresentable` probe) to get the dropdown's own window frame, then centers the panel vertically
    on the current mouse position rather than the row's exact bounds — the mouse is necessarily over that
    row's vertical span when hover fires, so this holds up without needing per-row frame tracking. The old
    right-click context menu (Focus Tab / Paste /handoff / Paste /compact) is left in place as a redundant
    fast path.

    **Follow-up fix, reported directly against a real run:** the panel closed before the mouse could
    reach its buttons. Root cause: the row and panel are separate windows with a gap between them, and the
    hide-timer was scheduled purely off the *row's* hover-exit — it fired and won the moment the pointer
    left the row heading toward the panel, since nothing else could cancel it. Fixed by having the panel
    report its own hover state back too (`SessionDetailPanelView.onHoverChanged`) and tracking
    `pointerOverRow`/`pointerOverPanel` independently in `SessionListViewModel`; the hide timer now only
    actually hides if *neither* is true when it fires, so crossing the gap toward the panel keeps it open.
14. **Footer written out as text menu rows, not icons.** Requested directly: the gear icon for Settings
    read as decoration rather than a menu item. `FooterView` now shows "Settings…" and "Quit" as full-width
    left-aligned text rows with a hover highlight, matching how a standard macOS menu bar dropdown lists
    its items — the ellipsis follows the platform convention for a menu item that opens a window rather
    than acting immediately.
15. **Blue hover highlight and flush-adjacent flyout, without converting to native NSMenu.** Requested
    directly, again against a Docker Desktop screenshot: rows/menu items should highlight system-accent
    blue with white text on hover, and the detail flyout should sit directly next to the item, the way a
    real native submenu does. Asked directly whether that requires a different component: getting *exactly*
    that chrome (system vibrant menu material, true adjacency, automatic keyboard nav) means a real
    `NSMenu` — SwiftUI's custom `.window`-style dropdown can't produce that material/behavior because it
    isn't a menu under the hood. Given the choice between rebuilding on `NSStatusItem`/`NSMenu` (custom
    NSMenuItem views to keep the colored status dots, but responsible for drawing their own hover
    highlight since AppKit doesn't do that for custom-view items) versus enhancing the existing SwiftUI
    component, the latter was chosen to avoid that rewrite's risk. `MenuRowLabel` is now the shared label
    style for every plain row (footer, panel actions): `Color.accentColor` background with white text on
    hover, matching the system's own selection color exactly since it *is* the system accent color, not a
    hand-picked blue. `SessionRowView` got the same treatment directly (all its secondary/tertiary text
    forced to white while highlighted — native menus don't preserve text hierarchy through a selection,
    everything just goes solid white). `DetailPanelPresenter` now overlaps the dropdown's right edge by a
    couple points instead of leaving a 6pt gap, and the panel's action rows were rebuilt to span its full
    width edge-to-edge (previously inset like the info text above them) so their highlight bar reads as a
    menu selection rather than a button.
16. **Notification/banner lead time defaults to a minute, not 30s.** Requested directly, after asking how
    TTL detection works: the warning should surface further ahead of a session going cold.
    `SettingsStore.notifyLeadTimeSeconds`'s default changed from 30 to 60 (the Settings slider already
    supported this — its range is 10...120 — only the default moved). This governs both the system
    notification and the top-of-screen banner in `checkNotifications()`; the row's own "expiring soon"
    dot color is separate (`expiringSoonThresholdSeconds`, default 90s) and already exceeded a minute.
17. **"Ping" action: a nop keep-alive, distinct from /handoff and /compact.** Requested directly, with the
    exact wording to paste: "Are you still there? Answer yes/no." Unlike `/handoff` (asks for a real
    summary) or `/compact` (does real compaction work), Ping's only purpose is to push a session's TTL
    back out with the smallest possible turn — a trivial question the LLM can answer without doing
    anything, for when you just want to keep a session warm and don't actually want it to do more work
    right now. `SessionListViewModel.pingPrompt`/`.ping(_:)` pastes (never runs — same Ghostty "as if
    pasted" semantics as the other paste actions) that exact text and focuses the tab. Exposed everywhere
    /handoff and /compact already were: the row's right-click menu, the hover detail panel's action rows,
    and — since "about to go cold" is exactly when a quick nop matters most — a third button on the
    top-of-screen banner (which grew from 320pt to 360pt wide to fit it).
18. **Model and reasoning-effort shown in the detail panel.** Requested directly. Verified against a real
    transcript first rather than assumed: each `assistant` event carries `message.model` (e.g.
    `"claude-sonnet-5"`) and, separately, a top-level `effort` field (e.g. `"high"`) — both ground truth
    from the event itself, not inferred. `Session.model`/`.effort` hold the *most recent* turn's values
    (overwritten as the transcript is parsed, same pattern as `detectedTTL`), shown as two new rows at the
    top of the panel's Session section.
19. **`rtk gain` integration, plus a "Hooks" usage category.** Asked directly whether the transcript
    exposes "loaded plugins/MCPs" the way it exposes *used* ones (`Session.toolUsage`), which surfaced two
    findings verified against real data, not assumed:
    - Hooks (like `rtk`, a Bash-rewriting CLI) are a distinct mechanism from MCP/Skills: they run
      transparently around a tool call rather than being something the model chose to invoke, so they
      never appear as a `tool_use` block — only as their own `attachment` event (`{"type": "attachment",
      "attachment": {"type": "hook_success", "command": "rtk hook claude", ...}}`, confirmed by grepping a
      real transcript). `ToolUsage.hooks` tallies these by the hook binary's name (the first word of
      `command`), shown as its own "Hooks" category right next to Plugins/MCP in the detail panel, per
      direct request.
    - Separately, real per-project stats: `rtk gain -p -f json` (confirmed by running it directly in this
      repo — `{"summary": {"total_commands", "total_saved", "avg_savings_pct", ...}}`). Its `-p`/`--project`
      flag is a *boolean* that scopes to the process's current working directory, not a path argument
      (also confirmed directly: zero counts run from `/tmp`, real counts from this repo) — so
      `RTKService` shells out once per unique session directory with `Process.currentDirectoryURL` set,
      rather than one call for everything. Shown as an "RTK savings" row in the panel's Session section.
      If `rtk` isn't found at all, `RTKService.isAvailable` goes false and a footer warning proposes
      installing "a token-savings CLI (e.g. rtk)" — deliberately generic rather than a hardcoded install
      command, since `rtk` is a personal tool with no public install path this app could assume for anyone
      else running it.
20. **Adaptive warning lead time, scaled by how much there was to read and how long the user's been away.**
    Requested directly: "the more to read the more time a user likely needs." Two new signals, both
    verified against real data rather than assumed feasible:
    - **How much there was to read**: `Session.lastVisibleCharCount`, the character count of the most
      recent assistant reply that had an actual `text` content block — deliberately *not*
      `usage.output_tokens`, which also counts invisible `thinking` tokens the user never saw. Only
      overwritten on a turn that said something, so a later turn that's pure `tool_use` (mid tool-round-
      trip) doesn't erase what the user last actually had to read.
    - **How long since the user was looking at this tab**: genuinely new tracking, not something Ghostty's
      AppleScript exposes as history — it only exposes *current* state (`front window`'s `selected tab`'s
      `focused terminal`). `GhosttyController` now samples that once per `refreshAvailability()` call (but
      only bothers asking Ghostty at all when `NSWorkspace` says Ghostty is frontmost — a plain, free
      check) and records the timestamp per working directory, so `timeSinceLastActive(workingDirectory:)`
      is a best-effort "last observed," resolution-limited to the refresh interval — not exact, and it can
      only ever get more stale between polls, never predict focus changes it didn't sample.
    - `SessionListViewModel.adaptiveLeadTime(for:)` combines both with the base `notifyLeadTimeSeconds`
      setting: up to 240s of extra runway for reading (at a conservative ~15 chars/sec), plus up to 120s
      more the longer it's been since the tab was last observed active. Both caps exist so a huge response
      or a long-idle tab can't blow the warning threshold out to something absurd — this is a heuristic,
      not measured reading behavior. Both raw signals ("Last output" chars, "Last active" time-ago) are
      shown in the detail panel rather than the derived lead-time number itself, so the formula doesn't
      need to be kept in sync in two places.
21. **Claude Code CLI version shown in the detail panel.** Requested directly. Confirmed by inspecting a
    real transcript that every event line — not just `assistant` turns — carries a top-level `"version"`
    field (e.g. `"2.1.227"`). `TranscriptWatcher` keeps overwriting `Session.version` while parsing, same
    pattern as `model`/`.effort`, so it ends up holding the version that wrote the transcript's last line
    (i.e. whichever CLI is currently running that session) — shown as a "CLI version" row alongside Model
    and Effort.
22. **`SettingsLink` swapped for `openSettings()` + explicit `NSApp.activate`.** Reported directly: the
    footer's Settings row did nothing when clicked. Root cause: on an accessory-policy app (no Dock icon,
    never activates the normal way), a plain `SettingsLink` can request the Settings window without the
    app ever becoming key/frontmost — the window opens but stays behind everything, indistinguishable from
    "nothing happened." `FooterView`'s Settings row now calls `NSApp.activate(ignoringOtherApps: true)`
    immediately before `openSettings()` (the `SettingsLink`-equivalent environment action) to force it
    forward.
23. **Sessions with no live process are dropped from the list, not just marked cold.** Requested directly.
    `SessionListViewModel.rescan()` now filters `withCost` down to `isProcessRunning` sessions (from
    `ProcessMatcher.livePIDs`) once PIDs are resolved — a transcript can be within the 24h recency window
    while its process already exited, and that's no longer shown at all rather than lingering as a cold
    entry. Guarded on `ProcessMatcher` having found *some* live `claude` process across the whole scan: if
    `pgrep`/`lsof` failed outright, every session would read as "not running" and this filter would empty
    the entire list — worse than showing stale entries — so the filter is skipped in that case.
24. **"Prompt cache TTL" removed from Settings; window widened and locked to content size.** Both reported
    directly, from a screenshot of the Settings window:
    - The TTL picker was removed entirely. It never controlled anything real — the actual TTL is fixed by
      how Claude Code itself was launched (`ENABLE_PROMPT_CACHING_1H`), and `Session.detectedTTL` already
      reads the true value straight off each session's own transcript (see item 18's neighbor, the
      pre-existing TTL-detection work). Presenting a "setting" that looked editable but didn't actually
      change anything was misleading. `SettingsStore.ttl` still exists as the fallback used only before a
      session's first cache-writing turn, now a fixed 300s (5 min, the actual API default) rather than a
      user-editable 60 min.
    - The window's labels ("Expiring-soon threshold", "Enable Ghostty focus action") were clipped, not
      wrapped, in the screenshot — meaning the window had been resized narrower than `Form`'s natural
      content width, which `Form` clips rather than reflows. Fixed two ways together: `SettingsView`'s
      content width went from 360pt (clipping) to 340pt then, per direct follow-up that text was still
      cut off, to 440pt; and `.windowResizability(.contentSize)` on the `Settings` scene (`App.swift`)
      stops the window from being resized below that width at all, so the same clipping can't recur.
25. **Codex sessions are now observed, but not mutated.** Requested directly after asking whether Codex
    instances should also be tracked. `CodexSessionWatcher` scans recent `.jsonl` rollouts under
    `~/.codex` and parses only structural/session fields (`session_meta`, `turn_context`,
    `event_msg/token_count`, and function-call names). It deliberately never opens credential files and
    never writes Codex metadata. Real local rollouts expose `input_tokens`, `cached_input_tokens`,
    `output_tokens`, and `reasoning_output_tokens`, so Codex rows show cached-input ratio and raw token
    totals. They do **not** show a TTL countdown, because the Codex transcript gives observed cache usage
    but no exact cache-expiry timestamp. Codex row actions are similarly read/open-only: "Open in Codex"
    uses the documented `codex://threads/<thread-id>` deep link. App-server can technically mutate stored
    thread metadata such as `isPinned`, but Tokenomics does not auto-pin, rename, archive, or otherwise
    mark Codex sessions from the outside.
26. **`xcodebuild` build step not executed.** Full Xcode isn't installed in the build environment (only
    Command Line Tools). `swift build -c release` was run successfully and is the verified build path;
    the `xcodebuild` command in the README is the documented equivalent per Apple's SPM-as-Xcode-project
    support but wasn't run there.

## Source layout

Matches `spec.md` §7 with one addition (`Services/SettingsStore.swift`, see deviation #9):

```
Sources/ClaudeSessionMonitor/
  App.swift
  Models/Session.swift
  Models/CacheStatus.swift
  Services/TranscriptWatcher.swift
  Services/CodexSessionWatcher.swift
  Services/UsageService.swift
  Services/NotificationService.swift
  Services/GhosttyController.swift
  Services/SettingsStore.swift
  Services/BannerPresenter.swift
  Services/ProcessMatcher.swift
  Services/RTKService.swift
  Services/DetailPanelPresenter.swift
  ViewModels/SessionListViewModel.swift
  Views/MenuContentView.swift
  Views/SessionRowView.swift
  Views/SessionDetailPanelView.swift
  Views/MenuRowLabel.swift
  Views/SettingsView.swift
  Views/FooterView.swift
  Views/WindowAccessor.swift
Resources/Info.plist
Scripts/build_app.sh
```
