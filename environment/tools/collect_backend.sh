#!/bin/bash
# F2 采集（只采集原始数据，不做断言）：入口与直连后端探针的原始状态码/响应体
set -u
mkdir -p /app/ops/evidence
ENTRY=http://127.0.0.1:80
BE=http://127.0.0.1:9000
H=/tmp/.ce_hdr
printf 'X-Verify-Token: %s\n' "$(head -c 16384 /dev/zero | tr '\0' 'x')" > "$H"
{
  echo "backend_big_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "@$H" "$BE/api/v1/profile")"
  echo "entry_big_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "@$H" "$ENTRY/api/v1/profile")"
  echo "entry_norm_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$ENTRY/api/v1/profile")"
  echo "healthz_big_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "@$H" "$ENTRY/healthz")"
  echo "server_header=$(curl -s -D - -o /dev/null --max-time 15 "$ENTRY/api/v1/profile" | grep -i '^server:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
  echo "profile_body=$(curl -s --max-time 15 "$BE/api/v1/profile" | head -n1)"
  echo "healthz_body=$(curl -s --max-time 15 -H "@$H" "$ENTRY/healthz" | tr -d '[:space:]')"
} > /app/ops/evidence/F2_backend_status.txt
cat /app/ops/evidence/F2_backend_status.txt
