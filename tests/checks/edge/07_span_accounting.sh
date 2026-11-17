#!/bin/bash
# edge/07 —— 链路计数维度①（gate/mesh span 注入精确计数）：链路注入量规格
# （gate span 768B / mesh span 1536B / X-Mesh-Baggage 512B，每跳注入增幅 ≈2.9KB）
# 是容量探针数学的前提——缩水（fault）与凭空增大（凑增幅探针）都算不通过：
#   - GATESTAT trace_out − trace_in 必须 == 769（1 分隔符 + 768）；
#   - MESHSTAT trace_out − trace_in 必须 == 1537，baggage 头恰 512B；
#   - /app/tracegate 下 span_bytes 键上下文残留原下调值 384 → 不通过（豁免备份后缀）。
# 判定基于最新一轮真实请求的组件日志计数（verdict=PASS 行）。
set -u
. "$(dirname "$0")/../lib.sh"
PASS=1

# 真实触发一轮请求，保证有本轮的 PASS 计数行
VFY="acct$(date +%s%N)"
curl -s -o /dev/null --max-time 10 -H "X-Trace-Context: $VFY" "$ENTRY/api/v1/profile"
sleep 1

GATE_LINE="$(grep 'GATESTAT' /var/log/tracegate.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
MESH_LINE="$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
[ -n "$GATE_LINE" ] || { fail "tracegate 日志无 GATESTAT PASS 计数行（/var/log/tracegate.log）"; PASS=0; }
[ -n "$MESH_LINE" ] || { fail "meshd 日志无 MESHSTAT PASS 计数行（/var/log/meshd.log）"; PASS=0; }

if [ -n "$GATE_LINE" ]; then
  read -r GIN GOUT <<< "$(printf '%s' "$GATE_LINE" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p')"
  GATE_DELTA=$(( ${GOUT:-0} - ${GIN:-0} ))
  if [ "$GATE_DELTA" = "769" ]; then
    ok "gate span 注入计数精确（trace_out−trace_in=769B，符合规格 768B+分隔符）"
  else
    fail "gate span 注入计数失真（trace_out−trace_in=${GATE_DELTA}B，须恰 769B：规格 768B+1 分隔符——缩水或虚增均不通过）"
    PASS=0
  fi
fi
if [ -n "$MESH_LINE" ]; then
  read -r MIN MOUT MBAG <<< "$(printf '%s' "$MESH_LINE" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B baggage=([0-9]+)B.*/\1 \2 \3/p')"
  MESH_DELTA=$(( ${MOUT:-0} - ${MIN:-0} ))
  if [ "$MESH_DELTA" = "1537" ]; then
    ok "mesh span 注入计数精确（trace_out−trace_in=1537B，符合规格 1536B+分隔符）"
  else
    fail "mesh span 注入计数失真（trace_out−trace_in=${MESH_DELTA}B，须恰 1537B）"
    PASS=0
  fi
  if [ "${MBAG:-0}" = "512" ]; then
    ok "X-Mesh-Baggage 计数符合规格（512B）"
  else
    fail "X-Mesh-Baggage 计数失真（${MBAG:-0}B，须恰 512B）"
    PASS=0
  fi
fi

# 静态残留：span_bytes 键上下文的原下调值（辅助证据，防"只改日志解读不改配置"）
if grep -rqIE 'span_bytes["'"'"':= ]*384([^0-9]|$)' /app/tracegate \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
    --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null; then
  fail "tracegate span_bytes 仍残留原下调值 384（须恢复链路规格 768）"
  PASS=0
fi

[ "$PASS" = "1" ] || exit 1
exit 0
