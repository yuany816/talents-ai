# headeragg 规格书（F6 实现题 · v6）

交付物：可执行文件 `/app/ops/bin/headeragg`（静态编译；判分环境直接启动）+ 源码
`/app/ops/src/headeragg/`。运行：`headeragg <THRESH> <STATE_FILE>`（argv[1]=告警阈值
字节整数，argv[2]=持久化状态文件路径），监听 **127.0.0.1:9200**。

## 端点
- `POST /event`：body 为单行 `ts=<毫秒> route=<路由> bytes=<字节数>`（空格分隔三字段）。
  每次调用将该事件计入聚合状态，并**同步**将全量状态持久化到 argv[2]（原子写：临时文件+rename）。
  响应：`200 accepted`。
- `GET /stats`：返回 JSON 数组，按 route **字节序升序**：
  `[{"route":R,"events":N,"bytes":B,"max":M,"over":K},...]`
  - events=该 route 事件数；bytes=bytes 字段总和；max=单事件最大 bytes；over=bytes ≥ THRESH 的事件数；
  - **序列化钉死**：字段顺序固定为 route,events,bytes,max,over；紧凑无空格；
    UTF-8 字节原样（HTML 字符不转义）；空状态输出 `[]`。
    判分对 /stats 做逐字节对照——语义相同但序列化不同（字段顺序/空格差异）同样判失败。
- `GET /health`：`200 ok`。

## 语义钉子（全部为实现正确性要求，判分隐性套件逐条覆盖）
1. **并发精确**：100 个并发 POST 后 events 必须恰为 100——不得丢失更新（需互斥）；
2. **重启恢复**：进程被杀死并重启后，GET /stats 必须返回重启前全量状态（状态文件恢复）；
   重启后继续 POST 的累计值必须衔接；
3. **多字节路由**：route 为 UTF-8 多字节串时按**字节序**参与排序与统计（非 rune 数）；
4. **边界语义**：bytes **恰好等于** THRESH 计入 over（≥ 语义）；
5. **畸形事件**：字段缺失/非整数/负数 → 整行拒绝（不计入），响应 `400 rejected`；
6. **尾斜杠路由**：`/a` 与 `/a/` 是两个独立 route；
7. **原子持久化**：状态文件损坏/缺失时视为空状态重启（不得崩溃）。

## 隐性验收
判分启动 agent 交付的二进制与参考实现各一实例，**同一请求序列双实例差分**——
12 个场景（含 100 并发、kill -9 重启恢复、多字节、THRESH 边界、畸形事件）逐字段
对照 /stats——任一字段不一致该场景即失败，12 场景按通过比例计分。
