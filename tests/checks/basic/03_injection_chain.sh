#!/bin/bash
# basic/03 —— 1) 注入链完整性（CAP 触发项，证据断言）：span_count.txt 记录的一次性 nonce
# 探针——回显的 X-Trace-Context 须按序包含 nonce→gate=→mesh=（真实注入为顺序追加），
# 且回显值较 nonce 增幅 ≥2048B（gate/mesh span 真实落头）。绕层/静态伪造无法满足有序段。
# schema：nonce=… / echo=…（回显完整头值）
set -u
. "$(dirname "$0")/../lib.sh"
SP=$(ev_path span_count.txt) || { fail "缺少证据文件 evidence/span_count.txt"; exit 1; }

nonce=$(ev_get nonce "$SP")
echo_val=$(ev_get echo "$SP")
[ -n "$nonce" ] || { fail "span_count.txt 缺 nonce 记录"; exit 1; }
[ -n "$echo_val" ] || { fail "span_count.txt 缺 echo 记录"; exit 1; }

case "$echo_val" in
  *"$nonce"*"gate="*"mesh="*) ok "注入链完整（回显 nonce→gate→mesh 有序追加）" ;;
  *) fail "注入链不完整或伪造（回显缺 nonce/gate=/mesh= 有序段——疑似绕过中间层）"; exit 1 ;;
esac
growth=$(( ${#echo_val} - ${#nonce} ))
if [ "$growth" -ge 2048 ]; then
  ok "注入链增幅达标（回显较 nonce 增幅 ${growth}B ≥ 2048B）"
  exit 0
fi
fail "注入链增幅不足（增幅 ${growth}B < 2048B——gate/mesh span 未真实落头）"
exit 1
