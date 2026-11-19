# /app/ops 交付目录说明（判分只读取本目录）

容量参数随 trial 随机生成于 `params.env`（LIM / WARN_RATIO）——**配置与声明必须与
params.env 一致，硬编码固定值会被一致性检查扣分**。

## 两阶段交付

**阶段 1（复现 + 取证）**——先取证后修复，只有脚本没有修复前输出不计分：
每个面交付 `repro/Fx.sh`（可执行脚本）+ `repro/Fx.out`（**修复前**运行的真实输出，
须含修复前故障签名）：

| 面 | Fx.out 须含的签名 |
|---|---|
| F1 nginx | 状态码 400 或 431 |
| F2 backend | 431 或 quota=8192 或 Request Header 拒绝 |
| F3 tracegate | GATESTAT/MESHSTAT 计数行且 gate 增幅≠769 或 mesh 增幅≠1537 |
| F4 kafka | MESSAGE_TOO_LARGE / kafka produce failed / 原限额 16384 |

**阶段 2（修复 + 证据 + 报告）**：
1. 五面修复真实生效（nginx reload / Go 重编译重启 / 中间层重启组件 / kafka 落盘）；
2. 证据文件：
   ```
   bash /app/tools/collect_nginx.sh     # → evidence/F1_nginx_T.txt
   bash /app/tools/collect_backend.sh   # → evidence/F2_backend_status.txt
   bash /app/tools/collect_trace.sh     # → evidence/F3_span_count.txt
   bash /app/tools/collect_kafka.sh     # → evidence/F4_kafka_audit.txt
   bash /app/tools/collect_meshd.sh     # → evidence/F5_meshd_status.txt
   ```
   另须**自产**三份核验记录（采集脚本不覆盖，格式见题面"验题契约"）：
   - `evidence/F1_boundary.txt`：双侧边界探针记录（LIM−1024 → 200；LIM+4096 → 400/431）；
   - `evidence/F2_restart.txt`：`supervisorctl restart all` 后复探
     （post_restart_entry_big_status=200 / post_restart_backend_big_status=200）；
   - `evidence/F2_calibration.txt`：预警双侧标定（THRESH=LIM×WARN_RATIO/100；
     below_warnings_delta=0；above_warnings_delta≥1 且 above_max_observed≥THRESH）；
   - `evidence/F4_restart.txt`：重启 kafka 后新标记事件复证（marker=/event_seen=ok）；
3. `diagnosis_report.md`：每面三行（根因一句话 / 证据文件相对路径 / 修复前后关键数值），
   修复前数值须与 Fx.out 实测一致。

## 判分口径
`reward = 0.15×结构(/5) + 0.30×基础(/9) + 0.35×证据(/5) + 0.20×报告(/2)`；
CAP：repro 取证全缺 → 封顶 0.45。完整口径见题面"验题契约"。
