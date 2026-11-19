#!/bin/bash
# F3 复现：注入链计数（修复前 span_bytes=384 → gate delta≠769）
N="vfy$(date +%s%N)"
curl -s -o /dev/null --max-time 10 -H "X-Trace-Context: $N" http://127.0.0.1:80/api/v1/profile
sleep 1
grep 'GATESTAT' /var/log/tracegate.log | grep 'verdict=PASS' | tail -n1
grep 'MESHSTAT' /var/log/meshd.log | grep 'verdict=PASS' | tail -n1
