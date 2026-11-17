#!/bin/bash
# =============================================================================
# 431 任务验题脚本（平台 tests/test.sh）—— 加权连续评分 + 双级门槛版（独立判分）
#
# 判分环境为 tests/Dockerfile 镜像（environment_mode="separate"）：无 nginx/go/kafka/
# 服务组件，本脚本与全部子检查**不发实时探针**——行为证据来自交付目录 /app/ops/
# （task.toml artifacts）及其 evidence/ 六个证据文件（题面"验题契约"逐文件 schema）。
# 门禁类子检查在判分环境本地伪造 /var/log/nginx 日志后执行交付的 quality_gate.sh。
#
# reward = 0.15×结构完整性 + 0.25×基础修复 + 0.40×边界与防线 + 0.2×综合报告质量
#
#   structure（结构完整性，3 交付阶段，逐阶段 all-or-nothing）：
#     阶段1 header_limits.env 存在且格式合法（LIM>4096，RATIO∈[50,90] 或缺失）；
#     阶段2 quality_gate.sh 可执行；阶段3 diagnosis_report.md 与 evidence/ 六文件齐全。
#   basic（基础修复，6 子项 = tests/checks/basic/*.sh 通过比例）：
#     环境在线（组件指纹）/ 端到端探针 / 注入链完整性 / L1 生效（**全部**活动指令取
#     最小值判定）/ 后端限额声明+行为 / 声明一致性（多条指令须全部与 LIM 相等）；
#   edge（边界与防线，9 子项 = tests/checks/edge/*.sh 通过比例）：
#     上边界拒绝 / 门禁（干净 + 三源**各自独立**注入：access / hdrsize / error，每源
#     另带非 431 内容不得误拦的对照）/ 链路计数（span 精确注入 + kafka 审计证据）/
#     双侧边界 / 预警内容实质（读交付 warnings.log）；
#   quality（综合报告质量，8 断言 = diagnosis_report.md 硬断言 ①~⑧ 通过比例）：
#     关键词之外还要求**同行配对/数值一致性**（状态码链须含真实码值、故障值须与
#     新值同行对照、报告数值须与 header_limits.env 声明咬合）——纯关键词堆砌不通过。
#
# 双级门槛（在加权总分之上生效，见 instruction.md"判定总则"）：
#   VETO（一票否决 → reward=0）：
#     ① 报告实质归因缺失——quality 断言①（归因结论）或④（实质归因：量化证据+
#       注入侧+限制侧）未通过（含报告缺失）；
#     ② 质检门禁核心行为失败——edge/02（无日志误拦）或 edge/03~05（access/hdrsize/
#       error 任一分源注入未拦截）不通过（含门禁缺失）。
#   CAP（交付空心封顶 → reward=min(score, 0.5500)）：
#     仅当 structure 与 basic 两维度均无任何通过项时触发；edge 单项缺失只扣该
#     维度分，不额外封顶。
#
# 随机化（每轮验题不同，固定样本匹配无效）：门禁注入标记、路径/字节数/时间戳与
# 两日志书写顺序每轮随机——门禁须按"431 证据"语义实现。
#
# 各子检查自身负责本地伪造日志的清理复原，验题可重复执行。
# reward.txt 总是被写入：脚本启动即落 0.0 兜底（/app/ops 缺失则立即以 0 退出），
# 结束按计算值覆盖（4 位小数浮点）；判分诊断同步写入 /logs/verifier/debug.txt
# （交付文件在位情况、各维度得分、VETO/CAP 触发与最终分）。
# 任一子检查异常退出按失败计，不影响其余子检查与总分落盘。
# 测试依赖：bash/curl/coreutils/grep/awk/sed —— 见 tests/Dockerfile（判分镜像）。
# =============================================================================
export LC_ALL=C
set -u

REWARD_FILE="/logs/verifier/reward.txt"
DEBUG_FILE="/logs/verifier/debug.txt"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 注意：不预创建 /app/ops——其存在与否是交付证据，须由 artifacts 收集结果决定
mkdir -p /logs/verifier /var/log/nginx 2>/dev/null || true

ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; }
note() { echo "[verifier] note : $1"; }

