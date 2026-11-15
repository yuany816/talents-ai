#!/bin/bash
# Kafka 启动封装（supervisord 托管）：确保存储已格式化（幂等）后前台启动 broker。
# exec 使 JVM 成为被托管进程本体，信号可达。
set -eu
/opt/kafka/bin/kafka-storage.sh format \
  -t 4L6g3nShT-eMCtK--X-Xsw \
  -c /opt/kafka/config/kraft/server.properties --ignore-formatted
exec /opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/kraft/server.properties
