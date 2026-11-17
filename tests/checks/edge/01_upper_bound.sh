#!/bin/bash
# edge/01 —— 3) 上边界：发送 LIM+4096 字节探针，必须仍被拒绝（限额语义保持，调大 ≠ 取消；
# 400/413/431 均算拒绝）。LIM 缺失或 >1MB 时跳过：exit 3（编排器不计入该维度分母，
# 不产生白送通过分；声明缺失由 basic/08 与结构维度扣分）。
set -u
. "$(dirname "$0")/../lib.sh"
load_lim || { note "header_limits.env 缺失，跳过上边界检查"; exit 3; }
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null || [ "$LIM" -gt 1048576 ] 2>/dev/null; then
  note "LIM 缺失/超 1MB，跳过上边界检查"
  exit 3
fi
# 探针锚定值随机化：越界偏移每轮取 {2048,4096,8192} 之一——固定值猜测无效
UPPER_OFF=$(( 2048 + RANDOM % 3 * 3072 ))
over=$(( LIM + UPPER_OFF ))
obig=$(gen_token "$over")
over_code=$(code_with_header "$ENTRY/api/v1/profile" "$obig")
case "$over_code" in
  200|000) fail "超上限请求未被拒绝（status=$over_code，LIM+${UPPER_OFF}）"; exit 1 ;;
  *)       ok "超上限请求仍被拒绝（status=$over_code，LIM+${UPPER_OFF}）"; exit 0 ;;
esac
