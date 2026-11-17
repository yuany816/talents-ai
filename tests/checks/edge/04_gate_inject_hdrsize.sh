#!/bin/bash
# edge/04 —— 4) 质检门禁（分源注入②）：向 hdrsize.log 追加一行 431 记录、向 error.log
# 追加一行含 client sent too long header line 的 info 级记录，门禁必须 exit ≠ 0。
# 门禁在 hdrsize.log 缺失时应跳过该来源（不得因此误拦或崩溃）。注入后清理复原。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少质检门禁 $GATE"; exit 1; }
[ -f /var/log/nginx/hdrsize.log ] && echo "$(date +%s).000 431 99999 \"GET /injected HTTP/1.1\"" >> /var/log/nginx/hdrsize.log
echo "$(date '+%Y/%m/%d %H:%M:%S') [info] 999#999: *1 client sent too long header line while reading client request headers, client: 127.0.0.1, server: _, request: \"GET /injected HTTP/1.1\"" >> /var/log/nginx/error.log
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
