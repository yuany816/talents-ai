#!/bin/bash
# edge/05 —— 5) 预警观测·静默检查：读取 header_limits.env（WARN_RATIO 缺失按 80，
# 声明值超出 [50,90] → 不通过）；清理 hdrsize.log 后发送常规请求（远低于阈值），
# 10s 内 warnings.log 行数不得增加（不得误报）。
set -u
. "$(dirname "$0")/lib.sh"
ensure_ops_dir
[ -f "$LIMENV" ] || { fail "缺少预警参数文件 $LIMENV"; exit 1; }
LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
if [ "$RATIO" -lt 50 ] 2>/dev/null || [ "$RATIO" -gt 90 ] 2>/dev/null; then
  fail "header_limits.env 的 WARN_RATIO=$RATIO 超出有效范围 [50,90]"
  RATIO=80
fi
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null; then
  fail "header_limits.env 缺少 NGINX_LARGE_HEADER_BUFFER_BYTES（或值 ≤ 4096）"
  exit 1
fi
# 清理日志增量后进入静默窗口（观测需容忍截断）
[ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
nginx -s reopen 2>/dev/null || true
sleep 2
before=$(wc -l < "$WARNLOG" 2>/dev/null || echo 0)
curl -s -o /dev/null --max-time 10 "$ENTRY/api/v1/profile"
sleep 10
mid=$(wc -l < "$WARNLOG" 2>/dev/null || echo 0)
if [ "$mid" -eq "$before" ]; then
  ok "预警观测：常规请求无误报"
  exit 0
fi
fail "预警观测：常规请求触发误报"
exit 1
