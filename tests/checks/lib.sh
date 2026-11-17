#!/bin/bash
# =============================================================================
# tests/checks/lib.sh —— 验题子检查公共库
#
# 约定（加权连续评分架构）：
#   - 每个子检查脚本独立可执行，由 ../test.sh 汇总运行，按 pass/total 计维度分；
#   - exit 0 = 该子检查通过；非 0 = 不通过（脚本内部不得因预期失败分支而崩溃）；
#   - ok()/fail() 仅打印诊断行，最终判定以脚本退出码为准；
#   - 子检查自身负责清理（日志截断/注入复原），保证验题可重复执行。
# =============================================================================
export LC_ALL=C
set -u

CHECKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$CHECKS_DIR")"

ENTRY="http://127.0.0.1:80"
UP="http://127.0.0.1:9000"
TG="http://127.0.0.1:9100"
MS="http://127.0.0.1:15001"
PROBE_BYTES=16384            # 复现探针：单个自定义 header 的值字节数（题面固定）

OPS_DIR="/app/ops"
LIMENV="$OPS_DIR/header_limits.env"
GATE="$OPS_DIR/quality_gate.sh"
RPT="$OPS_DIR/diagnosis_report.md"
WARNLOG="$OPS_DIR/warnings.log"

mkdir -p /logs/verifier /var/log/nginx 2>/dev/null || true

ok()   { echo "[check] ok   : $1"; }
fail() { echo "[check] FAIL : $1"; }
note() { echo "[check] note : $1"; }

gen_token() { head -c "$1" /dev/zero | tr '\0' 'x'; }

# code_with_header <url> <token|空>：带（或不带）X-Verify-Token 超长头请求，输出状态码
code_with_header() {
  local url="$1" tok="$2"
  if [ -n "$tok" ]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Verify-Token: $tok" "$url"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url"
  fi
}

# load_lim：从 header_limits.env 读取 LIM / RATIO（缺失 RATIO 按 80）
load_lim() {
  LIM=""; RATIO=""
  [ -f "$LIMENV" ] || return 1
  LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
  return 0
}

# nginx_buf_bytes：取 nginx -T 生效配置中 large_client_header_buffers 的单缓冲字节数
# （k/M 后缀折算；仅认未注释的活动指令）。结果存 NG_BUF / NG_BUF_B，找到返回 0。
nginx_buf_bytes() {
  local v
  v=$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | awk '{gsub(/;/,""); print $3}')
  if [ -z "$v" ]; then NG_BUF=""; NG_BUF_B=""; return 1; fi
  NG_BUF="$v"
  NG_BUF_B=$(printf '%s' "$v" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
  return 0
}

# res_clean：清理轮转目标（warnings.log 行数基准等）前的公共目录保障
ensure_ops_dir() { mkdir -p "$OPS_DIR" 2>/dev/null || true; }
