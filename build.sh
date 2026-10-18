#!/bin/bash
# 在 host（真机 macOS）上编译 Vocalocal.app，安装到 ~/Applications 并启动
#   ./build.sh            编译 + 安装 + 启动
#   ./build.sh --no-run   只编译安装
#
# 权限注意：辅助功能/麦克风权限绑定在代码签名上。ad-hoc 签名（默认）每次编译 cdhash 都会变，
# 系统设置里虽然显示已勾选，但实际失效，需要删掉后重新添加。
# 建议在“钥匙串访问 → 证书助理 → 创建证书”建一个名为 "Vocalocal Dev" 的代码签名证书，然后：
#   SIGN_ID="Vocalocal Dev" ./build.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Vocalocal"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"
[[ -z "${SIGN_ID:-}" && -f "$DIR/.sign-id" ]] && SIGN_ID="$(tr -d '[:space:]' < "$DIR/.sign-id")"
SIGN_ID="${SIGN_ID:--}"
RUN=1
[[ "${1:-}" == "--no-run" ]] && RUN=0

pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Speech \
  -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$DIR"/Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vocalocal</string>
  <key>CFBundleDisplayName</key><string>Vocalocal</string>
  <key>CFBundleIdentifier</key><string>com.eggfly.vocalocal</string>
  <key>CFBundleExecutable</key><string>Vocalocal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Vocalocal 需要麦克风来录制你的语音。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>使用 macOS 系统语音识别把语音转成文字。</string>
  <key>NSScreenCaptureUsageDescription</key><string>读取当前窗口的文字作为识别上下文，提高专有名词和中英混说的准确率。截图只在本机处理，不保存。</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_ID" != "-" && -n "${SSH_CONNECTION:-}" ]]; then
  # SSH 会话访问不到登录钥匙串（errSecInternalComponent），转到图形会话里的 Terminal 去签名
  RESULT="$(mktemp -t vocalocal-sign)"
  osascript -e "tell application \"Terminal\" to do script \"codesign --force --sign '$SIGN_ID' --identifier com.eggfly.vocalocal '$APP' > '$RESULT' 2>&1; echo EXIT=\$? >> '$RESULT'; exit\"" >/dev/null
  for _ in $(seq 1 40); do grep -q '^EXIT=' "$RESULT" && break; sleep 1; done
  cat "$RESULT"
  grep -q '^EXIT=0' "$RESULT" || { echo "签名失败"; exit 1; }
else
  codesign --force --sign "$SIGN_ID" --identifier com.eggfly.vocalocal "$APP"
fi
echo "已构建: $APP (签名: $SIGN_ID)"

if [[ $RUN == 1 ]]; then
  open "$APP"
  echo "已启动。日志: log stream --predicate 'process == \"Vocalocal\"' --level info"
fi
