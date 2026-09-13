#!/bin/bash
# 截取正在运行的 Claude Shell 主窗口（改完界面必须看一眼，不凭想象）。
#
#   ./scripts/shot.sh [输出路径] [--dark|--light] [--restart]
#
# --restart：先杀掉正在跑的实例再从 DerivedData 起新构建（open 对已运行实例只会切前台）。
# 需要给运行它的终端「屏幕录制」权限。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="/tmp/claudeshell.png"
MODE=""
RESTART=0
for arg in "$@"; do
  case "$arg" in
    --dark|--light) MODE="$arg" ;;
    --restart) RESTART=1 ;;
    *) OUT="$arg" ;;
  esac
done

APP="Claude Shell"
BUNDLE="$(pwd)/DerivedData/Build/Products/Debug/$APP.app"

case "$MODE" in
  --dark)  osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true' ;;
  --light) osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to false' ;;
esac

if [ "$RESTART" = 1 ] && pgrep -xq "$APP"; then
  pkill -x "$APP" || true
  for _ in $(seq 1 20); do pgrep -xq "$APP" || break; perl -e 'select undef,undef,undef,0.2'; done
fi

if ! pgrep -xq "$APP"; then
  [ -d "$BUNDLE" ] || { echo "未构建：$BUNDLE" >&2; exit 1; }
  open -n "$BUNDLE"
fi

WID=""
for _ in $(seq 1 60); do
  WID="$(python3 - "$APP" <<'PY'
import sys
from Quartz import (CGWindowListCopyWindowInfo, kCGWindowListOptionAll, kCGNullWindowID)
app = sys.argv[1]
best = None
# 不限于当前 Space：用户常切到别的桌面，screencapture -l 对别的 Space 上的窗口也能截。
for w in CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID) or []:
    if w.get("kCGWindowOwnerName") != app or w.get("kCGWindowLayer", 0) != 0:
        continue
    b = w.get("kCGWindowBounds", {})
    area = b.get("Width", 0) * b.get("Height", 0)
    if area < 100_000:
        continue
    if best is None or area > best[1]:
        best = (w.get("kCGWindowNumber"), area)
print(best[0] if best else "")
PY
)"
  [ -n "$WID" ] && break
  perl -e 'select undef,undef,undef,0.25'
done
[ -n "$WID" ] || { echo "找不到 $APP 的主窗口" >&2; exit 1; }
# 网页层要一点时间渲染
perl -e 'select undef,undef,undef,0.8'
screencapture -x -o -l"$WID" "$OUT"
echo "$OUT"
