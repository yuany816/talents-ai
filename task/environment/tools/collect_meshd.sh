#!/bin/bash
# F5 采集（只采集原始数据，不做断言）：meshd 生效限额（启动日志 source 口径）+ 磁盘配置
set -u
mkdir -p /app/ops/evidence
START_LINE="$(grep -E 'meshd listening on' /var/log/meshd.log 2>/dev/null | tail -n1)"
EFF="$(printf '%s' "$START_LINE" | grep -oE 'limit=[0-9]+' | head -n1 | cut -d= -f2)"
SRC="$(printf '%s' "$START_LINE" | grep -oE '(source=[a-zA-Z_]+)' | head -n1)"
YAML="$(sed -n 's/^max_header_bytes:[[:space:]]*//p' /app/mesh/sidecar.yaml 2>/dev/null | head -n1)"
{
  echo "effective_limit=${EFF:-0}"
  echo "source=${SRC:-unknown}"
  echo "yaml_max_header_bytes=${YAML:-unknown}"
  echo "startup_log=${START_LINE}"
  echo "supervisor_env=$(grep -E 'MESH_HEADER_LIMIT' /etc/supervisor/conf.d/app.conf 2>/dev/null || echo none)"
} > /app/ops/evidence/F5_meshd_status.txt
cat /app/ops/evidence/F5_meshd_status.txt
