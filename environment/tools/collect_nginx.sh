#!/bin/bash
# F1 采集（只采集原始数据，不做断言）：nginx -T 完整输出
set -u
mkdir -p /app/ops/evidence
nginx -T > /app/ops/evidence/F1_nginx_T.txt 2>&1
echo "[collect] F1_nginx_T.txt: $(wc -c < /app/ops/evidence/F1_nginx_T.txt) bytes"
