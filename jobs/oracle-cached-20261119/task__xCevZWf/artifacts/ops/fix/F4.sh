#!/bin/bash
# F4 修复：broker 限额动态生效 + 静态落盘
KAF_MAX=1048576
kafka-configs() { /opt/kafka/bin/kafka-configs.sh "$@"; }
timeout 30 kafka-configs --bootstrap-server 127.0.0.1:9092 --entity-type brokers --entity-name 1 \
  --alter --add-config "message.max.bytes=${KAF_MAX}"
sed -i -E "s/^(message\.max\.bytes=)[0-9]+/\1${KAF_MAX}/" /opt/kafka/config/kraft/server.properties
