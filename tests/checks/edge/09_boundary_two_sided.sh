#!/bin/bash
# edge/09 —— 隐蔽边界·双侧夹逼：以声明 LIM 为基准做双侧行为核验——
#   - 下侧：LIM−off 必须通过（200）——余量不足（缓冲恰好卡线）会被误拒；
#   - 上侧：LIM+off 必须被拒绝（非 200）——限额语义保持，调大 ≠ 取消。
# 偏移量每轮随机（{512,1024,1536}），锚定值不可预测——"猜探针"式解法无效；
# 声明一致性（LIM==nginx 生效单缓冲）由 basic/08 锁定，本检查只看行为。
# LIM 缺失/超 1MB 时跳过：exit 3（不计入分母）。
set -u
. "$(dirname "$0")/../lib.sh"
load_lim || { note "header_limits.env 缺失，跳过双侧边界检查"; exit 3; }
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null || [ "$LIM" -gt 1048576 ] 2>/dev/null; then
  note "LIM 缺失/超 1MB，跳过双侧边界检查"
  exit 3
fi

LOW_OFF=$(( 512 + RANDOM % 3 * 512 ))    # 512 / 1024 / 1536
HIGH_OFF=$(( 512 + RANDOM % 3 * 512 ))   # 512 / 1024 / 1536
PASS=1

below=$(( LIM - LOW_OFF )); [ "$below" -lt 1024 ] && below=1024
below_code=$(code_with_header "$ENTRY/api/v1/profile" "$(gen_token "$below")")
if [ "$below_code" = "200" ]; then
  ok "下侧边界：LIM−${LOW_OFF}=${below}B 探针通过（status=200，无卡线误拒）"
else
  fail "下侧边界：LIM−${LOW_OFF}=${below}B 探针被误拒（status=$below_code）——限额口径与余量不足"
  PASS=0
fi

above=$(( LIM + HIGH_OFF ))
above_code=$(code_with_header "$ENTRY/api/v1/profile" "$(gen_token "$above")")
case "$above_code" in
  200|000) fail "上侧边界：LIM+${HIGH_OFF}=${above}B 探针未被拒绝（status=$above_code）"; PASS=0 ;;
  *)       ok "上侧边界：LIM+${HIGH_OFF}=${above}B 探针仍被拒绝（status=$above_code）" ;;
esac

[ "$PASS" = "1" ] || exit 1
exit 0
