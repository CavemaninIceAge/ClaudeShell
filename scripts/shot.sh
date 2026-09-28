#!/bin/bash
# 离屏检查对话渲染；不会启动应用、切换系统外观、截图桌面或抢占输入。
# 用法：./scripts/shot.sh [输出路径] [--dark|--light]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="DerivedData/claudex-transcript.png"
MODE="light"
for arg in "$@"; do
  case "$arg" in
    --dark) MODE="dark" ;;
    --light) MODE="light" ;;
    --restart) echo "不再支持自动重启。此脚本仅离屏渲染正文。" >&2; exit 2 ;;
    *) OUT="$arg" ;;
  esac
done
mkdir -p "$(dirname "$OUT")"
swift scripts/web-preview/snapshot.swift "$(pwd)/scripts/web-preview/preview.html" "$OUT" "$MODE"
