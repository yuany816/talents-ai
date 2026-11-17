# 排查线上 431 Request Header Fields Too Large（5 故障面 / 2 交付阶段）

## 背景
某业务站点的接入网关上线"全量链路追踪"后，客户端截获的响应码在 400 与 431 之间跳变
（431 = Request Header Fields Too Large）。值班同学一度只调大了入口层配置，重启后故障
依旧——问题不是"某个组件配置写错了"，而是一条链路上多个模块共同作用的结果。这套接入层
经历过多次入口重构、配额调整与"带宽节省专项"，各处数值的对齐情况从未做过端到端核验，
生效值也可能来自部署环境而非磁盘配置。

## 当前状态
- 同步链路：nginx（入口反代，监听 80）→ tracegate（接入网关 trace 插件，127.0.0.1:9100）
  → meshd（mesh 数据面 sidecar，127.0.0.1:15001）→ Go 后端（127.0.0.1:9000）；
  异步审计旁路：Kafka 单节点 127.0.0.1:9092，trace-collector 消费落盘 /var/log/trace_events.log
- 组件源码/配置：/app/backend（标准 Go module：根包入口 + internal/ 业务包 + 退役入口
  存档 + configs/ 配置档案）、/app/tracegate、/app/mesh；均可离线编译（GOPROXY=off）；
  预编译二进制已随服务运行
- 路由：/api/v1/profile、/healthz；中间层有 /componentz 组件探针
- 日志：/var/log/nginx/（error log 已开 info 级）、/var/log/{backend,tracegate,meshd,kafka,trace_events}.log
- 服务管理：supervisord 编排（全组件 autorestart）；`supervisorctl status`（需 root）
- **平台以 100 轮（agent 交互轮次）为预算强制截断**，截断后按已落盘交付物计分——没写完的文件就是没有分；全部面修复+取证+证据+报告的工作量需要高效推进（先取证、后修复、随做随落盘）
- **容量参数随 trial 随机生成**于 `/app/ops/params.env`（`LIM` ∈ [17408,65535] 字节、
  `WARN_RATIO` ∈ [50,90] 整数百分比）——nginx 配置、预警阈值与相关声明必须与该文件一致，
  **硬编码固定值由一致性检查扣分**
- 交付骨架预置于 /app/ops/（repro/、fix/、evidence/、报告模板、/app/tools/ 采集脚本、README.md）
- 复现方式：向入口发送携带 16384 字节超大自定义 header 的请求（如 X-Debug-Trace），
  对比直连各层（9100 / 15001 / 9000）的返回与各层日志

## 五个故障面（判分按面计分）
| 面 | 组件 | 说明 |
|---|---|---|
| F1 | nginx 入口（业务 :80 + 管理 :8081） | header 缓冲对完整 header 行（16384B 探针 + 开销 ≈18B）口径不足；**多 server 多处指令**的历史漂移（业务面/管理面/http 级可能各自不同） |
| F2 | backend | 限额存在多处形态（标准库/框架层/业务配额/存档），生效值可能与磁盘不一致；**内置预警阈值硬编码**未与容量参数联动 |
| F3 | tracegate 注入链 | header 预算与 span 注入规格（gate 768B / mesh 1536B / baggage 512B） |
| F4 | kafka 审计旁路（broker + trace-collector） | broker 限额与全量头快照事件的容量关系；**生产/消费的 topic 口径**是否一致（与同步 431 区分的独立信号） |
| F5 | meshd sidecar | 数据面限额与 span 注入规格的生效口径（磁盘 vs 部署环境覆盖；规格 1536B/512B） |

链路的注入行为是容量数学的前提：span/baggage 规格不得缩水、也不得凭空增大（判分对
逐层计数与回显增幅做精确锚定）。

## 两阶段交付（产物落盘 /app/ops/）

