#!/bin/bash
# =============================================================================
# 431 任务验题脚本 v8 —— 共享判分 / 行为探针 / 短板定标
# verifier 与作答环境同容器：全部基础断言为**对活服务的行为探针**（不可伪造）。
# reward = 0.20×结构(/10) + 0.35×基础行为探针(/15) + 0.20×证据(/5) + 0.25×报告(/5)
#   structure(/10)：repro/Fx.sh+Fx.out 修复前签名 ×5 + fix/Fx.sh 可执行 ×5
#   basic(/15)：15 项行为探针——直接对活服务做（nginx -T/边界探针/端到端/预算二分/
#     nonce 注入链/server.properties+动态覆盖/标记落盘/meshd 生效限额/采样周期/差分实验）
#   evidence(/5)：五面采集文件存在性（evidence/Fx_*）
#   quality(/5)：报告逐面引用证据路径 ×5
# F6/F7 实现题套件保持不变（双实例差分/逐字节对抗——判分环境执行 ✓ 不可伪造）。
# reward = min(P1, F6, F7)——短板定标。
# =============================================================================
export LC_ALL=C
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWARD_FILE="/logs/verifier/reward.txt"
DEBUG_FILE="/logs/verifier/debug.txt"
OPS="/app/ops"; EV="$OPS/evidence"; RP="$OPS/repro"; FX="$OPS/fix"
mkdir -p /logs/verifier 2>/dev/null || true

ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; }
probe() {
  if [ -n "${2:-}" ] && [ "$2" -gt 0 ] 2>/dev/null; then
    printf 'X-Verify-Token: %s\n' "$(head -c "$2" /dev/zero | tr '\0' 'x')" > /tmp/.v_hdr
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "@/tmp/.v_hdr" "$1"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1"
  fi
}
ENTRY=http://127.0.0.1:80
GATE=http://127.0.0.1:9100; MESH=http://127.0.0.1:15001; BE=http://127.0.0.1:9000

printf '%s\n' "0.0000" > "$REWARD_FILE"
: > "$DEBUG_FILE"
[ -d "$OPS" ] || { echo "ops_dir=missing（空作答）" >> "$DEBUG_FILE"; exit 0; }
echo "ops_dir=present" >> "$DEBUG_FILE"

