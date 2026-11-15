#!/bin/bash
# 431 任务验题脚本（平台 tests/test.sh）
# 判定：端到端 + 双层真实修改（防伪造）+ 边界/输入覆盖 + 防线（门禁/预警）+ 综合归因报告
# 行为正确性以探针（不同输入/边界）判定；源码/配置扫描仅作"修改真实发生"的辅助证据。
# 测试依赖：bash/curl/nginx(仅 -T 读配置)/grep/awk/sed —— 均为环境镜像自带（见
# environment/Dockerfile），无 Python/pip 依赖，无需在测试时额外安装。
# 评分策略（3.7）：全部检查为硬性必要条件，采用 0/1 二值判定（无加权部分分）——
# 任一检查失败即 reward=0，通过即 1；题面"判定总则"已声明该语义。reward.txt 总是被
# 覆盖写入（0 或 1），不存在留空或沿用上次结果（3.5）。
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
# 链路完整性（防"绕过中间层直连下游"式伪修复）：入口请求经 tracegate/meshd 注入链
# 后由后端回显 X-Trace-Context——响应头须同时含 gate= 与 mesh= 注入段。
# 若中间层被绕开或注入/回显被拆除，该头缺失或缺少对应段。
tc_hdr=$(curl -s -D - -o /dev/null --max-time 10 "$ENTRY/api/v1/profile" | grep -i '^x-trace-context:' | head -n1)
if echo "$tc_hdr" | grep -q 'gate=' && echo "$tc_hdr" | grep -q 'mesh='; then
  ok "注入链完整（X-Trace-Context 含 gate/mesh 注入段）"
else
  fail "注入链不完整（响应缺 X-Trace-Context 或缺 gate/mesh 注入段——疑似绕过中间层）"
fi
# 响应体特征（防"桩替换"式作弊：必须是真实应用在服务，而非只回 200 的替身）
body=$(curl -s --max-time 10 "$ENTRY/api/v1/profile")
echo "$body" | grep -q '"msg":"ok"' && ok "业务路由响应体特征匹配" || fail "业务路由响应体异常（疑似应用被替换）"
hb=$(curl -s --max-time 10 -H "X-Verify-Token: $big" "$ENTRY/healthz" | tr -d '[:space:]')
[ "$hb" = "ok" ] && ok "/healthz 响应体特征匹配" || fail "/healthz 响应体异常（疑似应用被替换）"

# ---------- 2) 双层真实修改（防伪造辅助证据；行为判定见 1/3 节） ----------
# L1 下限 17408B = 16384B（探针值）+ 字段名/分隔符/CRLF（约 18B）+ 1024B 余量，
# 按完整 header 行口径计算——恰好 16384 的缓冲会误拒合规探针。
NG_BUF=$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | awk '{gsub(/;/,""); print $3}')
NG_BUF_B=$(printf '%s' "$NG_BUF" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
if [ -n "$NG_BUF_B" ] && [ "$NG_BUF_B" -ge 17408 ] 2>/dev/null; then
  ok "nginx large_client_header_buffers=${NG_BUF}（生效配置，完整行口径 ≥17408B）"
else
  fail "nginx header 缓冲未调大（当前=${NG_BUF:-无}，需按完整 header 行口径 ≥17408B）"
fi
# L2 扫描按关键词锚定 + 十进制全量两种口径：
# - 十进制形态 (^|[^0-9])8192([^0-9]|$) 不限上下文（覆盖业务配额键、退役入口常量等任意书写处）；
# - 等值移码/十六进制形态（1 << 13 / 0x2000）仅锚定 MaxHeaderBytes/max_header_bytes 上下文，
#   避免误伤无关代码中的位移/十六进制常量；数值有效性由检查 1/3 的行为探针证明。
if grep -rqIE '(^|[^0-9])8192([^0-9]|$)|(MaxHeaderBytes|max_header_bytes)["'\'':= ]*(1[[:space:]]*<<[[:space:]]*13([^0-9]|$)|0[xX]2000([^0-9a-fA-F]|$))' /app/backend \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
    --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null; then
  fail "后端侧 header 限额仍残留原故障值 8192（十进制或等值移码/十六进制形态，源码/配置）"
