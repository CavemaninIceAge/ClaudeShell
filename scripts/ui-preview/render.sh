#!/bin/bash
# Compile and render ACTUAL production views in an unordered, non-activating app.
# Usage: scripts/ui-preview/render.sh [output-directory]
set -euo pipefail
cd "$(dirname "$0")/../.."
PROJECT_ROOT="$(pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/.impeccable/review/workspace}"
BUILD_DIR="$PROJECT_ROOT/DerivedData/ui-preview"
APP_DIR="$BUILD_DIR/ClaudexUIPreview.app"
mkdir -p "$OUTPUT_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/module-cache"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find App/Sources -name '*.swift' ! -name 'ClaudeShellApp.swift' -print | sort)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -target "$(uname -m)-apple-macos15.0" \
  "${SOURCES[@]}" scripts/ui-preview/Fixtures.swift scripts/ui-preview/WorkspaceSnapshot.swift \
  -o "$APP_DIR/Contents/MacOS/ClaudexUIPreview"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClaudexUIPreview</string>
<key>CFBundleIdentifier</key><string>com.claudex.offline-ui-preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Use exactly the production transcript resources; no copied mock layout or CSS.
cp -R App/Resources/web "$APP_DIR/Contents/Resources/"
PREVIEW_TEMP="$(mktemp -d "${TMPDIR:-/private/tmp}/claudex-ui-preview.XXXXXX")"
trap 'rm -rf "$PREVIEW_TEMP"' EXIT
mkdir -p "$PREVIEW_TEMP/Library/Caches" "$PREVIEW_TEMP/Library/Preferences"
# Cocoa/WebKit preferences and caches belong to a disposable per-run home; HOME remains unchanged.
CFFIXED_USER_HOME="$PREVIEW_TEMP" TMPDIR="$PREVIEW_TEMP/" \
  "$APP_DIR/Contents/MacOS/ClaudexUIPreview" "$OUTPUT_DIR"
