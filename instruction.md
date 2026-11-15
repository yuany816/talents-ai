# 排查线上 431 Request Header Fields Too Large

## 背景
某业务站点的接入网关近期上线"全量链路追踪"，会在每个到达入口的请求头中注入较大的
Trace 上下文（单个请求头可达十几 KB，且会随链路跳数继续增长——每经过一跳都会追加一段
span 上下文）。上线后客服陆续收到反馈：部分接口"随机"失败，客户端截获到的响应码在
400 与 431 之间跳变（431 = Request Header Fields Too Large）。值班同学一度只调大了
入口层配置，重启后故障依旧——问题并不是"某个组件配置写错了"这么简单，而是一条链路上
多个模块共同作用的结果。这套接入层经历过多次入口重构与配额调整：代码库里同时保留着
现行入口、退役入口存档和多份配置档案副本，各处数值的对齐情况从未做过端到端核验；
这也意味着容量评估要为"继续增长"预留余量，而不是刚好够用。

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
- 服务管理：容器由 supervisord 驻留（kafka / trace-collector / backend / tracegate / meshd /
  nginx 均 autorestart）；`supervisorctl status` 查看并手动重启（需 root）
- 复现方式：向入口发送携带超大自定义 header 的请求（例如值为 16384 字节的 X-Debug-Trace），
  对比直连各层（9100 / 15001 / 9000）的返回，观察响应码差异与各层日志

## 期望结果
1. **端到端修复**：携带 16384 字节单个自定义 header 的请求，经入口访问 /api/v1/profile（及
   /healthz）与直连后端均返回 200（与常规请求一致）；**链路拓扑保持**——修复不得绕过或
   拆除中间组件：入口常规请求的响应须回显 `X-Trace-Context`（含 `gate=`/`mesh=` 注入段）；
2. **限额语义保持**：调大 ≠ 取消——超过（你自己声明的）上限的请求仍应被拒绝；
3. **多层真实修复（可被检查）**：
   - nginx 生效配置（`nginx -T` 输出）中存在 `large_client_header_buffers`，单缓冲 ≥ 17408 字节
     （17 KiB，按**完整 header 行**口径：16384B 值 + 字段名/": "/CRLF 约 18B + 1 KiB 余量；
     接受 k/M 后缀写法）；
   - 后端侧的 header 限额真实调大并生效——它可能存在于标准库/框架层，也可能存在于
     业务代码及其配置文件中；原故障值 `8192` 不得以任何等值书写形态残留于
     /app/backend 的源码或配置（验题做字面匹配，见"验题契约"）；
   - 链路其余各层（tracegate / meshd）的限额同样必须真实调大——由端到端行为探针判定，
     并辅以各自目录下 `max_header_bytes` 键上下文的残留扫描（10240 / 12288）；
4. **异步链路治理（明示不计入判定）**：Kafka 审计旁路的 `message.max.bytes` 与同步 431
   无关，是否对齐不影响 reward；但其报错（backend 日志中的 MESSAGE_TOO_LARGE）属于
   链路容量信号，综合报告中应予三角说明；
