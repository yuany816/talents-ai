#!/bin/bash
# 431 任务验题脚本（平台 tests/test.sh）
# 判定：端到端 + 双层真实修改（防伪造）+ 边界/输入覆盖 + 防线（门禁/预警）+ 综合归因报告
# 行为正确性以探针（不同输入/边界）判定；源码/配置扫描仅作"修改真实发生"的辅助证据。
REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier /var/log/nginx
PASS=1
ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; PASS=0; }

ENTRY="http://127.0.0.1:80"
UP="http://127.0.0.1:9000"
PROBE_BYTES=16384
big=$(head -c $PROBE_BYTES /dev/zero | tr '\0' 'x')

# ---------- 0) 环境在线 ----------
curl -s -o /dev/null --max-time 5 "$ENTRY/" || fail "入口不可达"
curl -s -o /dev/null --max-time 5 "$UP/" || fail "后端不可达"

# ---------- 1) 端到端：超长 header 与常规请求行为一致（多路由/多层） ----------
entry_big=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/api/v1/profile")
entry_norm=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ENTRY/api/v1/profile")
[ "$entry_big" = "200" ] && ok "入口超长header → 200" || fail "入口超长header → $entry_big"
[ "$entry_norm" = "200" ] && ok "入口常规请求 → 200" || fail "入口常规请求 → $entry_norm"
health_big=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/healthz")
[ "$health_big" = "200" ] && ok "入口/healthz超长header → 200" || fail "入口/healthz超长header → $health_big"
direct=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Verify-Token: $big" "$UP/api/v1/profile")
[ "$direct" = "200" ] && ok "直连后端超长header → 200" || fail "直连后端超长header → $direct"
srv=$(curl -s -D - -o /dev/null --max-time 10 "$ENTRY/api/v1/profile" | grep -i '^server:' | head -n1)
echo "$srv" | grep -qi nginx && ok "入口为 nginx 反代" || fail "入口响应缺 Server: nginx"
# 响应体特征（防"桩替换"式作弊：必须是真实应用在服务，而非只回 200 的替身）
body=$(curl -s --max-time 10 "$ENTRY/api/v1/profile")
echo "$body" | grep -q '"msg":"ok"' && ok "业务路由响应体特征匹配" || fail "业务路由响应体异常（疑似应用被替换）"
hb=$(curl -s --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/healthz" | tr -d '[:space:]')
[ "$hb" = "ok" ] && ok "/healthz 响应体特征匹配" || fail "/healthz 响应体异常（疑似应用被替换）"

# ---------- 2) 双层真实修改（防伪造辅助证据；行为判定见 1/3 节） ----------
NG_BUF=$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | awk '{gsub(/;/,""); print $3}')
NG_BUF_B=$(printf '%s' "$NG_BUF" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
if [ -n "$NG_BUF_B" ] && [ "$NG_BUF_B" -ge 16384 ] 2>/dev/null; then
  ok "nginx large_client_header_buffers=${NG_BUF}（生效配置，≥16384B）"
else
  fail "nginx header 缓冲未调大（当前=${NG_BUF:-无}）"
fi
if grep -rqE 'MaxHeaderBytes:[[:space:]]*8192([^0-9]|$)' /app/backend --include='*.go' 2>/dev/null; then
  fail "后端源码仍残留原故障值 MaxHeaderBytes:8192"
else
  ok "后端源码框架限额已调整"
fi

# ---------- 3) 边界与输入覆盖（以解题者声明的限额为基准） ----------
LIMENV="/app/ops/header_limits.env"
LIM=""
if [ -f "$LIMENV" ]; then
  LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
  # 3.1 声明一致性：LIM 必须与 nginx 生效单缓冲一致（k/M 折算后相等）
  if [ -n "$LIM" ] && [ -n "$NG_BUF_B" ] && [ "$LIM" -eq "$NG_BUF_B" ] 2>/dev/null; then
    ok "声明 LIM 与 nginx 生效单缓冲一致（${LIM}B）"
  else
    fail "声明 LIM(${LIM:-缺}) 与 nginx 生效单缓冲(${NG_BUF_B:-无}) 不一致"
  fi
  # 3.2 上边界：超过声明上限的请求必须仍被拒绝（限额语义仍在，而非一放了之）
  if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] && [ "$LIM" -le 1048576 ]; then
    over=$(( LIM + 4096 ))
    obig=$(head -c $over /dev/zero | tr '\0' 'x')
    over_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Verify-Token: $obig" "$ENTRY/api/v1/profile")
    case "$over_code" in
      200|000) fail "超上限请求未被拒绝（status=$over_code）" ;;
      *)       ok "超上限请求仍被拒绝（status=$over_code）" ;;
    esac
  else
    echo "[verifier] note : LIM 缺失/超 1MB，跳过上边界检查"
  fi
