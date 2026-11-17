#!/bin/bash
# basic/06 —— 2) 中间层扫描（tracegate）：/app/tracegate 下 max_header_bytes 键上下文
# 残留原故障值 10240 → 不通过（豁免备份后缀文件；行为探针为主要判定，扫描为辅助证据）。
set -u
. "$(dirname "$0")/lib.sh"
if grep -rqIE 'max_header_bytes["'"'"':= ]*10240([^0-9]|$)' /app/tracegate \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
    --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null; then
  fail "tracegate 侧 header 限额仍残留原故障值 10240（max_header_bytes 键上下文，源码/配置）"
  exit 1
fi
ok "tracegate 侧 header 限额已真实调整（源码/配置扫描）"
exit 0
