#!/bin/bash
# basic/04 —— 2) L1（证据断言）：evidence/nginx_T.txt（nginx -T 完整输出）中**全部**
# 未注释的 large_client_header_buffers 活动指令，其单缓冲均须 ≥ 17408B（完整 header 行
# 口径 = 16384B 值 + 行开销约 18B + 1KiB 余量；k/M 后缀折算）。
# 只验首条不足以判定：残留的过小指令（http/server/location 任一层）会按 nginx 继承
# 语义在对应作用域真实生效，探针仍会被拒——逐条取最小值判定。
set -u
. "$(dirname "$0")/../lib.sh"
NT=$(ev_path nginx_T.txt) || { fail "缺少证据文件 evidence/nginx_T.txt"; exit 1; }
nginx_buf_from_file "$NT" || { fail "nginx_T.txt 中未找到未注释的 large_client_header_buffers"; exit 1; }
if [ "$NG_BUF_MIN_B" -ge 17408 ] 2>/dev/null; then
  ok "nginx large_client_header_buffers 共 ${NG_BUF_COUNT} 条活动指令，最小单缓冲=$NG_BUF_MIN_RAW（${NG_BUF_MIN_B}B ≥17408B）"
  exit 0
fi
fail "nginx header 缓冲未调大或有残留过小指令（共 ${NG_BUF_COUNT} 条，最小=$NG_BUF_MIN_RAW=${NG_BUF_MIN_B}B <17408B——任一活动指令过小都会在其作用域真实生效）"
exit 1
