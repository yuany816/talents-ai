#!/bin/bash
# edge/03 —— 4) 质检门禁·分源注入①（判分环境本地伪造日志，**单源独立**）：仅向
# access.log 追加一条 combined 格式的随机 431 记录，交付的门禁必须 exit ≠ 0（431
# 高优先级拦截）；随后仅追加一条 200 记录（非 431）门禁必须 exit 0——按"431 状态"
# 语义拦截，非 431 内容不得误拦。注入标记随机化：路径/字节数/时间戳每轮不同——
# 门禁须按"431 状态"语义拦截，而非匹配固定样本。注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少可执行的质检门禁 $GATE"; exit 1; }
clean_ng_logs
INJ_PATH="/injected-$RANDOM$RANDOM"
INJ_BYTES=$(( 123 + RANDOM % 8000 ))
echo "127.0.$((RANDOM%256)).$((RANDOM%256)) - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET $INJ_PATH HTTP/1.1\" 431 $INJ_BYTES \"-\" \"verifier-$RANDOM\"" >> "$NGLOG_DIR/access.log"

PASS=1
if run_gate; then
  fail "质检门禁：access.log 单源注入 431 后未拦截"
  PASS=0
else
  ok "质检门禁：access.log 单源 431 拦截生效"
fi
# 非 431 对照：200 记录不得触发拦截（门禁须按 431 状态语义而非任意记录匹配）
: > "$NGLOG_DIR/access.log"
echo "127.0.$((RANDOM%256)).$((RANDOM%256)) - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET $INJ_PATH HTTP/1.1\" 200 $INJ_BYTES \"-\" \"verifier-$RANDOM\"" >> "$NGLOG_DIR/access.log"
if run_gate; then
  ok "质检门禁：access.log 的 200 记录未误拦"
else
  fail "质检门禁：access.log 非 431（200）记录被误拦——门禁须按 431 状态语义判定"
  PASS=0
fi
clean_ng_logs
[ "$PASS" = "1" ] || exit 1
exit 0
