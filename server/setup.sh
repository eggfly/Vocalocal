#!/bin/bash
# 创建本地服务需要的 Python 虚拟环境并下载模型（需要 uv：brew install uv）
#   bench/.venv       mlx-audio  → Qwen3-ASR 识别（约 2.5 GB）
#   bench/.venv-omni  mlx-vlm    → Qwen3-Omni 纠错（约 17 GB，可选）
#
#   ./server/setup.sh            只装识别（默认的小内存方案）
#   ./server/setup.sh all        同时装纠错模型
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR/bench"
command -v uv >/dev/null || { echo "需要 uv：brew install uv"; exit 1; }

# 模型下载走 Hugging Face；若系统配置了 SOCKS 代理，需要 socksio
uv venv -q --python 3.12 .venv
VIRTUAL_ENV=.venv uv pip install -q -U mlx-audio socksio
HF_HUB_DISABLE_XET=1 .venv/bin/python -c 'from huggingface_hub import snapshot_download as d; d("mlx-community/Qwen3-ASR-1.7B-8bit")'
echo "✓ 识别模型就绪"

if [[ "${1:-}" == "all" ]]; then
  uv venv -q --python 3.12 .venv-omni
  VIRTUAL_ENV=.venv-omni uv pip install -q -U mlx-vlm socksio
  HF_HUB_DISABLE_XET=1 .venv-omni/bin/python -c 'from huggingface_hub import snapshot_download as d; d("mlx-community/Qwen3-Omni-30B-A3B-Instruct-4bit")'
  echo "✓ 纠错模型就绪"
fi
echo "下一步：./server/install.sh"
