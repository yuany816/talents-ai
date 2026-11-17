#!/bin/bash
# basic/01 —— 0) 环境在线（证据断言）：kafka(:9092) 探活、tracegate/meshd 组件指纹
# 来自 evidence/kafka_audit.txt（作答环境记录；组件为环境组成部分，移除/替换即不通过）。
# schema：kafka_tcp=ok / tracegate_componentz=…(含 "tracegate") / meshd_componentz=…(含 "meshd")
set -u
. "$(dirname "$0")/../lib.sh"
KF=$(ev_path kafka_audit.txt) || { fail "缺少证据文件 evidence/kafka_audit.txt"; exit 1; }
PASS=1

tcp=$(ev_get kafka_tcp "$KF")
[ "$tcp" = "ok" ] && ok "kafka(9092) 探活记录 ok" || { fail "kafka_tcp 缺失或非 ok（got=${tcp:-无}）"; PASS=0; }

tg=$(ev_get tracegate_componentz "$KF")
printf '%s' "$tg" | grep -q '"tracegate"' \
  && ok "tracegate 组件指纹匹配" || { fail "tracegate_componentz 缺组件指纹（占位桩/组件被移除）"; PASS=0; }
ms=$(ev_get meshd_componentz "$KF")
printf '%s' "$ms" | grep -q '"meshd"' \
  && ok "meshd 组件指纹匹配" || { fail "meshd_componentz 缺组件指纹（占位桩/组件被移除）"; PASS=0; }

[ "$PASS" = "1" ] || exit 1
exit 0
