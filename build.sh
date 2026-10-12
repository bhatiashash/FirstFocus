#!/usr/bin/env bash
# Build, bundle and sign DailyOS with only Command Line Tools.
#
# Usage: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
ENV_FILE="$HOME/DailyOS-data/dailyos.env"

CERT_NAME="${CERT_NAME:-}"
if [[ -z "$CERT_NAME" && -f "$ENV_FILE" ]]; then
    CERT_NAME=$(grep -E '^CERT_NAME=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)
fi
CERT_NAME="${CERT_NAME:-DailyOS Local Dev}"

echo "Building DailyOS ($CONFIG)..."
swift build -c "$CONFIG"
BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)

APP_BUNDLE=".build/FirstFocus.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH/DailyOS" "$APP_BUNDLE/Contents/MacOS/DailyOS"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
# Sparkle offers an update only when its CFBundleVersion is higher, so the
# build number is the commit count, which only goes up. VERSION (release.sh
# sets it) replaces the user-facing version when given.
PLIST="$APP_BUNDLE/Contents/Info.plist"
# The public repo started with fresh history at build 283 (0.1.6), so its
# commit count is offset past that to keep the number rising.
BUILD_NUMBER_OFFSET=300
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + BUILD_NUMBER_OFFSET ))" "$PLIST"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# llama.swift's llama.framework: the executable's only LC_RPATH entry is
# @loader_path (its own directory), so the framework has to live right
# beside the binary in Contents/MacOS, not in a Contents/Frameworks it
# never looks in.
cp -R "$BIN_PATH/llama.framework" "$APP_BUNDLE/Contents/MacOS/llama.framework"
# Sparkle (ADR 0044) sits beside it for the same reason. ditto keeps the
# framework's Versions symlinks intact.
ditto "$BIN_PATH/Sparkle.framework" "$APP_BUNDLE/Contents/MacOS/Sparkle.framework"

echo "Signing with identity: $CERT_NAME"
codesign --force --sign "$CERT_NAME" "$APP_BUNDLE/Contents/MacOS/llama.framework"
# Sparkle's helpers are signed inside out, then the framework, as Sparkle's
# own docs lay out for signing outside Xcode.
SPARKLE="$APP_BUNDLE/Contents/MacOS/Sparkle.framework"
codesign --force --sign "$CERT_NAME" -o runtime "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$CERT_NAME" -o runtime --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$CERT_NAME" -o runtime "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign "$CERT_NAME" -o runtime "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign "$CERT_NAME" -o runtime "$SPARKLE"
codesign --force --sign "$CERT_NAME" "$APP_BUNDLE"

echo "Built and signed: $APP_BUNDLE"
codesign -dvvv "$APP_BUNDLE" 2>&1 | grep -E "Authority=|Identifier="
