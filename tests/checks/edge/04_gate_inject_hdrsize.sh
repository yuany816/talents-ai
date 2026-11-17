#!/bin/bash
# edge/04 —— 4) 质检门禁·分源注入② hdrsize（判分环境本地伪造日志，**单源独立**）：
# 仅向 hdrsize.log 追加一行 <msec> 431 <len> "GET <随机路径> HTTP/1.1"（error.log 完全
# 不存在——同时复验缺文件容忍），交付的门禁必须 exit ≠ 0；随后仅追加一条 200 记录
# （非 431）门禁必须 exit 0——按"431 证据"语义逐源判定，非 431 内容不得误拦。
# 注入标记每轮随机；注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少可执行的质检门禁 $GATE"; exit 1; }
clean_ng_logs
INJ_PATH="/injected-$RANDOM$RANDOM"
INJ_MSEC="$(date +%s).$((RANDOM % 900 + 100))"
INJ_LEN=$(( 30000 + RANDOM % 60000 ))
echo "$INJ_MSEC 431 $INJ_LEN \"GET $INJ_PATH HTTP/1.1\"" >> "$NGLOG_DIR/hdrsize.log"

PASS=1
if run_gate; then
  fail "质检门禁：hdrsize.log 单源注入 431 后未拦截（error.log 缺失时也须按 hdrsize 来源拦截）"
  PASS=0
else
  ok "质检门禁：hdrsize.log 单源 431 拦截生效"
fi
# 非 431 对照：200 记录不得触发拦截（门禁须按 431 语义而非任意注入行匹配）
: > "$NGLOG_DIR/hdrsize.log"
echo "$INJ_MSEC 200 $INJ_LEN \"GET $INJ_PATH HTTP/1.1\"" >> "$NGLOG_DIR/hdrsize.log"
if run_gate; then
  ok "质检门禁：hdrsize.log 的 200 记录未误拦"
else
  fail "质检门禁：hdrsize.log 非 431（200）记录被误拦——门禁须按 431 语义判定"
  PASS=0
fi
clean_ng_logs
[ "$PASS" = "1" ] || exit 1
exit 0
