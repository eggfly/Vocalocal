#!/bin/bash
# 按总内存列出占用最多的进程，并单独列出其中的 GPU 内存。
#
# Apple Silicon 是统一内存：GPU 和 CPU 用同一块内存，区别只在于谁申请的——
# 通过 Metal 申请的（模型权重、显存缓冲区）在 footprint 里记为 "IOAccelerator"，
# 活动监视器没有“GPU 内存”这一列，“内存”列对这部分也统计不全。
#
#   ./tools/gpumem.sh          当前用户的进程（约 5 秒）
#   ./tools/gpumem.sh 30       显示前 30 个
#   sudo ./tools/gpumem.sh     所有进程（包括 WindowServer 等系统进程）
set -uo pipefail
top=${1:-15}

if [[ $EUID -eq 0 ]]; then pids=$(ps -A -o pid=); else pids=$(ps -U "$USER" -o pid=); fi
args=()
for pid in $pids; do args+=(-p "$pid"); done

echo "正在统计 $(( ${#args[@]} / 2 )) 个进程，约需 5 秒…" >&2

# 一次 footprint 调用分析所有进程（逐个调用要 15 秒以上）。
# 输出结构：每个进程一段 "名称 [PID]: ... Footprint: X"，后面跟若干 "Shared with ..." 段（共享内存，不计入该进程）。
footprint -f bytes "${args[@]}" 2>/dev/null | awk '
  /\[[0-9]+\]: .*Footprint:/ {
    match($0, /\[[0-9]+\]/); pid = substr($0, RSTART + 1, RLENGTH - 2)
    name[pid] = $1
    for (i = 1; i <= NF; i++) if ($i == "Footprint:") total[pid] = $(i + 1)
    cur = pid; own = 1; next
  }
  /^Shared with/ { own = 0; next }
  own && /IOAccelerator/ { gpu[cur] += $1 }
  END { for (p in total) printf "%d %d %s %s\n", total[p], gpu[p], p, name[p] }
' | sort -rn | head -"$top" | {
  printf "%9s  %9s  %6s  %s\n" "总内存" "GPU内存" "PID" "进程"
  while read -r t g pid name; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null | sed -E 's#^.*/##' | cut -c1-55)
    awk -v t="$t" -v g="$g" -v p="$pid" -v n="${cmd:-$name}" \
      'BEGIN { printf "%7.2f GB  %7.2f GB  %6s  %s\n", t / 1073741824, g / 1073741824, p, n }'
  done
}

# 整个 GPU 已分配的内存（所有进程合计，包括没有权限分析的系统进程）
ioreg -r -c AGXAccelerator -d 1 2>/dev/null |
  grep -oE '"Alloc system memory"=[0-9]+' | head -1 |
  awk -F= '{ printf "\nGPU 合计已分配: %.1f GB\n", $2 / 1073741824 }'
