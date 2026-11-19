#!/bin/bash
# F1 复现：16384B 单自定义 header 打入口（修复前 400/431）
curl -s -o /dev/null -w 'entry_big=%{http_code}\n' --max-time 10 \
  -H "X-Verify-Token: $(head -c 16384 /dev/zero | tr '\0' 'x')" http://127.0.0.1:80/api/v1/profile
