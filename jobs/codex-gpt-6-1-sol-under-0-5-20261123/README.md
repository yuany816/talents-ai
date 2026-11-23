# Codex gpt-6.1-sol 校准复评（2026-11-23）

本目录保存原 Codex 轨迹在修复 F6 启动参数后，使用最终校准套件复评的结果。

## 最终结果

- P1 运维修复：`0.9567`
- F6 headeragg：`12/12 = 1.0000`
- F7 calibrator：`5/12 = 0.4167`
- 总分：`min(P1, F6, F7) = 0.4167`

F7 通过场景为 `sc01/sc02/sc07/sc11/sc12`；失败场景为
`sc03/sc04/sc05/sc06/sc08/sc09/sc10`。

## 产物

- `verifier/reward.txt`：最终分数
- `verifier/debug.txt`：维度汇总
- `verifier/test-stdout.txt`：完整 verifier 输出
- `params.env`：复评参数
- `source/headeragg-main.go`：复评时实际使用的 F6 修复源码
- `source/candidate-calibrator-main.go`：复评时实际使用的 F7 回答源码
- `source/spec-calibrator.md`：公开规格快照
- `source/gen-calibrator-main.go`：场景生成器源码快照
- `source/gen-calibrator`：Linux ARM64 静态生成器，SHA-256
  `b64c61ae4f0b899982af4a695726582c9493df1458fefa2b609358ad40cbb9f5`

对应门禁：

- oracle：`jobs/oracle-under-0-5-r2-20261123`，`1.0000`
- nop：`jobs/nop-under-0-5-r2-20261123`，`0.0000`
