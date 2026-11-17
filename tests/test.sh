#!/bin/bash
# =============================================================================
# 431 任务验题脚本（平台 tests/test.sh）—— 加权连续评分 + 双级门槛版
#
# reward = 0.1×结构完整性 + 0.25×基础修复 + 0.45×边界与防线 + 0.2×综合报告质量
#
#   structure（结构完整性，5 子项）：
#     /app/ops 四产物齐备 + header_limits.env 的 LIM 键有效性 + WARN_RATIO 格式合法；
#   basic（基础修复，8 子项 = tests/checks/basic/*.sh 通过比例）：
#     环境在线 / 端到端探针 / 注入链完整性 / L1 生效 / 后端与中间层扫描 / 声明一致性；
#   edge（边界与防线，10 子项 = tests/checks/edge/*.sh 通过比例）：
#     上边界拒绝 / 门禁（干净+分源注入）/ 预警（静默+告警）/
#     链路计数（span 精确注入 + kafka 审计事件）/ 双侧边界 / 预警内容实质；
#   quality（综合报告质量，8 断言 = diagnosis_report.md 硬断言 ①~⑧ 通过比例）。
#
# 双级门槛（在加权总分之上生效，见 instruction.md"判定总则"）：
#   VETO（一票否决 → reward=0）：
#     ① 报告实质归因缺失——quality 断言①（归因结论）或④（实质归因：量化证据+
#       注入侧+限制侧）未通过（含报告缺失）；
#     ② 质检门禁核心行为失败——edge/02（干净误拦）或 edge/03、edge/04（分源注入
#       未拦截）任一不通过（含门禁缺失）。
#   CAP（链路完整性封顶 → reward=min(score, 0.4500)）：
#     注入链完整性（basic/03）、span 精确注入计数（edge/07）、kafka 审计事件计数
#     （edge/08）任一不通过——"改对一半"（漏掉 span 规格恢复/kafka 治理/绕层）
#     的解法封顶 0.45，不可能越过 0.5。
#
# 随机化（每轮验题不同，固定值猜测无效）：上/双侧边界偏移、门禁注入标记与书写顺序、
# kafka 探针锚定值（按声明 LIM 自适应）、预警探针偏移。
#
# 行为正确性以探针判定（不同输入/边界场景）；源码/配置扫描仅作"修改真实发生"的辅助
# 证据。各子检查自身负责日志清理与注入复原，验题可重复执行。
# reward.txt 总是被写入：脚本启动即落 0.0 兜底，结束按计算值覆盖（4 位小数浮点）；
# 任一子检查异常退出按失败计，不影响其余子检查与总分落盘。
# 测试依赖：bash/curl/nginx(仅 -T 读配置)/grep/awk/sed —— 均为环境镜像自带（见
# environment/Dockerfile），无 Python/pip 依赖，无需在测试时额外安装。
# =============================================================================
export LC_ALL=C
set -u

REWARD_FILE="/logs/verifier/reward.txt"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /logs/verifier /var/log/nginx /app/ops 2>/dev/null || true

ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; }

# 启动即落兜底值：任何中途异常（超时/被杀）下 reward.txt 都存在且可读
printf '%s\n' "0.0000" > "$REWARD_FILE"

# ---------- dimension: structure（交付物结构完整性，5 子项） ----------
S_PASS=0; S_TOTAL=5
[ -s /app/ops/header_limits.env ] && { ok "结构 1/5：header_limits.env 存在且非空"; S_PASS=$((S_PASS+1)); } \
  || fail "结构 1/5：header_limits.env 缺失或为空"
[ -x /app/ops/quality_gate.sh ] && { ok "结构 2/5：quality_gate.sh 存在且可执行"; S_PASS=$((S_PASS+1)); } \
  || fail "结构 2/5：quality_gate.sh 缺失或不可执行"
[ -s /app/ops/diagnosis_report.md ] && { ok "结构 3/5：diagnosis_report.md 存在且非空"; S_PASS=$((S_PASS+1)); } \
  || fail "结构 3/5：diagnosis_report.md 缺失或为空"
LIM=""
if [ -f /app/ops/header_limits.env ]; then
  LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' /app/ops/header_limits.env | head -n1 | tr -dc '0-9')
fi
if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] 2>/dev/null; then
  ok "结构 4/5：NGINX_LARGE_HEADER_BUFFER_BYTES 声明有效（${LIM}B > 4096）"; S_PASS=$((S_PASS+1))
