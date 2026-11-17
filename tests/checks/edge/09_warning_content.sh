#!/bin/bash
# edge/09 —— 预警内容实质性核验（证据断言）：交付的 /app/ops/warnings.log 须存在且非空，
# 且至少一条告警行携带 ≥ THRESH 的整数观测值（THRESH = LIM×RATIO/100）——
# 纯文本占位行或小数值伪造行不通过（防 T3c 式空行伪造）。
# 运行时静默/触发窗口在独立判分环境不可复现（无服务），由题面契约披露：本检查只核
# "行有实数"；LIM 缺失时跳过：exit 3（参数缺失由结构/basic/06 判定）。
set -u
. "$(dirname "$0")/../lib.sh"
load_lim || { note "header_limits.env 缺失，跳过预警内容核验"; exit 3; }
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null; then
  note "LIM 缺失/无效，跳过预警内容核验"
  exit 3
fi
[ -n "$RATIO" ] || RATIO=80
THRESH=$(( LIM * RATIO / 100 ))

[ -s "$WARNLOG" ] || { fail "warnings.log 缺失或为空（作答环境未产生任何告警记录）"; exit 1; }

MAXV=0
while IFS= read -r ln; do
  [ -n "$ln" ] || continue
  v=$(printf '%s' "$ln" | grep -oE '[0-9]+' | sort -n | tail -n1)
  [ -n "$v" ] && [ "$v" -gt "$MAXV" ] 2>/dev/null && MAXV=$v
done < "$WARNLOG"
if [ "$MAXV" -ge "$THRESH" ] 2>/dev/null; then
  ok "预警内容核验：告警行携带真实观测值（最大观测数 ${MAXV} ≥ THRESH ${THRESH}）"
  exit 0
fi
fail "预警内容核验：告警行缺 ≥ THRESH(${THRESH}) 的观测值（行内最大数=${MAXV}——空文本/小数值伪造行不通过）"
exit 1
