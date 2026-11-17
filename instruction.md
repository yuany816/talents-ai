# 排查线上 431 Request Header Fields Too Large

## 背景
某业务站点的接入网关近期上线"全量链路追踪"，会在每个到达入口的请求头中注入较大的
Trace 上下文（单个请求头可达十几 KB，且会随链路跳数继续增长——每经过一跳都会追加一段
span 上下文）。上线后客服陆续收到反馈：部分接口"随机"失败，客户端截获到的响应码在
400 与 431 之间跳变（431 = Request Header Fields Too Large）。值班同学一度只调大了
入口层配置，重启后故障依旧——问题并不是"某个组件配置写错了"这么简单，而是一条链路上
多个模块共同作用的结果。这套接入层经历过多次入口重构与配额调整：代码库里同时保留着
现行入口、退役入口存档和多份配置档案副本，各处数值的对齐情况从未做过端到端核验；
这也意味着容量评估要为"继续增长"预留余量，而不是刚好够用。此外，这套接入层历史上
经历过多次发布模式切换，部分组件曾由部署编排（supervisord program environment）注入
运行时参数——磁盘配置与实际生效值并不总是一致。

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
     /app/backend 的源码或配置（独立判分以"声明 + 行为"双证据判定，见"验题契约"）；
   - 链路其余各层（tracegate / meshd）的限额同样必须真实调大——由端到端行为探针判定，
     并以 evidence/ 中记录的逐层计数与限额值交叉印证（原故障值 10240 / 12288）；
   - **tracegate 的 span 注入须恢复链路规格**：gate span 每跳注入恰为 **768B**
     （规格见下文"注入链 span 固定尺寸"），当前 `tracegate.yaml` 的 `span_bytes`
     曾被带宽节省专项临时下调——注入链增幅探针与逐层计数核验（`GATESTAT`
     `trace_out−trace_in` 精确 == 769）都会失败；缩水与凭空增大均判不通过；
4. **异步链路治理（计入评分：计数维度）**：Kafka 审计旁路的 `message.max.bytes`
   （原故障值 16384）过小——审计事件携带全量请求头快照，超限被拒
   （backend 日志 MESSAGE_TOO_LARGE）。治理后大请求的审计事件必须真实落盘
   （`/var/log/trace_events.log`，以一次性标记自证并记入 evidence/kafka_audit.txt）；
   动态调整须同步落盘 `/opt/kafka/config/kraft/server.properties`（落盘值随证据记录，
   防重启回退）；取值须为"全量头快照 + 余量"（建议 ≥64KiB）；
   综合报告中应予三角说明（报告断言⑧）；
