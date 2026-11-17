#!/bin/bash
# edge/06 —— 5) 预警观测·告警检查：发送 THRESH+512 字节探针两次（立即一次、约 9 秒后
# 一次），30s 内 warnings.log 行数必须增加（即 $request_length ≥ THRESH 的请求必须被
# 观测到）。THRESH = LIM×RATIO/100；RATIO∈[50,90] 保证探针越过阈值且不越过上限
# （范围越界已在 edge/05 判定，此处仅按 80 兜底计算）。
set -u
. "$(dirname "$0")/../lib.sh"
ensure_ops_dir
[ -f "$LIMENV" ] || { fail "缺少预警参数文件 $LIMENV"; exit 1; }
LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
if [ "$RATIO" -lt 50 ] 2>/dev/null || [ "$RATIO" -gt 90 ] 2>/dev/null; then
  note "WARN_RATIO=$RATIO 越界（edge/05 已判定），按 80 计算探针"
  RATIO=80
fi
if [ -z "$LIM" ] || [ "$LIM" -le 4096 ] 2>/dev/null; then
  fail "header_limits.env 缺少 NGINX_LARGE_HEADER_BUFFER_BYTES（或值 ≤ 4096）"
  exit 1
fi
THRESH=$(( LIM * RATIO / 100 ))
PROBE2=$(( THRESH + 512 )); CAP=$(( LIM - 1024 )); [ "$PROBE2" -gt "$CAP" ] && PROBE2=$CAP
mid=$(wc -l < "$WARNLOG" 2>/dev/null || echo 0)
p2=$(gen_token "$PROBE2")
curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $p2" "$ENTRY/api/v1/profile"
hit=0
for i in $(seq 1 10); do
  sleep 3
  after=$(wc -l < "$WARNLOG" 2>/dev/null || echo 0)
  if [ "$after" -gt "$mid" ]; then hit=1; break; fi
  if [ "$i" = "3" ]; then
    curl -s -o /dev/null --max-time 10 -H "X-Verify-Token: $p2" "$ENTRY/api/v1/profile"
  fi
done
if [ "$hit" = "1" ]; then
  ok "预警观测：接近阈值请求已产生告警（${PROBE2}B ≥ ${THRESH}B）"
  exit 0
fi
fail "预警观测：30s 内未产生告警"
exit 1
