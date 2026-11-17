#!/bin/bash
# edge/04 —— 4) 质检门禁·分源注入②（判分环境本地伪造日志）：向 hdrsize.log 追加一行
# 431 记录、向 error.log 追加一行含 client sent too long header line 的 info 级记录，
# 交付的门禁脚本必须 exit ≠ 0。注入标记与书写顺序随机化（两日志写入顺序每轮洗牌、
# 路径/msec 随机）——门禁须按"431 证据"语义逐源拦截。注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少可执行的质检门禁 $GATE"; exit 1; }
clean_ng_logs
INJ_PATH="/injected-$RANDOM$RANDOM"
INJ_MSEC="$(date +%s).$((RANDOM % 900 + 100))"
INJ_LEN=$(( 30000 + RANDOM % 60000 ))
HDRV="$INJ_MSEC 431 $INJ_LEN \"GET $INJ_PATH HTTP/1.1\""
ERRV="$(date '+%Y/%m/%d %H:%M:%S') [info] $((RANDOM%999))#$((RANDOM%99)): *$((RANDOM%50+1)) client sent too long header line while reading client request headers, client: 127.0.$((RANDOM%256)).$((RANDOM%256)), server: _, request: \"GET $INJ_PATH HTTP/1.1\""

# 两源写入顺序洗牌：门禁对任一顺序都必须拦截
if [ $(( RANDOM % 2 )) = "0" ]; then
  echo "$HDRV" >> "$NGLOG_DIR/hdrsize.log"
  echo "$ERRV" >> "$NGLOG_DIR/error.log"
else
  echo "$ERRV" >> "$NGLOG_DIR/error.log"
  echo "$HDRV" >> "$NGLOG_DIR/hdrsize.log"
fi

if run_gate; then
  fail "质检门禁：hdrsize/error 注入 431 后未拦截"
  clean_ng_logs
  exit 1
fi
ok "质检门禁：hdrsize/error 来源拦截生效"
clean_ng_logs
exit 0
