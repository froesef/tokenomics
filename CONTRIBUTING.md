# Contributing

Thanks for taking a look at Tokenomics. This is a small macOS menu bar app built with Swift Package
Manager — no Xcode project file, no external dependencies.

## Setup

```bash
swift build          # debug build
swift test            # run tests
make app && make run  # build a real .app bundle and launch it
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for implementation notes and known deviations from
[spec.md](spec.md), and the README's "Running without Xcode" section for why the app must be run as a
`.app` bundle (`make app`) rather than a bare `swift run` executable for anything beyond quick UI checks.

## Before opening a PR

- `swift build` and `swift test` pass.
- `swiftlint lint --quiet` and `swift format lint --recursive Sources Tests Package.swift` are clean —
  same checks CI runs (`.github/workflows/ci.yml`).
- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) if the change is user-visible.

## Versioning

Tokenomics follows [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`, tagged as
`vMAJOR.MINOR.PATCH` (e.g. `v0.1.0`), which triggers `.github/workflows/release.yml`.

- Pre-1.0 (`0.x.y`): no compatibility guarantees between minor versions — settings, UI, and behavior can
  change. Patch bumps are bug fixes only.
- Post-1.0: MAJOR for breaking behavior changes, MINOR for new features, PATCH for bug fixes.

The tag's version (without the `v`) belongs in `Resources/Info.plist`'s `CFBundleShortVersionString`
before tagging a release — bump it in the same PR/commit that's about to be tagged. `CFBundleVersion` is
*not* hand-edited: `Scripts/build_app.sh` stamps it with the short git commit hash at build time, so
every build is traceable to the exact source it came from. Both show up in the app's standard
"About Tokenomics" panel as "Version 0.1.0 (a1b2c3d)".

To cut a release once `CFBundleShortVersionString` is bumped and merged to `main`:

```bash
git tag v0.1.0
git push origin v0.1.0
```