else
  fail "缺少预警参数文件 /app/ops/header_limits.env"
fi

# ---------- 4) 防线：质检门禁（干净日志通过；注入 431 拦截；可重复） ----------
GATE="/app/ops/quality_gate.sh"
if [ -x "$GATE" ]; then
  for lg in /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/hdrsize.log; do
    [ -f "$lg" ] && : > "$lg"
  done
  nginx -s reopen 2>/dev/null || true
  curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/api/v1/profile"
  sleep 1
  if bash "$GATE" >/dev/null 2>&1; then ok "质检门禁：干净日志通过（exit 0）"; else fail "质检门禁：干净日志被误拦截"; fi
  ts=$(date +%s)
  [ -f /var/log/nginx/hdrsize.log ] && echo "$ts.000 431 99999 \"GET /injected HTTP/1.1\"" >> /var/log/nginx/hdrsize.log
  echo "$(date '+%Y/%m/%d %H:%M:%S') [info] 999#999: *1 client sent too long header line while reading client request headers, client: 127.0.0.1, server: _, request: \"GET /injected HTTP/1.1\"" >> /var/log/nginx/error.log
  if bash "$GATE" >/dev/null 2>&1; then fail "质检门禁：注入 431 后未拦截（exit 0）"; else ok "质检门禁：431 高优先级拦截生效"; fi
  [ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
  : > /var/log/nginx/error.log
  nginx -s reopen 2>/dev/null || true
else
  fail "缺少质检门禁 /app/ops/quality_gate.sh"
fi

# ---------- 5) 防线：预警观测（近阈值告警 + 小请求不误报） ----------
if [ -f "$LIMENV" ]; then
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
  if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] 2>/dev/null; then
    THRESH=$(( LIM * RATIO / 100 ))
    PROBE2=$(( THRESH + 512 )); CAP=$(( LIM - 1024 )); [ "$PROBE2" -gt "$CAP" ] && PROBE2=$CAP
    WPID=$(cat /app/ops/watchdog.pid 2>/dev/null)
    kill -0 "$WPID" 2>/dev/null && ok "预警观测进程运行中" || fail "预警观测进程未运行"
    # 清理日志增量后进入静默窗口（观测需容忍截断）
    [ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
    nginx -s reopen 2>/dev/null || true
    sleep 2
    before=$(wc -l < /app/ops/warnings.log 2>/dev/null || echo 0)
    # 5.1 静默检查：常规请求（远低于阈值）10s 内不得产生告警
    curl -s -o /dev/null --max-time 10 "$ENTRY/api/v1/profile"
    sleep 10
    mid=$(wc -l < /app/ops/warnings.log 2>/dev/null || echo 0)
    [ "$mid" -eq "$before" ] && ok "预警观测：常规请求无误报" || fail "预警观测：常规请求触发误报"
    # 5.2 近阈值请求：两次探针（立即 + ~9s 后），30s 内行数必须增加
    p2=$(head -c $PROBE2 /dev/zero | tr '\0' 'x')
    curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $p2" "$ENTRY/api/v1/profile"
    hit=0
    for i in $(seq 1 10); do
      sleep 3
      after=$(wc -l < /app/ops/warnings.log 2>/dev/null || echo 0)
      if [ "$after" -gt "$mid" ]; then hit=1; break; fi
      if [ "$i" = "3" ]; then
        curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $p2" "$ENTRY/api/v1/profile"
      fi
    done
    [ "$hit" = "1" ] && ok "预警观测：接近阈值请求已产生告警（${PROBE2}B ≥ ${THRESH}B）" || fail "预警观测：30s 内未产生告警"
  else
    fail "header_limits.env 缺少 NGINX_LARGE_HEADER_BUFFER_BYTES（或值 ≤ 4096）"
  fi
else
  fail "缺少预警参数文件 /app/ops/header_limits.env"
fi

# ---------- 结果 ----------
echo "$PASS" > "$REWARD_FILE"
echo "[verifier] reward=$PASS"
exit 0
