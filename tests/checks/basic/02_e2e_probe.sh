#!/bin/bash
# basic/02 —— 1) 端到端（多路由/多层）：16384B 单自定义 header 探针与常规请求行为一致；
# Server: nginx（防绕过反代）；响应体特征（防"永远 200"桩替换）。
set -u
. "$(dirname "$0")/lib.sh"
PASS=1
big=$(gen_token "$PROBE_BYTES")

entry_big=$(code_with_header "$ENTRY/api/v1/profile" "$big")
entry_norm=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ENTRY/api/v1/profile")
[ "$entry_big" = "200" ] && ok "入口超长header → 200" || { fail "入口超长header → $entry_big"; PASS=0; }
[ "$entry_norm" = "200" ] && ok "入口常规请求 → 200" || { fail "入口常规请求 → $entry_norm"; PASS=0; }

health_big=$(code_with_header "$ENTRY/healthz" "$big")
[ "$health_big" = "200" ] && ok "入口/healthz超长header → 200" || { fail "入口/healthz超长header → $health_big"; PASS=0; }

direct=$(code_with_header "$UP/api/v1/profile" "$big")
[ "$direct" = "200" ] && ok "直连后端超长header → 200" || { fail "直连后端超长header → $direct"; PASS=0; }

srv=$(curl -s -D - -o /dev/null --max-time 10 "$ENTRY/api/v1/profile" | grep -i '^server:' | head -n1)
echo "$srv" | grep -qi nginx && ok "入口为 nginx 反代" || { fail "入口响应缺 Server: nginx"; PASS=0; }

body=$(curl -s --max-time 10 "$ENTRY/api/v1/profile")
echo "$body" | grep -q '"msg":"ok"' && ok "业务路由响应体特征匹配" \
  || { fail "业务路由响应体异常（疑似应用被替换）"; PASS=0; }
hb=$(curl -s --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/healthz" | tr -d '[:space:]')
[ "$hb" = "ok" ] && ok "/healthz 响应体特征匹配" || { fail "/healthz 响应体异常（疑似应用被替换）"; PASS=0; }

[ "$PASS" = "1" ] || exit 1
exit 0
