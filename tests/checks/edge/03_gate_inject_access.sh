#!/bin/bash
# edge/03 —— 4) 质检门禁（分源注入①）：仅向 access.log 追加一条 combined 格式的 431
# 记录，门禁必须 exit ≠ 0（431 高优先级拦截）。注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少质检门禁 $GATE"; exit 1; }
# 注入标记随机化：路径/字节数/时间戳每轮不同——门禁须按"431 状态"语义拦截，而非匹配固定样本
INJ_PATH="/injected-$RANDOM$RANDOM"
INJ_BYTES=$(( 123 + RANDOM % 8000 ))
echo "127.0.$((RANDOM%256)).$((RANDOM%256)) - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET $INJ_PATH HTTP/1.1\" 431 $INJ_BYTES \"-\" \"verifier-$RANDOM\"" >> /var/log/nginx/access.log
if bash "$GATE" >/dev/null 2>&1; then
  fail "质检门禁：access.log 注入 431 后未拦截"
  : > /var/log/nginx/access.log
  exit 1
fi
ok "质检门禁：access.log 来源拦截生效"
: > /var/log/nginx/access.log
exit 0
