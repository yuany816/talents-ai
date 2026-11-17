# 排查线上 431 Request Header Fields Too Large（4 故障面 / 2 交付阶段）

## 背景
某业务站点的接入网关上线"全量链路追踪"后，客户端截获的响应码在 400 与 431 之间跳变
（431 = Request Header Fields Too Large）。值班同学一度只调大了入口层配置，重启后故障
依旧——问题不是"某个组件配置写错了"，而是一条链路上多个模块共同作用的结果。这套接入层
经历过多次入口重构、配额调整与"带宽节省专项"，各处数值的对齐情况从未做过端到端核验。

## 当前状态
- 环境内已运行完整同步链路：nginx（入口反代，监听 80）→ tracegate（接入网关 trace 插件，
  127.0.0.1:9100）→ meshd（mesh 数据面 sidecar，127.0.0.1:15001）→ Go 后端（127.0.0.1:9000）；
  另有异步审计旁路（Kafka 单节点 127.0.0.1:9092，由 trace-collector 消费落盘
  /var/log/trace_events.log），独立于同步请求路径
- 各组件源码/配置：/app/backend（标准 Go module：根包入口 + internal/ 业务包 + 退役入口
  存档 + configs/ 配置档案）、/app/tracegate、/app/mesh；均可离线编译；预编译二进制已随服务运行
- 已注册路由：`/api/v1/profile`（业务接口）、`/healthz`；中间层提供 `/componentz` 组件健康探针
- 日志位置：nginx 在 /var/log/nginx/（error log 已开 info 级）；各组件 stdout/stderr 在
  /var/log/{backend,tracegate,meshd,kafka,trace_events}.log
- 服务管理：supervisord 编排（kafka / trace-collector / backend / tracegate / meshd / nginx
  均 autorestart）；`supervisorctl status` 查看并手动重启（需 root）
- **容量参数随 trial 随机生成**于 `/app/ops/params.env`（`LIM` ∈ [17408,65535] 字节、
  `WARN_RATIO` ∈ [50,90] 整数百分比）——你的 nginx 配置与相关声明必须与该文件一致，
  **硬编码固定值由判分的一致性检查扣分**
- 交付骨架已预置于 /app/ops/（repro/、fix/、evidence/、报告模板、/app/tools/ 四面采集
  脚本、/app/ops/README.md 使用说明）
- 复现方式：向入口发送携带超大自定义 header 的请求（例如值为 16384 字节的 X-Debug-Trace），
  对比直连各层（9100 / 15001 / 9000）的返回，观察响应码差异与各层日志

## 四个故障面（判分按面计分）
| 面 | 组件 | 说明 |
|---|---|---|
| F1 | nginx 入口 | header 缓冲对完整 header 行口径不足 |
| F2 | backend | 限额存在于多处形态（标准库/框架层/业务配额/存档），且生效值可能与磁盘不一致 |
| F3 | tracegate 注入链 | header 预算与 span 注入规格（gate 768B / mesh 1536B / baggage 512B，每跳 ≈2.9KB） |
| F4 | kafka 审计旁路 | broker 限额与全量头快照事件的容量关系（与同步 431 区分） |

注：meshd 是链路组成部分（数据面 sidecar），其限额**不在计分面中单独计分**，但 F2 的
端到端探针经全链路——任何一环拦截都会让 F2 证据无法成立。链路的注入行为是容量数学的
前提：span/baggage 规格不得缩水、也不得凭空增大（逐层计数锚定精确值）。

## 期望结果（两阶段交付，产物落盘 /app/ops/）

**阶段 1（复现）**：`/app/ops/repro/F1.sh ~ F4.sh` 四个**可执行**脚本，各自稳定触发/展示
对应故障面（判分按"存在且可执行"计分；脚本内可用 curl / 读日志 / 打组件计数等任意方式）。

**阶段 2（修复 + 证据）**：
1. **每面修复真实生效**（判分断言见"验题契约"）：
   - F1：nginx 生效配置（nginx -T）中未注释的 `large_client_header_buffers` 单缓冲
     **全部等于 params.env 的 LIM**（完整 header 行口径 = 16384B 探针 + 行开销 ≈18B +
     余量；LIM ≥17408 恒可放行探针）；k/M 后缀写法均可；
   - F2：16384B 大探针经入口**与直连 9000** 均 200（响应体特征 `"msg":"ok"` / `ok`，
     防桩替换）；原故障值 8192 及其等值书写形态（移码/十六进制）须从 /app/backend 的
     生效源码/配置中真实移除（退役存档与备份后缀文件豁免）；
   - F3：逐层计数恢复链路规格——gate `trace_out−trace_in` 恰 769、mesh 恰 1537、
     baggage 恰 512（缩水与凭空增大均不通过）；
   - F4：broker `message.max.bytes` 静态落盘 > 16384（动态调整须同步落盘，防重启回退）。
