# 一轮质检报告 —— 431 排查题（incident-coding / hard）

## 基本信息
- 题目：排查线上 431 Request Header Fields Too Large（nginx + Go 双层故障）
- 质检人：Claude（出题工作区自动化质检）
- 质检日期：2026-11-13
- 验证方式：**真实 Docker 环境**——本机安装 docker.io，`docker build`（environment/Dockerfile → task431 镜像）
  构建并运行容器（supervisord 编排 backend/nginx），`docker exec` 在容器内执行 solve.sh 与 tests/test.sh，
  另做 2 组负向校准测试。容器内为 GNU grep 3.8（与 debian:bookworm-slim 目标环境一致，无本机 ugrep 怪癖干扰）。

## 端到端验证结果（真实容器内）

| 场景 | 期望 | 实际 | 结论 |
|---|---|---|---|
| 裸环境（故障态）+ test.sh | reward=0（exit 1） | reward=0（exit 1），18 项 FAIL 全部合规、零脚本报错 | PASS |
| solve.sh | exit 0 | exit 0（400 → L1 后仍 431 → L1+L2 后 200，故障链完整复现） | PASS |
| solve 后 + test.sh 第 1 次 | reward=1（exit 0） | reward=1，33/33 项 ok | PASS |
| solve 后 + test.sh 第 2 次（可重复验题） | reward=1 | reward=1 | PASS |
| 负向①：L1=16k"刚好够用" | reward=0 | reward=0，命中"单缓冲需 ≥32768B（2×探针）"断言 | PASS |
| 负向②：WARN_RATIO=95（超 [50,90]） | reward=0 | reward=0，且仅此 1 项 FAIL（无连带误伤） | PASS |
| 负向②复原后终验 | reward=1 | reward=1，33/33 项 ok | PASS |

关键实测证据（容器内）：
- 裸环境：入口 16384B 探针 → 400、直连 → 431、常规 → 200；error.log 出现 info 级
  `client sent too long header line`；`config.yaml: max_header_bytes: 8192`、`MaxHeaderBytes: 16384` 均在位
- 修复后：hdrsize 末行 status=200、request_length=16482B（与契约 16402B 全行口径吻合）；
  HDRSTAT 观测 `max_header=X-Verify-Token:16402B`；告警行实测值 53096B/63575B ∈ [52428, 65536]；
  上边界 LIM+4096 探针 → 400 仍被拒绝；supervisorctl 重启后全部探针复测通过

## 模块一：题目描述质量
| 检查项 | 结果 | 说明 |
|--------|------|------|
| 1.1 学科背景准确性 | PASS | 431 语义、nginx 默认 1k/4 8k、net/http MaxHeaderBytes 默认 1MB、"nginx 超长行回 400 且属 info 级日志"均与容器实测一致 |
| 1.2 问题定义清晰度 | PASS | 链路故事与故障机制（多层限额过小、"调大入口无效"）自洽 |
| 1.3 期望输出明确性 | PASS | 期望结果 4 节 + 产物 schema + 验题契约精确到断言窗（[16403, RL+200] 等） |
| 1.4 约束条件完整性 | PASS | nginx -t 再重载、改源码需重编译重启、离线编译、容忍日志截断均已声明 |
| 1.5 是否泄露答案 | PASS | 验题契约为设计性披露（题面明示"agent 可据此还原判定"）：给出判定阈值与产物要求，但未给出"改哪里/怎么改"——故障位（config.yaml 配额、MaxHeaderBytes、需重编译、中间件接线）仍需自行定位。提示节仅方向性 |
| 1.6 难度标注合理性 | PASS | hard：3 处故障跨 2 层、需重编译、4 项防线产物、门禁时间窗语义、重启持久性，与标注匹配（难度最终以平台 trial pass rate 复核，目标 <0.5） |
| 1.7 拼写/术语正确性 | PASS | large_client_header_buffers、MaxHeaderBytes、$request_length、combined 格式等术语准确 |