# 启动即落兜底值：任何提前退出/中途异常（超时/被杀）下 reward.txt 都存在且是有效零分
printf '%s\n' "0.0000" > "$REWARD_FILE"
: > "$DEBUG_FILE"
[ -d /app/ops ] || { echo "ops_dir=missing（空作答：未交付 /app/ops）" >> "$DEBUG_FILE"; exit 0; }
echo "ops_dir=present" >> "$DEBUG_FILE"

# ---------- dimension: structure（交付物三阶段，逐阶段 all-or-nothing） ----------
S_PASS=0; S_TOTAL=3
# 阶段 1：header_limits.env 存在且格式合法（LIM 整数 >4096；RATIO 合法或缺失按 80）
LIM=""; RATIO=""; S1=0
if [ -s /app/ops/header_limits.env ]; then
  LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' /app/ops/header_limits.env | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^WARN_RATIO=//p' /app/ops/header_limits.env | head -n1 | tr -dc '0-9')
  if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] 2>/dev/null \
     && { [ -z "$RATIO" ] || { [ "$RATIO" -ge 50 ] 2>/dev/null && [ "$RATIO" -le 90 ] 2>/dev/null; }; }; then
    S1=1
  fi
fi
[ "$S1" = "1" ] && { ok "结构 阶段1/3：header_limits.env 存在且格式合法（LIM=${LIM}B，RATIO=${RATIO:-缺失按80}）"; S_PASS=$((S_PASS+1)); } \
  || fail "结构 阶段1/3：header_limits.env 缺失/为空/格式非法（LIM 须整数 >4096；RATIO∈[50,90] 或缺失）"
# 阶段 2：quality_gate.sh 存在且可执行（模板预置为 644 占位，实现后须 chmod +x）
[ -x /app/ops/quality_gate.sh ] && { ok "结构 阶段2/3：quality_gate.sh 存在且可执行"; S_PASS=$((S_PASS+1)); } \
  || fail "结构 阶段2/3：quality_gate.sh 缺失或不可执行"
# 阶段 3：diagnosis_report.md 与 evidence/ 六文件齐全（任一缺失该阶段 0 分）
S3=1
[ -s /app/ops/diagnosis_report.md ] || { fail "结构 阶段3/3：diagnosis_report.md 缺失或为空"; S3=0; }
for _evf in nginx_T.txt curl_entry.txt curl_backend.txt upper_boundary.txt span_count.txt kafka_audit.txt; do
  [ -s "/app/ops/evidence/$_evf" ] || { fail "结构 阶段3/3：evidence/$_evf 缺失或为空（运行 bash /app/collect_evidence.sh 采集）"; S3=0; }
done
[ "$S3" = "1" ] && { ok "结构 阶段3/3：报告与 evidence/ 六证据齐全"; S_PASS=$((S_PASS+1)); } || true

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

