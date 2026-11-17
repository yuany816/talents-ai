#!/bin/bash
# edge/09 —— 隐蔽边界·双侧夹逼（证据断言）：以声明 LIM 为基准的双侧行为核验——
#   - 下侧：LIM−off 探针（off ∈ {512,1024,1536}，且 ≥16384 保证是真实 16KB 级请求）
#     必须 200——余量不足（缓冲恰好卡线）会被误拒；
#   - 上侧：LIM+off 探针必须被拒绝（非 200、非无响应）。
# declared_lim 与 header_limits.env 的一致性由 basic/06 锁定，本检查只看行为记录。
# schema：upper_boundary.txt（below_probe_bytes/below_status/above_probe_bytes/above_status）
# LIM 缺失/超 1MB 时跳过：exit 3（不计入分母）。
set -u
. "$(dirname "$0")/../lib.sh"
load_lim || { note "header_limits.env 缺失，跳过双侧边界检查"; exit 3; }
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null || [ "$LIM" -gt 1048576 ] 2>/dev/null; then
  note "LIM 缺失/超 1MB，跳过双侧边界检查"
  exit 3
fi
UB=$(ev_path upper_boundary.txt) || { fail "缺少证据文件 evidence/upper_boundary.txt"; exit 1; }
PASS=1

below=$(ev_get below_probe_bytes "$UB"); below_status=$(ev_get below_status "$UB")
if [ -n "$below" ] && [ "$below" -ge 16384 ] 2>/dev/null && [ "$below" -lt "$LIM" ] 2>/dev/null; then
  if [ "$below_status" = "200" ]; then
    ok "下侧边界：LIM 下探针 ${below}B 通过（status=200，无卡线误拒）"
  else
    fail "下侧边界：LIM 下探针 ${below}B 被误拒（status=${below_status:-缺}）——限额口径与余量不足"
    PASS=0
  fi
else
  fail "below_probe_bytes=${below:-缺} 须 ∈ [16384, LIM=${LIM})——下侧探针未按口径记录"
  PASS=0
fi

above=$(ev_get above_probe_bytes "$UB"); above_status=$(ev_get above_status "$UB")
if [ -n "$above" ] && [ "$above" -gt "$LIM" ] 2>/dev/null; then
  case "$above_status" in
    200|"") fail "上侧边界：LIM 上探针 ${above}B 未被拒绝（status=${above_status:-缺}）"; PASS=0 ;;
    *)      ok "上侧边界：LIM 上探针 ${above}B 仍被拒绝（status=$above_status）" ;;
  esac
else
  fail "above_probe_bytes=${above:-缺} 须 > LIM=${LIM}"
  PASS=0
fi

[ "$PASS" = "1" ] || exit 1
exit 0
