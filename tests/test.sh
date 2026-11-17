#!/bin/bash
# =============================================================================
# 431 任务验题脚本（平台 tests/test.sh）—— 5 面 / 2 阶段 + 前置取证 + 持久化核验
# （独立判分：判分环境无服务、不发实时探针，只读 /app/ops/ 交付）
#
# reward = 0.15×结构(/5) + 0.30×基础修复(/9) + 0.35×证据齐全(/5) + 0.20×报告质量(/2)
#
#   structure（/5）：repro/F1~F4.sh 可执行 **且** repro/Fx.out 含修复前故障签名
#     （先取证后修复——只有脚本没有修复前真实输出不计分）+ diagnosis_report.md；
#   basic（/9，每面修复是否可验证）：
#     F1a nginx_T 全部活动指令单缓冲 == params LIM（随机参数一致性，硬编码不通过）；
#     F1b 双侧边界证据（LIM−1024 放行 200 / LIM+4096 拒绝非 200）；
#     F2a 端到端大探针 200 + 响应体特征；F2b restart all 后全链路仍 200（持久化）；
#     F2c 预警双侧标定（THRESH+512 触发 / THRESH−1024 静默，warnings 增量口径）；
#     F3  注入链规格恢复（gate 769 / mesh 1537 / baggage 512 精确 + 回显增幅恰 2306）；
#     F4a broker 静态限额落盘 >16384；F4b broker 重启后新标记事件仍落盘（持久化）；
#     F5a meshd 生效限额 ≥17408（含部署环境覆盖口径）；
#   edge（/5）：evidence/ 下每面至少一个文件；
#   quality（/2）：报告引用证据路径；修复前数值与真实故障值咬合（8192/10240/12288/
#     384/16384 至少出现 4 个——未做过真实诊断的报告无法凑齐）。
#
# CAP：repro 取证项全缺 → 总分封顶 0.45。兜底 0.0000；/app/ops 缺失即 0 退出。
# 诊断写 /logs/verifier/debug.txt。依赖：bash/coreutils/grep/awk/sed（tests/Dockerfile）。
# =============================================================================
export LC_ALL=C
set -u

REWARD_FILE="/logs/verifier/reward.txt"
DEBUG_FILE="/logs/verifier/debug.txt"
OPS="/app/ops"; EV="$OPS/evidence"; RP="$OPS/repro"
mkdir -p /logs/verifier 2>/dev/null || true

ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; }

printf '%s\n' "0.0000" > "$REWARD_FILE"
: > "$DEBUG_FILE"
[ -d "$OPS" ] || { echo "ops_dir=missing（空作答）" >> "$DEBUG_FILE"; exit 0; }
echo "ops_dir=present" >> "$DEBUG_FILE"

# ---------- params.env（trial 随机容量参数） ----------
LIM=""; RATIO=""
[ -f "$OPS/params.env" ] && {
  LIM=$(sed -n 's/^LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
}
THRESH=0
[ -n "$LIM" ] && [ -n "$RATIO" ] && THRESH=$(( LIM * RATIO / 100 ))
echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing} THRESH=${THRESH}" >> "$DEBUG_FILE"

