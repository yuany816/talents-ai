# trae+gpt-6.1-sol 执行归档

此目录按你指定的名称创建，记录本会话实际完成的评测编排、环境构建、验证结果和公开操作。模型名称是归档标签，不是 Harbor 验证过的模型调用记录。

## 内容

- [执行记录.md](执行记录.md)：操作过程、遇到的问题、处理方式与结果。
- [trajectory.json](trajectory.json)：结构化执行记录，便于程序读取。
- `evidence/oracle/`：oracle 的 job/trial 结果、参考解输出、逐项判分日志和 reward。
- `evidence/nop/`：nop 的 job/trial 结果、逐项判分日志和 reward。
- `environment/`：本次缓存依赖构建使用的 Dockerfile 与题包配置。

## 已完成结果

| 模式 | 得分 | 来源 |
|---|---:|---|
| oracle | 1.0000 | Harbor 执行题包已有的 `solution/solve.sh` |
| nop | 0.0000 | Harbor 在初始环境中直接执行 verifier |

oracle 的结构检查 10/10、基础行为 15/15、证据 5/5、报告 5/5、calibrator 12/12、headeragg 12/12 均通过。

上述分数分别属于 oracle 和 nop。本目录没有将它们归为 `trae+gpt-6.1-sol` 独立解题的得分，也没有生成新的模型作答。`trajectory.json` 是本会话操作的事后整理，不是原生模型 transcript 或 Harbor ATIF 文件。

## 复验范围

仓库提交：`c8477780b878c6bf51b70c9d11ab401e0f012fde`。

Harbor 版本：`0.26.0`。镜像：`talents-ai-harbor-20261119:latest`。

本次复验复用了本机系统依赖和 Kafka 3.7.2，重新编译当前题包源码并恢复当前初始配置；临时题包副本通过 `environment.docker_image` 选择镜像。仓库中题包的源码、参考解和判分脚本均未修改。这是本地缓存依赖环境的结果，不能替代其他 runner 的完整配置复验。

完整原始作答产物与服务日志仍保留在：

`../../jobs/oracle-cached-20261119/task__xCevZWf/artifacts/`
