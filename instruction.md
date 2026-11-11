# 排查线上 431 Request Header Fields Too Large

## 背景
某业务站点的接入网关近期上线"全量链路追踪"，会在每个到达入口的请求头中注入较大的
Trace 上下文（单个请求头可达十几 KB）。上线后客服陆续收到反馈：部分接口"随机"失败，
客户端截获到的响应码在 400 与 431 之间跳变（431 = Request Header Fields Too Large）。
值班同学一度只调大了入口层配置，重启后故障依旧——问题并不是"某个组件配置写错了"这么简单，
而是一条链路上多个模块共同作用的结果。

## 当前状态
- 环境内已运行完整链路：nginx（入口反代，监听 80）→ Go 后端（127.0.0.1:9000）
- 后端源码位于 /app/backend（标准 Go module，可离线编译；预编译二进制已随服务运行）
- 已注册路由：`/api/v1/profile`（业务接口）、`/healthz`
- 日志位置：nginx 在 /var/log/nginx/（error log 已开 info 级），后端 stdout/stderr 在 /var/log/backend.log
- 复现方式：向入口发送携带超大自定义 header 的请求（例如值为 16384 字节的 X-Debug-Trace），
  对比直连后端（127.0.0.1:9000）的返回，观察响应码差异与各层日志

## 期望结果
1. **端到端修复**：携带 16384 字节单个自定义 header 的请求，经入口访问 /api/v1/profile（及
   /healthz）与直连后端均返回 200（与常规请求一致）；
2. **限额语义保持**：调大 ≠ 取消——超过（你自己声明的）上限的请求仍应被拒绝；
3. **双层真实修复（可被检查）**：
   - nginx 生效配置（`nginx -T` 输出）中存在 `large_client_header_buffers`，单缓冲 ≥ 16384 字节
     （接受 k/M 后缀写法）；
   - /app/backend 下 `*.go` 源码中的框架层 header 限额被真实调大并重新编译生效，
     原故障值 `MaxHeaderBytes: 8192` 不得残留（验题做字面匹配，见"验题契约"）；
