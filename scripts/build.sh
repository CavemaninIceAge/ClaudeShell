#!/bin/bash
# 生成工程并编译。用法：./scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
case "$CONFIG" in Debug|Release) ;; *) echo "用法：$0 [Debug|Release]" >&2; exit 2 ;; esac
# project.yml 改过、或 App/ 下有比工程文件新的源文件（新加的文件不进工程就编不到），都重新生成。
if [ ! -d ClaudexShell.xcodeproj ] || [ project.yml -nt ClaudexShell.xcodeproj/project.pbxproj ] \
   || [ -n "$(find App -type f -newer ClaudexShell.xcodeproj/project.pbxproj -print -quit)" ]; then
  xcodegen generate >/dev/null
fi
mkdir -p DerivedData
set +e
xcodebuild -project ClaudexShell.xcodeproj -scheme ClaudexShell -configuration "$CONFIG" \
  -derivedDataPath DerivedData build CODE_SIGN_IDENTITY=- > DerivedData/build-$CONFIG.log 2>&1
status=$?
set -e
awk '/(error|warning): |BUILD (SUCCEEDED|FAILED)/ && !/appintentsmetadataprocessor/' "DerivedData/build-$CONFIG.log" | sort -u | head -80
[ $status -eq 0 ] || exit $status
echo "App: $(pwd)/DerivedData/Build/Products/$CONFIG/Claudex Shell.app"
