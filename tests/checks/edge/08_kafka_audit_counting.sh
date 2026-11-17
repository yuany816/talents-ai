#!/bin/bash
# edge/08 —— 链路计数②（CAP 触发项，证据断言）：kafka 异步审计链路治理——
#   - kafka_message_max_bytes_static：/opt/kafka/config/kraft/server.properties 落盘值
#     不得残留原故障值 16384（动态 alter 不落盘 = 重启回退风险），且须 > 16384；
#   - audit_event_recorded=ok + audit_event_marker：作答环境以一次性标记大探针自证
#     审计事件真实落盘（/var/log/trace_events.log 出现该标记）——审计链路未贯通、
#     事件被瘦身或限额未治理时该自证无法成立。
# schema：kafka_audit.txt（kafka_message_max_bytes / kafka_message_max_bytes_static /
# audit_event_marker / audit_event_recorded）
set -u
. "$(dirname "$0")/../lib.sh"
KF=$(ev_path kafka_audit.txt) || { fail "缺少证据文件 evidence/kafka_audit.txt"; exit 1; }
PASS=1

st=$(ev_get kafka_message_max_bytes_static "$KF")
if [ -n "$st" ] && [ "$st" -gt 16384 ] 2>/dev/null; then
  ok "kafka 静态配置已治理并落盘（message.max.bytes=$st > 16384，防重启回退）"
else
  fail "kafka_message_max_bytes_static=${st:-缺}（须 >16384——静态配置残留原故障值或未落盘）"
  PASS=0
fi
dyn=$(ev_get kafka_message_max_bytes "$KF")
[ -n "$dyn" ] && ok "kafka 动态生效值已记录（message.max.bytes=$dyn）" \
  || { fail "缺 kafka_message_max_bytes 记录"; PASS=0; }

mark=$(ev_get audit_event_marker "$KF")
rec=$(ev_get audit_event_recorded "$KF")
[ -n "$mark" ] || { fail "缺 audit_event_marker 记录（须为一次性标记）"; PASS=0; }
[ "$rec" = "ok" ] && ok "审计事件落盘自证成立（标记 ${mark} 已见于 trace_events.log）" \
  || { fail "audit_event_recorded=${rec:-缺}（须 ok——大探针的审计事件未真实落盘）"; PASS=0; }

[ "$PASS" = "1" ] || exit 1
exit 0