**阶段 1（复现 + 取证）**：先修后证拿不到分——每个面交付两个文件：
- `repro/Fx.sh`（可执行）：触发/展示该面故障的脚本；
- `repro/Fx.out`：**修复前**运行该脚本的真实输出，且必须含修复前故障签名（判分逐面核对）：
  - F1.out：HTTP 状态码 **400 或 431**（大探针打入口的真实拒绝记录）；
  - F2.out：**431** 或 backend banner **quota=8192** 或 Request Header 拒绝记录；
  - F3.out：GATESTAT/MESHSTAT 原始计数行，且 gate 增幅 **≠769** 或 mesh 增幅 **≠1537**
    （修复后的规格值不算取证）；
  - F4.out：**MESSAGE_TOO_LARGE** / kafka produce failed / 原限额 16384 记录；
  - F5.out：meshd 生效限额 **< 17408**（修复前磁盘与部署环境双口径未达标）。

**阶段 2（修复 + 证据 + 报告）**：
1. 五面修复真实生效（nginx 配置 reload、Go 源码重编译并重启、中间层改后重启组件、
   kafka 动态调整同步落盘静态配置）；
2. **证据文件**（原始数据采集脚本 + 模型自产核验记录）：
   ```
   bash /app/tools/collect_nginx.sh     # → evidence/F1_nginx_T.txt（nginx -T 全量）
   bash /app/tools/collect_backend.sh   # → evidence/F2_backend_status.txt（探针状态/响应体）
   bash /app/tools/collect_trace.sh     # → evidence/F3_span_count.txt（逐层计数+回显）
   bash /app/tools/collect_kafka.sh     # → evidence/F4_kafka_audit.txt（限额+事件流）
   bash /app/tools/collect_meshd.sh     # → evidence/F5_meshd_status.txt（生效限额+来源）
   ```
   另须模型自产四份核验记录（格式见"验题契约"）：
   - `evidence/F1_boundary.txt`：双侧边界探针——LIM−1024 须 200、LIM+4096 须 400/431；
   - `evidence/F2_restart.txt`：`supervisorctl restart all` **之后**的复探记录
     （post_restart_entry_big_status=200 / post_restart_backend_big_status=200）；
   - `evidence/F2_calibration.txt`：预警双侧标定——THRESH=LIM×WARN_RATIO/100，
     THRESH+512 探针必须触发告警（above_warnings_delta≥1 且观测值≥THRESH），
     THRESH−1024 探针必须静默（below_warnings_delta=0）——观测口径与注入开销的
     关系需要你自己想清楚；
   - `evidence/F4_restart.txt`：重启 kafka 后以**新标记**探针复证事件仍落盘（marker=/event_seen=ok）；
   - `evidence/F5_restart.txt`：restart all 之后重跑 collect_meshd.sh 的输出
     （effective_limit 须仍 ≥17408）。
3. **fix/ 修复脚本交付**：`fix/F1.sh ~ F5.sh` 五个可执行脚本，各自封装该面的修复动作
   （判分按存在且可执行计结构分；内容须与实际生效的修复一致）；
4. **diagnosis_report.md**：每个面三行——根因一句话、所引用的证据文件相对路径、
   修复前后一个关键数值对比（修复前数值须与 Fx.out 实测一致）。

## 验题契约（tests/test.sh 的精确行为）
**判定总则**：独立判分（判分环境无服务，只读 /app/ops/）。4 位小数写入
/logs/verifier/reward.txt，诊断写 /logs/verifier/debug.txt。
`reward = 0.15×P1(运维修复清单) + 0.85×F7(实现题隐性套件)`：
P1 = 0.20×结构(/10) + 0.35×基础(/11) + 0.20×证据(/5) + 0.25×报告(/5)。

## F7 实现题：calibrator（权重 0.85 · 隐性对抗验证）

