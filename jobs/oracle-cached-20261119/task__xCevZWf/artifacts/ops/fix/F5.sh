#!/bin/bash
# F5 修复：meshd 磁盘与部署环境双口径对齐后重启
Q=1048576
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"$Q"'/' /app/mesh/sidecar.yaml
sed -i -E 's/(MESH_HEADER_LIMIT=")[0-9]+(")/\1'"$Q"'\2/' /etc/supervisor/conf.d/app.conf
supervisorctl reread && supervisorctl update && supervisorctl restart meshd