## 模块二：环境与代码质量
| 检查项 | 结果 | 说明 |
|--------|------|------|
| 2.1 Dockerfile 可构建 | PASS | 本机 docker.io 真实构建成功（Successfully tagged task431），容器 supervisord 正常拉起两服务 |
| 2.2 bug 需要领域知识 | PASS | 需理解 nginx 缓冲语义、Go 标准库/配置层限额层次与 reload/restart 差异 |
| 2.3 bug 数量和分布 | PASS | 3 处：nginx `4 8k`（入口）、`config.yaml 8192`（业务配额）、`MaxHeaderBytes=16384`（"刚好够用"陷阱） |
| 2.4 代码结构合理性 | PASS | main.go 结构清晰、配额配置驱动、注释含合理叙事（含 MAX_HEADER_KB 诱饵环境变量，与题面提示呼应） |
| 2.5 参数与描述一致性 | PASS | 题面 16384B 复现口径、8192 原故障值、16KiB"刚好够用"第二故障与环境实际一致 |
| 2.6 环境破坏合理性 | PASS | 破坏面符合"链路多模块共同作用"叙事，非凭空损坏 |

## 模块三：测试脚本质量
| 检查项 | 结果 | 说明 |
|--------|------|------|
| 3.1 reward.txt 写入 | PASS | 末尾无条件覆盖写 /logs/verifier/reward.txt（裸环境 run 实证写入 0） |
| 3.2 数值验证合理性 | PASS | 16400/16403 行开销口径、L1≥32768=2×探针、RATIO∈[50,90] 数学自洽（⟹ THRESH+512 ≤ LIM−1024）、±200 实测容差 |
| 3.3 物理约束检查 | PASS | 上边界 LIM+4096 必拒（实测 400）、静默 10s/告警 30s、hdrsize 末行 msec 新鲜度（≥now−120） |
| 3.4 反硬编码措施 | PASS | 行为探针（响应体特征、入口/直连分层、LIM 耦合、上边界、重启持久）为主，源码扫描仅辅助；实测窗杀"抄模板报告"；分源注入验证门禁真读日志 |
| 3.5 崩溃兜底 | PASS | 裸环境 18 项 FAIL 全部正常输出、exit=1，无 command not found/awk 报错/未捕获异常 |
| 3.6 期望答案正确性 | PASS | 裸→0、solve→1、重复验题→1、负向 16k→0、负向 WARN_RATIO=95→0（仅 1 项 FAIL），全部符合设计 |

## 模块四：参考解正确性
| 检查项 | 结果 | 说明 |
|--------|------|------|
| 4.1 修复了所有 bug | PASS | nginx `16 64k`、config.yaml→1048576、MaxHeaderBytes→4194304，hdrsize 全路由挂载，四项防线产物齐全 |
| 4.2 修复方式科学正确 | PASS | L1 经 nginx -t 后 reload；L2 重编译后经 supervisorctl 重启；门禁 300s 时间窗（历史 431 不误拦）；预警请求路径同步写 |
| 4.3 环境修复完整 | PASS | 端到端/直连/LIM−2048 耦合/上边界/重启持久探针全部符合预期 |
| 4.4 无多余修改 | PASS | 改动仅限 nginx 配置、/app/backend（源码+配置+新增观测中间件）、/app/ops 产物；备份 *.solve.bak 被验题排除口径覆盖 |
| 4.5 solve+test 能得到 1 | PASS | 实测两次 reward=1（33/33 ok） |

## 综合评估
- **总体结论**：通过
- **评分**：24/24 项 PASS → **100 / 100（> 80 ✓）**
- **关键问题**：无阻塞项。6 次 verifier 运行 + 1 次 solve 运行全程零报错。
- **改进建议**（非阻塞）：
  1. test.sh §5.3 告警内容断言中，"阈值=THRESH" 字面值自身也落在 [THRESH,LIM] 区间——若伪造观测固定回显阈值常量可通过该断言；建议收紧为">THRESH+64"或指定 total= 字段取值（当前 solve 实现写真实 total=53096B，不受影响，仅契约层面可更严）；
  2. 仓库根目录 Dockerfile / compose.yaml / compose.debug.yaml 为脚手架遗留（golang:alpine、EXPOSE 3000），与任务环境（environment/Dockerfile）无关，建议删除避免混淆；
  3. `nginx -s reload` 后亚秒级内新旧 worker 有竞态（本质检负向测试注入配置后立即判分曾见瞬时 400 连锁）——真实 solve→test 协议中服务经 supervisorctl stop/start（startsecs=2）无此竞态，不受影响；
  4. 平台 trial（world-lab）为权威判分，建议以本报告环境同构性（同 Dockerfile/同 test.sh）发起 trial 复核整体 pass rate 目标（<0.5）。
