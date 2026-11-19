#!/bin/bash
# F4 复现：审计旁路容量信号（修复前 MESSAGE_TOO_LARGE / broker 限额 16384）
grep -c 'kafka produce failed' /var/log/backend.log 2>/dev/null || true
grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties
