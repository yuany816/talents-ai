#!/bin/bash
# basic/06 —— 3) 声明一致性（证据断言）：header_limits.env 的
# NGINX_LARGE_HEADER_BUFFER_BYTES 折算后必须与 nginx_T.txt 的生效单缓冲**相等**。
# nginx_T.txt 中存在多条未注释指令时，各条单缓冲须**全部与 LIM 相等**——同一限额键
# 多处取值不一致属配置漂移（无法确定入口实际生效值），按不通过处理。
set -u
. "$(dirname "$0")/../lib.sh"
[ -f "$LIMENV" ] || { fail "缺少预警参数文件 $LIMENV"; exit 1; }
NT=$(ev_path nginx_T.txt) || { fail "缺少证据文件 evidence/nginx_T.txt"; exit 1; }
LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
nginx_buf_from_file "$NT" || { fail "nginx_T.txt 中未找到未注释的 large_client_header_buffers"; exit 1; }
if [ -z "$LIM" ]; then
  fail "声明 LIM 缺失（NGINX_LARGE_HEADER_BUFFER_BYTES 未填）"
  exit 1
fi
if [ "$NG_BUF_MIN_B" = "$NG_BUF_MAX_B" ] && [ "$LIM" -eq "$NG_BUF_MIN_B" ] 2>/dev/null; then
  ok "声明 LIM 与 nginx 生效单缓冲一致（${LIM}B，${NG_BUF_COUNT} 条活动指令取值一致）"
  exit 0
fi
fail "声明 LIM(${LIM:-缺}) 与 nginx 生效单缓冲不一致（${NG_BUF_COUNT} 条指令，取值范围 ${NG_BUF_MIN_B}~${NG_BUF_MAX_B}B——须全部相等且等于 LIM）"
exit 1
