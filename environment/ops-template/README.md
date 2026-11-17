# /app/ops 交付目录说明（判分只读取本目录）

| 交付物 | 要求 |
|---|---|
| `header_limits.env` | 取消模板注释，填入实际取值（三键必填，见模板内说明） |
| `quality_gate.sh` | 实现 431 门禁后 `chmod +x`（判分会本地伪造日志验证拦截行为） |
| `diagnosis_report.md` | 按题面"验题契约"6) 硬断言填写（①~⑧） |
| `warnings.log` | 预警观测记录；至少一条告警行须含 ≥ 阈值（LIM×RATIO/100）的整数观测值 |
| `evidence/` | 运行 `bash /app/collect_evidence.sh` 自动采集六个证据文件 |

## 采集脚本用法
```
bash /app/collect_evidence.sh
```
脚本按作答环境**实际状态**探测（nginx -T、入口/直连后端探针、双侧边界探针、
一次性 nonce 注入链、GATESTAT/MESHSTAT 逐层计数、kafka 探活/组件指纹/审计标记），
输出到 `/app/ops/evidence/`。运行后请核对输出取值与你的实际配置一致；如你的观测
实现路径不同（如告警写入位置），手工修正对应文件即可——判分只按题面 schema 读取。

判分为加权连续评分（structure / basic / edge / quality 四维度 + VETO/CAP 门槛），
详见题面"验题契约"。
