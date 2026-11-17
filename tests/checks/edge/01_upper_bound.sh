#!/bin/bash
# edge/01 —— 3) 上边界（证据断言）：evidence/upper_boundary.txt 记录的 LIM+off 探针
# 必须仍被拒绝（限额语义保持，调大 ≠ 取消；400/413/431 均算拒绝）。
# LIM 缺失或 >1MB 时跳过：exit 3（不计入该维度分母；声明缺失由 basic/06 与结构维度扣分）。
# schema：declared_lim / above_probe_bytes / above_status
set -u
. "$(dirname "$0")/../lib.sh"
load_lim || { note "header_limits.env 缺失，跳过上边界检查"; exit 3; }
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null || [ "$LIM" -gt 1048576 ] 2>/dev/null; then
  note "LIM 缺失/超 1MB，跳过上边界检查"
  exit 3
fi
UB=$(ev_path upper_boundary.txt) || { fail "缺少证据文件 evidence/upper_boundary.txt"; exit 1; }

declared=$(ev_get declared_lim "$UB")
[ -n "$declared" ] && [ "$declared" -eq "$LIM" ] 2>/dev/null \
  || { fail "upper_boundary.txt 的 declared_lim(${declared:-缺}) 与 header_limits.env LIM(${LIM}) 不一致"; exit 1; }

above=$(ev_get above_probe_bytes "$UB")
if [ -z "$above" ] || [ "$above" -le "$LIM" ] 2>/dev/null; then
  fail "above_probe_bytes(${above:-缺}) 须 > declared_lim(${LIM})——探针必须越过声明上限"
  exit 1
fi
over_status=$(ev_get above_status "$UB")
case "$over_status" in
  200|"") fail "超上限请求未被拒绝（above_status=${over_status:-缺}，探针 ${above}B）"; exit 1 ;;
  *)      ok "超上限请求仍被拒绝（above_status=$over_status，探针 ${above}B > LIM ${LIM}B）"; exit 0 ;;
esac
