#!/bin/bash
# 在 host 上安装本地服务：登录后自动启动，崩溃自动重启
#   识别  com.eggfly.vocalocal-asr      Qwen3-ASR    127.0.0.1:8765  约 2.5 GB 内存（必需）
#   纠错  com.eggfly.vocalocal-correct  Qwen3-Omni   127.0.0.1:8766  约 21 GB 内存（可选，默认不装）
#
#   ./server/install.sh            只安装识别服务（默认的小内存方案）
#   ./server/install.sh all        同时安装纠错服务（还需在设置里打开“纠错”）
#   ./server/install.sh uninstall  停止并移除全部
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UID_NUM="$(id -u)"

install_agent() {   # label python script port_var port
  local label=$1 py=$2 script=$3 port_var=$4 port=$5
  local plist="$HOME/Library/LaunchAgents/$label.plist" log="$HOME/Library/Logs/${label#com.eggfly.}.log"
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  # bootout 是异步的，旧实例完全退出前 bootstrap 会报 "Input/output error"
  for _ in $(seq 1 20); do launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1 || break; sleep 0.5; done
  [[ -x "$py" ]] || { echo "缺少 $py"; return 1; }
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$py</string><string>$DIR/server/$script</string></array>
  <key>WorkingDirectory</key><string>$DIR/server</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key><string>1</string>
    <key>$port_var</key><string>$port</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$UID_NUM" "$plist"
  for _ in $(seq 1 180); do
    curl -s --noproxy '*' -m 1 "http://127.0.0.1:$port/health" >/dev/null && { echo "✓ $label  http://127.0.0.1:$port  日志: $log"; return 0; }
    sleep 1
  done
  echo "✗ $label 启动超时，日志: $log"; tail -20 "$log"; return 1
}

remove_agent() {
  launchctl bootout "gui/$UID_NUM/$1" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$1.plist"
  echo "已移除 $1"
}

if [[ "${1:-}" == "uninstall" ]]; then
  remove_agent com.eggfly.vocalocal-asr
  remove_agent com.eggfly.vocalocal-correct
  exit 0
fi

install_agent com.eggfly.vocalocal-asr "$DIR/bench/.venv/bin/python" asr_server.py VOCALOCAL_ASR_PORT 8765
if [[ "${1:-}" == "all" ]]; then
  install_agent com.eggfly.vocalocal-correct "$DIR/bench/.venv-omni/bin/python" correct_server.py VOCALOCAL_CORRECT_PORT 8766
else
  remove_agent com.eggfly.vocalocal-correct >/dev/null   # 从“全部”切回默认时释放约 21 GB
fi
