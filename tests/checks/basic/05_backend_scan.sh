#!/bin/bash
# basic/05 —— 2) L2 后端扫描（防伪造辅助证据）：对 /app/backend 下所有文本文件
# （豁免备份后缀）做原故障值 8192 字面匹配——十进制形态不限上下文；
# 等值移码/十六进制书写形态仅锚定 MaxHeaderBytes/max_header_bytes 键上下文。命中即不通过。
set -u
. "$(dirname "$0")/lib.sh"
if grep -rqIE '(^|[^0-9])8192([^0-9]|$)|(MaxHeaderBytes|max_header_bytes)["'\'':= ]*(1[[:space:]]*<<[[:space:]]*13([^0-9]|$)|0[xX]2000([^0-9a-fA-F]|$))' /app/backend \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
    --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null; then
  fail "后端侧 header 限额仍残留原故障值 8192（十进制或等值移码/十六进制形态，源码/配置）"
  exit 1
fi
ok "后端侧 header 限额已真实调整（源码/配置扫描）"
exit 0
