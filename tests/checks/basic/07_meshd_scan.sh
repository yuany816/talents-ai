#!/bin/bash
# basic/07 —— 2) 中间层扫描（meshd）：/app/mesh 下 max_header_bytes 键上下文
# 残留原故障值 12288 → 不通过（豁免备份后缀文件）。注意：磁盘配置改了但运行时
# 仍被 supervisor env 覆盖压制的情形由端到端探针（basic/02）与行为检查判定。
set -u
. "$(dirname "$0")/../lib.sh"
if grep -rqIE 'max_header_bytes["'"'"':= ]*12288([^0-9]|$)' /app/mesh \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
    --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null; then
  fail "meshd 侧 header 限额仍残留原故障值 12288（max_header_bytes 键上下文，源码/配置）"
  exit 1
fi
ok "meshd 侧 header 限额已真实调整（源码/配置扫描）"
exit 0
