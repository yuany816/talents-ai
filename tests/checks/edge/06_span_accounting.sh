#!/bin/bash
# edge/06 —— 链路计数①（CAP 触发项，证据断言）：链路注入量规格（gate span 768B /
# mesh span 1536B / X-Mesh-Baggage 512B）是容量探针数学的前提——缩水与凭空增大都判不通过。
# evidence/span_count.txt 记录逐层精确计数与 nonce 回显：
#   gate_trace_delta==769（768+分隔符）、mesh_trace_delta==1537、baggage_bytes==512；
#   且回显增幅（${#echo}−${#nonce}）必须恰 == 769+1537=2306——逐层计数与端到端回显
#   两口径互相咬合（伪造或局部篡改任一记录即失配）。
set -u
. "$(dirname "$0")/../lib.sh"
SP=$(ev_path span_count.txt) || { fail "缺少证据文件 evidence/span_count.txt"; exit 1; }
PASS=1

nonce=$(ev_get nonce "$SP"); echo_val=$(ev_get echo "$SP")
[ -n "$nonce" ] && [ -n "$echo_val" ] || { fail "span_count.txt 缺 nonce/echo 记录"; exit 1; }

g=$(ev_get gate_trace_delta "$SP")
[ "$g" = "769" ] && ok "gate span 注入计数精确（trace_out−trace_in=769B = 768B+分隔符）" \
  || { fail "gate_trace_delta=${g:-缺}，须恰 769（规格 768B+1 分隔符——缩水或虚增均不通过）"; PASS=0; }

m=$(ev_get mesh_trace_delta "$SP")
[ "$m" = "1537" ] && ok "mesh span 注入计数精确（trace_out−trace_in=1537B = 1536B+分隔符）" \
  || { fail "mesh_trace_delta=${m:-缺}，须恰 1537"; PASS=0; }

b=$(ev_get baggage_bytes "$SP")
[ "$b" = "512" ] && ok "X-Mesh-Baggage 计数符合规格（512B）" \
  || { fail "baggage_bytes=${b:-缺}，须恰 512"; PASS=0; }

growth=$(( ${#echo_val} - ${#nonce} ))
if [ "$growth" -eq 2306 ]; then
  ok "端到端回显增幅与逐层计数咬合（echo−nonce=${growth}B == 769+1537）"
else
  fail "回显增幅失真（echo−nonce=${growth}B，须恰 2306 = gate 769 + mesh 1537——记录互相矛盾或规格被改）"
  PASS=0
fi

[ "$PASS" = "1" ] || exit 1
exit 0
