# Codex gpt-6.1-sol 轨迹说明

- 原始 Harbor trial：`task__7UD4Kwv/`
- 原始结果：F6 未启动导致总分 `0.0000`
- 启动问题：`headeragg` 仅接受两个业务参数，verifier 传入可选端口后进程立即退出
- 修复方式：支持规格规定的 `headeragg <THRESH> <STATE_FILE> [PORT]`
- 最终校准复评：`jobs/codex-gpt-6-1-sol-under-0-5-20261123/`
- 最终分数：`0.4167`（P1=`0.9567`、F6=`1.0000`、F7=`0.4167`）