5. **持续防线，产物落盘于 /app/ops/**：
   - `header_limits.env`：链路限额与预警参数，**必须**包含 `NGINX_LARGE_HEADER_BUFFER_BYTES`
     （nginx 侧单 header 上限，字节，须与 nginx 生效单缓冲一致）与 `WARN_RATIO`
     （预警阈值百分比，有效范围 **[50, 90]**，缺失时验题按 80 处理）；
   - 观测能力（可由后端观测中间件在请求处理路径中同步实现，无独立常驻进程亦可）：
     请求达到阈值时向 `warnings.log` 追加告警行，**30 秒内**必须可观测到（行数增加）；
     远低于阈值的常规请求不得产生告警；
   - `quality_gate.sh`：变更质检门禁，对日志中的 431 高优先级拦截——检查
     /var/log/nginx/hdrsize.log（若存在，格式 `$msec $status $request_length ...`）、
     /var/log/nginx/access.log 与 /var/log/nginx/error.log；日志干净时退出码 0，出现 431 时**非零**退出；
   - `diagnosis_report.md`：链路级综合分析报告——包含各层状态码链（修复前/分层修复后）、
     各模块限额修改前后对照，以及对"哪个模块注入的 header 过多、哪几层限制过小"的归因结论
     （结论是链路级综合归因，不是单点归责）。

## 验题契约（tests/test.sh 的精确行为，agent 可据此还原判定）

**判定总则**：以下任一检查失败，reward=0；全部通过 reward=1。结果写入
/logs/verifier/reward.txt（"1"/"0"）。验题脚本**可重复执行**（日志清理与注入均会复原），
你的方案在重复验题下必须保持可判定。行为正确性以探针判定（不同输入/边界场景）；
对源码与配置的字符串扫描仅作为"修改真实发生"的**辅助**证据（防伪造），不单独构成通过依据。

**固定参数及其题面依据**：

| 固定值 | 依据 |
|---|---|
| 探针 16384 字节 | 题面复现场景；高于旧 nginx 默认单行上限 8k 与后端旧故障值 8192。**完整 header 行 ≈16402B**（字段名 14B + ": " + 16384B + CRLF） |
| L1 要求 ≥17408B（17KiB） | 完整 header 行口径：16384B 值 + 行开销约 18B + 1KiB 余量——恰好 16384 的缓冲会误拒合规探针 |
| LIM 须 == nginx 生效单缓冲 | 边界与预警判定需与实际限额同一数值基准 |
| L2 扫描形态 | 十进制 `8192` 不限上下文；等值移码/十六进制书写仅在 `MaxHeaderBytes`/`max_header_bytes` 键上下文中扫描（均豁免备份后缀文件） |
| 中间层扫描形态 | tracegate 原故障值 `10240`、meshd 原故障值 `12288`：仅锚定 `/app/tracegate`、`/app/mesh` 下 `max_header_bytes` 键上下文（豁免备份后缀文件） |
| 组件探针/指纹 | tracegate(:9100) 与 meshd(:15001) 的 `/componentz` 须可达且响应含各自组件名；kafka(:9092) 仅 TCP 探活（3×2s 重试，容 JVM 慢启）——组件为环境组成部分，移除/替换即不通过 |
| 注入链 nonce 探针 | 验题注入一次性 `X-Trace-Context: vfy<纳秒>`；回显须**按序**含 nonce→`gate=`→`mesh=` 段且较 nonce 增幅 ≥2048B（静态 add_header 无法预知 nonce；绕层则无注入段） |
| span 固定尺寸 | gate span 768B / mesh span 1536B / X-Mesh-Baggage 512B（每请求注入增幅 ≈2.9KB）——容量探针数学的前提，不得缩水或拆除 |
| 注入链完整性探针 | 入口常规请求的响应 `X-Trace-Context` 须同时含 `gate=` 与 `mesh=` 段（tracegate/meshd 注入、backend 回显）——防绕层伪修复 |
| 上边界探针 LIM+4096 | 必须越过声明上限以验证"仍被拒绝"；LIM>1MB 时跳过（受单参数长度限制） |
| 预警探针 THRESH+512（≤LIM−1024） | 必须越过阈值触发告警，但不得越过上限 |
| THRESH = LIM×RATIO/100，RATIO 有效范围 [50,90] | 题面"预警阈值取上限的 ~80%"；范围内恒有 THRESH+512 ≤ LIM−1024（L≥17408 ⟹ 0.9L+512 ≤ L−1024），探针保证越过阈值且不越过上限 |
| LIM ≤4096 视为缺失 | 低于旧故障值 8192 的一半，属未有效扩容 |
| 静默窗口 10s / 告警窗口 30s | 覆盖请求时同步写入的观测粒度加反应余量 |
| 注入日志行格式 | 与 nginx hdrsize/error/access 日志真实格式一致，用于触发门禁行为，非伪造结论 |

**0) 环境在线**：入口与后端任一不可达 → 不通过；tracegate(:9100)/meshd(:15001) 的
`/componentz` 不可达、或响应缺对应组件名指纹（占位桩）→ 不通过；kafka(:9092) TCP 探活
失败（含 3×2s 重试）→ 不通过。

**1) 端到端（多路由/多层）**（探针：值为 16384 个 `x` 的单个自定义 header，头名不限）：
- 入口 `/api/v1/profile` 与 `/healthz` + 超长 header → 200；`/api/v1/profile` 常规请求 → 200；
- 直连 127.0.0.1:9000 同路径 + 超长 header → 200；
- 入口响应头须含 `Server: nginx`（防绕过反代直接放行）；
- **注入链完整性**：验题注入一次性 nonce `X-Trace-Context: vfy<纳秒>` 后，入口响应头回显的
  `X-Trace-Context` 须**按序**包含该 nonce、`gate=` 与 `mesh=` 注入段（真实注入是顺序追加，
  tracegate/meshd 注入、backend 回显），且回显值较 nonce 增幅 ≥2048B——绕过/拆除中间层
  或以静态头伪造注入段的方案不通过；
- **响应体特征校验**：/api/v1/profile 返回体含 `"msg":"ok"`、/healthz 返回体（去空白后）
  等于 `ok`——证明是真实应用在服务，替换成"永远 200"的桩不会通过。

**2) 双层真实修改（反硬编码判定范围，辅助证据）**：
- L1：`nginx -T` 生效配置中 `large_client_header_buffers` 的**单缓冲**数值 ≥ 17408
  （完整 header 行口径，`k`/`M` 后缀折算；仅认未注释的活动指令）；
- L2：对 /app/backend 下所有文本文件（源码与配置，排除常见备份命名：`*.bak`、`*.bak.*`、
  `*.candbak`、`*.orig`、`*.old`、`*.backup`、`*.disabled`）做原故障值
  `8192` 的字面匹配——十进制形态 `(^|[^0-9])8192([^0-9]|$)` 不限上下文，
  等值的移码/十六进制书写形态仅锚定 `MaxHeaderBytes`/`max_header_bytes` 键上下文，
  **命中即不通过**（原故障值必须以任何等值形态从生效的源码/配置中真实移除；
  历史备份文件不计入）；调大到任何足够字节的表达式/数值均可，
  由检查 1/3 的行为探针证明足够；
- **已知局限（披露）**：后端侧行为上边界受探针尺寸限制不可黑盒探测（MB 级 header
  不现实），后端侧以"行为探针 + 源码/配置扫描"组合判定；
- 中间层（tracegate / meshd）限额为配置驱动：`/app/tracegate`、`/app/mesh` 下
  `max_header_bytes` 键上下文分别残留原故障值 `10240`、`12288` → 不通过
  （端到端行为探针为主要判定，扫描为辅助证据）。

**3) 边界与输入覆盖（以你声明的 LIM 为基准）**：
- **声明一致性**：header_limits.env 中的 `NGINX_LARGE_HEADER_BUFFER_BYTES` 折算后必须与
  nginx 生效单缓冲**相等**，否则不通过；
- **上边界**：发送 LIM+4096 字节探针，必须**仍被拒绝**（非 200、非无响应；400/413/431 均
  算拒绝）；LIM 缺失或 >1MB 时跳过该项；
- （行为性检查，不依赖源码字面。）

**4) 质检门禁**：`/app/ops/quality_gate.sh` 存在且可执行。验题会：
- **截断** /var/log/nginx/{access,error,hdrsize}.log（不存在则跳过）并 `nginx -s reopen`，
  重放一轮正常流量后，门禁必须 **exit 0**；
- **分源注入**合成 431 证据并分别验证拦截：
  ① 仅向 access.log 追加一条 combined 格式的 431 记录 → 门禁必须 **exit ≠ 0**；
  ② 再向 hdrsize.log 追加一行 `<unix秒>.000 431 99999 "GET /injected HTTP/1.1"`、
     向 error.log 追加一行含 `client sent too long header line` 的 info 级记录 → 门禁必须 **exit ≠ 0**；
  每轮注入后验题会清理恢复；
- 你的门禁在 hdrsize.log 缺失时应跳过该来源（不得因此误拦或崩溃）。

**5) 预警观测**：
- 读取 header_limits.env：`NGINX_LARGE_HEADER_BUFFER_BYTES` 缺失（或 ≤4096）→ 不通过；
  `WARN_RATIO` 缺失按 80，**声明值超出 [50,90] → 不通过**；
- 验题会再次清理 hdrsize.log 并进入**静默检查**：发送常规请求，10s 内 warnings.log
  行数不得增加（不得误报）；
- **告警检查**：发送 THRESH+512 字节探针两次（立即一次、约 9 秒后一次），30s 内
  warnings.log 行数必须增加（即 `$request_length ≥ THRESH` 的请求必须被观测到）。

**6) 综合分析报告**：/app/ops/diagnosis_report.md 非空；按以下硬断言校验——
① 归因结论：含"归因"或"综合"；
② 状态码链：含"状态码链"或"修复前"，且以箭头（→）呈现分层链条；
③ 数值对照：同时含原故障值 `8192` 与生效的新限额数值（即题面声明的 `NGINX_LARGE_HEADER_BUFFER_BYTES`）；
④ 实质归因：含量化观测证据（`HDRSTAT` / `max_header` / `request_length` 至少其一），
   且同时具备"谁注入过多"（含"注入"或"增长"）与"哪层限制过小"（含"过小"/"未同步"/"未扩容"）两类表述；
⑤ 容量依据：含"余量"或"sizing"；
⑥ 提及所修改的限制项名称（`large_client_header_buffers` / `MaxHeaderBytes` / `ReadBufferSize` 至少其一）；
⑦ 中间层限额对照：同时含 tracegate 原故障值 `10240` 与 meshd 原故障值 `12288` 的数值对照。

**产物 schema（结构化输出契约，验题按此读取）**：
- `/app/ops/header_limits.env`：KEY=VALUE 行；**必含** `NGINX_LARGE_HEADER_BUFFER_BYTES`
  （整数，字节，等于 nginx 生效单缓冲）与 `WARN_RATIO`（整数，百分比，缺失按 80）；
  其余键（如框架层限额、原始值）可选；
- `/app/ops/warnings.log`：每行一条告警（自由文本，建议含时间与触发的请求大小）；
  验题只校验"行数在窗口内是否增加"；
- `/var/log/nginx/hdrsize.log`（可选存在）：每行 `$msec $status $request_length "$request"`；
- `/app/ops/diagnosis_report.md`：Markdown；必含 ①各层状态码链（修复前/分层修复后）
  ②限额修改前后对照（含具体数值）③"归因/综合"结论 ④容量取值依据（"余量"或"sizing"）。

## 约束
- 不要硬编码"通过"结果；修复必须真实生效于配置与源码（验题按上文判定范围检查）；
- 修改 nginx 配置后需通过 nginx -t 校验再重载；
- 修改 Go 源码后需重新编译并重启服务；
- 中间层组件（tracegate/meshd）的限额配置在进程启动时读取，修改后需重启对应组件；
- 链路的注入行为是容量探针的数学前提：gate span（768B）/ mesh span（1536B）/
  X-Mesh-Baggage（512B）不得缩水或拆除，kafka/tracegate/meshd/trace-collector 为环境
  组成部分，不可移除或替换为桩；
- 不依赖外部网络（工具链与源码均在环境内）；
- 观测/门禁需容忍日志截断与轮转（验题会截断日志）。

## 提示（可选）
- 431/400 可能产生于链路的不同层：先用 curl 分别打入口与直连各层，区分拦截点；
  各组件日志（GATESTAT/MESHSTAT/HDRSTAT、审计通道的 produce 应答）提供逐层体量与拦截证据，
  注意区分同步链路的 431 与异步链路的容量信号；
- 区分请求头（request header）与请求体（body）的限制——两者经常被混淆，调错一个不会生效；
- 后端侧的限额可能不止一处、也不止一种形态（标准库默认/显式配置/业务代码逻辑/构建产物）；
  注意甄别看起来相关、但实际未被代码读取的历史配置与环境变量；
  以运行进程的实际观测为准，区分"已书写"与"已生效"；
- 修完别忘了"预防复发"：能提前感知逼近阈值的请求，并在变更质检中把 431 当作高优先级拦截项；
  容量取值要为"Trace 上下文随跳数继续增长"预留余量，并给出你的 sizing 依据。
