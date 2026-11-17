#!/bin/bash
# edge/03 —— 4) 质检门禁（分源注入①）：仅向 access.log 追加一条 combined 格式的 431
# 记录，门禁必须 exit ≠ 0（431 高优先级拦截）。注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/lib.sh"
[ -x "$GATE" ] || { fail "缺少质检门禁 $GATE"; exit 1; }
echo "127.0.0.1 - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET /injected HTTP/1.1\" 431 0 \"-\" \"verifier\"" >> /var/log/nginx/access.log
if bash "$GATE" >/dev/null 2>&1; then
  fail "质检门禁：access.log 注入 431 后未拦截"
  : > /var/log/nginx/access.log
  exit 1
fi
ok "质检门禁：access.log 来源拦截生效"
: > /var/log/nginx/access.log
exit 0
