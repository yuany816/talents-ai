# Harbor oracle / nop 验证结果

验证时间：2026-11-19（Asia/Shanghai）

- 仓库提交：`1fd0615c4637a81397f11c62dd8e97fc64c09729`
- Harbor：`0.26.0`
- 题目：`humanlaya/coding-task`
- verifier 模式：`shared`

## 结论

| 模式 | Trial ID | Reward | Harbor 异常 | 结论 |
|---|---|---:|---:|---|
| oracle | `harbor-prebuilt-task__3HRL9G6` | `1.0000` | 0 | 符合要求 |
| nop | `harbor-prebuilt-task__GaBdpp6` | `0.0000` | 0 | 符合要求 |

oracle 的 verifier 明细为 `structure=10/10`、`basic=15/15`、`edge=5/5`、`quality=5/5`，最终 `score=1.0000`。

nop 的 verifier 明细为 `structure=0/10`、`basic=2/15`、`edge=0/5`、`quality=0/5`，最终 `score=0.0000`。

## 实际命令

```bash
harbor run -p work/harbor-prebuilt-task -a oracle \
  --job-name oracle-verified-r2-20261119 -n 1 --debug

harbor run -p work/harbor-prebuilt-task -a nop \
  --job-name nop-verified-20261119 -n 1 --debug
```

`work/harbor-prebuilt-task` 是当前 `task/` 的逐文件副本。唯一变更是在临时 `task.toml` 的 `[environment]` 中加入：

```toml
docker_image = "talents-ai-harbor-20261119:latest"
```

该镜像由提交 `c8477780b878c6bf51b70c9d11ab401e0f012fde` 的同一 `task/` 构建；`c847778..1fd0615` 之间 `task/` 无文件差异。原始与验证用 task 配置均保存在 `metadata/`。

## 原始 task 冷构建说明

也执行了未加镜像覆盖的原始命令：

```bash
harbor run -p task -a oracle \
  --job-name oracle-actual-20261119 -n 1 --debug
```

该次作业没有进入评分：Dockerfile 已完成 apt 安装和三段 Go 编译，但 Docker 虚拟机从 `archive.apache.org` 下载 120,713,953 字节的 Kafka 3.7.2 文件时速度约 14–18 KB/s，超过题目 `build_timeout_sec = 600` 后得到 `EnvironmentStartTimeoutError`。因此这次基础设施异常没有作为 oracle 分数；异常原件保存在 `direct-build-attempt/`。

## 产物索引

- `oracle/job-result.json`：oracle 作业汇总
- `oracle/trial-result.json`：oracle trial 详情
- `oracle/reward.txt`：原始分数 `1.0000`
- `oracle/debug.txt`：维度分数
- `oracle/test-stdout.txt`：verifier 全量输出
- `oracle/agent-oracle.txt`：官方解执行日志
- `nop/job-result.json`：nop 作业汇总
- `nop/trial-result.json`：nop trial 详情
- `nop/reward.txt`：原始分数 `0.0000`
- `nop/debug.txt`：维度分数
- `nop/test-stdout.txt`：verifier 全量输出
- `direct-build-attempt/`：原始 task 冷构建超时证据
- `summary.json`：机器可读摘要

完整 Harbor 作业目录仍保留在：

- `jobs/oracle-verified-r2-20261119/`
- `jobs/nop-verified-20261119/`
- `jobs/oracle-actual-20261119/`