else
  ok "后端侧 header 限额已真实调整（源码/配置扫描）"
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
  # 4.2a 独立验证 access.log 来源
  echo "127.0.0.1 - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET /injected HTTP/1.1\" 431 0 \"-\" \"verifier\"" >> /var/log/nginx/access.log
  if bash "$GATE" >/dev/null 2>&1; then fail "质检门禁：access.log 注入 431 后未拦截"; else ok "质检门禁：access.log 来源拦截生效"; fi
  : > /var/log/nginx/access.log
  # 4.2b 独立验证 hdrsize.log + error.log 来源
  [ -f /var/log/nginx/hdrsize.log ] && echo "$(date +%s).000 431 99999 \"GET /injected HTTP/1.1\"" >> /var/log/nginx/hdrsize.log
  echo "$(date '+%Y/%m/%d %H:%M:%S') [info] 999#999: *1 client sent too long header line while reading client request headers, client: 127.0.0.1, server: _, request: \"GET /injected HTTP/1.1\"" >> /var/log/nginx/error.log
  if bash "$GATE" >/dev/null 2>&1; then fail "质检门禁：hdrsize/error 注入 431 后未拦截"; else ok "质检门禁：hdrsize/error 来源拦截生效"; fi
  [ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
  : > /var/log/nginx/error.log
  nginx -s reopen 2>/dev/null || true
else
  fail "缺少质检门禁 /app/ops/quality_gate.sh"
fi

# ---------- 5) 防线：预警观测（近阈值告警 + 小请求不误报） ----------
if [ -f "$LIMENV" ]; then
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
  # WARN_RATIO 有效范围 [50,90]：超范围则阈值/探针关系无法保证（高比例会截短探针到阈值以下）
  if [ "$RATIO" -lt 50 ] 2>/dev/null || [ "$RATIO" -gt 90 ] 2>/dev/null; then
    fail "header_limits.env 的 WARN_RATIO=$RATIO 超出有效范围 [50,90]"
    RATIO=80
  fi
  if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] 2>/dev/null; then
    THRESH=$(( LIM * RATIO / 100 ))
    PROBE2=$(( THRESH + 512 )); CAP=$(( LIM - 1024 )); [ "$PROBE2" -gt "$CAP" ] && PROBE2=$CAP
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

# ---------- 6) 综合分析报告（结构化要求见题面"产物 schema"；数值对照+实质归因为硬断言） ----------
RPT="/app/ops/diagnosis_report.md"
if [ -s "$RPT" ]; then
  grep -qE '归因|综合' "$RPT" && ok "综合分析报告存在（含归因结论）" || fail "报告缺归因结论"
  grep -qE 'large_client_header_buffers|MaxHeaderBytes|ReadBufferSize' "$RPT" \
    && ok "报告含各层限额对照" || fail "报告未覆盖各层限额对照"
  # 状态码链：须含"修复前"表述且呈现分层链（箭头连接）
  grep -qE '状态码链|修复前' "$RPT" && grep -qE '→|->' "$RPT" \
    && ok "报告含状态码链（修复前→分层修复后）" || fail "报告缺状态码链（修复前/修复后链条）"
  # 数值对照：须同时含原故障值 8192 与生效的新限额数值（LIM=题面声明值）
  grep -q '8192' "$RPT" && grep -q "${LIM:-65536}" "$RPT" \
    && ok "报告含限额数值对照（8192 → 新值）" || fail "报告缺限额数值对照（缺 8192 或新限额 $LIM）"
  # 实质归因：须含量化观测证据 + "谁注入过多"与"哪层限制过小"两类归因表述
  grep -qE 'HDRSTAT|max_header|request_length' "$RPT" \
    && grep -qE '注入|增长' "$RPT" && grep -qE '过小|未同步|未扩容' "$RPT" \
    && ok "报告含实质归因（量化证据+两侧归因）" || fail "报告缺实质归因（量化证据/注入侧/限制侧）"
  grep -qiE '余量|sizing' "$RPT" \
    && ok "报告含容量取值依据（增长余量/sizing）" || fail "报告缺容量取值依据（余量/sizing）"
else
  fail "缺少综合分析报告 /app/ops/diagnosis_report.md"
fi

# ---------- 结果 ----------
echo "$PASS" > "$REWARD_FILE"
echo "[verifier] reward=$PASS"
exit 0
