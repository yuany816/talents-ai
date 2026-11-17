#!/bin/bash
# =============================================================================
# 431 任务验题脚本（平台 tests/test.sh）—— 4 面 / 2 阶段 加权部分分（独立判分）
#
# 判分环境为 tests/Dockerfile 镜像（environment_mode="separate"）：无 nginx/go/kafka
# 服务，不发实时探针——全部判定读取交付目录 /app/ops/（task.toml artifacts）。
#
# reward = 0.15×结构 + 0.30×基础修复 + 0.35×证据齐全 + 0.20×报告质量
#
#   structure（/5）：repro/F1.sh~F4.sh 四个可执行复现脚本 + diagnosis_report.md 存在
#     ——模型先交复现即可拿基础分（阶段 1）；
#   basic（/4，每面修复是否可验证）：
#     F1 nginx_T 生效单缓冲**全部等于 params.env 的 LIM**（随机参数一致性——硬编码
#       固定值直接不通过）；F2 端到端大探针 200（经全链路，meshd 限额必须同时打通）；
#     F3 注入链规格恢复（gate 769 / mesh 1537 / baggage 512 精确）；
#     F4 broker 限额治理落盘（static > 16384）；
#   edge（/4，证据齐全度）：evidence/ 下每面至少一个文件；
#   quality（1）：诊断报告引用了 evidence 下证据文件相对路径。
#
# CAP：repro 四脚本全缺 → 总分封顶 0.45（交付空心）。
# reward.txt 启动即落 0.0000 兜底（/app/ops 缺失立即以 0 退出），结束覆盖写；
# 诊断写 /logs/verifier/debug.txt。依赖：bash/coreutils/grep/awk/sed（tests/Dockerfile）。
# =============================================================================
export LC_ALL=C
set -u

REWARD_FILE="/logs/verifier/reward.txt"
DEBUG_FILE="/logs/verifier/debug.txt"
OPS="/app/ops"
EV="$OPS/evidence"
mkdir -p /logs/verifier 2>/dev/null || true

ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; }

printf '%s\n' "0.0000" > "$REWARD_FILE"
: > "$DEBUG_FILE"
[ -d "$OPS" ] || { echo "ops_dir=missing（空作答）" >> "$DEBUG_FILE"; exit 0; }
echo "ops_dir=present" >> "$DEBUG_FILE"

# ---------- params.env（trial 随机容量参数——硬编码扣分的锚定基准） ----------
LIM=""; RATIO=""
[ -f "$OPS/params.env" ] && {
  LIM=$(sed -n 's/^LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
}
echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing}" >> "$DEBUG_FILE"

# ---------- 维度 1：结构（/5：4 个 repro 可执行 + 报告存在） ----------
S_PASS=0; S_TOTAL=5
for f in F1 F2 F3 F4; do
  if [ -x "$OPS/repro/${f}.sh" ] && [ -s "$OPS/repro/${f}.sh" ]; then
    ok "结构 repro/${f}.sh 存在且可执行"; S_PASS=$((S_PASS+1))
  else
    fail "结构 repro/${f}.sh 缺失/不可执行/为空（阶段 1：复现脚本）"
  fi
done
if [ -s "$OPS/diagnosis_report.md" ]; then
  ok "结构 diagnosis_report.md 存在"; S_PASS=$((S_PASS+1))
else
  fail "结构 diagnosis_report.md 缺失或为空"
fi

