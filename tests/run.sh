#!/bin/bash
# 编译并运行规则测试（需要 macOS，用到 CoreFoundation 的拼音转换）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)/rules-tests"
swiftc -swift-version 5 -o "$OUT" \
  "$DIR/Sources/TextCleanup.swift" "$DIR/Sources/PhoneticGuard.swift" "$DIR/tests/main.swift"
"$OUT"
