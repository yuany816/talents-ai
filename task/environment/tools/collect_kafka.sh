#!/bin/bash
# F4 采集（只采集原始数据，不做断言）：broker 限额（动态+静态落盘）、审计事件原始流
set -u
mkdir -p /app/ops/evidence
KAF_STATIC="$(grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties 2>/dev/null | head -n1)"
KAF_DYN="$(timeout 20 /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9092 \
  --entity-type brokers --entity-name 1 --describe 2>/dev/null | grep -oE 'message\.max\.bytes=[0-9]+' | head -n1)"
{
  echo "kafka_message_max_bytes_static=${KAF_STATIC:-unknown}"
  echo "kafka_message_max_bytes_dynamic=${KAF_DYN:-none}"
  echo "--- trace_events.log tail（原始审计事件流）---"
  tail -n 5 /var/log/trace_events.log 2>/dev/null || true
  echo "--- MESSAGE_TOO_LARGE 历史信号（故障期残留，供对照）---"
  grep -c 'MESSAGE_TOO_LARGE\|kafka produce failed' /var/log/backend.log 2>/dev/null || true
} > /app/ops/evidence/F4_kafka_audit.txt
cat /app/ops/evidence/F4_kafka_audit.txt | head -8
