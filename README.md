# Tokenomics

A macOS menu bar app that shows local coding-agent sessions: [Claude Code](https://code.claude.com)
prompt-cache countdowns, costs, and cache-hit ratios, plus Codex cached-input token usage from local
session rollouts.

Each project directory you run Claude Code in gets its own independent prompt cache with its own TTL.
Once that cache goes cold, the next turn reprocesses the full context uncached — expensive, and easy to
miss if a session sits idle in a background tab. Tokenomics watches every session at once and warns you
before that happens.

Codex tracking is observe-only: Tokenomics reads local `~/.codex` JSONL session rollouts and shows model,
last activity, token totals, and cached-input ratio. Codex rows do **not** show a prompt-cache expiry
countdown, because Codex's local transcript exposes cached-token usage but not an exact cache-expiry
timestamp.

## Features

- **Live countdown per session** — the menu bar shows the soonest-to-expire session; the dropdown lists
  every session from the last 24h, sorted with warm/expiring sessions always above cold ones.
- **Savings / waste meter** — a strip at the top of the dropdown quantifies today: **tokens lost to
  cold-cache expirations** (when a session sat idle past its TTL and the next turn had to re-write the
  whole prompt prefix at cache-write price instead of a cheap cache read) and **tokens saved** (warm-cache
  reads billed at ~0.1× vs. full input price, plus `rtk` output-filtering). Token counts are exact from the
  transcript; dollar figures are a labeled estimate (`~$X est.`, from a small per-model rate table — the
  per-session cost column still delegates to `ccusage`, which exposes no per-token rates). The menu bar can
  be switched (Settings → Menu Bar) to show `🔻 128k lost` instead of the countdown.
- **Big-context nudge** — when a large tool result (a full file read, a big Bash dump) is sitting
  un-compacted in a session's context, inflating every subsequent turn, the row flags it and the hover
  panel offers a one-click `/compact`.
- **Cost per session**, via [`ccusage`](https://github.com/ryoppippi/ccusage). **Cache-hit ratio per
  session**, computed directly from the transcript's own token counts — no `ccusage` involved.
- **Codex session rows** — cached-input ratio, raw input/output/reasoning token totals, model, effort,
  CLI version, and a safe "Open in Codex" action via the documented `codex://threads/<id>` deep link.
- **Hover for full detail**: working directory, TTL source, last-turn time, raw token counts, model and
  reasoning effort, CLI version, whether a live `claude` process was actually found, and which tools /
  MCP plugins / Skills / hooks that session used.
- **Idle / running / compacting / needs-input badge per row** — inferred from transcript structure (no
  explicit "in progress" flag exists), so a session mid-turn or mid-`/compact` is visibly distinct from one
  that's just sitting idle. A session whose latest tool call is an `AskUserQuestion` or an `ExitPlanMode`
  approval reads as "needs input" instead of "running" — it's blocked on you, not doing any work. A
  `/clear` (or `/compact`) resets that row's cache and tool-usage stats in place, since the old numbers no
  longer reflect what's actually loaded.
- **Menu bar never goes blank while something's happening** — the bar normally shows the soonest cache
  countdown, but a tool call regularly outlasts a session's TTL (5 minutes by default); once every session
  is cold there's no countdown left to show, so the bar falls back to whichever session is running,
  compacting, or waiting on you, rather than showing a bare, easy-to-miss timer icon.
- **Click a row to focus the matching Ghostty tab** — only offered when a real matching tab exists.
- **Right-click (or the hover panel) for `/handoff`, `/compact`, and a no-op "Ping"** — these paste into
  Claude Code's terminal as if typed, never run automatically.
- **Warnings before a session goes cold**: a top-of-screen banner plus a system notification, with
  quick-action buttons, timed to scale with how much there is to read and how long you've been away.
- **Settings window** (menu-bar mode, refresh interval, expiring-soon threshold, notification lead time,
  Ghostty toggle, keep-alive caps), separate from the dropdown.

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
xcodebuild -scheme Tokenomics -destination 'platform=macOS' build
```

If the scheme name differs, `xcodebuild -list` from this directory shows the generated scheme name to
use instead.

## Permissions

- **Automation (Ghostty control):** the first time the app tries to focus a tab, macOS prompts for
  Automation permission. If denied or not yet granted, the focus button/row-tap is simply disabled —
  grant it later via System Settings → Privacy & Security → Automation → Tokenomics → Ghostty.
- **Notifications:** requested once on launch (only inside a real `.app` bundle — see above). Denial
  degrades gracefully; no in-app countdown functionality depends on it.
- No other permissions are used. The app never writes to `~/.claude` or `~/.codex`.

## Debugging

The app writes one line per scan to stderr: `[Tokenomics] scan: N session(s), warnings: [...]`.
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
