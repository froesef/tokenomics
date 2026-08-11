#!/bin/bash
# Builds ClaudeSessionMonitor.app: `swift build -c release`, then wraps the resulting executable in a
# real .app bundle with Resources/Info.plist. See README "Running without Xcode" for why this exists —
# a bare SPM executable has no CFBundleIdentifier, which crashes UserNotifications at runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP_NAME="ClaudeSessionMonitor"
APP_BUNDLE=".build/${APP_NAME}.app"
BIN_PATH=".build/release/${APP_NAME}"

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Done: ${APP_BUNDLE}"
echo "    open '${APP_BUNDLE}'"
