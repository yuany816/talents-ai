#!/bin/bash
# =============================================================================
# 431 任务验题脚本 v3.1 —— 5 面 / 2 阶段 / 前置取证 / 持久化核验 / 部分分
# reward = 0.20×结构(/10) + 0.35×基础(/10) + 0.20×证据(/5) + 0.25×报告(/5)
#   structure(/10)：repro/Fx.sh+Fx.out 修复前签名 ×5 + fix/Fx.sh 可执行 ×5
#   basic(/10)：F1a 参数一致性 / F1b 双侧边界 / F2a e2e / F2b restart-all / F2c 双侧标定
#     / F3 精确规格 / F4a 落盘 / F4b broker 重启复证 / F5a meshd 生效限额 / F5b meshd 重启复证
#   edge(/5)：每面证据文件存在；quality(/5)：报告逐面引用 evidence 路径
# CAP：repro 取证全缺 → 封顶 0.45。兜底 0.0000。诊断 → /logs/verifier/debug.txt
# =============================================================================
export LC_ALL=C
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWARD_FILE="/logs/verifier/reward.txt"
DEBUG_FILE="/logs/verifier/debug.txt"
OPS="/app/ops"; EV="$OPS/evidence"; RP="$OPS/repro"; FX="$OPS/fix"
mkdir -p /logs/verifier 2>/dev/null || true

ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; }

printf '%s\n' "0.0000" > "$REWARD_FILE"
: > "$DEBUG_FILE"
[ -d "$OPS" ] || { echo "ops_dir=missing（空作答）" >> "$DEBUG_FILE"; exit 0; }
echo "ops_dir=present" >> "$DEBUG_FILE"

# ---------- params.env ----------
LIM=""; RATIO=""; HT_F=0; HM_F=0
[ -f "$OPS/params.env" ] && {
  LIM=$(sed -n 's/^[[:space:]]*LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^[[:space:]]*WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  HT_F=$(sed -n 's/^[[:space:]]*hidden.tracegate_factor=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  HM_F=$(sed -n 's/^[[:space:]]*hidden.mesh_factor=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  DP_P=$(sed -n 's/^[[:space:]]*hidden.drop_period=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
}
THRESH=0
[ -n "$LIM" ] && [ -n "$RATIO" ] && THRESH=$(( LIM * RATIO / 100 ))
echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing} THRESH=${THRESH}" >> "$DEBUG_FILE"

# ---------- 修复前取证签名 ----------
sig1() { grep -qE '(^|[^0-9])(400|431|502)([^0-9]|$)' "$1" 2>/dev/null; }
sig2() { grep -qE '(^|[^0-9])431([^0-9]|$)|quota=8192|Request Header' "$1" 2>/dev/null; }
sig3() {
  local g m
  g=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B' "$1" 2>/dev/null | head -n1 | sed -E 's/trace_in=([0-9]+)B trace_out=([0-9]+)B/\1 \2/' | awk '{print $2-$1}')
  m=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B baggage' "$1" 2>/dev/null | head -n1 | sed -E 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/' | awk '{print $2-$1}')
  { [ -z "$g" ] && [ -z "$m" ]; } && return 0   # 无计数行=注入链不可达，亦为修复前证据
  { [ -n "$g" ] && [ "$g" != "769" ]; } && return 0
  { [ -n "$m" ] && [ "$m" != "1537" ]; } && return 0
  return 1
}
sig4() { grep -qE 'MESSAGE_TOO_LARGE|kafka produce failed|message\.max\.bytes=16384' "$1" 2>/dev/null; }
# F5 签名：修复前生效限额 <17408（磁盘与部署环境双口径任一未达标即算）
sig5() {
  local e
  e=$(grep -oE 'effective_limit=[0-9]+' "$1" 2>/dev/null | head -n1 | grep -oE '[0-9]+')
  [ -n "$e" ] && [ "$e" -lt 17408 ] 2>/dev/null
}