# ---------- 维度 1：结构（/5：4 个 repro 双条件 + 报告） ----------
S_PASS=0; S_TOTAL=5
# F1.out 签名：修复前入口对大探针返回 400/431
sig1() { grep -qE '(^|[^0-9])(400|431)([^0-9]|$)' "$1" 2>/dev/null; }
# F2.out 签名：直连后端 431 或 quota=8192 banner 或 Request Header 拒绝
sig2() { grep -qE '(^|[^0-9])431([^0-9]|$)|quota=8192|Request Header' "$1" 2>/dev/null; }
# F3.out 签名：修复前注入链计数偏离规格（gate≠769 或 mesh≠1537），或缺计数行
sig3() {
  local g m
  g=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B' "$1" 2>/dev/null | head -n1 | sed -E 's/trace_in=([0-9]+)B trace_out=([0-9]+)B/\1 \2/' | awk '{print $2-$1}')
  m=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B baggage' "$1" 2>/dev/null | head -n1 | sed -E 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/' | awk '{print $2-$1}')
  [ -z "$g" ] && [ -z "$m" ] && return 1
  [ -n "$g" ] && [ "$g" != "769" ] && return 0
  [ -n "$m" ] && [ "$m" != "1537" ] && return 0
  return 1
}
# F4.out 签名：MESSAGE_TOO_LARGE / produce failed / 原限额 16384
sig4() { grep -qE 'MESSAGE_TOO_LARGE|kafka produce failed|message\.max\.bytes=16384' "$1" 2>/dev/null; }
i=0
for spec in "F1:sig1" "F2:sig2" "F3:sig3" "F4:sig4"; do
  f="${spec%%:*}"; fn="${spec##*:}"
  if [ -x "$RP/$f.sh" ] && [ -s "$RP/$f.sh" ] && [ -s "$RP/$f.out" ] && "$fn" "$RP/$f.out"; then
    ok "结构 repro/$f：脚本可执行 + 修复前取证签名匹配"; S_PASS=$((S_PASS+1))
  else
    fail "结构 repro/$f：脚本缺失/不可执行，或 Fx.out 缺失/无修复前故障签名（须先取证后修复）"
  fi
done
if [ -s "$OPS/diagnosis_report.md" ]; then
  ok "结构 diagnosis_report.md 存在"; S_PASS=$((S_PASS+1))
else
  fail "结构 diagnosis_report.md 缺失或为空"
fi

# ---------- 维度 2：基础修复（/9） ----------
B_PASS=0; B_TOTAL=9
# F1a：nginx 生效单缓冲全部 == params LIM
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
    fail "F1a：生效单缓冲（${CNT} 条，${MINB:-无}~${MAXB:-无}）须全部 == LIM=${LIM:-缺}（随机参数一致性）"
  fi
else
  fail "F1a：evidence/F1_nginx_T.txt 缺失或 params LIM 缺失"
fi
# F1b：双侧边界（LIM−1024 放行 200；LIM+4096 拒绝 400/431）
F1B="$EV/F1_boundary.txt"
LM1=$(( ${LIM:-0} - 1024 )); LP4=$(( ${LIM:-0} + 4096 ))
if [ -s "$F1B" ] && [ -n "$LIM" ]; then
  BELOW_LINE=$(grep "$LM1" "$F1B" | head -n1)
  ABOVE_LINE=$(grep "$LP4" "$F1B" | head -n1)
  if printf '%s' "$BELOW_LINE" | grep -qE '(^|[^0-9])200([^0-9]|$)' \
     && printf '%s' "$ABOVE_LINE" | grep -qE '(^|[^0-9])(400|431|413|49[0-9]|502)([^0-9]|$)'; then
    ok "F1b：双侧边界（LIM−1024 放行 200 / LIM+4096 拒绝）"; B_PASS=$((B_PASS+1))
  else
    fail "F1b：双侧边界证据不成立（below 行=${BELOW_LINE:--} / above 行=${ABOVE_LINE:--}）——LIM−1024 须 200，LIM+4096 须 400/431"
  fi
else
  fail "F1b：evidence/F1_boundary.txt 缺失（自跑探针并记录两侧状态）"
fi
# F2a：端到端 + 响应体特征
F2="$EV/F2_backend_status.txt"
if [ -s "$F2" ]; then
  BB=$(sed -n 's/^backend_big_status=//p' "$F2" | head -n1)
  EB=$(sed -n 's/^entry_big_status=//p' "$F2" | head -n1)
  PB=$(sed -n 's/^profile_body=//p' "$F2" | head -n1)
  if [ "$BB" = "200" ] && [ "$EB" = "200" ] && printf '%s' "$PB" | grep -q '"msg":"ok"'; then
    ok "F2a：入口与直连后端大探针 200 + 响应体特征"; B_PASS=$((B_PASS+1))
  else
    fail "F2a：backend=${BB:-缺}/entry=${EB:-缺}/响应体异常——全链路须打通"
  fi