交付：`/app/ops/bin/calibrator`（静态可执行，任意语言；源码建议放 /app/ops/src/）。
规格：`/app/tools/specs/spec-calibrator.md`（**逐条实现——含全部语义钉子**）。
判分：判分环境以**隐性对抗套件**（12 个复合场景，每流组合 4~6 条规格规则交互：
合并 SUM、字节序排序、多字节字节长、JSON 转义膨胀、精确 THRESH 边界、解析顺序、
invalid 桶、skipped 计数）逐字节对照参考实现——**场景每 trial 由 params 派生的
种子随机生成，不预先披露**。通过比例 = F7 分。套件难度按首试通过率 0.3~0.5 校准，
实现质量决定分数；运行修补只是入场券（P1 0.15）。

| 维度 | 子项 | 判定 |
|---|---|---|
| 结构 /10 | repro/Fx.sh + Fx.out ×5 | 可执行 且 .out 含对应修复前签名（见上表；F5 签名=生效限额 <17408） |
| | fix/Fx.sh ×5 | 存在且可执行（封装该面实际修复动作） |
| 基础 /11 | F1a | nginx_T 全部活动指令单缓冲 == params LIM（多条须一致；硬编码不通过） |
| | F1b | F1_boundary：LIM−1024 行含 200、LIM+4096 行含 400/431 |
| | F2a | backend_big_status=200 且 entry_big_status=200 且响应体 `"msg":"ok"` |
| | F2d | 启动 banner 的 warn_threshold == params THRESH（预警阈值与容量参数联动，硬编码不通过） |
| | F2b | F2_restart：post_restart_entry/backend_big_status=200 |
| | F2c | F2_calibration：below_warnings_delta=0 且 above_warnings_delta≥1 且 above_max_observed≥THRESH |
| | F3 | gate/mesh/baggage 恰 769/1537/512 且回显增幅恰 2306 |
| | F4a | kafka_message_max_bytes_static > 16384 |
| | F4b | F4_restart：含 marker= 且 event_seen=ok |
| | F5a | F5_meshd_status：effective_limit ≥ 17408 |
| | F5b | F5_restart：effective_limit ≥ 17408（restart all 后仍生效） |
| 证据 /5 | F1~F5 | evidence/ 下各有至少一个 `Fx_*` 文件 |
| 报告 /5 | 逐面引用 | 报告逐面引用 evidence/Fx_* 证据文件相对路径（F1~F5 各计 1 项） |

- **CAP**：repro 取证项全缺 → 总分封顶 0.45；**兜底**：启动即写 0.0000，/app/ops 缺失即 0 退出。
- 记录间互相咬合（回显增幅 vs 逐层计数、修复前数值 vs 故障面实际），相互矛盾按不通过计。
- 另有部分持久化/标定语义未在此完全披露——以修复真实生效为准，不要只做表面记录。

## 约束
- 不要硬编码固定参数值（params.env 随 trial 变化）；不要硬编码"通过"结果；
- 链路组件不可移除或替换为桩；span/baggage 规格不得缩水或凭空增大；
- 审计事件保留全量请求头快照；kafka 动态调整须同步落盘；
- 不依赖外部网络；采集脚本幂等可重跑；判分可重复执行。

## 提示（可选）
- 先分层直连（9100/15001/9000）区分拦截点，再逐面取证；
- 后端限额可能不止一处、不止一种形态；生效值可能来自部署环境而非磁盘配置；
- 区分同步 431 与异步审计容量信号（MESSAGE_TOO_LARGE）；
- 预警观测的实现口径（入口 request_length vs 后端请求头总量）会直接影响双侧标定结果；
- 先取证、再修复、最后自产核验记录——顺序反了部分分拿不到；
- **F7 实现题占 0.85 权重**：运维修复只是入场券——先读 /app/tools/specs/spec-calibrator.md，把每条语义钉子（规范化序列化口径、合并 SUM、排序、skipped/invalid 口径）逐条实现，并用自构造的对抗输入（多字节、转义、同 route+ts 合并、恰好 THRESH）自测后再交付；
- 100 轮预算内做不完全部交付是常态：按权重取舍（结构 0.20 / 基础 0.35 / 证据 0.20 / 报告 0.25），每完成一批立即落盘。
