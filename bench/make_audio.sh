#!/bin/bash
# 用 macOS 自带的 Tingting 语音，按 truth.tsv 生成 tts*/trap* 测试音频（16 kHz 单声道 WAV）。
# real* 是真人录音，不在仓库里；放到 audio/ 下即可参与评测。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p audio
grep -E '^(tts|trap)' truth.tsv | while IFS=$'\t' read -r id text; do
  say -v Tingting -o "/tmp/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "/tmp/$id.aiff" "audio/$id.wav"
  rm -f "/tmp/$id.aiff"
  echo "audio/$id.wav"
done
