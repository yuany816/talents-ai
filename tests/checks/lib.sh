#!/bin/bash
# =============================================================================
# tests/checks/lib.sh —— 验题子检查公共库（独立判分版）
#
# 约定（加权连续评分架构 + 独立判分 evidence 口径）：
#   - 判分环境为 tests/Dockerfile 镜像：无 nginx/go/kafka/服务组件，本库不发任何
#     实时请求、不执行 nginx -T；一切行为证据来自交付目录 /app/ops/（task.toml
#     artifacts）及其 evidence/ 子目录（题面"验题契约"逐文件 schema）；
#   - 每个子检查脚本独立可执行，由 ../test.sh 汇总运行，按 pass/total 计维度分；
#   - exit 0 = 通过；exit 3 = 跳过（不计入维度分母）；其他非 0 = 不通过；
#   - ok()/fail()/note() 仅打印诊断行，最终判定以脚本退出码为准；
#   - 门禁注入类子检查在判分环境本地伪造 /var/log/nginx 日志后运行交付的门禁脚本，
#     自负责清理，保证验题可重复执行。
# =============================================================================
export LC_ALL=C
set -u

CHECKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$CHECKS_DIR")"

OPS_DIR="/app/ops"
EV_DIR="$OPS_DIR/evidence"
LIMENV="$OPS_DIR/header_limits.env"
GATE="$OPS_DIR/quality_gate.sh"
RPT="$OPS_DIR/diagnosis_report.md"
WARNLOG="$OPS_DIR/warnings.log"
NGLOG_DIR=/var/log/nginx

mkdir -p /logs/verifier "$NGLOG_DIR" 2>/dev/null || true

ok()   { echo "[check] ok   : $1"; }
fail() { echo "[check] FAIL : $1"; }
note() { echo "[check] note : $1"; }

# ev_path <文件名>：证据文件路径；不存在（或为空）时返回非 0
ev_path() {
  local f="$EV_DIR/$1"
  [ -s "$f" ] || return 1
  printf '%s' "$f"
}

# ev_get <KEY> <文件>：取 key=value 行的 value（首个命中，含行内其余全部内容）
ev_get() {
  sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n1
}

# load_lim：从 header_limits.env 读取 LIM / RATIO（缺失 RATIO 按 80）
load_lim() {
  LIM=""; RATIO=""
  [ -f "$LIMENV" ] || return 1
  LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
  return 0
}

# nginx_buf_from_file <nginx_T.txt>：解析 large_client_header_buffers 的单缓冲字节数
# （k/M 后缀折算；仅认未注释的活动指令）。结果存 NG_BUF / NG_BUF_B，找到返回 0。
nginx_buf_from_file() {
  local f="$1" v
  v=$(grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' "$f" 2>/dev/null | head -n1 | awk '{gsub(/;/,""); print $3}')
  if [ -z "$v" ]; then NG_BUF=""; NG_BUF_B=""; return 1; fi
  NG_BUF="$v"
  NG_BUF_B=$(printf '%s' "$v" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
  return 0
}

# run_gate <日志伪造子检查用>：在判分环境执行交付的门禁脚本（可执行性由调用方先判定）
run_gate() { bash "$GATE" >/dev/null 2>&1; }

# clean_ng_logs：清除判分环境本地伪造的 nginx 日志（注入复原）
clean_ng_logs() {
  rm -f "$NGLOG_DIR/access.log" "$NGLOG_DIR/error.log" "$NGLOG_DIR/hdrsize.log" 2>/dev/null || true
}
