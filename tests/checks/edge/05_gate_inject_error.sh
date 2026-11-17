#!/bin/bash
# edge/05 —— 4) 质检门禁·分源注入③ error（判分环境本地伪造日志，**单源独立**）：
# 仅向 error.log 追加一行含 client sent too long header line 的 info 级记录
# （hdrsize.log 完全不存在——同时复验缺文件容忍），交付的门禁必须 exit ≠ 0；
# 随后仅追加一条不含超长头证据的普通 info 记录，门禁必须 exit 0——按 431 证据语义
# 判定，无关 error 日志不得误拦。注入标记每轮随机；注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少可执行的质检门禁 $GATE"; exit 1; }
clean_ng_logs
INJ_PATH="/injected-$RANDOM$RANDOM"
echo "$(date '+%Y/%m/%d %H:%M:%S') [info] $((RANDOM%999))#$((RANDOM%99)): *$((RANDOM%50+1)) client sent too long header line while reading client request headers, client: 127.0.$((RANDOM%256)).$((RANDOM%256)), server: _, request: \"GET $INJ_PATH HTTP/1.1\"" >> "$NGLOG_DIR/error.log"

PASS=1
if run_gate; then
  fail "质检门禁：error.log 单源注入 431 证据后未拦截（hdrsize.log 缺失时也须按 error 来源拦截）"
  PASS=0
else
  ok "质检门禁：error.log 单源 too-long-header 拦截生效"
fi
# 非 431 对照：普通 info 记录（不含超长头证据）不得触发拦截
: > "$NGLOG_DIR/error.log"
echo "$(date '+%Y/%m/%d %H:%M:%S') [info] $((RANDOM%999))#$((RANDOM%99)): *$((RANDOM%50+1)) upstream response is buffered to a temporary file while reading upstream, client: 127.0.0.1, server: _, request: \"GET $INJ_PATH HTTP/1.1\"" >> "$NGLOG_DIR/error.log"
if run_gate; then
  ok "质检门禁：error.log 无关 info 记录未误拦"
else
  fail "质检门禁：error.log 无关 info 记录被误拦——门禁须按 431 证据语义判定"
  PASS=0
fi
clean_ng_logs
[ "$PASS" = "1" ] || exit 1
exit 0