# ---------- dimension: quality（综合分析报告硬断言 ①~⑧，配对/数值一致性口径） ----------
# 反"关键词堆砌"：②③④⑤⑦⑧ 的证据须落在**同一行**（对照表行/叙述行）且携带真实
# 码值/字节数——散落全文的孤立关键词不构成对照。
Q_PASS=0; Q_TOTAL=8; Q_A1=0; Q_A4=0
R="/app/ops/diagnosis_report.md"
# pair_line <报告> <故障值>：存在一行——含故障值（词边界），剥离故障值后同行的其余数字
# （k/M 折算）中有 ≥16402B 且 > 故障值者（16402=16384B 探针完整 header 行下限——新限额
# 必须放行探针，故配对"新值"不可能低于它；纯关键词或仅邻近小数字不构成对照）。
pair_line() {
  awk -v fv="$2" '
    {
      line=$0
      pat="(^|[^0-9])" fv "([^0-9]|$)"
      if (line !~ pat) next
      gsub(pat, " ", line)
      s=line
      while (match(s, /[0-9]+[kKmM]?/)) {
        tok=substr(s, RSTART, RLENGTH); v=tok+0
        if (tok ~ /[kK]$/) v*=1024; else if (tok ~ /[mM]$/) v*=1048576
        if (v >= 16402 && v > fv) { found=1; exit }
        s=substr(s, RSTART+RLENGTH)
      }
    }
    END { if (!found) exit 1 }
  ' "$1"
}
if [ -s "$R" ]; then
  # ① 归因结论：含"归因|综合"，且报告点名 ≥2 个链路组件（nginx/tracegate/meshd/backend）
  _c=0
  grep -qi  nginx     "$R" && _c=$((_c+1))
  grep -qi  tracegate "$R" && _c=$((_c+1))
  grep -qi  meshd     "$R" && _c=$((_c+1))
  grep -qiE 'backend|后端' "$R" && _c=$((_c+1))
  if grep -qE '归因|综合' "$R" && [ "$_c" -ge 2 ]; then
    ok "报告①：归因结论（含 ${_c} 个链路组件）"; Q_PASS=$((Q_PASS+1)); Q_A1=1
  else
    fail "报告①：缺归因结论或未点名链路组件（仅 ${_c} 个，须 ≥2：nginx/tracegate/meshd/backend）"
  fi
  # ② 状态码链：含"状态码链|修复前"，且**同一行**呈现真实码值链条（431/400 → … → 200）
  if grep -qE '状态码链|修复前' "$R" \
     && awk '/(^|[^0-9])(431|400)([^0-9]|$)/ && /→|->/ && /(^|[^0-9])200([^0-9]|$)/ {found=1} END{exit !found}' "$R"; then
    ok "报告②：状态码链（同一行含 431/400 → 200 真实码值）"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告②：状态码链缺真实码值（须一行内呈现 431/400 → 200 的箭头链条）"
  fi
  # ③ 数值对照：报告全文含声明 LIM（词边界，与 header_limits.env 咬合），且**同一行**
  #   含原故障值 8192 与放行探针级别的更大新值（≥16402B，k/M 折算）
  if [ -n "$LIM" ] && grep -qE "(^|[^0-9])${LIM}([^0-9]|\$)" "$R" && pair_line "$R" 8192; then
    ok "报告③：限额数值对照（8192 与 ≥16402B 新值同行；声明 LIM=${LIM} 在报告出现）"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告③：缺同行数值对照（8192 → ≥16402B 新值）或报告未含声明 LIM=${LIM:-缺}"
  fi
  # ④ 实质归因（VETO 项）：量化证据须**携带数字**（HDRSTAT/max_header/request_length 行
  #   至少一条含 ≥3 位数字），并具备注入侧与限制侧两类表述
  if grep -E 'HDRSTAT|max_header|request_length' "$R" | grep -Eq '[0-9]{3,}' \
     && grep -qE '注入|增长' "$R" && grep -qE '过小|未同步|未扩容' "$R"; then
    ok "报告④：实质归因（量化证据带数值+注入侧+限制侧）"; Q_PASS=$((Q_PASS+1)); Q_A4=1
  else
    fail "报告④：量化证据行无数字，或缺注入侧/限制侧表述（HDRSTAT/max_header/request_length 行须含真实字节数）"
  fi
  # ⑤ 容量依据："余量|sizing" 行须携带数字（无数值的 sizing 不构成取值依据）
  if grep -Ei '余量|sizing' "$R" | grep -Eq '[0-9]'; then
    ok "报告⑤：容量取值依据（余量/sizing 且带数值）"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告⑤：容量依据行无数值（余量/sizing 须配具体字节/百分比）"
  fi
  grep -qE 'large_client_header_buffers|MaxHeaderBytes|ReadBufferSize' "$R" \
    && { ok "报告⑥：所改限制项名称"; Q_PASS=$((Q_PASS+1)); } || fail "报告⑥：未提及所修改的限制项名称"
  # ⑦ 中间层限额对照：10240 与 12288 各须**同行**伴随放行探针级别的更大新值（≥16402B）
  if pair_line "$R" 10240 && pair_line "$R" 12288; then
    ok "报告⑦：tracegate/meshd 层限额同行对照（10240/12288 → ≥16402B 新值）"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告⑦：10240/12288 须各自与 ≥16402B 新值同行对照（散落关键词不计）"
  fi
  # ⑧ 异步审计旁路三角说明（VETO 联动 ①/④）：16384 与 kafka/MESSAGE_TOO_LARGE **同行**
  #   呈现（治理对照或信号归因行），跨行孤立关键词不计
  if grep -E '(^|[^0-9])16384([^0-9]|$)' "$R" | grep -qiE 'MESSAGE_TOO_LARGE|kafka'; then
    ok "报告⑧：异步审计旁路三角说明（16384 与 kafka/MESSAGE_TOO_LARGE 同行）"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告⑧：16384 须与 kafka/MESSAGE_TOO_LARGE 同行呈现（对照 16384→新值 / 信号归因行）"
  fi
