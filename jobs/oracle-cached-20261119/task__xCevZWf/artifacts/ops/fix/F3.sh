#!/bin/bash
# F3 修复：tracegate 预算与 span 规格恢复（768）
Q=1048576
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"$Q"'/; s/^(span_bytes:[[:space:]]*)[0-9]+/\1768/' /app/tracegate/tracegate.yaml
supervisorctl restart tracegate
