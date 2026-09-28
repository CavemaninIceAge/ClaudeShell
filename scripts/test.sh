#!/bin/bash
# 编译真实应用模块并运行隔离 fixtures，不启动 GUI，也不读写本机登录态。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p DerivedData/tests/module-cache
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find App/Sources -name '*.swift' ! -name 'ClaudeShellApp.swift' -print | sort)
TESTS=()
while IFS= read -r path; do TESTS+=("$path"); done < <(find scripts/tests -name '*.swift' -print | sort)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -module-cache-path DerivedData/tests/module-cache \
  -target "$(uname -m)-apple-macos15.0" \
  "${SOURCES[@]}" "${TESTS[@]}" -o DerivedData/tests/ClaudexRegression
DerivedData/tests/ClaudexRegression
