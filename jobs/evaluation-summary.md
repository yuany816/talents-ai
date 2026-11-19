# Harbor evaluation — 2026-11-19

Repository: `/Users/bytedance/Documents/test/talents-ai`

Commit: `c8477780b878c6bf51b70c9d11ab401e0f012fde`

Harbor: `0.26.0`, installed in `/tmp/talents-harbor-venv`.

| Mode | Expected reward | Actual reward | Status |
|---|---:|---:|---|
| oracle | 1 | 1.0000 | Completed; 1 trial, 0 errors |
| nop | 0 | 0.0000 | Completed; 1 trial, 0 errors |
| Claude Code / `clauude` | — | Not obtained | Stopped during runtime installation; no model invocation |

Oracle passed structure 10/10, behavior 15/15, evidence 5/5, report 5/5, calibrator 12/12, and header aggregator 12/12.

## Results and logs

- Oracle job: `oracle-cached-20261119/result.json`
- Oracle reward and checks: `oracle-cached-20261119/task__xCevZWf/verifier/`
- Oracle solution output: `oracle-cached-20261119/task__xCevZWf/agent/oracle.txt`
- Oracle completed answer artifacts: `oracle-cached-20261119/task__xCevZWf/artifacts/ops/`
- Oracle service-log snapshot, exported after the solution and before container deletion: `oracle-cached-20261119/task__xCevZWf/artifacts/service-logs/`
- nop job: `nop-cached-20261119/result.json`
- nop reward and checks: `nop-cached-20261119/task__FdyDY3q/verifier/`
- Incomplete Claude Code trial: `../trajectory/claudecode+claaude/task__J3zHJHu/`

The Claude Code archive contains an incomplete trial's configuration and setup logs. Its exported container log directories are empty. It contains no completed Claude transcript or ATIF trajectory and must not be presented as one.

## Environment provenance

Docker Hub and dependency downloads timed out or were too slow for the initial builds. The successful local evaluations used `talents-ai-harbor-20261119:latest`, rebuilt with cached nginx, Go, JDK, and Kafka 3.7.2 dependencies from `talents-ai-env:tmux`.

Old application directories and Kafka data were cleared inside the new image. Current task source was recompiled, and current task initial configuration was copied into it. The image retains additional utilities from the cached base, including tmux.

An isolated task copy at `/tmp/talents-harbor-evaluation/task` selected the rebuilt image through `environment.docker_image`. Its environment source, solution, and verifier match the repository byte-for-byte. The repository's tracked task files were unchanged.

This verifies the task under the local cached-dependency environment. It does not establish a clean build from the original Dockerfile or equivalence to another runner's complete configuration.

Rebuild instructions are preserved in `evaluation-environment.Dockerfile`; the evaluation task configuration is in `evaluation-task.toml`.

## Commands used for the completed evaluations

```bash
/tmp/talents-harbor-venv/bin/harbor run \
  -p /tmp/talents-harbor-evaluation/task -a oracle \
  --job-name oracle-cached-20261119 -n 1 --debug

/tmp/talents-harbor-venv/bin/harbor run \
  -p /tmp/talents-harbor-evaluation/task -a nop \
  --job-name nop-cached-20261119 -n 1 --debug
```

The initial jobs without `-cached-` were interrupted and do not represent completed evaluations.

## Claude Code prerequisite

Harbor's agent identifier is `claude-code`. The requested model `clauude` was passed unchanged; its provider availability was not validated. No Anthropic API key, auth token, or Claude OAuth credential was configured.

Configure authentication in the terminal environment and supply the exact available model ID before running this mode again. Do not put secrets in the report or trajectory files.