else
  fail "报告①~⑦：缺少综合分析报告 $R"
fi

# ---------- 加权总分 + 双级门槛（始终覆盖写入，4 位小数） ----------
frac() { awk "BEGIN{p=$1; t=$2; printf \"%.4f\", (t>0)?p/t:0}"; }
STRUCTURE=$(frac "$S_PASS" "$S_TOTAL")
BASIC=$(frac "$BASIC_PASS" "$BASIC_TOTAL")
EDGE=$(frac "$EDGE_PASS" "$EDGE_TOTAL")
QUALITY=$(frac "$Q_PASS" "$Q_TOTAL")
SCORE=$(awk "BEGIN{printf \"%.4f\", 0.15*$STRUCTURE + 0.25*$BASIC + 0.40*$EDGE + 0.2*$QUALITY}")

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
GATE_RC2="${RC[edge/02_gate_clean.sh]:-9}"; GATE_RC3="${RC[edge/03_gate_inject_access.sh]:-9}"; GATE_RC4="${RC[edge/04_gate_inject_hdrsize.sh]:-9}"; GATE_RC5="${RC[edge/05_gate_inject_error.sh]:-9}"
if [ "$GATE_RC2" != "0" ] || [ "$GATE_RC3" != "0" ] || [ "$GATE_RC4" != "0" ] || [ "$GATE_RC5" != "0" ]; then
  VETO_REASON="${VETO_REASON:+$VETO_REASON；}质检门禁核心行为失败（edge/02~05 任一不通过：干净误拦或 access/hdrsize/error 任一分源 431 未拦截，431 高优先级拦截防线未建立）"
fi
if [ -n "$VETO_REASON" ]; then
  echo "[verifier] VETO 一票否决：$VETO_REASON"
  SCORE="0.0000"
else
  # ---- CAP（交付空心封顶 0.5500）：仅当 structure 与 basic 两维度均无任何通过项时触发；
  #      edge 单项缺失只扣该维度分，不额外封顶（链路计数失真等按比例扣分）----
  if [ "$S_PASS" -eq 0 ] && [ "${BASIC_PASS:-0}" -eq 0 ]; then
    echo "[verifier] CAP 交付空心封顶：structure 与 basic 均无通过项，reward 封顶 0.5500"
    CAP_NOTE="structure+basic 均为 0 → 封顶 0.5500"
    SCORE=$(awk "BEGIN{v=$SCORE; printf \"%.4f\", (v>0.55)?0.55:v}")
  else
    CAP_NOTE="none"
  fi
fi

# ---------- debug.txt（判分诊断：交付文件在位情况 + 各维度得分 + 门槛与最终分） ----------
{
  echo "=== delivery ==="
  echo "ops_dir=present"
  for _f in header_limits.env quality_gate.sh diagnosis_report.md warnings.log; do
    _p="/app/ops/$_f"
    if [ "$_f" = "quality_gate.sh" ]; then
      echo "$_f exists=$([ -f "$_p" ] && echo yes || echo no) executable=$([ -x "$_p" ] && echo yes || echo no)"
    else
      echo "$_f exists=$([ -s "$_p" ] && echo yes || echo no)"
    fi
  done
  for _f in nginx_T.txt curl_entry.txt curl_backend.txt upper_boundary.txt span_count.txt kafka_audit.txt; do
    echo "evidence/$_f exists=$([ -s "/app/ops/evidence/$_f" ] && echo yes || echo no)"
  done
  echo "=== dimensions ==="
  echo "structure=$STRUCTURE ($S_PASS/$S_TOTAL)"
  echo "basic=$BASIC ($BASIC_PASS/$BASIC_TOTAL)"
  echo "edge=$EDGE ($EDGE_PASS/$EDGE_TOTAL)"
  echo "quality=$QUALITY ($Q_PASS/$Q_TOTAL)"
  echo "veto=${VETO_REASON:-none}"
  echo "cap=${CAP_NOTE:-none}"
  echo "reward=$SCORE"
} > "$DEBUG_FILE"

printf '%s\n' "$SCORE" > "$REWARD_FILE"
echo "[verifier] reward=$SCORE → $REWARD_FILE（诊断 → $DEBUG_FILE）"
exit 0
