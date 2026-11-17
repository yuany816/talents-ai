# /app/ops 交付目录说明（判分只读取本目录）

本目录已预置交付骨架（`repro/`、`fix/`、`evidence/`、`diagnosis_report.md` 模板），
容量参数随 trial 随机生成于 `params.env`（LIM / WARN_RATIO）——**你的配置与声明必须
与 params.env 一致，硬编码固定值会被判分扣分**。

## 两阶段交付

**阶段 1（复现）**：编写 `/app/ops/repro/F1.sh ~ F4.sh` 四个可执行脚本，各自稳定触发
对应故障面（判分按"存在且可执行"计 structure 分）：

| 面 | 脚本应触发/展示的故障 |
|---|---|
| F1 | nginx 入口对 16384B 超长 header 探针的拦截（curl 即可） |
| F2 | 直连 backend 的 431（或入口 431 透传） |
| F3 | 注入链 span 计数与链路规格的偏差 |
| F4 | kafka 审计旁路的容量信号（MESSAGE_TOO_LARGE / 限额过小） |

**阶段 2（修复 + 证据）**：
- 修复每个面并使其真实生效（配置/源码修改后按题面约束重启/重编译）；
- 运行四面采集脚本生成证据（只采集原始数据，**判分按取值断言**，须与实际一致）：
  ```
  bash /app/tools/collect_nginx.sh    # → evidence/F1_nginx_T.txt
  bash /app/tools/collect_backend.sh  # → evidence/F2_backend_status.txt
  bash /app/tools/collect_trace.sh    # → evidence/F3_span_count.txt
  bash /app/tools/collect_kafka.sh    # → evidence/F4_kafka_audit.txt
  ```
- 填写 `diagnosis_report.md`：每个面三行——根因一句话、所引用的证据文件相对路径、
  修复前后一个关键数值对比（判分检查报告是否引用了 evidence 下对应路径）。

## 判分口径（加权 4 维度）
`reward = 0.15×结构 + 0.30×基础修复 + 0.35×证据齐全 + 0.20×报告质量`
- 结构（/5）：4 个 repro 脚本 + 报告存在；
- 基础修复（/4）：每面修复真实生效（F1 与 params.env 的 LIM 一致、F2 端到端 200、
  F3 链路规格恢复、F4 broker 限额治理）；
- 证据齐全（/4）：evidence/ 下每面至少一个文件；
- 报告质量：引用证据路径。
- CAP：repro 四脚本全缺 → 总分封顶 0.45。完整口径见题面"验题契约"。