# ---------- 维度 1：结构（/10：repro×5 双条件 + fix×5 可执行） ----------
S_PASS=0; S_TOTAL=10
i=0
for spec in "F1:sig1" "F2:sig2" "F3:sig3" "F4:sig4" "F5:sig5"; do
  f="${spec%%:*}"; fn="${spec##*:}"
  if [ -x "$RP/$f.sh" ] && [ -s "$RP/$f.sh" ] && [ -s "$RP/$f.out" ] && "$fn" "$RP/$f.out"; then
    ok "结构 repro/$f：脚本可执行 + 修复前取证签名匹配"; S_PASS=$((S_PASS+1))
  else
    fail "结构 repro/$f：脚本缺失/不可执行，或 Fx.out 缺失/无修复前故障签名"
  fi
done
for f in F1 F2 F3 F4 F5; do
  if [ -x "$FX/$f.sh" ] && [ -s "$FX/$f.sh" ]; then
    ok "结构 fix/$f.sh 存在且可执行"; S_PASS=$((S_PASS+1))
  else
    fail "结构 fix/$f.sh 缺失/不可执行（修复脚本须落盘交付）"
  fi
done

# ---------- 维度 2：基础修复（/10） ----------
B_PASS=0; B_TOTAL=16
NT="$EV/F1_nginx_T.txt"
if [ -s "$NT" ] && [ -n "$LIM" ]; then
  MINB=""; MAXB=""; CNT=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    b=$(printf '%s' "$v" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
    case "$b" in ''|*[!0-9]*) continue ;; esac
    CNT=$((CNT+1))
    { [ -z "$MINB" ] || [ "$b" -lt "$MINB" ]; } && MINB=$b
    { [ -z "$MAXB" ] || [ "$b" -gt "$MAXB" ]; } && MAXB=$b
  done < <(grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' "$NT" 2>/dev/null | sed -E 's/#.*//; s/;.*//' | awk '{print $3}')
  if [ "$CNT" -ge 1 ] && [ "$MINB" = "$MAXB" ] && [ "$LIM" -eq "$MINB" ] 2>/dev/null; then
    ok "F1a：nginx 生效单缓冲全部 == params LIM（${CNT} 条 = ${MINB}B）"; B_PASS=$((B_PASS+1))
  else
    fail "F1a：生效单缓冲（${CNT} 条，${MINB:-无}~${MAXB:-无}）须全部 == LIM=${LIM:-缺}"
  fi
else
  fail "F1a：evidence/F1_nginx_T.txt 缺失或 params LIM 缺失"
fi
F1B="$EV/F1_boundary.txt"
LM1=$(( ${LIM:-0} - 1024 )); LP4=$(( ${LIM:-0} + 4096 ))
if [ -s "$F1B" ] && [ -n "$LIM" ]; then
  BELOW_LINE=$(grep "$LM1" "$F1B" 2>/dev/null | grep -m1 -E '(^|[^0-9])200([^0-9]|$)')
  ABOVE_LINE=$(grep "$LP4" "$F1B" 2>/dev/null | grep -m1 -E '(^|[^0-9])(400|431|413|49[0-9]|502)([^0-9]|$)')
  if printf '%s' "$BELOW_LINE" | grep -qE '(^|[^0-9])200([^0-9]|$)' \
     && printf '%s' "$ABOVE_LINE" | grep -qE '(^|[^0-9])(400|431|413|49[0-9]|502)([^0-9]|$)'; then
    ok "F1b：双侧边界（LIM−1024 放行 200 / LIM+4096 拒绝）"; B_PASS=$((B_PASS+1))
  else
    fail "F1b：双侧边界证据不成立（含 ${LM1} 且 200 的行 / 含 ${LP4} 且 400|431 的行 均未找到）"
  fi
else
  fail "F1b：evidence/F1_boundary.txt 缺失"
fi
F2="$EV/F2_backend_status.txt"
if [ -s "$F2" ]; then
  BB=$(sed -n 's/^[[:space:]]*backend_big_status=//p' "$F2" | head -n1)
  EB=$(sed -n 's/^[[:space:]]*entry_big_status=//p' "$F2" | head -n1)
  PB=$(sed -n 's/^[[:space:]]*profile_body=//p' "$F2" | head -n1)
  if [ "$BB" = "200" ] && [ "$EB" = "200" ] && printf '%s' "$PB" | grep -q '"msg":"ok"'; then
    ok "F2a：入口与直连后端大探针 200 + 响应体特征"; B_PASS=$((B_PASS+1))
  else
    fail "F2a：backend=${BB:-缺}/entry=${EB:-缺}/响应体异常"
  fi
else
  fail "F2a：evidence/F2_backend_status.txt 缺失"
fi
# F2d：预警阈值与 params 一致（内置预警阈值硬编码 → 必须按 THRESH=LIM×WARN_RATIO/100 联动）
if [ -s "$F2" ] && [ "$THRESH" -gt 0 ] 2>/dev/null; then
  BN=$(grep -oE 'warn_threshold=[0-9]+B' "$F2" | head -n1 | grep -oE '[0-9]+')
  if [ -n "$BN" ] && [ "$BN" -eq "$THRESH" ] 2>/dev/null; then
    ok "F2d：预警阈值与 params 一致（warn_threshold=${BN} == THRESH=${THRESH}）"; B_PASS=$((B_PASS+1))
  else
    fail "F2d：预警阈值 warn_threshold=${BN:-缺} ≠ params THRESH=${THRESH}——阈值须按 LIM×WARN_RATIO/100 联动，硬编码不通过"
  fi
else
  fail "F2d：evidence/F2_backend_status.txt 缺失（须含启动 banner）或 params 缺失"
fi
F2R="$EV/F2_restart.txt"
if [ -s "$F2R" ] \
   && grep -qE '^[[:space:]]*post_restart_entry_big_status=200' "$F2R" \
   && grep -qE '^[[:space:]]*post_restart_backend_big_status=200' "$F2R"; then
  ok "F2b：restart all 后全链路仍 200"; B_PASS=$((B_PASS+1))
else
  fail "F2b：evidence/F2_restart.txt 缺 post_restart_*_status=200"
fi
F2C="$EV/F2_calibration.txt"
if [ -s "$F2C" ] && [ "$THRESH" -gt 0 ] 2>/dev/null; then
  BD=$(sed -n 's/^[[:space:]]*below_warnings_delta=//p' "$F2C" | head -n1 | tr -dc '0-9')
  AD=$(sed -n 's/^[[:space:]]*above_warnings_delta=//p' "$F2C" | head -n1 | tr -dc '0-9')
  AM=$(sed -n 's/^[[:space:]]*above_max_observed=//p' "$F2C" | head -n1 | tr -dc '0-9')
  if [ "$BD" = "0" ] && [ -n "$AD" ] && [ "$AD" -ge 1 ] 2>/dev/null \
     && [ -n "$AM" ] && [ "$AM" -ge "$THRESH" ] 2>/dev/null; then
    ok "F2c：预警双侧标定成立（below 0 / above ${AD} / 观测 ${AM} ≥ THRESH ${THRESH}）"
    B_PASS=$((B_PASS+1))
  else
    fail "F2c：双侧标定不成立（below_delta=${BD:-缺} 须 0；above_delta=${AD:-缺} 须 ≥1 且观测 ${AM:-缺} ≥ THRESH=${THRESH}）"
  fi
else
  fail "F2c：evidence/F2_calibration.txt 缺失或 params 缺失"
fi
F3="$EV/F3_span_count.txt"
if [ -s "$F3" ]; then
  G=$(sed -n 's/^[[:space:]]*gate_trace_delta=//p' "$F3" | head -n1)
  M=$(sed -n 's/^[[:space:]]*mesh_trace_delta=//p' "$F3" | head -n1)
  BG=$(sed -n 's/^[[:space:]]*baggage_bytes=//p' "$F3" | head -n1)
  NC=$(sed -n 's/^[[:space:]]*nonce=//p' "$F3" | head -n1)
  EC=$(sed -n 's/^[[:space:]]*echo=//p' "$F3" | head -n1)
  GRW=$(( ${#EC} - ${#NC} ))
  if [ "$G" = "769" ] && [ "$M" = "1537" ] && [ "$BG" = "512" ] && [ "$GRW" -eq 2306 ] 2>/dev/null; then
    ok "F3：注入链规格恢复（769/1537/512，回显增幅恰 2306）"; B_PASS=$((B_PASS+1))
  else
    fail "F3：链路计数/回显失真（gate=${G:-缺} mesh=${M:-缺} baggage=${BG:-缺} 增幅=${GRW}——须恰 769/1537/512/2306）"
  fi
else
  fail "F3：evidence/F3_span_count.txt 缺失"
fi
F4="$EV/F4_kafka_audit.txt"
if [ -s "$F4" ]; then
  ST=$(sed -n 's/^[[:space:]]*kafka_message_max_bytes_static=//p' "$F4" | head -n1 | grep -oE '[0-9]+' | head -n1)
  if [ -n "$ST" ] && [ "$ST" -gt 16384 ] 2>/dev/null; then
    ok "F4a：broker 静态限额落盘 ${ST} > 16384"; B_PASS=$((B_PASS+1))
  else
    fail "F4a：static=${ST:-缺} 须 >16384"
  fi
else
  fail "F4a：evidence/F4_kafka_audit.txt 缺失"
fi
F4R="$EV/F4_restart.txt"
if [ -s "$F4R" ] && grep -q 'marker=' "$F4R" && grep -qE 'event_seen=(ok|yes|true|1)' "$F4R"; then
  ok "F4b：broker 重启后新标记事件落盘"; B_PASS=$((B_PASS+1))
else
  fail "F4b：evidence/F4_restart.txt 缺 marker=/event_seen=ok"
fi
F5="$EV/F5_meshd_status.txt"
if [ -s "$F5" ]; then
  EFF=$(grep -oE 'effective_limit=[0-9]+' "$F5" | head -n1 | grep -oE '[0-9]+')
  if [ -n "$EFF" ] && [ "$EFF" -ge 17408 ] 2>/dev/null; then
    ok "F5a：meshd 生效限额 ${EFF} ≥ 17408"; B_PASS=$((B_PASS+1))
  else
    fail "F5a：meshd effective_limit=${EFF:-缺} 须 ≥17408"
  fi
else
  fail "F5a：evidence/F5_meshd_status.txt 缺失"
fi
F5R="$EV/F5_restart.txt"
if [ -s "$F5R" ]; then
  EFR=$(grep -oE 'effective_limit=[0-9]+' "$F5R" | head -n1 | grep -oE '[0-9]+')
  if [ -n "$EFR" ] && [ "$EFR" -ge 17408 ] 2>/dev/null; then
    ok "F5b：restart all 后 meshd 生效限额仍 ≥17408"; B_PASS=$((B_PASS+1))
  else
    fail "F5b：F5_restart.txt 生效限额=${EFR:-缺} 须 ≥17408（重启后须仍生效）"
  fi
else
  fail "F5b：evidence/F5_restart.txt 缺失（restart all 后重跑 collect_meshd 并保存）"
fi
# F8：隐藏采样周期推断（measured_period == hidden.drop_period）+ 修复后 100% 落盘
F8F="$EV/F8_period.txt"
DP=$(( ${DP_P:-0} ))
if [ -s "$F8F" ] && [ "$DP" -ge 3 ] 2>/dev/null; then
  MP=$(sed -n 's/^[[:space:]]*measured_period=//p' "$F8F" | head -n1 | tr -dc '0-9')
  PL=$(sed -n 's/^[[:space:]]*post_fix_landed=//p' "$F8F" | head -n1 | tr -dc '0-9')
  PN=$(sed -n 's/^[[:space:]]*post_fix_probes=//p' "$F8F" | head -n1 | tr -dc '0-9')
  if [ -n "$MP" ] && [ "$MP" -eq "$DP" ] 2>/dev/null      && [ -n "$PN" ] && [ "$PN" -ge 20 ] 2>/dev/null && [ "$PL" -eq "$PN" ] 2>/dev/null; then
    ok "F8：隐藏采样周期推断正确（measured=$MP == hidden $DP）且修复后 ${PL}/${PN} 全落盘"; B_PASS=$((B_PASS+1))
  else
    fail "F8：measured_period=${MP:-缺} ≠ hidden.drop_period=${DP}，或修复后落盘 ${PL:-缺}/${PN:-缺} 非全量——采样逻辑未定位或未修复"
  fi
else
  fail "F8：evidence/F8_period.txt 缺失或 params hidden.drop_period 缺失（须发送 ≥20 标记探针统计落盘率推断周期）"
fi
# F9：多字节规格偏移差分（修复前 CJK 路由 delta ∈{1531,1533,1535}，修复后恰 1537）
F9F="$EV/F9_offset.txt"
if [ -s "$F9F" ]; then
  PRE=$(grep -oE 'prefix_multibyte_delta=[0-9]+' "$F9F" | head -n1 | grep -oE '[0-9]+')
  POST=$(grep -oE 'post_multibyte_delta=[0-9]+' "$F9F" | head -n1 | grep -oE '[0-9]+')
  if [ -n "$PRE" ] && [ "$PRE" -ge 1530 ] 2>/dev/null && [ "$PRE" -le 1536 ] 2>/dev/null && [ "$PRE" != "1537" ]; then
    if [ "$POST" = "1537" ]; then
      ok "F9：多字节偏移差分成立（修复前 $PRE ≠ 1537 → 修复后恰 1537）"; B_PASS=$((B_PASS+1))
    else
      fail "F9：post_multibyte_delta=${POST:-缺} 须恰 1537（修复后规格恢复）"
    fi
  else
    fail "F9：prefix_multibyte_delta=${PRE:-缺} 须 ∈{1531,1533,1535}（修复前多字节偏移未捕获）"
  fi
else
  fail "F9：evidence/F9_offset.txt 缺失（差分实验：ASCII vs 多字节路由的逐跳 delta 对照）"
fi
# F2g：门禁脚本行为（判分环境本地伪造日志——干净过/注入拒，恢复 v3.1 覆盖回归）
GATEB="$OPS/quality_gate.sh"
if [ -x "$GATEB" ]; then
  mkdir -p /var/log/nginx
  : > /var/log/nginx/access.log; : > /var/log/nginx/hdrsize.log; : > /var/log/nginx/error.log
  G1=0; bash "$GATEB" >/dev/null 2>&1 || G1=1
  echo '127.0.0.1 - - ['"$(date '+%d/%b/%Y:%H:%M:%S +0000')"'] "GET /injected HTTP/1.1" 431 0 "-" "verifier"' >> /var/log/nginx/access.log
  G2=0; bash "$GATEB" >/dev/null 2>&1 || G2=1
  : > /var/log/nginx/access.log
  echo "$(date +%s).000 431 99999 \"GET /injected HTTP/1.1\"" >> /var/log/nginx/hdrsize.log
  G3=0; bash "$GATEB" >/dev/null 2>&1 || G3=1
  : > /var/log/nginx/hdrsize.log
  if [ "$G1" = "0" ] && [ "$G2" = "1" ] && [ "$G3" = "1" ]; then
    ok "F2g：门禁行为（干净过/431 注入拒）"; B_PASS=$((B_PASS+1))
  else
    fail "F2g：门禁行为异常（clean=$G1 inject_access=$G2 inject_hdrsize=$G3——须 clean=0/inject≠0）"
  fi
  : > /var/log/nginx/access.log; : > /var/log/nginx/hdrsize.log; : > /var/log/nginx/error.log
else
  fail "F2g：quality_gate.sh 缺失或不可执行——门禁行为 0 分"
fi
# F2e：tracegate 修复前生效预算 == 故障基值 × hidden 因子（须实测标定，硬编码不通过）
F3B="$EV/F3_budget.txt"
TB=$(( 10240 * ${HT_F:-0} / 10 ))
if [ -s "$F3B" ] && [ "${HT_F:-0}" -gt 0 ] 2>/dev/null; then
  PB=$(sed -n 's/^prefix_budget=//p' "$F3B" | head -n1 | tr -dc '0-9')
  if [ -n "$PB" ] && [ "$PB" -eq "$TB" ] 2>/dev/null; then
    ok "F2e：tracegate 修复前生效预算实测 == ${TB}（基值 10240 × factor ${HT_F}/10）"; B_PASS=$((B_PASS+1))
  else
    fail "F2e：prefix_budget=${PB:-缺} ≠ ${TB}（10240×factor/10）——修复前生效预算未实测或与 hidden 因子不一致"
  fi
else
  fail "F2e：evidence/F3_budget.txt 缺失或 params hidden 因子缺失"
fi
# F2f：mesh 修复前生效预算 == 故障基值 × hidden 因子
F5B2="$EV/F5_budget.txt"
MB=$(( 12288 * ${HM_F:-0} / 10 ))
if [ -s "$F5B2" ] && [ "${HM_F:-0}" -gt 0 ] 2>/dev/null; then
  MP=$(sed -n 's/^prefix_budget=//p' "$F5B2" | head -n1 | tr -dc '0-9')
  if [ -n "$MP" ] && [ "$MP" -eq "$MB" ] 2>/dev/null; then
    ok "F2f：mesh 修复前生效预算实测 == ${MB}（基值 12288 × factor ${HM_F}/10）"; B_PASS=$((B_PASS+1))
  else
    fail "F2f：prefix_budget=${MP:-缺} ≠ ${MB}（12288×factor/10）——mesh 修复前生效预算未实测"
  fi
else
  fail "F2f：evidence/F5_budget.txt 缺失或 params hidden 因子缺失"
fi

# ---------- 维度 3：证据齐全（/5） ----------
E_PASS=0; E_TOTAL=5
for f in F1 F2 F3 F4 F5; do
  if ls "$EV/${f}_"* >/dev/null 2>&1; then
    ok "证据 ${f}_* 存在"; E_PASS=$((E_PASS+1))
  else
    fail "证据 ${f}_* 缺失"
  fi
done

# ---------- 维度 4：报告质量（/5：逐面引用证据路径） ----------
Q_PASS=0; Q_TOTAL=5
R="$OPS/diagnosis_report.md"
for f in F1 F2 F3 F4 F5; do
  if [ -s "$R" ] && grep -q "evidence/${f}_" "$R"; then
    ok "报告：引用 ${f} 面证据路径"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告：未引用 ${f} 面证据文件相对路径（evidence/${f}_*）"
  fi
done

# ---------- P1：运维修复清单（权重 0.15） ----------
P1=$(awk "BEGIN{printf \"%.4f\", 0.20*$S_PASS/$S_TOTAL + 0.35*$B_PASS/$B_TOTAL + 0.20*$E_PASS/$E_TOTAL + 0.25*$Q_PASS/$Q_TOTAL}")
echo "==================================================================="
echo "[verifier] P1 运维清单: 结构=$S_PASS/$S_TOTAL 基础=$B_PASS/$B_TOTAL 证据=$E_PASS/$E_TOTAL 报告=$Q_PASS/$Q_TOTAL → P1=$P1"

# ---------- P2：F7 标定器实现（隐性对抗套件，权重 0.85） ----------
# 规格见 /app/tools/specs/spec-calibrator.md；判分环境以 tests/bin/calibrator-ref 为
# 参考实现，12 个复合场景逐字节对照 agent 交付的 /app/ops/bin/calibrator。
F7_PASS=0; F7_TOTAL=0
F6_PASS=0; F6_TOTAL=12
AGG="$OPS/bin/calibrator"
REFBIN="/tests/bin/calibrator-ref"; [ -x "$REFBIN" ] || REFBIN="$TESTS_DIR/bin/calibrator-ref"
GENBIN="/tests/bin/gen-calibrator"; [ -x "$GENBIN" ] || GENBIN="$TESTS_DIR/bin/gen-calibrator"
THRESH_V=$(( ${LIM:-0} * ${RATIO:-0} / 100 ))
if [ -n "$LIM" ] && [ -n "$RATIO" ] && [ -x "$AGG" ]; then
  CASES=/tmp/f7cases
  rm -rf "$CASES"; mkdir -p "$CASES"
  SEED="trial-LIM=$LIM-RATIO=$RATIO-ht=$(grep -oE 'hidden.tracegate_factor=[0-9.]+' /app/ops/params.env 2>/dev/null)-hm=$(grep -oE 'hidden.mesh_factor=[0-9.]+' /app/ops/params.env 2>/dev/null)"
  "$GENBIN" "$LIM" "$RATIO" "$SEED" "$CASES" "$REFBIN" >/dev/null 2>&1 || true
  for cin in $(ls "$CASES"/sc*.in 2>/dev/null | sort); do
    F7_TOTAL=$((F7_TOTAL+1))
    "$AGG" "$THRESH_V" < "$cin" > /tmp/f7-agent.out 2>/dev/null || true
    "$REFBIN" "$THRESH_V" < "$cin" > /tmp/f7-ref.out 2>/dev/null || true
    if diff -q /tmp/f7-agent.out /tmp/f7-ref.out >/dev/null 2>&1; then
      ok "F7 场景 $(basename "$cin") 逐字节一致"; F7_PASS=$((F7_PASS+1))
    else
      fail "F7 场景 $(basename "$cin") 输出不一致（规格角未实现或实现偏差）"
    fi
  done
else
  F7_TOTAL=12
  fail "F7：/app/ops/bin/calibrator 缺失或不可执行，或 params.env 缺失——实现题 0 分"
fi
P2=$(awk "BEGIN{t=$F7_TOTAL; p=$F7_PASS; printf \"%.4f\", (t>0)?p/t:0}")

# ---------- P3：F6 headeragg 实现题（隐性差分套件） ----------
F6_PASS=0; F6_TOTAL=12
HAGG="$OPS/bin/headeragg"
HREFB="$TESTS_DIR/bin/headeragg-ref"
THRESH_F6="$THRESH_V"
if [ -n "$LIM" ] && [ -n "$RATIO" ] && [ -x "$HAGG" ] && [ -x "$HREFB" ]; then
  for pid in $(ss -ltnp 2>/dev/null | grep -E ':92[0-9]{2} |:93[0-9]{2} ' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do kill -9 "$pid" 2>/dev/null; done
  sleep 0.3
  rm -f /tmp/f6-a.state /tmp/f6-r.state
  "$HAGG" "$THRESH_F6" /tmp/f6-a.state 9200 & PA=$!
  "$HREFB" "$THRESH_F6" /tmp/f6-r.state 9300 & PR=$!
  sleep 0.6
  killA() { kill -9 "$PA" 2>/dev/null; }
  killR() { kill -9 "$PR" 2>/dev/null; }
  restartBoth() {
    killA; killR; sleep 0.3
    "$HAGG" "$THRESH_F6" /tmp/f6-a.state 9200 & PA=$!
    "$HREFB" "$THRESH_F6" /tmp/f6-r.state 9300 & PR=$!
    sleep 0.6
  }
  post() { curl -s -X POST -d "$1" "http://127.0.0.1:$2/event" >/dev/null; }
  cmpStats() {
    a=$(curl -s "http://127.0.0.1:9200/stats")
    r=$(curl -s "http://127.0.0.1:9300/stats")
    if [ "$a" = "$r" ]; then F6_PASS=$((F6_PASS+1)); ok "F6 场景 $1 双实例一致"
    else fail "F6 场景 $1 双实例不一致（agent=$r vs ref=$r2）"; fi
  }
  cmpStats() {
    a=$(curl -s "http://127.0.0.1:9200/stats")
    r=$(curl -s "http://127.0.0.1:9300/stats")
    if [ "$a" = "$r" ]; then F6_PASS=$((F6_PASS+1)); ok "F6 场景 $1 双实例 stats 一致"
    else fail "F6 场景 $1 双实例 stats 不一致"; fi
  }
  # s1 单事件
  post "ts=100 route=/api bytes=500" 9200; post "ts=100 route=/api bytes=500" 9300
  cmpStats s1
  # s2 混合 10 事件
  for i in 1 2 3 4 5; do post "ts=$((100+i)) route=/r$((i%2)) bytes=$((100+i*7))" 9200; post "ts=$((100+i)) route=/r$((i%2)) bytes=$((100+i*7))" 9300; done
  cmpStats s2
  # s3 并发 100（精确计数）
  seq 1 100 | xargs -P 20 -I{} curl -s -X POST -d "ts=500 route=/burst bytes=100" http://127.0.0.1:9200/event >/dev/null
  seq 1 100 | xargs -P 20 -I{} curl -s -X POST -d "ts=500 route=/burst bytes=100" http://127.0.0.1:9300/event >/dev/null
  sleep 0.5
  cmpStats s3
  # s4 多字节路由
  post "ts=600 route=/路由/α bytes=333" 9200; post "ts=600 route=/路由/α bytes=333" 9300
  post "ts=600 route=/emoji🚀 bytes=444" 9200; post "ts=600 route=/emoji🚀 bytes=444" 9300
  cmpStats s4
  # s5 边界恰等（bytes==THRESH 计 over）+ s6 THRESH+1
  post "ts=700 route=/edge bytes=$THRESH_F6" 9200; post "ts=700 route=/edge bytes=$THRESH_F6" 9300
  cmpStats s5
  post "ts=700 route=/edge bytes=$((THRESH_F6+1))" 9200; post "ts=700 route=/edge bytes=$((THRESH_F6+1))" 9300
  cmpStats s6
  # s7 畸形事件（stats 不得变化）
  post "bad line" 9200; post "bad line" 9300
  post "ts=x route=/m bytes=1" 9200; post "ts=x route=/m bytes=1" 9300
  cmpStats s7
  # s8 尾斜杠独立路由
  post "ts=800 route=/a bytes=10" 9200; post "ts=800 route=/a bytes=10" 9300
  post "ts=800 route=/a/ bytes=20" 9200; post "ts=800 route=/a/ bytes=20" 9300
  cmpStats s8
  # s9 双实例 kill+restart 持久化恢复
  killA; killR; sleep 0.3
  "$HAGG" "$THRESH_F6" /tmp/f6-a.state 9200 & PA=$!
  "$HREFB" "$THRESH_F6" /tmp/f6-r.state 9300 & PR=$!
  sleep 0.6
  cmpStats s9
  # s10 重启后衔接
  post "ts=900 route=/post bytes=777" 9200; post "ts=900 route=/post bytes=777" 9300
  cmpStats s10
  # s11 静默（THRESH−1 不得计 over）
  post "ts=1000 route=/quiet bytes=$((THRESH_F6-1))" 9200; post "ts=1000 route=/quiet bytes=$((THRESH_F6-1))" 9300
  cmpStats s11
  # s12 终态混合
  post "ts=1100 route=/fin/α bytes=999" 9200; post "ts=1100 route=/fin/α bytes=999" 9300
  post "ts=1100 route=/fin bytes=1" 9200; post "ts=1100 route=/fin bytes=1" 9300
  cmpStats s12
  killA; killR
else
  F6_TOTAL=12
  fail "F6：/app/ops/bin/headeragg 缺失或不可执行——实现题 0 分"
fi
F6=$(awk "BEGIN{t=$F6_TOTAL; p=$F6_PASS; printf \"%.4f\", (t>0)?p/t:0}")

# ---------- 加权总分：短板定标 min(P1, F6, F7) ----------
SCORE=$(awk "BEGIN{m=$P1; if ($F6<m) m=$F6; if ($P2<m) m=$P2; printf \"%.4f\", m}")

# ---------- CAP：repro 取证全缺 → 封顶 0.45 ----------
REPRO_OK=0
for spec in "F1:sig1" "F2:sig2" "F3:sig3" "F4:sig4" "F5:sig5"; do
  f="${spec%%:*}"; fn="${spec##*:}"
  { [ -x "$RP/$f.sh" ] && [ -s "$RP/$f.out" ] && "$fn" "$RP/$f.out"; } && REPRO_OK=$((REPRO_OK+1))
done
CAP_NOTE="none"
if [ "$REPRO_OK" -eq 0 ]; then
  SCORE=$(awk "BEGIN{printf \"%.4f\", ($SCORE < 0.45 ? $SCORE : 0.45)}")
  CAP_NOTE="repro 取证全缺 → 封顶 0.4500"
  echo "[verifier] CAP：repro 取证全缺，reward 封顶 0.4500"
fi

# ---------- debug.txt ----------
{
  echo "=== delivery ==="
  echo "ops_dir=present"
  echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing} THRESH=${THRESH}"
  for f in F1 F2 F3 F4 F5; do
    echo "repro/$f: sh=$([ -x "$RP/$f.sh" ] && echo ok || echo no) out=$([ -s "$RP/$f.out" ] && echo ok || echo no) fix=$([ -x "$FX/$f.sh" ] && echo ok || echo no)"
  done
  for f in "$EV"/*; do [ -f "$f" ] && echo "evidence/$(basename "$f") exists=yes"; done
  echo "=== dimensions ==="
  echo "structure=$S_PASS/$S_TOTAL"
  echo "basic=$B_PASS/$B_TOTAL"
  echo "edge=$E_PASS/$E_TOTAL"
  echo "quality=$Q_PASS/$Q_TOTAL"
  echo "repro_ok=$REPRO_OK"
  echo "score=$SCORE"
} > "$DEBUG_FILE"

printf '%s\n' "$SCORE" > "$REWARD_FILE"
echo "[verifier] reward=$SCORE → $REWARD_FILE（诊断 → $DEBUG_FILE）"
exit 0
