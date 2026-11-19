# 431 事件诊断报告（5 面 / 2 阶段）

容量参数（params.env）：LIM=39485B，WARN_RATIO=82%——nginx 配置、预警阈值（THRESH=32377）与声明已与之一致。

## F1（nginx 入口）
- 根因：large_client_header_buffers 16k 对 16402B 完整 header 行不足，且 server 级与 http 级配置漂移
- 证据：evidence/F1_nginx_T.txt、evidence/F1_boundary.txt、repro/F1.out
- 修复前后数值对比：入口大探针 400 → 200（生效单缓冲 →     large_client_header_buffers 4 39485，双侧边界 LIM−1024=200 / LIM+4096=4xx）
## F2（backend）
- 根因：业务配额 8192 经 go:embed 编译期固化，框架层 MaxHeaderBytes 1<<13 与退役存档残留 8192——改盘不重编译不生效
- 证据：evidence/F2_backend_status.txt、evidence/F2_restart.txt、evidence/F2_calibration.txt、repro/F2.out
- 修复前后数值对比：直连后端大探针 431 → 200（配额 8192 → 1048576；restart all 后仍 200；预警双侧标定 THRESH=32377 通过）
## F3（tracegate 注入链）
- 根因：max_header_bytes 10240 过小，span_bytes 被带宽节省专项下调至 384，注入链增幅缩水
- 证据：evidence/F3_span_count.txt、repro/F3.out
- 修复前后数值对比：span_bytes 384 → 768（gate 计数恢复恰 769 / mesh 1537 / baggage 512；回显增幅恰 2306）
## F4（kafka 审计旁路）
- 根因：broker message.max.bytes 16384 过小，全量头快照事件被 MESSAGE_TOO_LARGE 拒绝（异步容量信号，区别于同步 431）
- 证据：evidence/F4_kafka_audit.txt、evidence/F4_restart.txt、repro/F4.out
- 修复前后数值对比：message.max.bytes 16384 → 1048576（动态生效+静态落盘；broker 重启后新标记事件仍落盘）
## F5（meshd sidecar）
- 根因：磁盘配置 12288 与 supervisord 程序环境 MESH_HEADER_LIMIT=12288 双口径压制生效值
- 证据：evidence/F5_meshd_status.txt
- 修复前后数值对比：生效限额 12288 → 1048576（双口径同步，启动日志 source 口径确认）
## F8（审计事件采样丢弃）
- 根因：审计 producer 内置隐藏采样逻辑（每 4 个事件丢弃 1 个，容量压测模式残留）
- 证据：evidence/F8_period.txt、repro/F8.out
- 修复前后数值对比：落盘率 0/30 → 30/30（移除采样逻辑后 100% 落盘）
## F9（meshd 多字节规格偏移）
- 根因：span 注入尺寸按 rune 口径对多字节路由压缩（差分实验定位：ASCII delta 正常、多字节 delta 偏移）
- 证据：evidence/F9_offset.txt、repro/F9.out
- 修复前后数值对比：多字节路由 delta 1531 → 1537（规格恢复，ASCII 与多字节一致）
