# Tokenomics

A macOS menu bar app that shows every [Claude Code](https://code.claude.com) session's prompt-cache
countdown, cost, and cache-hit ratio in real time, and can focus the matching Ghostty tab.

Each project directory you run Claude Code in gets its own independent prompt cache with its own TTL.
Once that cache goes cold, the next turn reprocesses the full context uncached — expensive, and easy to
miss if a session sits idle in a background tab. Tokenomics watches every session at once and warns you
before that happens.

## Features

- **Live countdown per session** — the menu bar shows the soonest-to-expire session; the dropdown lists
  every session from the last 24h, sorted with warm/expiring sessions always above cold ones.
- **Cost and cache-hit ratio per session**, via [`ccusage`](https://github.com/ryoppippi/ccusage).
- **Hover for full detail**: working directory, TTL source, last-turn time, raw token counts, model and
  reasoning effort, CLI version, whether a live `claude` process was actually found, and which tools /
  MCP plugins / Skills / hooks that session used.
- **Idle / running / compacting badge per row** — inferred from transcript structure (no explicit "in
  progress" flag exists), so a session mid-turn or mid-`/compact` is visibly distinct from one that's just
  sitting idle. A `/clear` (or `/compact`) resets that row's cache and tool-usage stats in place, since the
  old numbers no longer reflect what's actually loaded.
- **Click a row to focus the matching Ghostty tab** — only offered when a real matching tab exists.
- **Right-click (or the hover panel) for `/handoff`, `/compact`, and a no-op "Ping"** — these paste into
  the terminal as if typed, never run automatically.
- **Warnings before a session goes cold**: a top-of-screen banner plus a system notification, with
  quick-action buttons, timed to scale with how much there is to read and how long you've been away.
- **Settings window** (TTL threshold, refresh interval, notification lead time, Ghostty toggle), separate
  from the dropdown.

## Build & run

This ships as a Swift Package (not a hand-written `.xcodeproj`) with an executable target.

### Option A — Makefile (command line, no Xcode required)

```bash
make run      # builds a release binary, wraps it in Tokenomics.app, and opens it
```

Other targets:

```bash
make build    # debug build only (swift build)
make release  # release build only (swift build -c release)
make app      # release build + assemble .build/Tokenomics.app
make stop     # kill a running instance
make clean    # remove .build
```

`Scripts/build_app.sh` (what `make app` runs) exists because a bare SPM executable has no
`CFBundleIdentifier` — without it, `UNUserNotificationCenter` crashes the process outright. The script
wraps the built binary with `Resources/Info.plist` into a real `.app` bundle.

Gatekeeper note: this build is unsigned. First launch of `.build/Tokenomics.app` via double-click may be
blocked; right-click → Open, or run `xattr -dr com.apple.quarantine .build/Tokenomics.app` first. No
Apple Developer account is required or used anywhere in this project.

### Option B — Xcode

Xcode can open a `Package.swift` directly as a project (has been able to since Xcode 11):

```bash
open Package.swift
```

Then build from the command line with:

```bash
xcodebuild -scheme ClaudeSessionMonitor -destination 'platform=macOS' build
```

If the scheme name differs, `xcodebuild -list` from this directory shows the generated scheme name to
use instead.

## Permissions

- **Automation (Ghostty control):** the first time the app tries to focus a tab, macOS prompts for
  Automation permission. If denied or not yet granted, the focus button/row-tap is simply disabled —
  grant it later via System Settings → Privacy & Security → Automation → Tokenomics → Ghostty.
- **Notifications:** requested once on launch (only inside a real `.app` bundle — see above). Denial
  degrades gracefully; no in-app countdown functionality depends on it.
- No other permissions are used. The app never writes to `~/.claude`.

## Debugging

The app writes one line per scan to stderr: `[ClaudeSessionMonitor] scan: N session(s), warnings: [...]`.
Nothing else surfaces this for a menu-bar-only app with no console, so if the dropdown looks wrong, run
it from Terminal to see it directly:

```bash
.build/Tokenomics.app/Contents/MacOS/Tokenomics
```

## Documentation

- [`spec.md`](spec.md) — the original design spec.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) — implementation notes, verification details, and deviations from
  the spec.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).
