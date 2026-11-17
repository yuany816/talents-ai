#!/bin/bash
# edge/10 —— 预警内容实质性核验：warnings.log 的新增告警行必须携带真实观测字节数——
# 行内须含 ≥ THRESH 的整数（观测到的请求体量），纯文本占位行或小数值伪造行不通过。
# 探针偏移随机化（THRESH+{512,768,1024}，封顶 LIM−1024）——锚定值不可预测。
# 行数增加本身由 edge/06 判定；本检查核"行有实数"（防 T3c 式空行伪造通过行数检查）。
# LIM 缺失时跳过：exit 3（参数缺失由结构/basic/08 与 edge/05 判定）。
set -u
. "$(dirname "$0")/../lib.sh"
ensure_ops_dir
load_lim || { note "header_limits.env 缺失，跳过预警内容核验"; exit 3; }
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null; then
  note "LIM 缺失/无效，跳过预警内容核验"
  exit 3
fi
RATIO="$([ -n "$RATIO" ] && echo "$RATIO" || echo 80)"
THRESH=$(( LIM * RATIO / 100 ))

OFF=$(( 512 + RANDOM % 3 * 256 ))        # 512 / 768 / 1024
PROBE3=$(( THRESH + OFF )); CAP=$(( LIM - 1024 )); [ "$PROBE3" -gt "$CAP" ] && PROBE3=$CAP

before=$(wc -l < "$WARNLOG" 2>/dev/null || echo 0)
curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $(gen_token "$PROBE3")" "$ENTRY/api/v1/profile"

new_lines=""
for i in $(seq 1 7); do
  sleep 3
  now=$(wc -l < "$WARNLOG" 2>/dev/null || echo 0)
  if [ "$now" -gt "$before" ]; then
    new_lines=$(tail -n +"$(( before + 1 ))" "$WARNLOG" 2>/dev/null)
    break
  fi
done
if [ -z "$new_lines" ]; then
  fail "预警内容核验：20s 内未产生新告警行（THRESH=${THRESH}B，探针 ${PROBE3}B）"
  exit 1
fi

# 每条新行须含 ≥ THRESH 的整数（观测字节数）；无数字或数字偏小均判伪造/观测不实
MAXV=0
while IFS= read -r ln; do
  v=$(printf '%s' "$ln" | grep -oE '[0-9]+' | sort -n | tail -n1)
  [ -n "$v" ] && [ "$v" -gt "$MAXV" ] 2>/dev/null && MAXV=$v
done <<< "$new_lines"
if [ "$MAXV" -ge "$THRESH" ] 2>/dev/null; then
  ok "预警内容核验：新告警行携带真实观测值（最大观测数 ${MAXV} ≥ THRESH ${THRESH}）"
  exit 0
fi
fail "预警内容核验：告警行缺真实观测值（行内最大数=${MAXV}，须 ≥ THRESH=${THRESH}——空文本/小数值伪造行不通过）"
exit 1
