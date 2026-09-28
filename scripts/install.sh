#!/bin/bash
# 后台构建和安装；不退出应用、不改 Dock、不打开窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh Release
APP="Claudex Shell"
SRC="DerivedData/Build/Products/Release/$APP.app"
DST="/Applications/$APP.app"
if ps -axo comm= | awk -v p="$DST/Contents/MacOS/" 'index($0,p)==1 {found=1} END {exit !found}'; then
  echo "$APP 正在运行。请在方便时退出后再次运行安装脚本；已构建：$SRC" >&2
  exit 1
fi
STAGE="$(mktemp -d /Applications/.claudex-shell-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$SRC" "$STAGE/$APP.app"
codesign --verify --deep --strict "$STAGE/$APP.app"
if [ -e "$DST" ]; then
  BACKUP="/Applications/$APP.previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$DST" "$BACKUP"
  if ! mv "$STAGE/$APP.app" "$DST"; then
    mv "$BACKUP" "$DST"
    exit 1
  fi
else
  mv "$STAGE/$APP.app" "$DST"
fi
echo "已安装：${DST}（未启动，未改动正在运行的旧版）"
