#!/bin/bash
# basic/01 —— 0) 环境在线：入口/后端可达；中间层组件指纹；kafka 探活（3×2s 重试，容 JVM 慢启）
# 组件为环境组成部分（防"删除组件降噪"与端口占位桩）。
set -u
. "$(dirname "$0")/../lib.sh"
PASS=1
curl -s -o /dev/null --max-time 5 "$ENTRY/" || { fail "入口不可达"; PASS=0; }
curl -s -o /dev/null --max-time 5 "$UP/" || { fail "后端不可达"; PASS=0; }
curl -s -o /dev/null --max-time 5 "$TG/componentz" || { fail "tracegate(9100) 不可达"; PASS=0; }
curl -s -o /dev/null --max-time 5 "$MS/componentz" || { fail "meshd(15001) 不可达"; PASS=0; }
curl -s --max-time 5 "$TG/componentz" | grep -q '"tracegate"' \
  && ok "tracegate(9100) 组件指纹匹配" || { fail "9100 非预期服务（缺 tracegate 组件指纹）"; PASS=0; }
curl -s --max-time 5 "$MS/componentz" | grep -q '"meshd"' \
  && ok "meshd(15001) 组件指纹匹配" || { fail "15001 非预期服务（缺 meshd 组件指纹）"; PASS=0; }
kafka_ok=0
for _ in 1 2 3; do
  if timeout 3 bash -c 'exec 3<> /dev/tcp/127.0.0.1/9092' 2>/dev/null; then kafka_ok=1; break; fi
  sleep 2
done
[ "$kafka_ok" = "1" ] && ok "kafka(9092) 端口在线" || { fail "kafka(9092) 不可达"; PASS=0; }
[ "$PASS" = "1" ] || exit 1
exit 0