else
  fail "F2a：evidence/F2_backend_status.txt 缺失"
fi
# F2b：restart all 持久化
F2R="$EV/F2_restart.txt"
if [ -s "$F2R" ] \
   && grep -qE '^post_restart_entry_big_status=200' "$F2R" \
   && grep -qE '^post_restart_backend_big_status=200' "$F2R"; then
  ok "F2b：restart all 后全链路仍 200（持久化自证）"; B_PASS=$((B_PASS+1))
else
  fail "F2b：evidence/F2_restart.txt 缺 post_restart_*_status=200——重启全部服务后须复探并记录"
fi
# F2c：预警双侧标定（THRESH+512 触发 / THRESH−1024 静默；warnings 增量口径）
F2C="$EV/F2_calibration.txt"
if [ -s "$F2C" ] && [ "$THRESH" -gt 0 ] 2>/dev/null; then
  BD=$(sed -n 's/^below_warnings_delta=//p' "$F2C" | head -n1 | tr -dc '0-9')
  AD=$(sed -n 's/^above_warnings_delta=//p' "$F2C" | head -n1 | tr -dc '0-9')
  AM=$(sed -n 's/^above_max_observed=//p' "$F2C" | head -n1 | tr -dc '0-9')
  if [ "$BD" = "0" ] && [ -n "$AD" ] && [ "$AD" -ge 1 ] 2>/dev/null \
     && [ -n "$AM" ] && [ "$AM" -ge "$THRESH" ] 2>/dev/null; then
    ok "F2c：预警双侧标定成立（below 增量 0 / above 增量 ${AD}，观测 ${AM} ≥ THRESH ${THRESH}）"
    B_PASS=$((B_PASS+1))
  else
    fail "F2c：双侧标定不成立（below_delta=${BD:-缺} 须 0；above_delta=${AD:-缺} 须 ≥1 且观测 ${AM:-缺} ≥ THRESH=${THRESH}）"
  fi
else
  fail "F2c：evidence/F2_calibration.txt 缺失或 params 缺失（双侧标定：THRESH=LIM×WARN_RATIO/100）"
fi
# F3：注入链规格恢复 + 回显增幅恰 2306
F3="$EV/F3_span_count.txt"
if [ -s "$F3" ]; then
  G=$(sed -n 's/^gate_trace_delta=//p' "$F3" | head -n1)
  M=$(sed -n 's/^mesh_trace_delta=//p' "$F3" | head -n1)
  BG=$(sed -n 's/^baggage_bytes=//p' "$F3" | head -n1)
  NC=$(sed -n 's/^nonce=//p' "$F3" | head -n1)
  EC=$(sed -n 's/^echo=//p' "$F3" | head -n1)
  GRW=$(( ${#EC} - ${#NC} ))
  if [ "$G" = "769" ] && [ "$M" = "1537" ] && [ "$BG" = "512" ] && [ "$GRW" -eq 2306 ] 2>/dev/null; then
    ok "F3：注入链规格恢复（769/1537/512，回显增幅恰 2306）"; B_PASS=$((B_PASS+1))
  else
    fail "F3：链路计数/回显失真（gate=${G:-缺} mesh=${M:-缺} baggage=${BG:-缺} 增幅=${GRW}——须恰 769/1537/512/2306）"
  fi
else
  fail "F3：evidence/F3_span_count.txt 缺失"
fi
# F4a：broker 静态限额落盘
F4="$EV/F4_kafka_audit.txt"
if [ -s "$F4" ]; then
  ST=$(sed -n 's/^kafka_message_max_bytes_static=//p' "$F4" | head -n1 | grep -oE '[0-9]+' | head -n1)
  if [ -n "$ST" ] && [ "$ST" -gt 16384 ] 2>/dev/null; then
    ok "F4a：broker 静态限额落盘 ${ST} > 16384"; B_PASS=$((B_PASS+1))
  else
    fail "F4a：static=${ST:-缺} 须 >16384（动态调整须同步落盘 server.properties）"
  fi
else
  fail "F4a：evidence/F4_kafka_audit.txt 缺失"
fi
# F4b：broker 重启后新标记事件仍落盘
F4R="$EV/F4_restart.txt"
if [ -s "$F4R" ] && grep -q 'marker=' "$F4R" && grep -qE 'event_seen=(ok|yes|true|1)' "$F4R"; then
  ok "F4b：broker 重启后新标记事件落盘（持久化自证）"; B_PASS=$((B_PASS+1))
else
  fail "F4b：evidence/F4_restart.txt 缺 marker=/event_seen=ok——重启 kafka 后须以新标记探针复证事件落盘"
fi
# F5a：meshd 生效限额 ≥17408（含部署环境覆盖口径）
F5="$EV/F5_meshd_status.txt"
if [ -s "$F5" ]; then
  EFF=$(grep -oE 'effective_limit=[0-9]+' "$F5" | head -n1 | grep -oE '[0-9]+')
  if [ -n "$EFF" ] && [ "$EFF" -ge 17408 ] 2>/dev/null; then
    ok "F5a：meshd 生效限额 ${EFF} ≥ 17408"; B_PASS=$((B_PASS+1))
  else
    fail "F5a：meshd effective_limit=${EFF:-缺} 须 ≥17408（磁盘与部署环境覆盖双口径都以实际生效为准）"
  fi
else
  fail "F5a：evidence/F5_meshd_status.txt 缺失"
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

# ---------- 维度 4：报告质量（/2：引用证据 + 修复前数值咬合） ----------
Q_PASS=0; Q_TOTAL=2
R="$OPS/diagnosis_report.md"
if [ -s "$R" ] && grep -q 'evidence/F' "$R"; then
  ok "报告：引用证据路径"; Q_PASS=$((Q_PASS+1))
else
  fail "报告：未引用 evidence 下证据文件相对路径"
fi
HIT=0
for v in 8192 10240 12288 384 16384; do
  grep -qE "(^|[^0-9])${v}([^0-9]|\$)" "$R" 2>/dev/null && HIT=$((HIT+1))
done
if [ "$HIT" -ge 4 ]; then
  ok "报告：修复前数值咬合（${HIT}/5 个真实故障值出现）"; Q_PASS=$((Q_PASS+1))
else
  fail "报告：修复前数值咬合不足（${HIT}/5——须至少出现 8192/10240/12288/384/16384 中的 4 个真实故障值）"
fi

# ---------- 加权总分 ----------
SCORE=$(awk "BEGIN{printf \"%.4f\", 0.15*$S_PASS/$S_TOTAL + 0.30*$B_PASS/$B_TOTAL + 0.35*$E_PASS/$E_TOTAL + 0.20*$Q_PASS/$Q_TOTAL}")
echo "==================================================================="
echo "[verifier] 结构=$S_PASS/$S_TOTAL 基础=$B_PASS/$B_TOTAL 证据=$E_PASS/$E_TOTAL 报告=$Q_PASS/$Q_TOTAL"

# ---------- CAP：repro 取证全缺 → 封顶 0.45 ----------
REPRO_OK=0
for spec in "F1:sig1" "F2:sig2" "F3:sig3" "F4:sig4"; do
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
  for f in F1 F2 F3 F4; do
    echo "repro/$f.sh=$([ -x "$RP/$f.sh" ] && echo ok || echo no) $f.out=$([ -s "$RP/$f.out" ] && echo ok || echo no)"
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
