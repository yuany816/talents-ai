#!/bin/bash
# basic/04 —— 2) L1：nginx -T 生效配置中 large_client_header_buffers 的单缓冲 ≥ 17408B
# （完整 header 行口径 = 16384B 值 + 行开销约 18B + 1KiB 余量；k/M 后缀折算，仅认活动指令）。
set -u
. "$(dirname "$0")/lib.sh"
nginx_buf_bytes || { fail "nginx 生效配置中未找到 large_client_header_buffers"; exit 1; }
if [ -n "$NG_BUF_B" ] && [ "$NG_BUF_B" -ge 17408 ] 2>/dev/null; then
  ok "nginx large_client_header_buffers=$NG_BUF（生效配置，完整行口径 ≥17408B）"
  exit 0
fi
fail "nginx header 缓冲未调大（当前=${NG_BUF:-无}，需按完整 header 行口径 ≥17408B）"
exit 1