4. **持续防线，产物落盘于 /app/ops/**：
   - `header_limits.env`：链路限额与预警参数，**必须**包含 `NGINX_LARGE_HEADER_BUFFER_BYTES`
     （nginx 侧单 header 上限，字节，须与 nginx 生效单缓冲一致）与 `WARN_RATIO`
     （预警阈值百分比，缺失时验题按 80 处理）；
   - `header_size_watch.sh`（或等价观测进程，pid 记录于 `watchdog.pid`）：基于日志增量判断，
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
| 探针 16384 字节 | 题面复现场景；高于旧 nginx 默认单行上限 8k 与后端旧故障值 8192 |
| L1 要求 ≥16384B | 保证 16KB 探针能通过且高于旧默认 4×8k |
| LIM 须 == nginx 生效单缓冲 | 边界与预警判定需与实际限额同一数值基准 |
| 上边界探针 LIM+4096 | 必须越过声明上限以验证"仍被拒绝"；LIM>1MB 时跳过（受单参数长度限制） |
| 预警探针 THRESH+512（≤LIM−1024） | 必须越过阈值触发告警，但不得越过上限 |
| THRESH = LIM×RATIO/100，RATIO 缺省 80 | 题面"预警阈值取上限的 ~80%" |
| LIM ≤4096 视为缺失 | 低于旧故障值 8192 的一半，属未有效扩容 |
| 静默窗口 10s / 告警窗口 30s | 覆盖 3s 级日志轮询粒度加反应余量 |
| 注入日志行格式 | 与 nginx hdrsize/error 日志真实格式一致，用于触发门禁行为，非伪造结论 |

**0) 环境在线**：入口与后端任一不可达 → 不通过。

**1) 端到端（多路由/多层）**（探针：值为 16384 个 `x` 的单个自定义 header，头名不限）：
- 入口 `/api/v1/profile` 与 `/healthz` + 超长 header → 200；`/api/v1/profile` 常规请求 → 200；
- 直连 127.0.0.1:9000 同路径 + 超长 header → 200；
- 入口响应头须含 `Server: nginx`（防绕过反代直接放行）；
- **响应体特征校验**：/api/v1/profile 返回体含 `"msg":"ok"`、/healthz 返回体（去空白后）
  等于 `ok`——证明是真实应用在服务，替换成"永远 200"的桩不会通过。

**2) 双层真实修改（反硬编码判定范围，辅助证据）**：
- L1：`nginx -T` 生效配置中 `large_client_header_buffers` 的**单缓冲**数值 ≥ 16384
  （`k`/`M` 后缀折算；仅认未注释的活动指令）；
- L2：对 /app/backend 下所有 `*.go` 做字面正则匹配
  `MaxHeaderBytes:\s*8192([^0-9]|$)`，**命中即不通过**（原故障值必须被真实修改）；
  调大到任何足够字节的表达式/数值均可，由检查 1/3 的行为探针证明足够。

**3) 边界与输入覆盖（以你声明的 LIM 为基准）**：
- **声明一致性**：header_limits.env 中的 `NGINX_LARGE_HEADER_BUFFER_BYTES` 折算后必须与
  nginx 生效单缓冲**相等**，否则不通过；
- **上边界**：发送 LIM+4096 字节探针，必须**仍被拒绝**（非 200、非无响应；400/413/431 均
  算拒绝）；LIM 缺失或 >1MB 时跳过该项；
- （行为性检查，不依赖源码字面。）

**4) 质检门禁**：`/app/ops/quality_gate.sh` 存在且可执行。验题会：
- **截断** /var/log/nginx/{access,error,hdrsize}.log（不存在则跳过）并 `nginx -s reopen`，
  重放一轮正常流量后，门禁必须 **exit 0**；
- **注入**合成 431 证据（向 hdrsize.log 追加一行 `<unix秒>.000 431 99999 "GET /injected HTTP/1.1"`，
  向 error.log 追加一行含 `client sent too long header line` 的 info 级记录）后，
  门禁必须 **exit ≠ 0**；注入后验题会清理恢复；
- 你的门禁在 hdrsize.log 缺失时应跳过该来源（不得因此误拦或崩溃）。

**5) 预警观测**：
- 读取 header_limits.env：`NGINX_LARGE_HEADER_BUFFER_BYTES` 缺失（或 ≤4096）→ 不通过；
  `WARN_RATIO` 缺失按 80；校验 watchdog.pid 指向的观测进程存活；
- 验题会再次清理 hdrsize.log 并进入**静默检查**：发送常规请求，10s 内 warnings.log
  行数不得增加（不得误报）；
- **告警检查**：发送 THRESH+512 字节探针两次（立即一次、约 9 秒后一次），30s 内
  warnings.log 行数必须增加（即 `$request_length ≥ THRESH` 的请求必须被观测到）。

**6) 综合分析报告**：/app/ops/diagnosis_report.md 非空；包含"归因"或"综合"表述；
提及所修改的限制项名称（`large_client_header_buffers` / `MaxHeaderBytes` / `ReadBufferSize` 至少其一）。

## 约束
- 不要硬编码"通过"结果；修复必须真实生效于配置与源码（验题按上文判定范围检查）；
- 修改 nginx 配置后需通过 nginx -t 校验再重载；
- 修改 Go 源码后需重新编译并重启服务；
- 不依赖外部网络（工具链与源码均在环境内）；
- 观测/门禁需容忍日志截断与轮转（验题会截断日志）。

## 提示（可选）
- 431/400 可能产生于链路的不同层：先用 curl 分别打入口与直连后端，区分拦截点；
- nginx 对请求头行/缓冲有可配置上限（与请求头单行长度、缓冲区个数相关）；
- Go 标准库与常见 HTTP 框架对请求头也有自己的限额（可在源码中显式设置），两层都要核对；
- 修完别忘了"预防复发"：能提前感知逼近阈值的请求，并在变更质检中把 431 当作高优先级拦截项。
