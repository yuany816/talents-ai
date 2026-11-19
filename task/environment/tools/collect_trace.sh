#!/bin/bash
# F3 采集（只采集原始数据，不做断言）：真实触发一轮链路请求，抓取最新的
# GATESTAT/MESHSTAT PASS 计数行与注入链回显原始值
set -u
mkdir -p /app/ops/evidence
ENTRY=http://127.0.0.1:80
NONCE="vfy$(date +%s%N)"
ECHO_VAL="$(curl -s -D - -o /dev/null --max-time 15 -H "X-Trace-Context: $NONCE" "$ENTRY/api/v1/profile" 2>/dev/null \
  | grep -i '^x-trace-context:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
sleep 1
GL="$(grep 'GATESTAT' /var/log/tracegate.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
ML="$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
read -r GI GO <<< "$(printf '%s' "$GL" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p')"
read -r MI MO MBAG <<< "$(printf '%s' "$ML" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B baggage=([0-9]+)B.*/\1 \2 \3/p')"
{
  echo "gate_trace_delta=$(( ${GO:-0} - ${GI:-0} ))"
  echo "mesh_trace_delta=$(( ${MO:-0} - ${MI:-0} ))"
  echo "baggage_bytes=${MBAG:-0}"
  echo "nonce=${NONCE}"
  echo "echo=${ECHO_VAL}"
  echo "gatestat_raw=${GL}"
  echo "meshstat_raw=${ML}"
} > /app/ops/evidence/F3_span_count.txt
cat /app/ops/evidence/F3_span_count.txt | sed 's/echo=.\{80\}.*/echo=…/'
