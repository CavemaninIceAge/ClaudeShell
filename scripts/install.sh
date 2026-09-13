#!/bin/bash
# Release 构建 → 拷到 /Applications → 加进 Dock。用法：./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh Release
APP="Claude Shell"
SRC="DerivedData/Build/Products/Release/$APP.app"
DST="/Applications/$APP.app"
# 只结束 /Applications 里那份正在跑的实例，DerivedData 里的调试实例不动（可能正有人在用）。
ps -axo pid=,comm= | awk -v p="$DST/" 'index($0, p) { print $1 }' | while read -r pid; do kill "$pid" 2>/dev/null || true; done
sleep 1
rm -rf "$DST"
cp -R "$SRC" "$DST"
echo "已安装：$DST"
# Dock 存进去后路径里的空格会变成 %20，两种写法都要认，否则每次安装都多加一个图标。
if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Claude%20Shell.app\|$APP.app"; then
  defaults write com.apple.dock persistent-apps -array-add \
    "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$DST</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
  killall Dock
  echo "已加进 Dock"
else
  echo "Dock 里已经有了"
fi
open "$DST"
