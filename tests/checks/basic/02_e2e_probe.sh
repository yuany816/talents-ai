#!/bin/bash
# basic/02 —— 1) 端到端（多路由/多层，证据断言）：16384B 单自定义 header 探针与常规请求
# 行为一致；Server: nginx（防绕过反代）；响应体特征（防"永远 200"桩替换）；直连后端同口径。
# schema：curl_entry.txt（entry_big_status/entry_norm_status/healthz_big_status/
# server_header/profile_body/healthz_body）、curl_backend.txt（backend_big_status/profile_body）。
set -u
. "$(dirname "$0")/../lib.sh"
EN=$(ev_path curl_entry.txt) || { fail "缺少证据文件 evidence/curl_entry.txt"; exit 1; }
BE=$(ev_path curl_backend.txt) || { fail "缺少证据文件 evidence/curl_backend.txt"; exit 1; }
PASS=1

v=$(ev_get entry_big_status "$EN")
[ "$v" = "200" ] && ok "入口超长header → 200" || { fail "入口超长header status=${v:-缺}（须 200）"; PASS=0; }
v=$(ev_get entry_norm_status "$EN")
[ "$v" = "200" ] && ok "入口常规请求 → 200" || { fail "入口常规请求 status=${v:-缺}（须 200）"; PASS=0; }
v=$(ev_get healthz_big_status "$EN")
[ "$v" = "200" ] && ok "入口/healthz超长header → 200" || { fail "入口/healthz超长header status=${v:-缺}（须 200）"; PASS=0; }

v=$(ev_get server_header "$EN")
printf '%s' "$v" | grep -qi nginx && ok "入口为 nginx 反代（Server: $v）" \
  || { fail "server_header 缺 nginx（got=${v:-无}）"; PASS=0; }

v=$(ev_get profile_body "$EN")
printf '%s' "$v" | grep -q '"msg":"ok"' && ok "业务路由响应体特征匹配" \
  || { fail "profile_body 异常（疑似应用被替换）"; PASS=0; }
v=$(ev_get healthz_body "$EN")
[ "$v" = "ok" ] && ok "/healthz 响应体特征匹配" || { fail "healthz_body=${v:-缺}（去空白后须恰为 ok）"; PASS=0; }

v=$(ev_get backend_big_status "$BE")
[ "$v" = "200" ] && ok "直连后端超长header → 200" || { fail "直连后端 status=${v:-缺}（须 200）"; PASS=0; }
v=$(ev_get profile_body "$BE")
printf '%s' "$v" | grep -q '"msg":"ok"' && ok "直连后端响应体特征匹配" \
  || { fail "直连后端 profile_body 异常"; PASS=0; }

[ "$PASS" = "1" ] || exit 1
exit 0