2. **证据文件**（四面采集脚本只采集原始数据，判分按取值断言，须与实际一致）：
   ```
   bash /app/tools/collect_nginx.sh     # → evidence/F1_nginx_T.txt
   bash /app/tools/collect_backend.sh   # → evidence/F2_backend_status.txt
   bash /app/tools/collect_trace.sh     # → evidence/F3_span_count.txt
   bash /app/tools/collect_kafka.sh     # → evidence/F4_kafka_audit.txt
   ```
3. **diagnosis_report.md**：每个面三行——根因一句话、所引用的证据文件相对路径
   （判分检查是否引用 evidence 下对应路径）、修复前后一个关键数值对比。

## 验题契约（tests/test.sh 的精确行为）
**判定总则**：独立判分（判分环境无服务、不发实时探针，只读 /app/ops/ 交付）。
`reward = 0.15×结构 + 0.30×基础修复 + 0.35×证据齐全 + 0.20×报告质量`，4 位小数写入
/logs/verifier/reward.txt；诊断写 /logs/verifier/debug.txt。各维度按子项通过比例计分：

| 维度 | 子项 | 判定 |
|---|---|---|
| 结构 /5 | repro/F1~F4.sh | 存在、非空、可执行 |
| | diagnosis_report.md | 存在且非空 |
| 基础 /4 | F1 | nginx_T 中全部活动指令单缓冲 == params LIM（多条须取值一致；硬编码不通过） |
| | F2 | backend_big_status=200 且 entry_big_status=200 且响应体 `"msg":"ok"` |
| | F3 | gate/mesh/baggage 计数恰 769/1537/512 |
| | F4 | kafka_message_max_bytes_static > 16384 |
| 证据 /4 | F1~F4 | evidence/ 下各有至少一个 `Fx_*` 文件 |
| 报告 /1 | 引用证据 | 报告含 evidence 下证据文件相对路径 |

- **CAP**：repro 四脚本全缺 → 总分封顶 0.45（交付空心）。
- **兜底**：reward.txt 启动即写 0.0000，/app/ops 缺失立即以有效零分退出。
- 修复类断言的取值须来自真实生效状态：F1 与 params.env 咬合（随机参数，每 trial 不同），
  F3 与逐层计数咬合，F4 与落盘文件咬合——相互矛盾或凭空书写的记录按不通过计。
- 修复生效语义：nginx 配置须 `nginx -t` 通过后 reload；Go 源码修改须重新编译并重启；
  tracegate/meshd 限额为进程启动时读取，修改后须重启对应组件；kafka 动态调整须同步落盘。

## 约束
- 不要硬编码"通过"结果或固定参数值（params.env 随 trial 变化，一致性检查会扣分）；
- 链路组件（kafka/tracegate/meshd/trace-collector）为环境组成部分，不可移除或替换为桩；
- span/baggage 注入规格不得缩水、不得凭空增大（容量探针数学的前提）；
- 审计事件保留全量请求头快照（不得裁剪事件头或瘦身后发送）；
- 不依赖外部网络（工具链与源码均在环境内）；
- 采集脚本可重复运行（幂等覆盖写），判分可重复执行。

## 提示（可选）
- 431/400 可能产生于链路的不同层：先分层直连（9100/15001/9000）区分拦截点；
- 后端侧限额可能不止一处、不止一种形态（默认值/移码书写/构建期固化/退役存档），
  注意甄别"看起来相关但实际未被读取"的配置与环境变量——以运行进程的实际观测为准；
- 生效限额可能来自部署环境而非磁盘配置：以组件启动日志打印的生效值（及 source 标注）
  与进程环境为准，区分"已书写"与"已生效"；
- 区分同步链路的 431 与异步审计链路的容量信号（MESSAGE_TOO_LARGE）；
- 链路注入的逐层计数（GATESTAT/MESHSTAT 的 trace_in/trace_out/baggage 字段）提供
  规格核对依据（768/1536/512）；
- 先交 repro 拿结构分，再逐面修复与采证。