else
  fail "结构 4/5：NGINX_LARGE_HEADER_BUFFER_BYTES 缺失（或 ≤4096，低于旧故障值一半属未有效扩容）"
fi
RATIO=""
[ -f /app/ops/header_limits.env ] && RATIO=$(sed -n 's/^WARN_RATIO=//p' /app/ops/header_limits.env | head -n1 | tr -dc '0-9')
if [ -z "$RATIO" ] && [ -f /app/ops/header_limits.env ]; then
  ok "结构 5/5：WARN_RATIO 缺失（按 80 处理）"; S_PASS=$((S_PASS+1))
elif [ -n "$RATIO" ] && [ "$RATIO" -ge 50 ] 2>/dev/null && [ "$RATIO" -le 90 ] 2>/dev/null; then
  ok "结构 5/5：WARN_RATIO=$RATIO 格式有效"; S_PASS=$((S_PASS+1))
else
  fail "结构 5/5：WARN_RATIO 未声明（参数文件缺失）或非法（有效范围 [50,90]；范围越界对行为的影响由 edge/05 判定）"
fi

# ---------- dimension: basic / edge（子检查目录按字典序逐个执行） ----------
declare -A RC   # 记录各子检查退出码（门槛判定用：RC["basic/03..."]=0/1/3）
run_dim() {  # $1=checks 子目录名；结果写入 BASIC_PASS/BASIC_TOTAL 或 EDGE_PASS/EDGE_TOTAL
  local dim="$1" dir="$TESTS_DIR/checks/$1" f base pass=0 total=0 rc=9
  for f in $(ls "$dir"/*.sh 2>/dev/null | sort); do
    base=$(basename "$f")
    echo "----- [$dim/$base] -----"
    bash "$f"; rc=$?
    RC["$dim/$base"]=$rc
    case $rc in
      0) ok "$dim/$base 通过"; pass=$((pass + 1)); total=$((total + 1)) ;;
      3) note "$dim/$base 跳过（不计入维度分母）" ;;
      *) fail "$dim/$base 不通过"; total=$((total + 1)) ;;
    esac
  done
  case "$dim" in
    basic) BASIC_PASS=$pass; BASIC_TOTAL=$total ;;
    edge)  EDGE_PASS=$pass;  EDGE_TOTAL=$total ;;
  esac
  return 0
}
run_dim basic
run_dim edge

# ---------- dimension: quality（综合分析报告硬断言 ①~⑧） ----------
Q_PASS=0; Q_TOTAL=8; Q_A1=0; Q_A4=0
R="/app/ops/diagnosis_report.md"
if [ -s "$R" ]; then
  grep -qE '归因|综合' "$R" && { ok "报告①：归因结论"; Q_PASS=$((Q_PASS+1)); Q_A1=1; } || fail "报告①：缺归因结论"
  grep -qE '状态码链|修复前' "$R" && grep -qE '→|->' "$R" \
    && { ok "报告②：状态码链（修复前→分层修复后）"; Q_PASS=$((Q_PASS+1)); } || fail "报告②：缺状态码链（修复前/修复后链条）"
  grep -q '8192' "$R" && grep -q "${LIM:-65536}" "$R" \
    && { ok "报告③：限额数值对照（8192 → 新值）"; Q_PASS=$((Q_PASS+1)); } || fail "报告③：缺限额数值对照（缺 8192 或新限额 $LIM）"
  grep -qE 'HDRSTAT|max_header|request_length' "$R" \
    && grep -qE '注入|增长' "$R" && grep -qE '过小|未同步|未扩容' "$R" \
    && { ok "报告④：实质归因（量化证据+注入侧+限制侧）"; Q_PASS=$((Q_PASS+1)); Q_A4=1; } || fail "报告④：缺实质归因（量化证据/注入侧/限制侧）"
  grep -qiE '余量|sizing' "$R" \
    && { ok "报告⑤：容量取值依据（余量/sizing）"; Q_PASS=$((Q_PASS+1)); } || fail "报告⑤：缺容量取值依据（余量/sizing）"
  grep -qE 'large_client_header_buffers|MaxHeaderBytes|ReadBufferSize' "$R" \
    && { ok "报告⑥：所改限制项名称"; Q_PASS=$((Q_PASS+1)); } || fail "报告⑥：未提及所修改的限制项名称"
  grep -q '10240' "$R" && grep -q '12288' "$R" \
    && { ok "报告⑦：tracegate/meshd 层限额对照"; Q_PASS=$((Q_PASS+1)); } || fail "报告⑦：缺 tracegate/meshd 层限额数值对照"
  # ⑧ 异步审计旁路三角说明：报告须覆盖 kafka 容量信号的治理与归因（edge/08 的计数判定
  #   之外，还要求"谁注入过多/哪层限制过小"的链路级报告覆盖异步链路）
  grep -q '16384' "$R" && grep -qiE 'MESSAGE_TOO_LARGE|kafka' "$R" \
    && { ok "报告⑧：异步审计旁路三角说明（kafka 容量信号归因）"; Q_PASS=$((Q_PASS+1)); } \
    || fail "报告⑧：缺异步审计旁路三角说明（kafka 治理对照 16384→新值 / MESSAGE_TOO_LARGE 归因）"
else
  fail "报告①~⑦：缺少综合分析报告 $R"
fi

# ---------- 加权总分 + 双级门槛（始终覆盖写入，4 位小数） ----------
frac() { awk "BEGIN{p=$1; t=$2; printf \"%.4f\", (t>0)?p/t:0}"; }
STRUCTURE=$(frac "$S_PASS" "$S_TOTAL")
BASIC=$(frac "$BASIC_PASS" "$BASIC_TOTAL")
EDGE=$(frac "$EDGE_PASS" "$EDGE_TOTAL")
QUALITY=$(frac "$Q_PASS" "$Q_TOTAL")
SCORE=$(awk "BEGIN{printf \"%.4f\", 0.1*$STRUCTURE + 0.25*$BASIC + 0.45*$EDGE + 0.2*$QUALITY}")

echo "==================================================================="
echo "[verifier] 结构完整性 structure=$STRUCTURE ($S_PASS/$S_TOTAL)"
echo "[verifier] 基础修复   basic    =$BASIC ($BASIC_PASS/$BASIC_TOTAL)"
echo "[verifier] 边界防线   edge     =$EDGE ($EDGE_PASS/$EDGE_TOTAL)"
echo "[verifier] 报告质量   quality  =$QUALITY ($Q_PASS/$Q_TOTAL)"

# ---- VETO（一票否决 → 0）----
VETO_REASON=""
if [ "$Q_A1" != "1" ] || [ "$Q_A4" != "1" ]; then
  VETO_REASON="报告实质归因缺失（quality①/④ 未通过：只会改参数不会归因的解法不构成修复）"
fi
GATE_RC2="${RC[edge/02_gate_clean.sh]:-9}"; GATE_RC3="${RC[edge/03_gate_inject_access.sh]:-9}"; GATE_RC4="${RC[edge/04_gate_inject_hdrsize.sh]:-9}"
if [ "$GATE_RC2" != "0" ] || [ "$GATE_RC3" != "0" ] || [ "$GATE_RC4" != "0" ]; then
  VETO_REASON="${VETO_REASON:+$VETO_REASON；}质检门禁核心行为失败（edge/02/03/04 任一不通过：431 高优先级拦截防线未建立）"
fi
if [ -n "$VETO_REASON" ]; then
  echo "[verifier] VETO 一票否决：$VETO_REASON"
  SCORE="0.0000"
else
  # ---- CAP（链路完整性封顶 0.45）----
  CHAIN_RC3="${RC[basic/03_injection_chain.sh]:-9}"; CHAIN_RC7="${RC[edge/07_span_accounting.sh]:-9}"; CHAIN_RC8="${RC[edge/08_kafka_audit_counting.sh]:-9}"
  if [ "$CHAIN_RC3" != "0" ] || [ "$CHAIN_RC7" != "0" ] || [ "$CHAIN_RC8" != "0" ]; then
    CAP_TRIGGER=""
    [ "$CHAIN_RC3" != "0" ] && CAP_TRIGGER="$CAP_TRIGGER 注入链完整性(basic/03);"
    [ "$CHAIN_RC7" != "0" ] && CAP_TRIGGER="$CAP_TRIGGER span精确计数(edge/07);"
    [ "$CHAIN_RC8" != "0" ] && CAP_TRIGGER="$CAP_TRIGGER kafka审计计数(edge/08);"
    echo "[verifier] CAP 链路完整性封顶：$CAP_TRIGGER 改对一半的解法 reward 封顶 0.4500"
    SCORE=$(awk "BEGIN{v=$SCORE; printf \"%.4f\", (v>0.45)?0.45:v}")
  fi
fi

printf '%s\n' "$SCORE" > "$REWARD_FILE"
echo "[verifier] reward=$SCORE → $REWARD_FILE"
exit 0
