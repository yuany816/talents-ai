#!/bin/bash
# edge/02 —— 4) 质检门禁·干净通过（判分环境本地执行交付的门禁脚本）：判分环境无 nginx
# 与任何日志——门禁须跳过全部缺失来源且 exit 0（"日志缺失时不得误拦或崩溃"的契约口径）。
# 前置清理保证可重复（上一轮注入残留必须被清除）。
set -u
. "$(dirname "$0")/../lib.sh"
[ -x "$GATE" ] || { fail "缺少可执行的质检门禁 $GATE"; exit 1; }
clean_ng_logs
if run_gate; then
  ok "质检门禁：无日志环境干净通过（exit 0，缺失来源已跳过）"
  exit 0
fi
fail "质检门禁：判分环境无日志时被误拦（须跳过缺失来源并 exit 0）"
exit 1
