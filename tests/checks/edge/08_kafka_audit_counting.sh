#!/bin/bash
# edge/08 —— 链路计数维度②（kafka 异步审计事件计数）：审计事件携带全量请求头快照，
# broker 侧 message.max.bytes 过小（原故障值 16384）时以 MESSAGE_TOO_LARGE 拒绝——
# 大探针的审计事件必须真实落盘（trace-collector 消费 → /var/log/trace_events.log）：
#   - 行为判定：发送带一次性标记的大探针（锚定值按声明 LIM 自适应且随机化），
#     45s 内 /var/log/trace_events.log 必须出现该标记的事件（审计链路真实贯通）；
#   - 静态残留：/opt/kafka/config/kraft/server.properties 的 message.max.bytes=16384
#     → 不通过（只动态 alter 不落盘的方案重启即回退，属残留风险）。
# 探针取值窗口 (16384+overhead, LIM)：须越过 broker 原限额、又不得越过声明上限。
set -u
. "$(dirname "$0")/../lib.sh"
PASS=1
EVENT_LOG=/var/log/trace_events.log
KAF_STATIC=/opt/kafka/config/kraft/server.properties

# 探针锚定值自适应 + 随机化：min(LIM−256, 32768)，LIM 缺失时按 24576 兜底
# （仍高于 broker 原故障值 16384；nginx 未扩容时大探针本就到不了后端，事件缺失照判）。
load_lim && [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] 2>/dev/null || LIM=""
if [ -n "$LIM" ]; then
  PROBE_K=$(( LIM - 256 )); [ "$PROBE_K" -gt 32768 ] && PROBE_K=32768
else
  PROBE_K=24576
fi
[ "$PROBE_K" -gt 16896 ] || PROBE_K=16896

MARK="kaf$(date +%s%N)"
pbig="$(gen_token "$PROBE_K")"
before=$(grep -c "$MARK" "$EVENT_LOG" 2>/dev/null || echo 0)
curl -s -o /dev/null --max-time 15 -H "X-Verify-Token: $pbig" -H "X-Case-Marker: $MARK" "$ENTRY/api/v1/profile"

hit=0
for i in $(seq 1 9); do
  sleep 5
  now=$(grep -c "$MARK" "$EVENT_LOG" 2>/dev/null || echo 0)
  if [ "$now" -gt "$before" ]; then hit=1; break; fi
done
if [ "$hit" = "1" ]; then
  ok "kafka 审计计数：大探针（${PROBE_K}B，标记 $MARK）的审计事件已落盘（${EVENT_LOG}）"
else
  fail "kafka 审计计数：45s 内未见大探针（${PROBE_K}B）的审计事件——broker 限额未治理（MESSAGE_TOO_LARGE）或审计链路被裁剪"
  PASS=0
fi

# 静态残留：broker 静态配置中的原故障值（动态 alter 不落盘 = 重启回退风险）
if [ -f "$KAF_STATIC" ] && grep -qE '^message\.max\.bytes[[:space:]]*=[[:space:]]*16384([^0-9]|$)' "$KAF_STATIC" 2>/dev/null; then
  fail "kafka 静态配置仍残留原故障值 message.max.bytes=16384（动态调整须同步落盘，防重启回退）"
  PASS=0
fi

[ "$PASS" = "1" ] || exit 1
exit 0
