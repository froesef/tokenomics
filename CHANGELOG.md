# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning follows
[Semantic Versioning](https://semver.org/) — see [CONTRIBUTING.md](CONTRIBUTING.md#versioning) for how
that applies pre-1.0.

## [Unreleased]

## [0.1.0] - 2026-08-14

Initial release.

- Menu bar countdown per Claude Code session (prompt-cache TTL), sorted warm-to-cold.
- Savings/waste meter for tokens lost to cold-cache expirations vs. tokens saved.
- Big-context nudge with one-click `/compact`.
- Cost and cache-hit ratio per session.
- Codex session rows (observe-only): cached-input ratio, token totals, model, effort.
- Idle/running/compacting/needs-input badge per session.
- Click-to-focus matching terminal tab (Ghostty or iTerm2).
- `/handoff`, `/compact`, and "Ping" quick actions via right-click or hover panel.
- Optional experimental auto keep-alive for active sessions.

[Unreleased]: https://github.com/froesef/tokenomics/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/froesef/tokenomics/releases/tag/v0.1.0
