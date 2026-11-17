#!/bin/bash
# edge/02 —— 4) 质检门禁（干净日志通过）：截断 /var/log/nginx/{access,error,hdrsize}.log
# （不存在则跳过）并 nginx -s reopen，重放一轮正常流量后，门禁必须 exit 0。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少质检门禁 $GATE"; exit 1; }
for lg in /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/hdrsize.log; do
  [ -f "$lg" ] && : > "$lg"
done
nginx -s reopen 2>/dev/null || true
big=$(gen_token "$PROBE_BYTES")
curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/api/v1/profile"
sleep 1
if bash "$GATE" >/dev/null 2>&1; then
  ok "质检门禁：干净日志通过（exit 0）"
  exit 0
fi
fail "质检门禁：干净日志被误拦截"
exit 1
