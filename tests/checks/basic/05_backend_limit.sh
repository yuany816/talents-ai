#!/bin/bash
# basic/05 —— 2) L2 后端限额（证据断言）：源码/配置扫描在独立判分环境不可执行
# （判分环境无 /app/backend），改为"声明 + 行为"双证据——
#   - 声明：header_limits.env 的 APP_MAX_HEADER_BYTES（后端侧生效限额，字节）须 > 8192
#     （原故障值的一半以下视为未扩容；solve.sh 与题面契约均要求该键）；
#   - 行为：curl_backend.txt 的 backend_big_status=200 证明 16384B 探针真实通过后端
#     （配合 basic/02 的响应体特征，桩替换/纯声明不通过）。
set -u
. "$(dirname "$0")/../lib.sh"
PASS=1
[ -f "$LIMENV" ] || { fail "缺少 $LIMENV"; exit 1; }
APP_LIM=$(sed -n 's/^APP_MAX_HEADER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
if [ -n "$APP_LIM" ] && [ "$APP_LIM" -gt 8192 ] 2>/dev/null; then
  ok "后端侧限额声明 APP_MAX_HEADER_BYTES=${APP_LIM}B（> 原故障值 8192）"
else
  fail "header_limits.env 缺 APP_MAX_HEADER_BYTES（或 ≤8192，got=${APP_LIM:-缺}）"
  PASS=0
fi
BE=$(ev_path curl_backend.txt) || { fail "缺少证据文件 evidence/curl_backend.txt"; exit 1; }
v=$(ev_get backend_big_status "$BE")
[ "$v" = "200" ] && ok "后端行为证据：backend_big_status=200" \
  || { fail "backend_big_status=${v:-缺}（须 200——声明与行为须同真）"; PASS=0; }
[ "$PASS" = "1" ] || exit 1
exit 0
