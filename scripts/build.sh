#!/bin/bash
# 生成工程并编译。用法：./scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
if [ ! -d ClaudeShell.xcodeproj ] || [ project.yml -nt ClaudeShell.xcodeproj/project.pbxproj ]; then
  xcodegen generate >/dev/null
fi
mkdir -p DerivedData
set +e
xcodebuild -project ClaudeShell.xcodeproj -scheme ClaudeShell -configuration "$CONFIG" \
  -derivedDataPath DerivedData build CODE_SIGN_IDENTITY=- > DerivedData/build-$CONFIG.log 2>&1
status=$?
set -e
grep -E "(error|warning): |BUILD (SUCCEEDED|FAILED)" "DerivedData/build-$CONFIG.log" | grep -v "appintentsmetadataprocessor" | sort -u | head -80
[ $status -eq 0 ] || exit $status
echo "App: $(pwd)/DerivedData/Build/Products/$CONFIG/Claude Shell.app"
