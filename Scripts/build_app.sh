#!/bin/bash
# Builds Tokenomics.app: `swift build -c release`, then wraps the resulting executable in a
# real .app bundle with Resources/Info.plist. See README "Running without Xcode" for why this exists —
# a bare SPM executable has no CFBundleIdentifier, which crashes UserNotifications at runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

BIN_NAME="ClaudeSessionMonitor"
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

echo "==> Done: ${APP_BUNDLE}"
echo "    open '${APP_BUNDLE}'"
