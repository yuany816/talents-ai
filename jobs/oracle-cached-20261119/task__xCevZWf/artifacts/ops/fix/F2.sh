#!/bin/bash
# F2 修复：配额与框架限额对齐 params，重编译并重启
QUOTA=1048576
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"$QUOTA"'/' /app/backend/configs/quota.yaml
sed -i -E 's/(MaxHeaderBytes:[[:space:]]*)1[[:space:]]*<<[[:space:]]*13/\1'"$QUOTA"'/' /app/backend/main.go
sed -i -E 's/(legacyQuotaBytes[[:space:]]*=[[:space:]]*)[0-9]+/\1'"$QUOTA"'/' /app/backend/legacy_server.go
cd /app/backend && GOPROXY=off CGO_ENABLED=0 go build -o backend . && supervisorctl restart backend
