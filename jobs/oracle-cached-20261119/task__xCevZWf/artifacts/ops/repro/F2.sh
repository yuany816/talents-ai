#!/bin/bash
# F2 复现：直连后端（修复前 431——配额 8192 编译期固化）
curl -s -o /dev/null -w 'backend_big=%{http_code}\n' --max-time 10 \
  -H "X-Debug-Trace: $(head -c 16384 /dev/zero | tr '\0' 'x')" http://127.0.0.1:9000/api/v1/profile