5. **持续防线，产物落盘于 /app/ops/**：
   - `header_limits.env`：链路限额与预警参数，**必须**包含 `NGINX_LARGE_HEADER_BUFFER_BYTES`
     （nginx 侧单 header 上限，字节，须与 nginx 生效单缓冲一致）与 `WARN_RATIO`
     （预警阈值百分比，有效范围 **[50, 90]**，缺失时验题按 80 处理）；
   - 观测能力（可由后端观测中间件在请求处理路径中同步实现，无独立常驻进程亦可）：
     请求达到阈值时向 `warnings.log` 追加告警行，**30 秒内**必须可观测到（行数增加）；
     **告警行须携带真实观测字节数**（行内含 ≥ 阈值的整数，空文本/小数值伪造行无效）；
     远低于阈值的常规请求不得产生告警；
   - `quality_gate.sh`：变更质检门禁，对日志中的 431 高优先级拦截——检查
     /var/log/nginx/hdrsize.log（若存在，格式 `$msec $status $request_length ...`）、
     /var/log/nginx/access.log 与 /var/log/nginx/error.log；日志干净时退出码 0，出现 431 时**非零**退出；
   - `diagnosis_report.md`：链路级综合分析报告——包含各层状态码链（修复前/分层修复后）、
     各模块限额修改前后对照，以及对"哪个模块注入的 header 过多、哪几层限制过小"的归因结论
     （结论是链路级综合归因，不是单点归责）；
   - `evidence/`（独立判分证据，Harbor 随 /app/ops/ 收集，判分环境按同一绝对路径读取，
     **不再发起实时探针**）：`nginx_T.txt`（nginx -T 完整输出）、`curl_entry.txt`
     （入口探针：大探针/常规/healthz 大探针状态码 + Server 响应头 + 响应体）、
     `curl_backend.txt`（直连后端探针）、`upper_boundary.txt`（双侧边界探针记录）、
     `span_count.txt`（一次性 nonce 注入链回显 + GATESTAT/MESHSTAT 逐层精确计数）、
     `kafka_audit.txt`（kafka 探活/组件指纹/限额落盘值/审计事件标记自证）——
     **环境已内置采集脚本 `/app/collect_evidence.sh`：运行它自动生成六文件，
     然后核对输出取值与实际配置一致、按需手工修正**（观测路径不同的部分）；
     逐文件 schema 与判定口径见"验题契约"，相互矛盾的记录按失败计；
   - `/app/ops/` 各交付物均已预置空模板（含注释示例，不计分）：填实
     `header_limits.env`、实现并 `chmod +x` `quality_gate.sh`、按契约填写
     `diagnosis_report.md`；`/app/ops/README.md` 有完整交付说明。

## 验题契约（tests/test.sh 的精确行为，agent 可据此还原判定）

**判定总则（独立判分）**：题包以 `environment_mode = "separate"` 提交——判分环境为
tests/Dockerfile 镜像（bash/curl/coreutils/grep/awk/sed，**无 nginx/go/kafka 等服务**），
验题**不发任何实时探针**，全部判定读取交付目录 /app/ops/（task.toml artifacts）及其
evidence/ 六个证据文件。验题为**加权连续评分 + 双级门槛**，结果写入
/logs/verifier/reward.txt（0~1 浮点，4 位小数）：`reward = 0.15×结构完整性 +
0.25×基础修复 + 0.40×边界与防线 + 0.2×报告质量`。各维度按其子检查的**通过比例**
取 0~1（子检查与各节对应关系见下）；下文各节所述"不通过"即指该子检查不通过，其中
行为类证据失败通常意味着对应修复未真实生效，连锁拉低多个维度。子检查归属：
**结构完整性**（3 交付阶段，逐阶段 all-or-nothing）= 阶段1 `/app/ops/header_limits.env`
存在且格式合法（LIM 整数 >4096，RATIO∈[50,90] 或缺失按 80）→ 阶段2
`quality_gate.sh` 可执行 → 阶段3 `diagnosis_report.md` 与 evidence/ 六文件齐全；
**基础修复**（6 项）= 0) 组件在线、1) 端到端与注入链完整性、L1 生效、L2 后端限额
声明+行为、声明一致性（全部读证据文件）；**边界与防线**（9 项）= 3) 上边界拒绝与
双侧夹逼、4) 质检门禁（判分环境本地伪造日志执行你的脚本：干净通过 + access/hdrsize/
error **三源各自独立**注入，每源另带非 431 内容不得误拦的对照）、链路计数（span 精确
注入、kafka 审计证据）、预警内容实质；**报告质量**（8 项）= 6) 综合分析报告硬断言
①~⑧（关键词之外还要求**同行配对/数值一致性**，纯关键词堆砌不通过）。

**双级门槛**（在加权总分之上生效）：
- **VETO（一票否决 → reward=0）**：① 报告实质归因缺失——断言①（归因结论）或
  ④（实质归因：量化证据 + 注入侧 + 限制侧）未通过（含报告缺失）；
  ② 质检门禁核心行为失败——无日志误拦或任一分源注入未拦截（含门禁缺失）；
- **CAP（交付空心封顶 → reward=min(总分, 0.55)）**：仅当 structure 与 basic 两维度
  **均无任何通过项**时触发；边界与防线（edge）的单项缺失只扣该维度分，不额外封顶。

evidence/ 由环境内置的 `/app/collect_evidence.sh` **自动采集**：运行它，脚本按作答
环境实际状态探测（nginx -T、入口/直连后端探针、双侧边界探针、一次性 nonce 注入链、
GATESTAT/MESHSTAT 逐层计数、kafka 探活/组件指纹/审计标记）并生成六文件；运行后
**核对输出取值与实际配置一致**，观测路径不同的部分手工修正。判分环境亦有同目录
模板与 `/app/ops/README.md` 说明。各记录**互相咬合**：如 span_count.txt 的回显增幅
必须恰等于逐层计数之和（2306B），upper_boundary.txt 的 declared_lim 必须与
header_limits.env 的 LIM 相等——相互矛盾、偏离规格或凭空书写的记录按该子检查
失败计。验题脚本**可重复执行**（判分环境本地伪造日志的注入均会清理复原）。
门禁注入含**随机化**：标记、路径、字节数与两日志书写顺序每轮不同——门禁须按
"431 证据"语义实现而非匹配固定行。

**固定参数及其题面依据**：

| 固定值 | 依据 |
|---|---|
| 探针 16384 字节 | 题面复现场景；高于旧 nginx 默认单行上限 8k 与后端旧故障值 8192。**完整 header 行 ≈16402B**（字段名 14B + ": " + 16384B + CRLF） |
| L1 要求 ≥17408B（17KiB） | 完整 header 行口径：16384B 值 + 行开销约 18B + 1KiB 余量——恰好 16384 的缓冲会误拒合规探针 |
| LIM 须 == nginx 生效单缓冲 | 边界与预警判定需与实际限额同一数值基准；多条未注释指令须全部与 LIM 相等（取值不一致=配置漂移） |
| L2 判定口径 | 判分环境无 /app/backend，源码字面扫描不再由判分环境执行——以 header_limits.env 的 `APP_MAX_HEADER_BYTES`（须 >8192）+ `backend_big_status=200` 行为证据双口径判定（作答环境仍须真实移除原故障值及其等值书写形态） |
| 中间层判定口径 | tracegate/meshd 限额行为由注入链证据（span_count.txt 逐层计数 + 回显增幅）与组件指纹交叉印证——原故障值 `10240` / `12288` 对应的"调大"必须真实生效；运行时生效值可能受部署编排环境覆盖，以组件日志实际计数为准 |
| 组件探针/指纹（证据记录） | kafka_audit.txt：`kafka_tcp=ok`；tracegate(:9100)/meshd(:15001) 的 `/componentz` 响应记录须含各自组件名（占位桩/移除组件无法自洽）——组件为环境组成部分 |
| 注入链 nonce 探针（证据记录） | 你在作答环境向入口注入一次性 `X-Trace-Context: <nonce>`，将 nonce 与完整回显记入 span_count.txt；回显须**按序**含 nonce→`gate=`→`mesh=` 段（静态 add_header 无法预知 nonce；绕层则无注入段） |
| span 固定尺寸（证据锚定） | gate span 768B / mesh span 1536B / X-Mesh-Baggage 512B（每请求注入增幅 ≈2.9KB）——容量探针数学的前提，**不得缩水或拆除，也不得凭空增大**：span_count.txt 锚定精确值（`gate_trace_delta`==769、`mesh_trace_delta`==1537、`baggage_bytes`==512，且回显增幅 `${#echo}−${#nonce}` 必须恰 ==2306=769+1537，两口径互相咬合） |
| kafka 审计证据（证据记录） | 以一次性标记大探针（值 >16384 且 ≤LIM）自证审计事件落盘：`audit_event_marker` + `audit_event_recorded=ok`；`kafka_message_max_bytes_static`（server.properties 落盘值）须 >16384（残留 16384 → 不通过） |
| 注入链完整性（证据记录） | echo（入口常规请求回显的 `X-Trace-Context`）须同时含 `gate=` 与 `mesh=` 段（tracegate/meshd 注入、backend 回显）——防绕层伪修复 |
| 上边界探针（证据记录） | `above_probe_bytes` 必须 > `declared_lim`（建议 LIM+4096），对应 `above_status` ∉ {200, 空}（400/413/431 均算拒绝）；大探针建议经 `curl -H @file` 投递（规避内核单参数 ~128KB 上限）——**@file 须为完整头行（含字段名与结尾换行），curl 会静默丢弃无冒号行**；LIM>1MB 时跳过该项（不计入分母） |
| 双侧边界探针（证据记录） | `below_probe_bytes` ∈ [16384, LIM)（建议 LIM−{512~1536}）且 `below_status`=200（卡线余量不足会被误拒）；上侧同上 |
| 预警观测（证据记录） | 运行时窗口不再由判分环境复现（判分环境无服务可发探针）；以交付的 warnings.log 内容实质判定：至少一条告警行含 ≥ THRESH 的整数观测值（空文本/小数值伪造行不通过）；"远低于阈值不得误报"仍是实现契约 |
| THRESH = LIM×RATIO/100，RATIO 有效范围 [50,90] | 题面"预警阈值取上限的 ~80%"；范围内恒有 THRESH+512 ≤ LIM−1024（L≥17408 ⟹ 0.9L+512 ≤ L−1024），你的探针保证越过阈值且不越过上限 |
| LIM ≤4096 视为缺失 | 低于旧故障值 8192 的一半，属未有效扩容 |
| 静默窗口 10s / 告警窗口 30s | 实现契约：请求时同步写入的观测粒度加反应余量（判分不校验窗口，见上） |
| 门禁注入日志行格式 | 判分环境本地伪造的日志与 nginx hdrsize/error/access 真实格式一致（标记/路径/字节数/顺序随机），用于触发门禁行为 |

**0) 组件在线（basic/01，读 kafka_audit.txt）**：`kafka_tcp=ok`；`tracegate_componentz`
记录须含 `"tracegate"`、`meshd_componentz` 记录须含 `"meshd"`（组件指纹——占位桩或
移除组件的记录无法自洽）→ 任一不满足不通过。

**1) 端到端（basic/02，读 curl_entry.txt / curl_backend.txt）**（探针：值为 16384 个
`x` 的单个自定义 header，头名不限）：
- `entry_big_status` / `entry_norm_status` / `healthz_big_status` 三条记录均 = 200；
- `server_header` 含 `nginx`（防绕过反代直接放行）；
- `profile_body` 含 `"msg":"ok"`、`healthz_body` 去空白后恰为 `ok`（响应体特征——
  替换成"永远 200"的桩不会通过）；
- 直连后端：`backend_big_status` = 200 且 `profile_body` 同口径。
- **注入链完整性（basic/03，CAP 触发项，读 span_count.txt）**：`echo` 记录须**按序**
  包含 `nonce`、`gate=` 与 `mesh=` 段（真实注入是顺序追加），且回显较 nonce 增幅
  ≥2048B——绕过/拆除中间层或以静态头伪造注入段的记录无法满足有序段与增幅。

**2) 真实修改（basic/04~06，读 nginx_T.txt 与 header_limits.env）**：
- L1：`nginx_T.txt`（nginx -T 完整输出）中**全部**未注释的 `large_client_header_buffers`
  活动指令单缓冲 ≥ 17408（完整 header 行口径，`k`/`M` 后缀折算）——逐条取**最小值**
  判定：残留的过小指令（http/server/location 任一层）按 nginx 继承语义在对应作用域
  真实生效，仅验首条不构成判定；
- L2 后端：`APP_MAX_HEADER_BYTES` > 8192（声明）且 `backend_big_status=200`（行为）
  双证据——判分环境无 /app/backend，源码字面扫描不再由判分环境执行（作答环境仍须
  真实移除原故障值及其等值书写形态，含退役入口存档；备份后缀文件不计）；
- **声明一致性**：`NGINX_LARGE_HEADER_BUFFER_BYTES` 折算后必须与 nginx_T.txt 生效
  单缓冲**相等**；存在多条未注释指令时各条须**全部与 LIM 相等**（同一限额键多处
  取值不一致属配置漂移，无法确定入口实际生效值，按不通过处理）。

**3) 边界与输入覆盖（edge/01、edge/08，读 upper_boundary.txt）**：
- **上边界**：`above_probe_bytes` > `declared_lim` 且 `above_status` ∉ {200, 空}
  （必须**仍被拒绝**；400/413/431 均算拒绝）；`declared_lim` 须与 header_limits.env
  的 LIM 相等；LIM 缺失或 >1MB 时跳过该项（不计入分母）；
- **双侧夹逼**：`below_probe_bytes` ∈ [16384, LIM) 且 `below_status` = 200（下侧不得
  卡线误拒）；上侧同上。

**4) 质检门禁（edge/02~05，判分环境本地执行你的 /app/ops/quality_gate.sh）**：
- **干净**（edge/02）：判分环境无任何 /var/log/nginx 日志 → 门禁必须 **exit 0**
  （跳过全部缺失来源，不得误拦或崩溃）；
- **分源注入① access**（edge/03）：仅伪造 access.log 并追加一条 combined 格式的随机
  431 记录（路径/字节数/时间戳/UA 每轮随机）→ 门禁必须 **exit ≠ 0**；
- **分源注入② hdrsize**（edge/04）：仅伪造 hdrsize.log 并追加一行
  `<msec> 431 <随机长度> "GET <随机路径> HTTP/1.1"`（error.log 完全不存在，同时复验
  缺文件容忍）→ 门禁必须 **exit ≠ 0**；
- **分源注入③ error**（edge/05）：仅伪造 error.log 并追加一行含
  `client sent too long header line` 的 info 级记录（hdrsize.log 完全不存在）→
  门禁必须 **exit ≠ 0**；
- **非 431 对照**：每源注入判定后，仅追加该源的**非 431** 内容（access/hdrsize 的
  200 记录、error 的无关 info 行）→ 门禁必须 **exit 0**——按"431 证据"语义逐源
  判定，非 431 内容不得误拦；每轮注入后验题会清理复原；
- 门禁脚本在判分镜像内以 bash 执行（bash/curl/coreutils/grep/awk/sed 可用，无 nginx/go），
  不得依赖环境内服务或 /var/log 之外的现场状态。

**5) 预警内容实质（edge/09，读交付 warnings.log）**：
- 读取 header_limits.env：`NGINX_LARGE_HEADER_BUFFER_BYTES` 缺失（或 ≤4096）→ 不通过；
  `WARN_RATIO` 缺失按 80，**声明值超出 [50,90] → 不通过**（结构维度）；
- warnings.log 非空，且至少一条告警行含 ≥ `THRESH = LIM×RATIO/100` 的整数观测值
  （行内最大整数即"观测到的请求体量"）——空文本/小数值伪造行不通过；
- （运行时静默/触发窗口不再由判分环境复现——判分环境无服务可发探针；"远低于阈值
  不得误报、达到阈值 30s 内可观测"仍是实现契约，以你的 warnings.log 记录为判定对象。）

**6) 综合分析报告**：/app/ops/diagnosis_report.md 非空；按以下硬断言校验——
关键词之外还要求**同行配对/数值一致性**（对照须落在同一行/同一表行，散落全文的孤立
关键词不构成对照，防"关键词堆砌"式报告）：
① 归因结论：含"归因"或"综合"，且报告点名 ≥2 个链路组件（nginx / tracegate / meshd /
   backend 至少其二——链路级归因须落到具体模块）；
② 状态码链：含"状态码链"或"修复前"，且**同一行**以箭头（→）呈现真实码值链条
   （431/400 → … → 200）；
③ 数值对照：**同一行**含原故障值 `8192` 与更大的新值（≥16402B——16384B 探针完整行下限，k/M 折算），
   且报告全文含题面声明的 `NGINX_LARGE_HEADER_BUFFER_BYTES` 数值（与 header_limits.env
   咬合）；
④ 实质归因（触发 VETO）：量化观测证据行（`HDRSTAT` / `max_header` / `request_length`
   至少其一）须**携带真实字节数**（≥3 位数字），且同时具备"谁注入过多"（含"注入"或
   "增长"）与"哪层限制过小"（含"过小"/"未同步"/"未扩容"）两类表述；
⑤ 容量依据：含"余量"或"sizing"的行须**携带数值**（字节/百分比）；
⑥ 提及所修改的限制项名称（`large_client_header_buffers` / `MaxHeaderBytes` / `ReadBufferSize` 至少其一）；
⑦ 中间层限额对照：tracegate 原故障值 `10240` 与 meshd 原故障值 `12288` 各自**同行**
   伴随更大的新值（≥16402B——16384B 探针完整行下限，k/M 折算
   通过后必然 ≥17408）；
⑧ 异步审计旁路三角说明：**同一行**含原 broker 限额 `16384` 与 kafka / MESSAGE_TOO_LARGE
   （治理对照 16384→新值 或 容量信号归因行），并区分于同步 431（断言①/④任一未通过
   触发 VETO）。

**产物 schema（结构化输出契约，判分环境按此读取；task.toml artifacts =
["/app/ops/header_limits.env", "/app/ops/"]——主交付物为 header_limits.env 单文件
（对应 structure 阶段1），其余产物与 evidence/ 随目录一并收集作为加分项）**：
- `/app/ops/header_limits.env`：KEY=VALUE 行；**必含** `NGINX_LARGE_HEADER_BUFFER_BYTES`
  （整数，字节，等于 nginx 生效单缓冲）、`WARN_RATIO`（整数，百分比，缺失按 80）与
  `APP_MAX_HEADER_BYTES`（整数，字节，>8192，后端侧生效限额——basic/05 的声明证据）；
  其余键（如框架层限额、原始值）可选；
- `/app/ops/warnings.log`：每行一条告警（建议含时间与触发的请求大小）；edge/09 校验
  **至少一条行含 ≥ 阈值的整数观测值**（空文本/小数值伪造行不通过）；
- `/app/ops/quality_gate.sh`：可执行（判分环境以 bash 本地执行，见契约 4）；
- `/app/ops/diagnosis_report.md`：Markdown；必含 ①各层状态码链（修复前/分层修复后）
  ②限额修改前后对照（含具体数值）③"归因/综合"结论 ④容量取值依据（"余量"或
  "sizing"）⑤异步审计旁路三角说明（kafka 治理对照 16384→新值 / MESSAGE_TOO_LARGE
  归因，报告断言⑧）；
- `/app/ops/evidence/`（独立判分证据，六文件；key=value 行格式，判分脚本以
  `^KEY=` 前缀解析——值可含空格外的任意内容，勿在行尾追加注释）：
  - `nginx_T.txt`：`nginx -T 2>&1` 的**完整输出**（含 `# configuration file` 分节标记；
    basic/04 与 basic/06 从中解析未注释的 `large_client_header_buffers`）；
  - `curl_entry.txt`：`entry_big_status=` / `entry_norm_status=` / `healthz_big_status=`
    （HTTP 状态码）、`server_header=`（Server 响应头值）、`profile_body=` / `healthz_body=`
    （响应体，`healthz_body` 为去空白后的值）；
  - `curl_backend.txt`：`backend_big_status=`（直连 127.0.0.1:9000 大探针状态码）、
    `profile_body=`；
  - `upper_boundary.txt`：`declared_lim=`（须与 header_limits.env 的 LIM 相等）、
    `below_probe_bytes=` / `below_status=`（∈ [16384, LIM)，须 200）、
    `above_probe_bytes=`（> LIM，建议 LIM+4096）/ `above_status=`（须非 200 且非空）；
  - `span_count.txt`：`nonce=`（一次性 X-Trace-Context 值）、`echo=`（入口回显的完整
    X-Trace-Context 头值，须按序含 nonce→`gate=`→`mesh=` 且增幅 ≥2048B）、
    `gate_trace_delta=`（GATESTAT `trace_out−trace_in`，PASS 行，须恰 769）、
    `mesh_trace_delta=`（MESHSTAT 同口径，须恰 1537）、`baggage_bytes=`（须恰 512；
    回显增幅须恰 2306 = 769+1537，两口径互相咬合——CAP 触发项）；
  - `kafka_audit.txt`：`kafka_tcp=ok`、`tracegate_componentz=` / `meshd_componentz=`
    （各自 /componentz 响应体，含组件名指纹）、`kafka_message_max_bytes=`（动态生效值）、
    `kafka_message_max_bytes_static=`（server.properties 落盘值，须 >16384）、
    `audit_event_marker=`（一次性标记）、`audit_event_recorded=ok`（标记事件已见于
    /var/log/trace_events.log 的自证——CAP 触发项）。

## 约束
- 不要硬编码"通过"结果；修复必须真实生效于配置与源码；evidence/ 须来自作答环境的
  真实探针（判分以记录间的互相咬合与规格锚定判定，凭空书写/相互矛盾的记录按失败计）；
- 修改 nginx 配置后需通过 nginx -t 校验再重载；
- 修改 Go 源码后需重新编译并重启服务；
- 中间层组件（tracegate/meshd）的限额配置在进程启动时读取，修改后需重启对应组件；
- supervisord 程序级 environment 属于组件运行时配置的一部分：修改 supervisord 配置后需
  `supervisorctl reread && supervisorctl update` 交编排进程接管（仅 restart 不会重读配置）；
- 链路的注入行为是容量探针的数学前提：gate span（768B）/ mesh span（1536B）/
  X-Mesh-Baggage（512B）不得缩水或拆除、也不得凭空增大（逐层计数核验锚定精确值），
  kafka/tracegate/meshd/trace-collector 为环境组成部分，不可移除或替换为桩；
- 审计事件必须保留全量请求头快照（不得裁剪事件头或瘦身后发送）——异步审计链路的
  计数核验依赖完整快照；kafka 限额动态调整须同步落盘静态配置（防重启回退）；
- 不依赖外部网络（工具链与源码均在环境内）；
- quality_gate.sh 不得依赖判分环境不存在的现场（nginx/服务/既有日志须可跳过），
  且须容忍日志创建/截断与轮转（判分环境会本地伪造日志验证其拦截行为）。

## 提示（可选）
- 431/400 可能产生于链路的不同层：先用 curl 分别打入口与直连各层，区分拦截点；
  各组件日志（GATESTAT/MESHSTAT/HDRSTAT、审计通道的 produce 应答）提供逐层体量与拦截证据，
  注意区分同步链路的 431 与异步链路的容量信号；
- 链路注入的**逐层计数**（GATESTAT/MESHSTAT 的 trace_in/trace_out/baggage 字段）是
  容量数学的观测证据：span 注入尺寸偏离规格（缩水或虚增）都会让计数失真——
  以组件日志的实际计数核对题面规格（768/1536/512）；
- 异步审计链路是"计数维度"的判定对象：大探针的审计事件须真实落盘
  （/var/log/trace_events.log），kafka 限额与事件体积的余量关系用你的 sizing 依据说明；
- 区分请求头（request header）与请求体（body）的限制——两者经常被混淆，调错一个不会生效；
- 后端侧的限额可能不止一处、也不止一种形态（标准库默认/显式配置/业务代码逻辑/构建产物）；
  注意甄别看起来相关、但实际未被代码读取的历史配置与环境变量；
  反之亦然：看似装饰性的注入参数未必无效——生效限额可能来自部署环境而非磁盘配置，
  以组件启动日志打印的生效值（及 source 标注）与进程环境为准；
  以运行进程的实际观测为准，区分"已书写"与"已生效"；
- 修完别忘了"预防复发"：能提前感知逼近阈值的请求，并在变更质检中把 431 当作高优先级拦截项；
  容量取值要为"Trace 上下文随跳数继续增长"预留余量，并给出你的 sizing 依据。
