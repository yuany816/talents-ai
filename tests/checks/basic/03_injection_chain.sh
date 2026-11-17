#!/bin/bash
# basic/03 —— 1) 注入链完整性（防"绕过中间层直连下游"与"静态伪造注入段"式伪修复）：
# 验题注入一次性 nonce，后端回显的 X-Trace-Context 须按序包含 nonce→gate=→mesh=
# （真实注入为顺序追加），且回显值较 nonce 增幅 ≥2048B（gate/mesh span 真实落头）。
set -u
. "$(dirname "$0")/lib.sh"
PASS=1
VFY="vfy$(date +%s%N)"
tc_val=$(curl -s -D - -o /dev/null --max-time 10 -H "X-Trace-Context: $VFY" "$ENTRY/api/v1/profile" \
  | grep -i '^x-trace-context:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')
case "$tc_val" in
  *"$VFY"*"gate="*"mesh="*) ok "注入链完整（X-Trace-Context 回显 nonce→gate→mesh 有序追加）" ;;
  *) fail "注入链不完整或伪造（回显缺 nonce/gate=/mesh= 有序段——疑似绕过中间层）"; PASS=0 ;;
esac
if [ "${#tc_val}" -ge $(( ${#VFY} + 2048 )) ]; then
  ok "注入链增幅达标（回显 ${#tc_val}B，span 追加 ≥2048B）"
else
  fail "注入链增幅不足（回显 ${#tc_val}B，gate/mesh span 未真实落头）"
  PASS=0
fi
[ "$PASS" = "1" ] || exit 1
exit 0