# ---------- 维度 2：基础（/4，每面修复是否可验证） ----------
B_PASS=0; B_TOTAL=4
# F1：nginx 生效单缓冲全部 == params LIM（随机参数一致性；多条指令须取值一致）
NT="$EV/F1_nginx_T.txt"
if [ -s "$NT" ] && [ -n "$LIM" ]; then
  MINB=""; MAXB=""; CNT=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    b=$(printf '%s' "$v" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
    case "$b" in ''|*[!0-9]*) continue ;; esac
    CNT=$((CNT+1))
    if [ -z "$MINB" ] || [ "$b" -lt "$MINB" ]; then MINB=$b; fi
    if [ -z "$MAXB" ] || [ "$b" -gt "$MAXB" ]; then MAXB=$b; fi
  done < <(grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' "$NT" 2>/dev/null | sed -E 's/#.*//; s/;.*//' | awk '{print $3}')
  if [ "$CNT" -ge 1 ] && [ "$MINB" = "$MAXB" ] && [ "$LIM" -eq "$MINB" ] 2>/dev/null; then
    ok "F1：nginx 生效单缓冲全部 == params LIM（${CNT} 条指令 = ${MINB}B，随机参数一致）"
    B_PASS=$((B_PASS+1))
  else
    fail "F1：nginx 生效单缓冲（${CNT} 条，${MINB:-无}~${MAXB:-无}B）须全部 == params.env LIM=${LIM:-缺}——硬编码固定值不通过"
  fi
else
  fail "F1：evidence/F1_nginx_T.txt 缺失或 params.env LIM 缺失，无法核验生效配置"
fi
# F2：端到端大探针 200（经全链路）+ 响应体特征
F2="$EV/F2_backend_status.txt"
if [ -s "$F2" ]; then
  BB=$(sed -n 's/^backend_big_status=//p' "$F2" | head -n1)
  EB=$(sed -n 's/^entry_big_status=//p' "$F2" | head -n1)
  PB=$(sed -n 's/^profile_body=//p' "$F2" | head -n1)
  if [ "$BB" = "200" ] && [ "$EB" = "200" ] && printf '%s' "$PB" | grep -q '"msg":"ok"'; then
    ok "F2：入口与直连后端大探针均 200，响应体特征正确（全链路打通）"
    B_PASS=$((B_PASS+1))
  else
    fail "F2：backend_big_status=${BB:-缺} / entry_big_status=${EB:-缺} / 响应体异常——全链路（含 mesh 限额）须打通且 200"
  fi
else
  fail "F2：evidence/F2_backend_status.txt 缺失（运行 bash /app/tools/collect_backend.sh）"
fi
# F3：注入链规格恢复（gate 769 / mesh 1537 / baggage 512 精确——缩水与虚增均不通过）
F3="$EV/F3_span_count.txt"
if [ -s "$F3" ]; then
  G=$(sed -n 's/^gate_trace_delta=//p' "$F3" | head -n1)
  M=$(sed -n 's/^mesh_trace_delta=//p' "$F3" | head -n1)
  BG=$(sed -n 's/^baggage_bytes=//p' "$F3" | head -n1)
  if [ "$G" = "769" ] && [ "$M" = "1537" ] && [ "$BG" = "512" ]; then
    ok "F3：注入链规格恢复（gate 769 / mesh 1537 / baggage 512 精确）"
    B_PASS=$((B_PASS+1))
  else
    fail "F3：链路计数失真（gate=${G:-缺}/mesh=${M:-缺}/baggage=${BG:-缺}，须恰 769/1537/512——span 规格未恢复或虚增）"
  fi
else
  fail "F3：evidence/F3_span_count.txt 缺失（运行 bash /app/tools/collect_trace.sh）"
fi
# F4：broker 限额治理落盘（static > 16384，防重启回退）
F4="$EV/F4_kafka_audit.txt"
if [ -s "$F4" ]; then
  ST=$(sed -n 's/^kafka_message_max_bytes_static=//p' "$F4" | head -n1 | grep -oE '[0-9]+' | head -n1)
  if [ -n "$ST" ] && [ "$ST" -gt 16384 ] 2>/dev/null; then
    ok "F4：broker 静态限额已治理落盘（message.max.bytes=$ST > 16384）"
    B_PASS=$((B_PASS+1))
  else
    fail "F4：kafka_message_max_bytes_static=${ST:-缺}（须 >16384——限额未治理或未落盘 server.properties）"
  fi
else
  fail "F4：evidence/F4_kafka_audit.txt 缺失（运行 bash /app/tools/collect_kafka.sh）"
fi

# ---------- 维度 3：证据齐全（/4，每面至少一个文件） ----------
E_PASS=0; E_TOTAL=4
for f in F1 F2 F3 F4; do
  if ls "$EV/${f}_"* >/dev/null 2>&1; then
    ok "证据 ${f}_* 存在"; E_PASS=$((E_PASS+1))
  else
    fail "证据 ${f}_* 缺失（evidence/ 下须有该面的采集文件）"
  fi
done

# ---------- 维度 4：报告质量（引用证据路径） ----------
Q_PASS=0; Q_TOTAL=1
R="$OPS/diagnosis_report.md"
if [ -s "$R" ] && grep -q 'evidence/F' "$R"; then
  ok "报告：引用了 evidence 证据路径"; Q_PASS=$((Q_PASS+1))
else
  fail "报告：未引用 evidence 下证据文件相对路径（每面三行：根因/证据/前后数值）"
fi

# ---------- 加权总分 ----------
SCORE=$(awk "BEGIN{printf \"%.4f\", 0.15*$S_PASS/$S_TOTAL + 0.30*$B_PASS/$B_TOTAL + 0.35*$E_PASS/$E_TOTAL + 0.20*$Q_PASS/$Q_TOTAL}")
echo "==================================================================="
echo "[verifier] 结构 structure=$S_PASS/$S_TOTAL  基础 basic=$B_PASS/$B_TOTAL  证据 edge=$E_PASS/$E_TOTAL  报告 quality=$Q_PASS/$Q_TOTAL"

# ---------- CAP：repro 完全为空 → 封顶 0.45 ----------
REPRO_COUNT=0
for f in F1 F2 F3 F4; do
  [ -x "$OPS/repro/${f}.sh" ] && [ -s "$OPS/repro/${f}.sh" ] && REPRO_COUNT=$((REPRO_COUNT+1))
done
CAP_NOTE="none"
if [ "$REPRO_COUNT" -eq 0 ]; then
  SCORE=$(awk "BEGIN{printf \"%.4f\", ($SCORE < 0.45 ? $SCORE : 0.45)}")
  CAP_NOTE="repro 全缺 → 封顶 0.4500"
  echo "[verifier] CAP：repro 四脚本全缺，reward 封顶 0.4500"
fi

# ---------- debug.txt ----------
{
  echo "=== delivery ==="
  echo "ops_dir=present"
  for f in F1 F2 F3 F4; do
    echo "repro/$f.sh exists=$([ -s "$OPS/repro/$f.sh" ] && echo yes || echo no) executable=$([ -x "$OPS/repro/$f.sh" ] && echo yes || echo no)"
  done
  echo "diagnosis_report.md exists=$([ -s "$R" ] && echo yes || echo no)"
  for f in "$EV"/*; do [ -f "$f" ] && echo "evidence/$(basename "$f") exists=yes"; done
  echo "=== dimensions ==="
  echo "structure=$S_PASS/$S_TOTAL"
  echo "basic=$B_PASS/$B_TOTAL"
  echo "edge=$E_PASS/$E_TOTAL"
  echo "quality=$Q_PASS/$Q_TOTAL"
  echo "repro_count=$REPRO_COUNT"
  echo "score=$SCORE"
} > "$DEBUG_FILE"

printf '%s\n' "$SCORE" > "$REWARD_FILE"
echo "[verifier] reward=$SCORE → $REWARD_FILE（诊断 → $DEBUG_FILE）"
exit 0
