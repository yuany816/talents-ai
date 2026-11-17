#!/bin/bash
# basic/06 —— 3) 声明一致性（证据断言）：header_limits.env 的
# NGINX_LARGE_HEADER_BUFFER_BYTES 折算后必须与 evidence/nginx_T.txt 生效单缓冲相等
# （边界与预警判定需与实际限额同一数值基准）。
set -u
. "$(dirname "$0")/../lib.sh"
[ -f "$LIMENV" ] || { fail "缺少预警参数文件 $LIMENV"; exit 1; }
NT=$(ev_path nginx_T.txt) || { fail "缺少证据文件 evidence/nginx_T.txt"; exit 1; }
LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
nginx_buf_from_file "$NT" || true
if [ -n "$LIM" ] && [ -n "$NG_BUF_B" ] && [ "$LIM" -eq "$NG_BUF_B" ] 2>/dev/null; then
  ok "声明 LIM 与 nginx 生效单缓冲一致（${LIM}B）"
  exit 0
fi
fail "声明 LIM(${LIM:-缺}) 与 nginx 生效单缓冲(${NG_BUF_B:-无}) 不一致"
exit 1