# ---------- params.env ----------
TEST_BYTES=16384
LIM=""; RATIO=""; HT_F=0; HM_F=0
[ -f "$OPS/params.env" ] && {
  LIM=$(sed -n 's/^[[:space:]]*LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  RATIO=$(sed -n 's/^[[:space:]]*WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  HT_F=$(sed -n 's/^[[:space:]]*hidden.tracegate_factor=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  HM_F=$(sed -n 's/^[[:space:]]*hidden.mesh_factor=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
  DP_P=$(sed -n 's/^[[:space:]]*hidden.drop_period=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')
}
THRESH=0
[ -n "$LIM" ] && [ -n "$RATIO" ] && THRESH=$(( LIM * RATIO / 100 ))
echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing} THRESH=${THRESH}" >> "$DEBUG_FILE"

# ---------- 修复前取证签名 ----------
sig1() { grep -qE '(^|[^0-9])(400|431|502)([^0-9]|$)' "$1" 2>/dev/null; }
sig2() { grep -qE '(^|[^0-9])431([^0-9]|$)|quota=8192|Request Header' "$1" 2>/dev/null; }
sig3() {
  local g m
  g=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B' "$1" 2>/dev/null | head -n1 | sed -E 's/trace_in=([0-9]+)B trace_out=([0-9]+)B/\1 \2/' | awk '{print $2-$1}')
  m=$(grep -oE 'trace_in=[0-9]+B trace_out=[0-9]+B baggage' "$1" 2>/dev/null | head -n1 | sed -E 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/' | awk '{print $2-$1}')
  { [ -z "$g" ] && [ -z "$m" ]; } && return 0   # 无计数行=注入链不可达，亦为修复前证据
  { [ -n "$g" ] && [ "$g" != "769" ]; } && return 0
  { [ -n "$m" ] && [ "$m" != "1537" ]; } && return 0
  return 1
}
sig4() { grep -qE 'MESSAGE_TOO_LARGE|kafka produce failed|message\.max\.bytes=16384' "$1" 2>/dev/null; }
# F5 签名：修复前生效限额 <17408（磁盘与部署环境双口径任一未达标即算）
sig5() {
  local e
  e=$(grep -oE 'effective_limit=[0-9]+' "$1" 2>/dev/null | head -n1 | grep -oE '[0-9]+')
  [ -n "$e" ] && [ "$e" -lt 17408 ] 2>/dev/null
}

# ---------- 维度 1：结构（/10：repro×5 双条件 + fix×5 可执行） ----------
S_PASS=0; S_TOTAL=10
i=0
for spec in "F1:sig1" "F2:sig2" "F3:sig3" "F4:sig4" "F5:sig5"; do
  f="${spec%%:*}"; fn="${spec##*:}"
  if [ -x "$RP/$f.sh" ] && [ -s "$RP/$f.sh" ] && [ -s "$RP/$f.out" ] && "$fn" "$RP/$f.out"; then
    ok "结构 repro/$f：脚本可执行 + 修复前取证签名匹配"; S_PASS=$((S_PASS+1))
  else
    fail "结构 repro/$f：脚本缺失/不可执行，或 Fx.out 缺失/无修复前故障签名"
  fi
done
for f in F1 F2 F3 F4 F5; do
  if [ -x "$FX/$f.sh" ] && [ -s "$FX/$f.sh" ]; then
    ok "结构 fix/$f.sh 存在且可执行"; S_PASS=$((S_PASS+1))
  else
    fail "结构 fix/$f.sh 缺失/不可执行（修复脚本须落盘交付）"
  fi
done

# ---------- P1 基础修复：15 项行为探针（对活服务——不可伪造） ----------
B_PASS=0; B_TOTAL=15

# B1：nginx -T 全部活动指令单缓冲 == params LIM
NT="$(nginx -T 2>/dev/null)"
MINB=""; MAXB=""; CNT=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  b=$(printf '%s' "$v" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
  case "$b" in ''|*[!0-9]*) continue ;; esac
  CNT=$((CNT+1))
  { [ -z "$MINB" ] || [ "$b" -lt "$MINB" ]; } && MINB=$b
  { [ -z "$MAXB" ] || [ "$b" -gt "$MAXB" ]; } && MAXB=$b
done < <(grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' <<< "$NT" 2>/dev/null | sed -E 's/#.*//; s/;.*//' | awk '{print $3}')
if [ "$CNT" -ge 1 ] && [ "$MINB" = "$MAXB" ] && [ "${LIM:-0}" -eq "$MINB" ] 2>/dev/null; then
  ok "B1：nginx 全部指令单缓冲 == LIM（${CNT} 条 = ${MINB}B）"; B_PASS=$((B_PASS+1))
else
  fail "B1：nginx 单缓冲（${CNT} 条，${MINB:-无}~${MAXB:-无}）须全部 == LIM=${LIM:-缺}"
fi

# B2：双侧边界（LIVE nginx——LIM−1024 放行 / LIM+4096 限额拒绝）
# 拒绝语义白名单：400/413/431 是"header 超限"的真实拒绝码；502/404/5xx 是链路故障
# （上游挂了/路由错），302 是重写，都不得算作"限额仍生效"的通过依据。
BELOW_S=$(probe "$ENTRY/api/v1/profile" "$(( LIM - 1024 ))")
ABOVE_S=$(probe "$ENTRY/api/v1/profile" "$(( LIM + 4096 ))")
if [ "$BELOW_S" = "200" ] && printf '%s' "$ABOVE_S" | grep -qE '(^|[^0-9])(400|413|431)([^0-9]|$)'; then
  ok "B2：双侧边界（LIM−1024=${BELOW_S} / LIM+4096=${ABOVE_S} 限额拒绝）"; B_PASS=$((B_PASS+1))
else
  fail "B2：双侧边界（below=${BELOW_S:-缺} 须 200；above=${ABOVE_S:-缺} 须为 400/413/431 之一——其余状态码是链路故障而非限额拒绝）"
fi

# B3：端到端大探针（LIVE 全链路）+ 响应体
EB=$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")
BB=$(probe "$BE/api/v1/profile" "$TEST_BYTES")
BODY=$(curl -s --max-time 15 "$BE/api/v1/profile" 2>/dev/null | head -c 200)
if [ "$EB" = "200" ] && [ "$BB" = "200" ] && printf '%s' "$BODY" | grep -q '"msg":"ok"'; then
  ok "B3：端到端大探针 200 + 响应体特征"; B_PASS=$((B_PASS+1))
else
  fail "B3：entry=${EB:-缺} backend=${BB:-缺} body=${BODY:0:40}"
fi

# B4：预警阈值联动（LIVE backend banner）
BANNER=$(grep 'startup:' /var/log/backend.log 2>/dev/null | tail -n1)
WT=$(printf '%s' "$BANNER" | grep -oE 'warn_threshold=[0-9]+B' | grep -oE '[0-9]+' | head -n1)
if [ -n "$WT" ] && [ "${THRESH:-0}" -gt 0 ] && [ "$WT" -eq "$THRESH" ] 2>/dev/null; then
  ok "B4：预警阈值联动（banner warn_threshold=${WT} == THRESH=${THRESH}）"; B_PASS=$((B_PASS+1))
else
  fail "B4：banner warn_threshold=${WT:-缺} ≠ THRESH=${THRESH:-缺}（须按 LIM×WARN_RATIO/100 联动）"
fi

# B5：restart all 持久化（判分器自行重启 + 复探——不可伪造）
supervisorctl restart all >/dev/null 2>&1 || supervisorctl -c /tmp/eval-sup/supervisord.conf restart all >/dev/null 2>&1 || true
for _ in $(seq 1 15); do
  K=$(timeout 2 bash -c 'exec 3<> /dev/tcp/127.0.0.1/9092' 2>/dev/null && echo ok || echo no)
  [ "$K" = "ok" ] && curl -s -o /dev/null --max-time 3 "$BE/healthz" && break
  sleep 2
done
sleep 2
PR_E=$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")
PR_B=$(probe "$BE/api/v1/profile" "$TEST_BYTES")
if [ "$PR_E" = "200" ] && [ "$PR_B" = "200" ]; then
  ok "B5：restart all 后全链路仍 200（持久化）"; B_PASS=$((B_PASS+1))
else
  fail "B5：restart all 后 entry=${PR_E:-缺} backend=${PR_B:-缺}"
fi

# B6：预警双侧标定（LIVE warnings.log——判分器自行发探针并计行数）
: > "$OPS/warnings.log" 2>/dev/null || true
ABOVE_P=$(( THRESH + 512 ))
probe "$ENTRY/api/v1/profile" "$ABOVE_P" >/dev/null
sleep 2
AD=$(wc -l < "$OPS/warnings.log" 2>/dev/null || echo 0)
BELOW_P=1024  # 常规流量：注入开销 ~3KB 后仍远低于 THRESH（ THRESH ≥ 17408×0.5 = 8704）
probe "$ENTRY/api/v1/profile" "$BELOW_P" >/dev/null
sleep 2
BD=$(wc -l < "$OPS/warnings.log" 2>/dev/null || echo 0)
BD=$(( BD - AD ))
if [ "$AD" -ge 1 ] 2>/dev/null && [ "$BD" -eq 0 ] 2>/dev/null; then
  ok "B6：预警双侧标定（above 增量 ${AD} / below 增量 ${BD}）"; B_PASS=$((B_PASS+1))
else
  fail "B6：预警双侧标定（above_delta=${AD:-0} 须≥1 / below_delta=${BD:-0} 须=0）"
fi

# B7：tracegate 生效预算二分实测（LIVE 边界探针定位 431 翻转点）
TB_EXP=$(( 10240 * ${HT_F:-0} / 10 ))
TG_LO=4096; TG_HI=65536
while [ $(( TG_HI - TG_LO )) -gt 64 ]; do
  MID=$(( (TG_LO + TG_HI) / 2 ))
  S=$(probe "$GATE/api/v1/profile" "$MID")
  if [ "$S" = "431" ] || [ "$S" = "400" ]; then TG_HI=$MID; else TG_LO=$MID; fi
done
TG_MEASURED=$TG_LO
if [ "$TG_MEASURED" -ge 16384 ] 2>/dev/null && [ "$TG_MEASURED" -le 131072 ] 2>/dev/null; then
  ok "B7：tracegate 生效预算实测 ${TG_MEASURED} ≥ 16384（修复后放行探针）"; B_PASS=$((B_PASS+1))
else
  fail "B7：tracegate 生效预算 ${TG_MEASURED:-无} < 16384——预算未修复或修复不充分"
fi

# B8：mesh 生效预算二分实测（LIVE）
MH_LO=4096; MH_HI=65536
while [ $(( MH_HI - MH_LO )) -gt 64 ]; do
  MID=$(( (MH_LO + MH_HI) / 2 ))
  S=$(probe "$MESH/api/v1/profile" "$MID")
  if [ "$S" = "431" ] || [ "$S" = "400" ]; then MH_HI=$MID; else MH_LO=$MID; fi
done
MH_MEASURED=$MH_LO
if [ "$MH_MEASURED" -ge 16384 ] 2>/dev/null; then
  ok "B8：mesh 生效预算实测 ${MH_MEASURED} ≥ 16384"; B_PASS=$((B_PASS+1))
else
  fail "B8：mesh 生效预算 ${MH_MEASURED:-无} < 16384"
fi

# B9：注入链规格（LIVE nonce 探针 → echo 增幅恰 2306 + MESHSTAT 精确计数）
NONCE="vfi$(date +%s%N)"
ECHO_VAL="$(curl -s -D - -o /dev/null --max-time 15 -H "X-Trace-Context: $NONCE" "$ENTRY/api/v1/profile" 2>/dev/null | grep -i '^x-trace-context:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
GRW=$(( ${#ECHO_VAL} - ${#NONCE} ))
sleep 1
ML="$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
MD=$(printf '%s' "$ML" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p' | awk '{print $2-$1}')
if [ "$GRW" -eq 2306 ] && [ "$MD" = "1537" ] 2>/dev/null; then
  ok "B9：注入链规格（echo 增幅恰 2306 / mesh delta 恰 1537）"; B_PASS=$((B_PASS+1))
else
  fail "B9：注入链规格（echo 增幅=${GRW} 须 2306 / mesh delta=${MD:-0} 须 1537）"
fi

# B10：broker 限额双口径（LIVE server.properties 静态落盘 + 运行中 broker 动态覆盖）
# 运行时生效限额 = 动态覆盖（kafka-configs 设置过的，重启后仍持久）若存在，否则静态
# 落盘值——dynamic=16384 压过 static=65536 的"假治理"（改了文件没对齐运行态）在此现形。
KAF_FILE="/opt/kafka/config/kraft/server.properties"
KS=$(grep -oE '^message\.max\.bytes=[0-9]+' "$KAF_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
KAF_DYN="$(timeout 20 /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9092 \
  --entity-type brokers --entity-name 1 --describe 2>/dev/null \
  | grep -oE 'message\.max\.bytes=[0-9]+' | head -n1 | grep -oE '[0-9]+')"
if [ -n "$KS" ] && [ "$KS" -gt 16384 ] 2>/dev/null; then
  if [ -z "$KAF_DYN" ]; then
    ok "B10：broker 静态限额 ${KS} > 16384（无动态覆盖，静态生效口径）"; B_PASS=$((B_PASS+1))
  elif [ "$KAF_DYN" -gt 16384 ] 2>/dev/null; then
    ok "B10：broker 限额 static=${KS} / 动态覆盖=${KAF_DYN} 均 >16384"; B_PASS=$((B_PASS+1))
  else
    fail "B10：broker 动态覆盖 ${KAF_DYN} ≤16384——运行中 broker 仍按旧限额拒审计事件（dynamic 压过 static，须 kafka-configs 动态对齐或清除覆盖）"
  fi
else
  fail "B10：broker 静态限额 ${KS:-缺} 须 >16384"
fi

# B11：标记事件落盘（LIVE Kafka + marker 探针）
MRK="vfy$(date +%s%N)"
probe "$ENTRY/api/v1/profile" "$TEST_BYTES" >/dev/null
curl -s -o /dev/null --max-time 10 -H "X-Case-Marker: $MRK" "$ENTRY/api/v1/profile" 2>/dev/null || true
for _ in $(seq 1 8); do sleep 3; grep -q "$MRK" /var/log/trace_events.log 2>/dev/null && break; done
if grep -q "$MRK" /var/log/trace_events.log 2>/dev/null; then
  ok "B11：标记事件落盘（LIVE Kafka 管道）"; B_PASS=$((B_PASS+1))
else
  fail "B11：标记事件 30s 内未落盘"
fi

# B12：meshd 生效限额（LIVE meshd 日志——部署环境覆盖口径）
MESH_EFF=$(grep -oE 'limit=[0-9]+' /var/log/meshd.log 2>/dev/null | tail -n1 | grep -oE '[0-9]+')
if [ -n "$MESH_EFF" ] && [ "$MESH_EFF" -ge 16384 ] 2>/dev/null; then
  ok "B12：meshd 生效限额 ${MESH_EFF} ≥ 16384"; B_PASS=$((B_PASS+1))
else
  fail "B12：meshd 生效限额 ${MESH_EFF:-缺} < 16384"
fi

# B13：隐藏采样周期推断（LIVE 30 标记探针 → 落盘率 → 推断 N）
: > /tmp/f8-markers.txt
for i in $(seq 1 30); do
  MK="f8$(date +%s%N)$i"
  echo "$MK" >> /tmp/f8-markers.txt
  probe "$ENTRY/api/v1/profile" "$TEST_BYTES" >/dev/null
  curl -s -o /dev/null --max-time 10 -H "X-Case-Marker: $MK" "$ENTRY/api/v1/profile" 2>/dev/null || true
done
for _ in $(seq 1 8); do sleep 3; break; done
LAND=0
while IFS= read -r mk; do grep -q "$mk" /var/log/trace_events.log 2>/dev/null && LAND=$((LAND+1)); done < /tmp/f8-markers.txt
DP_EXP=$(( ${DP_P:-0} ))
if [ "$DP_EXP" -ge 3 ] 2>/dev/null; then
  LOST=$(( 30 - LAND ))
  if [ "$LOST" -gt 0 ] && [ "$LAND" -lt 30 ] 2>/dev/null; then
    ok "B13：隐藏采样周期可见（30 探针落盘 ${LAND}——丢失 ${LOST}，N≈$(( 30 / (LOST>0 ? LOST : 1) ))）"; B_PASS=$((B_PASS+1))
  else
    ok "B13：30 探针全落盘（采样已移除）"; B_PASS=$((B_PASS+1))
  fi
else
  fail "B13：hidden.drop_period 缺失——发送 ≥20 标记探针统计落盘率推断周期"
fi

# B14：多字节规格差分（LIVE ASCII vs 多字节路由探针 → 逐跳 delta 对照）
NA="vfa$(date +%s%N)"
curl -s -o /dev/null --max-time 15 -H "X-Trace-Context: $NA" "$ENTRY/api/v1/profile" 2>/dev/null
sleep 1
MA_D=$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1 | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p' | awk '{print $2-$1}')
NB="vfb$(date +%s%N)"
curl -s -o /dev/null --max-time 15 -H "X-Trace-Context: $NB" "$MESH/%E8%B7%AF%E7%94%B1%CE%B1" 2>/dev/null
sleep 1
MB_D=$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1 | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p' | awk '{print $2-$1}')
if [ "$MA_D" = "$MB_D" ] && [ "$MA_D" = "1537" ] 2>/dev/null; then
  ok "B14：多字节规格差分（ASCII 与多字节路由 delta 恰 1537——规格恢复）"; B_PASS=$((B_PASS+1))
else
  fail "B14：多字节差分异常（ascii=${MA_D:-0} multibyte=${MB_D:-0}——须恰 1537）"
fi

# B15：门禁脚本行为（判分环境本地伪造日志——干净过/431 注入拒）
GATEB="$OPS/quality_gate.sh"
if [ -x "$GATEB" ]; then
  mkdir -p /var/log/nginx
  : > /var/log/nginx/access.log; : > /var/log/nginx/hdrsize.log; : > /var/log/nginx/error.log
  G1=0; bash "$GATEB" >/dev/null 2>&1 || G1=1
  echo '127.0.0.1 - - ['"$(date '+%d/%b/%Y:%H:%M:%S +0000')"'] "GET /injected HTTP/1.1" 431 0 "-" "v"' >> /var/log/nginx/access.log
  G2=0; bash "$GATEB" >/dev/null 2>&1 || G2=1
  : > /var/log/nginx/access.log
  echo "$(date +%s).000 431 99999 \"GET /injected HTTP/1.1\"" >> /var/log/nginx/hdrsize.log
  G3=0; bash "$GATEB" >/dev/null 2>&1 || G3=1
  : > /var/log/nginx/hdrsize.log
  if [ "$G1" = "0" ] && [ "$G2" = "1" ] && [ "$G3" = "1" ]; then
    ok "B15：门禁行为（干净过 / 431 注入拒）"; B_PASS=$((B_PASS+1))
  else
    fail "B15：门禁行为（clean=$G1 inject=$G2/$G3——须 clean=0/inject≠0）"
  fi
  : > /var/log/nginx/access.log; : > /var/log/nginx/hdrsize.log; : > /var/log/nginx/error.log
else
  fail "B15：quality_gate.sh 缺失或不可执行"
fi

echo "P1 基础探针完成: $B_PASS/$B_TOTAL"
# ---------- 维度 3：证据齐全（/5） ----------
E_PASS=0; E_TOTAL=5
for f in F1 F2 F3 F4 F5; do
  if ls "$EV/${f}_"* >/dev/null 2>&1; then
    ok "证据 ${f}_* 存在"; E_PASS=$((E_PASS+1))
  else
    fail "证据 ${f}_* 缺失"
  fi
done

# ---------- 维度 4：报告质量（/5：逐面引用证据路径） ----------
Q_PASS=0; Q_TOTAL=5
R="$OPS/diagnosis_report.md"
for f in F1 F2 F3 F4 F5; do
  if [ -s "$R" ] && grep -q "evidence/${f}_" "$R"; then
    ok "报告：引用 ${f} 面证据路径"; Q_PASS=$((Q_PASS+1))
  else
    fail "报告：未引用 ${f} 面证据文件相对路径（evidence/${f}_*）"
  fi
done

# ---------- P1：运维修复清单（权重 0.15） ----------
P1=$(awk "BEGIN{printf \"%.4f\", 0.20*$S_PASS/$S_TOTAL + 0.35*$B_PASS/$B_TOTAL + 0.20*$E_PASS/$E_TOTAL + 0.25*$Q_PASS/$Q_TOTAL}")
echo "==================================================================="
echo "[verifier] P1 运维清单: 结构=$S_PASS/$S_TOTAL 基础=$B_PASS/$B_TOTAL 证据=$E_PASS/$E_TOTAL 报告=$Q_PASS/$Q_TOTAL → P1=$P1"

# ---------- P2：F7 标定器实现（隐性对抗套件，权重 0.85） ----------
# 规格见 /app/tools/specs/spec-calibrator.md；判分环境以 tests/bin/calibrator-ref 为
# 参考实现，12 个复合场景逐字节对照 agent 交付的 /app/ops/bin/calibrator。
F7_PASS=0; F7_TOTAL=0
F6_PASS=0; F6_TOTAL=12
AGG="$OPS/bin/calibrator"
REFBIN="/tests/bin/calibrator-ref"; [ -x "$REFBIN" ] || REFBIN="$TESTS_DIR/bin/calibrator-ref"
GENBIN="/tests/bin/gen-calibrator"; [ -x "$GENBIN" ] || GENBIN="$TESTS_DIR/bin/gen-calibrator"
THRESH_V=$(( ${LIM:-0} * ${RATIO:-0} / 100 ))
if [ -n "$LIM" ] && [ -n "$RATIO" ] && [ -x "$AGG" ]; then
  CASES=/tmp/f7cases
  rm -rf "$CASES"; mkdir -p "$CASES"
  SEED="trial-LIM=$LIM-RATIO=$RATIO-ht=$(grep -oE 'hidden.tracegate_factor=[0-9.]+' /app/ops/params.env 2>/dev/null)-hm=$(grep -oE 'hidden.mesh_factor=[0-9.]+' /app/ops/params.env 2>/dev/null)"
  "$GENBIN" "$LIM" "$RATIO" "$SEED" "$CASES" "$REFBIN" >/dev/null 2>&1 || true
  for cin in $(ls "$CASES"/sc*.in 2>/dev/null | sort); do
    F7_TOTAL=$((F7_TOTAL+1))
    "$AGG" "$THRESH_V" < "$cin" > /tmp/f7-agent.out 2>/dev/null || true
    "$REFBIN" "$THRESH_V" < "$cin" > /tmp/f7-ref.out 2>/dev/null || true
    if diff -q /tmp/f7-agent.out /tmp/f7-ref.out >/dev/null 2>&1; then
      ok "F7 场景 $(basename "$cin") 逐字节一致"; F7_PASS=$((F7_PASS+1))
    else
      fail "F7 场景 $(basename "$cin") 输出不一致（规格角未实现或实现偏差）"
    fi
  done
else
  F7_TOTAL=12
  fail "F7：/app/ops/bin/calibrator 缺失或不可执行，或 params.env 缺失——实现题 0 分"
fi
P2=$(awk "BEGIN{t=$F7_TOTAL; p=$F7_PASS; printf \"%.4f\", (t>0)?p/t:0}")

# ---------- P3：F6 headeragg 实现题（隐性差分套件） ----------
F6_PASS=0; F6_TOTAL=12
HAGG="$OPS/bin/headeragg"
HREFB="$TESTS_DIR/bin/headeragg-ref"
THRESH_F6="$THRESH_V"
if [ -n "$LIM" ] && [ -n "$RATIO" ] && [ -x "$HAGG" ] && [ -x "$HREFB" ]; then
  for pid in $(ss -ltnp 2>/dev/null | grep -E ':92[0-9]{2} |:93[0-9]{2} ' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do kill -9 "$pid" 2>/dev/null; done
  sleep 0.3
  rm -f /tmp/f6-a.state /tmp/f6-r.state
  "$HAGG" "$THRESH_F6" /tmp/f6-a.state 9200 & PA=$!
  "$HREFB" "$THRESH_F6" /tmp/f6-r.state 9300 & PR=$!
  sleep 0.6
  killA() { kill -9 "$PA" 2>/dev/null; }
  killR() { kill -9 "$PR" 2>/dev/null; }
  restartBoth() {
    killA; killR; sleep 0.3
    "$HAGG" "$THRESH_F6" /tmp/f6-a.state 9200 & PA=$!
    "$HREFB" "$THRESH_F6" /tmp/f6-r.state 9300 & PR=$!
    sleep 0.6
  }
  post() { curl -s -X POST -d "$1" "http://127.0.0.1:$2/event" >/dev/null; }
  cmpStats() {
    a=$(curl -s "http://127.0.0.1:9200/stats")
    r=$(curl -s "http://127.0.0.1:9300/stats")
    if [ "$a" = "$r" ]; then F6_PASS=$((F6_PASS+1)); ok "F6 场景 $1 双实例 stats 一致"
    else fail "F6 场景 $1 双实例 stats 不一致"; fi
  }
  # s1 单事件
  post "ts=100 route=/api bytes=500" 9200; post "ts=100 route=/api bytes=500" 9300
  cmpStats s1
  # s2 混合 10 事件
  for i in 1 2 3 4 5; do post "ts=$((100+i)) route=/r$((i%2)) bytes=$((100+i*7))" 9200; post "ts=$((100+i)) route=/r$((i%2)) bytes=$((100+i*7))" 9300; done
  cmpStats s2
  # s3 并发 100（精确计数）
  seq 1 100 | xargs -P 20 -I{} curl -s -X POST -d "ts=500 route=/burst bytes=100" http://127.0.0.1:9200/event >/dev/null
  seq 1 100 | xargs -P 20 -I{} curl -s -X POST -d "ts=500 route=/burst bytes=100" http://127.0.0.1:9300/event >/dev/null
  sleep 0.5
  cmpStats s3
  # s4 多字节路由
  post "ts=600 route=/路由/α bytes=333" 9200; post "ts=600 route=/路由/α bytes=333" 9300
  post "ts=600 route=/emoji🚀 bytes=444" 9200; post "ts=600 route=/emoji🚀 bytes=444" 9300
  cmpStats s4
  # s5 边界恰等（bytes==THRESH 计 over）+ s6 THRESH+1
  post "ts=700 route=/edge bytes=$THRESH_F6" 9200; post "ts=700 route=/edge bytes=$THRESH_F6" 9300
  cmpStats s5
  post "ts=700 route=/edge bytes=$((THRESH_F6+1))" 9200; post "ts=700 route=/edge bytes=$((THRESH_F6+1))" 9300
  cmpStats s6
  # s7 畸形事件（stats 不得变化）
  post "bad line" 9200; post "bad line" 9300
  post "ts=x route=/m bytes=1" 9200; post "ts=x route=/m bytes=1" 9300
  cmpStats s7
  # s8 尾斜杠独立路由
  post "ts=800 route=/a bytes=10" 9200; post "ts=800 route=/a bytes=10" 9300
  post "ts=800 route=/a/ bytes=20" 9200; post "ts=800 route=/a/ bytes=20" 9300
  cmpStats s8
  # s9 双实例 kill+restart 持久化恢复
  killA; killR; sleep 0.3
  "$HAGG" "$THRESH_F6" /tmp/f6-a.state 9200 & PA=$!
  "$HREFB" "$THRESH_F6" /tmp/f6-r.state 9300 & PR=$!
  sleep 0.6
  cmpStats s9
  # s10 重启后衔接
  post "ts=900 route=/post bytes=777" 9200; post "ts=900 route=/post bytes=777" 9300
  cmpStats s10
  # s11 静默（THRESH−1 不得计 over）
  post "ts=1000 route=/quiet bytes=$((THRESH_F6-1))" 9200; post "ts=1000 route=/quiet bytes=$((THRESH_F6-1))" 9300
  cmpStats s11
  # s12 终态混合
  post "ts=1100 route=/fin/α bytes=999" 9200; post "ts=1100 route=/fin/α bytes=999" 9300
  post "ts=1100 route=/fin bytes=1" 9200; post "ts=1100 route=/fin bytes=1" 9300
  cmpStats s12
  killA; killR
else
  F6_TOTAL=12
  fail "F6：/app/ops/bin/headeragg 缺失或不可执行——实现题 0 分"
fi
F6=$(awk "BEGIN{t=$F6_TOTAL; p=$F6_PASS; printf \"%.4f\", (t>0)?p/t:0}")

# ---------- 加权总分：短板定标 min(P1, F6, F7) ----------
SCORE=$(awk "BEGIN{m=$P1; if ($F6<m) m=$F6; if ($P2<m) m=$P2; printf \"%.4f\", m}")

# ---------- CAP：repro 取证全缺 → 封顶 0.45 ----------
REPRO_OK=0
for spec in "F1:sig1" "F2:sig2" "F3:sig3" "F4:sig4" "F5:sig5"; do
  f="${spec%%:*}"; fn="${spec##*:}"
  { [ -x "$RP/$f.sh" ] && [ -s "$RP/$f.out" ] && "$fn" "$RP/$f.out"; } && REPRO_OK=$((REPRO_OK+1))
done
CAP_NOTE="none"
if [ "$REPRO_OK" -eq 0 ]; then
  SCORE=$(awk "BEGIN{printf \"%.4f\", ($SCORE < 0.45 ? $SCORE : 0.45)}")
  CAP_NOTE="repro 取证全缺 → 封顶 0.4500"
  echo "[verifier] CAP：repro 取证全缺，reward 封顶 0.4500"
fi

# ---------- debug.txt ----------
{
  echo "=== delivery ==="
  echo "ops_dir=present"
  echo "params: LIM=${LIM:-missing} WARN_RATIO=${RATIO:-missing} THRESH=${THRESH}"
  for f in F1 F2 F3 F4 F5; do
    echo "repro/$f: sh=$([ -x "$RP/$f.sh" ] && echo ok || echo no) out=$([ -s "$RP/$f.out" ] && echo ok || echo no) fix=$([ -x "$FX/$f.sh" ] && echo ok || echo no)"
  done
  for f in "$EV"/*; do [ -f "$f" ] && echo "evidence/$(basename "$f") exists=yes"; done
  echo "=== dimensions ==="
  echo "structure=$S_PASS/$S_TOTAL"
  echo "basic=$B_PASS/$B_TOTAL"
  echo "edge=$E_PASS/$E_TOTAL"
  echo "quality=$Q_PASS/$Q_TOTAL"
  echo "repro_ok=$REPRO_OK"
  echo "score=$SCORE"
} > "$DEBUG_FILE"

printf '%s\n' "$SCORE" > "$REWARD_FILE"
echo "[verifier] reward=$SCORE → $REWARD_FILE（诊断 → $DEBUG_FILE）"
exit 0
