#!/bin/bash
# basic/04 —— 2) L1（证据断言）：evidence/nginx_T.txt（nginx -T 完整输出）中
# large_client_header_buffers 的单缓冲 ≥ 17408B（完整 header 行口径 = 16384B 值 +
# 行开销约 18B + 1KiB 余量；k/M 后缀折算，仅认未注释的活动指令）。
set -u
. "$(dirname "$0")/../lib.sh"
NT=$(ev_path nginx_T.txt) || { fail "缺少证据文件 evidence/nginx_T.txt"; exit 1; }
nginx_buf_from_file "$NT" || { fail "nginx_T.txt 中未找到未注释的 large_client_header_buffers"; exit 1; }
if [ -n "$NG_BUF_B" ] && [ "$NG_BUF_B" -ge 17408 ] 2>/dev/null; then
  ok "nginx large_client_header_buffers=$NG_BUF（生效配置，完整行口径 ≥17408B）"
  exit 0
fi
fail "nginx header 缓冲未调大（当前=${NG_BUF:-无}，需按完整 header 行口径 ≥17408B）"
exit 1
