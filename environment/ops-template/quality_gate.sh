#!/bin/bash
# 交付模板：实现 431 高优先级质检门禁后 chmod +x 再交付。
# 契约（题面"验题契约"4)）：逐源检查 /var/log/nginx/{hdrsize,access,error}.log
# （hdrsize 格式 $msec $status $request_length ...）；任一来源缺失须跳过（不得误拦
# 或崩溃）；日志中无 431 证据 → exit 0；发现 431 → exit 非零。
# 判分环境会在本地伪造日志并洗牌注入顺序，验证门禁按"431 证据"语义拦截。
exit 0
