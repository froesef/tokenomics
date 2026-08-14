#!/bin/bash
# Builds Tokenomics.app: `swift build -c release`, then wraps the resulting executable in a
# real .app bundle with Resources/Info.plist. See README "Running without Xcode" for why this exists —
# a bare SPM executable has no CFBundleIdentifier, which crashes UserNotifications at runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

BIN_NAME="Tokenomics"
APP_NAME="Tokenomics"
APP_BUNDLE=".build/${APP_NAME}.app"
BIN_PATH=".build/release/${BIN_NAME}"

# A previous run keeps living as a background menu-bar process (LSUIElement, no Dock icon) at the same
# bundle path; deleting/recreating that path out from under it is what causes `open` to fail afterwards
# with `_LSOpenURLsWithCompletionHandler() failed with error -1712`.
pkill -x "${APP_NAME}" 2>/dev/null || true
pkill -x "${BIN_NAME}" 2>/dev/null || true

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

# Stamp CFBundleVersion with the short git commit hash so the built .app is traceable to the exact
# source it came from — shows up as "Version 0.1.0 (a1b2c3d)" in the standard About panel. Falls back to
# "unknown" outside a git checkout (e.g. a source tarball) rather than failing the build.
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GIT_HASH}" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Done: ${APP_BUNDLE}"
echo "    open '${APP_BUNDLE}'"
