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
LIM=""; RATIO=""
[ -f "$OPS/params.env" ] && {
  LIM=$(sed -n 's/^[[:space:]]*LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^[[:space:]]*WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
}
THRESH=0
[ -n "$LIM" ] && [ -n "$RATIO" ] && THRESH=$(( LIM * RATIO / 100 ))
echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing} THRESH=${THRESH}" >> "$DEBUG_FILE"

# ---------- 修复前取证签名 ----------
sig1() { grep -qE '(^|[^0-9])(400|431)([^0-9]|$)' "$1" 2>/dev/null; }
sig2() { grep -qE '(^|[^0-9])431([^0-9]|$)|quota=8192|Request Header' "$1" 2>/dev/null; }
sig3() {
  local g m
  g=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B' "$1" 2>/dev/null | head -n1 | sed -E 's/trace_in=([0-9]+)B trace_out=([0-9]+)B/\1 \2/' | awk '{print $2-$1}')
  m=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B baggage' "$1" 2>/dev/null | head -n1 | sed -E 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/' | awk '{print $2-$1}')
  { [ -z "$g" ] && [ -z "$m" ]; } && return 1
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
B_PASS=0; B_TOTAL=11
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
  BELOW_LINE=$(grep "$LM1" "$F1B" | head -n1)
  ABOVE_LINE=$(grep "$LP4" "$F1B" | head -n1)
  if printf '%s' "$BELOW_LINE" | grep -qE '(^|[^0-9])200([^0-9]|$)' \
     && printf '%s' "$ABOVE_LINE" | grep -qE '(^|[^0-9])(400|431|413|49[0-9]|502)([^0-9]|$)'; then
    ok "F1b：双侧边界（LIM−1024 放行 200 / LIM+4096 拒绝）"; B_PASS=$((B_PASS+1))
  else
    fail "F1b：双侧边界证据不成立（below 行=${BELOW_LINE:--} / above 行=${ABOVE_LINE:--}）"
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

# ---------- 加权总分 ----------
SCORE=$(awk "BEGIN{printf \"%.4f\", 0.20*$S_PASS/$S_TOTAL + 0.35*$B_PASS/$B_TOTAL + 0.20*$E_PASS/$E_TOTAL + 0.25*$Q_PASS/$Q_TOTAL}")
echo "==================================================================="
echo "[verifier] 结构=$S_PASS/$S_TOTAL 基础=$B_PASS/$B_TOTAL 证据=$E_PASS/$E_TOTAL 报告=$Q_PASS/$Q_TOTAL"

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
