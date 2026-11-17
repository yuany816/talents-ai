#!/bin/bash
# edge/04 —— 4) 质检门禁（分源注入②）：向 hdrsize.log 追加一行 431 记录、向 error.log
# 追加一行含 client sent too long header line 的 info 级记录，门禁必须 exit ≠ 0。
# 门禁在 hdrsize.log 缺失时应跳过该来源（不得因此误拦或崩溃）。
# 注入标记与书写顺序随机化（两日志的写入顺序每轮洗牌、路径/msec 随机）——
# 门禁须按"431 证据"语义逐源拦截，而非匹配固定样本或固定顺序。
# 注入后清理复原，保证验题可重复。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少质检门禁 $GATE"; exit 1; }
INJ_PATH="/injected-$RANDOM$RANDOM"
INJ_MSEC="$(date +%s).$((RANDOM % 900 + 100))"
INJ_LEN=$(( 30000 + RANDOM % 60000 ))
HDRV="$INJ_MSEC 431 $INJ_LEN \"GET $INJ_PATH HTTP/1.1\""
ERRV="$(date '+%Y/%m/%d %H:%M:%S') [info] $((RANDOM%999))#$((RANDOM%99)): *$((RANDOM%50+1)) client sent too long header line while reading client request headers, client: 127.0.$((RANDOM%256)).$((RANDOM%256)), server: _, request: \"GET $INJ_PATH HTTP/1.1\""

# 两源写入顺序洗牌：门禁对任一顺序都必须拦截
if [ $(( RANDOM % 2 )) = "0" ]; then
  [ -f /var/log/nginx/hdrsize.log ] && echo "$HDRV" >> /var/log/nginx/hdrsize.log
  echo "$ERRV" >> /var/log/nginx/error.log
else
  echo "$ERRV" >> /var/log/nginx/error.log
  [ -f /var/log/nginx/hdrsize.log ] && echo "$HDRV" >> /var/log/nginx/hdrsize.log
fi

if bash "$GATE" >/dev/null 2>&1; then
  fail "质检门禁：hdrsize/error 注入 431 后未拦截"
  [ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
  : > /var/log/nginx/error.log
  exit 1
fi
ok "质检门禁：hdrsize/error 来源拦截生效"
[ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
: > /var/log/nginx/error.log
nginx -s reopen 2>/dev/null || true
exit 0
