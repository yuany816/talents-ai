#!/bin/bash
# =============================================================================
# solution/solve.sh —— 参考解（4 故障面 / 2 交付阶段 / params 随机参数感知）
#
# 面：F1 nginx 入口缓冲 / F2 backend 多形态限额 / F3 tracegate 注入链规格 /
#     F4 kafka 审计旁路限额。（meshd 为链路组成部分，其限额不在计分面单独计分，
#     但 F2 端到端证据依赖全链路——本脚本一并修复。）
# 阶段 1：交付 repro/F1~F4.sh 复现脚本（可执行）。
# 阶段 2：四面修复生效 + /app/tools/collect_*.sh 采集证据 + 每面三行诊断报告。
# 容量参数 LIM/WARN_RATIO 每 trial 随机（environment/entrypoint.sh 生成 params.env），
# 本脚本读取 params.env 并使 nginx 配置/声明与之一致——不硬编码。
# 运行约定：任务环境容器内 root；服务由 supervisord 编排；Go 模块在 /app 下。
# =============================================================================
set -uo pipefail
export LC_ALL=C
umask 022

APP=/app; OPS=$APP/ops; EV=$OPS/evidence; TOOLS=$APP/tools
TEST_BYTES=16384           # 复现探针（完整 header 行 ≈16402B）
NG_CHB_KB=16               # client_header_buffer_size
NG_BUF_N=4                 # large_client_header_buffers 数量
QUOTA_MAX=1048576          # backend/tracegate/meshd 新限额（≥ 任意 LIM）
KAF_MAX=1048576            # broker 新限额

say()  { echo "[solve.sh] $*"; }
warn() { echo "[solve.sh][WARN] $*" >&2; }
die()  { echo "[solve.sh][FATAL] $*" >&2; exit 1; }
tok()  { head -c "$1" /dev/zero | tr '\0' 'x'; }
backup() { [ -f "$1" ] && [ ! -f "$1.solve.bak" ] && cp -p "$1" "$1.solve.bak" || true; }

mkdir -p "$OPS/repro" "$OPS/fix" "$OPS/evidence" /var/log/nginx

# ---------- ⓪ params（每 trial 随机；缺失按兼容值兜底） ----------
LIM=65536; RATIO=80
if [ -f "$OPS/params.env" ]; then
  _p="$(sed -n 's/^LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')"; [ -n "$_p" ] && LIM=$_p
  _r="$(sed -n 's/^WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')"; [ -n "$_r" ] && RATIO=$_r
fi
say "params.env: LIM=${LIM} WARN_RATIO=${RATIO}"

# supervisord 控制通道自适配（容器内默认；复刻环境可能用独立 conf）
SUP="supervisorctl"
supervisorctl status >/dev/null 2>&1 || SUP="supervisorctl -c /tmp/eval-sup/supervisord.conf"
$SUP status >/dev/null 2>&1 || die "supervisord 未运行（环境编排缺失）"

ENTRY=http://127.0.0.1:80
GATE=http://127.0.0.1:9100; MESH=http://127.0.0.1:15001; BE=http://127.0.0.1:9000
probe() {  # $1=url $2=header值字节数（0/空=不带）
  if [ -n "${2:-}" ] && [ "$2" -gt 0 ] 2>/dev/null; then
    printf 'X-Verify-Token: %s\n' "$(tok "$2")" > /tmp/.sv_hdr
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "@/tmp/.sv_hdr" "$1"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1"
  fi
}
wait_up() { for _ in $(seq 1 20); do curl -s -o /dev/null --max-time 2 "$1" && return 0; sleep 1; done; return 1; }

# ---------- ① 分层复现（记录修复前状态，供报告数值对照） ----------
say "① 分层复现（${TEST_BYTES}B 探针）"
INIT_E="$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")"
INIT_T="$(probe "$GATE/api/v1/profile" "$TEST_BYTES")"
INIT_M="$(probe "$MESH/api/v1/profile" "$TEST_BYTES")"
INIT_B="$(probe "$BE/api/v1/profile" "$TEST_BYTES")"
NG_BEFORE="$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | sed -E 's/;.*//' | awk '{print $2, $3}')"
SPAN_BEFORE="$(sed -n 's/^span_bytes:[[:space:]]*//p' /app/tracegate/tracegate.yaml | head -n1)"
KAF_BEFORE="$(grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties | head -n1 | cut -d= -f2)"
say "修复前: nginx=${NG_BEFORE:-无} entry=${INIT_E} tracegate=${INIT_T} meshd=${INIT_M} backend=${INIT_B} span_bytes=${SPAN_BEFORE} kafka=${KAF_BEFORE}"

# ---------- ② F1 nginx：生效单缓冲 == params LIM（全指令一致） ----------
say "② F1 nginx（large_client_header_buffers 4 ${LIM}）"
# 注释全部旧指令（消除配置漂移），再于 http{} 块插入统一定义
while read -r f; do
  [ -f "$f" ] || continue
  backup "$f"
  sed -i -E 's/^([[:space:]]*)(client_header_buffer_size|large_client_header_buffers)/\1# disabled-by-solve.sh: &/' "$f"
done < <(grep -rlE '^[[:space:]]*(client_header_buffer_size|large_client_header_buffers)[[:space:]]' /etc/nginx 2>/dev/null)
NGINX_CONF="$(nginx -t 2>&1 | sed -nE 's#.*configuration file ([^[:space:]]+).*#\1#p' | head -n1)"
[ -z "$NGINX_CONF" ] && NGINX_CONF="/etc/nginx/nginx.conf"
backup "$NGINX_CONF"
awk -v ins="    client_header_buffer_size ${NG_CHB_KB}k;\n    large_client_header_buffers ${NG_BUF_N} ${LIM};" '
  !done && $0 ~ /^[[:space:]]*http[[:space:]]*[{]/ { print; print ins; done=1; next } { print }
' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
grep -qE "^[[:space:]]*large_client_header_buffers[[:space:]]+${NG_BUF_N}[[:space:]]+${LIM};" "$NGINX_CONF" \
  || die "F1 nginx 写入失败（http{} 块未定位）"
nginx -t >/dev/null 2>&1 || die "F1 nginx -t 校验失败（已回滚语义，须人工检查）"
if pgrep -x nginx >/dev/null 2>&1; then
  nginx -s reload 2>/dev/null || { pkill -x nginx 2>/dev/null || true; sleep 1; nginx -g 'daemon on;'; }
else
  nginx -g 'daemon on;'
fi
sleep 1
$SUP restart nginx >/dev/null 2>&1 || true

# ---------- ③ F2 backend：三处 8192 形态 + 编译期固化重建 ----------
say "③ F2 backend（配额/框架/存档 → ${QUOTA_MAX}，重建二进制）"
backup /app/backend/configs/quota.yaml
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/' /app/backend/configs/quota.yaml
backup /app/backend/main.go
# 移码书写形态（1 << 13）与普通数值两种口径各替换一次，保持行尾注释与逗号不动
sed -i -E 's/(MaxHeaderBytes:[[:space:]]*)1[[:space:]]*<<[[:space:]]*13/\1'"${QUOTA_MAX}"'/' /app/backend/main.go
sed -i -E 's/(MaxHeaderBytes:[[:space:]]*)[0-9]+([[:space:]]*,)/\1'"${QUOTA_MAX}"'\2/' /app/backend/main.go
grep -q "MaxHeaderBytes: ${QUOTA_MAX}" /app/backend/main.go || die "F2 MaxHeaderBytes 替换未生效（形态未识别）"
backup /app/backend/legacy_server.go
sed -i -E 's/(legacyQuotaBytes[[:space:]]*=[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/' /app/backend/legacy_server.go
# 全量残留清理：十进制 8192（退役存档/任意书写处）
while read -r rf; do
  [ -f "$rf" ] || continue
  backup "$rf"
  sed -i -E 's/(^|[^0-9])8192([^0-9]|$)/\1'"${QUOTA_MAX}"'\2/g; s/(^|[^0-9])8192([^0-9]|$)/\1'"${QUOTA_MAX}"'\2/g' "$rf"
done < <(grep -rlIE '(^|[^0-9])8192([^0-9]|$)' /app/backend \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.orig' --exclude='*.old' \
    --exclude='*.backup' --exclude='*.disabled' --exclude='*.solve.bak' 2>/dev/null || true)
( cd /app/backend && timeout 300 env GOPROXY=off CGO_ENABLED=0 go build -o backend.new . ) || die "F2 go build 失败"
mv -f /app/backend/backend.new /app/backend/backend && chmod 755 /app/backend/backend
$SUP restart backend >/dev/null 2>&1 || die "backend 重启失败"

# ---------- ④ F3 tracegate：限额 + span 规格恢复（384→768） ----------
say "④ F3 tracegate（max_header_bytes→${QUOTA_MAX}，span_bytes 384→768）"
backup /app/tracegate/tracegate.yaml
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/; s/^(span_bytes:[[:space:]]*)[0-9]+/\1768/' /app/tracegate/tracegate.yaml
$SUP restart tracegate >/dev/null 2>&1 || die "tracegate 重启失败"

# ---------- ④b meshd（不计分面，链路必需）：磁盘 + supervisor env 双口径 ----------
say "④b meshd（磁盘与程序环境覆盖双口径 → ${QUOTA_MAX}）"
backup /app/mesh/sidecar.yaml
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/' /app/mesh/sidecar.yaml
SUPCONF=/etc/supervisor/conf.d/app.conf
if grep -qE 'MESH_HEADER_LIMIT=' "$SUPCONF" 2>/dev/null; then
  backup "$SUPCONF"
  sed -i -E 's/(MESH_HEADER_LIMIT=")[0-9]+(")/\1'"${QUOTA_MAX}"'\2/' "$SUPCONF"
  $SUP reread >/dev/null 2>&1 && $SUP update >/dev/null 2>&1
fi
$SUP restart meshd >/dev/null 2>&1 || true

# ---------- ⑤ F4 kafka：动态生效 + 静态落盘 ----------
say "⑤ F4 kafka（message.max.bytes → ${KAF_MAX}，动态 + 静态防回退）"
timeout 30 /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9092 \
  --entity-type brokers --entity-name 1 --alter --add-config "message.max.bytes=${KAF_MAX}" >/dev/null 2>&1 \
  || warn "kafka 动态 alter 未确认（旁路不阻断）"
backup /opt/kafka/config/kraft/server.properties
sed -i -E "s/^(message\.max\.bytes=)[0-9]+/\1${KAF_MAX}/" /opt/kafka/config/kraft/server.properties

# ---------- ⑥ 全链路自验（供报告数值） ----------
say "⑥ 全链路自验"
wait_up "$ENTRY/healthz" || warn "入口未就绪"
FINAL_E="$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")"
FINAL_B="$(probe "$BE/api/v1/profile" "$TEST_BYTES")"
NORM_E="$(probe "$ENTRY/api/v1/profile" 0)"
ABOVE="$(probe "$ENTRY/api/v1/profile" "$(( LIM + 4096 ))")"
VFY="vfy$(date +%s%N)"
ECHO_VAL="$(curl -s -D - -o /dev/null --max-time 15 -H "X-Trace-Context: $VFY" "$ENTRY/api/v1/profile" 2>/dev/null \
  | grep -i '^x-trace-context:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
sleep 1
GL="$(grep 'GATESTAT' /var/log/tracegate.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
ML="$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
read -r GI GO <<< "$(printf '%s' "$GL" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p')"
read -r MI MO MBAG <<< "$(printf '%s' "$ML" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B baggage=([0-9]+)B.*/\1 \2 \3/p')"
GDEL=$(( ${GO:-0} - ${GI:-0} )); MDEL=$(( ${MO:-0} - ${MI:-0} ))
say "修复后: entry=${FINAL_E}(norm=${NORM_E}) backend=${FINAL_B} above(LIM+4096)=${ABOVE} gate_delta=${GDEL} mesh_delta=${MDEL} baggage=${MBAG:-0}"

PASS=1
[ "$FINAL_E" = "200" ] && [ "$FINAL_B" = "200" ] && [ "$NORM_E" = "200" ] || PASS=0
case "$ABOVE" in 200|000|"") PASS=0 ;; esac
[ "$GDEL" = "769" ] && [ "$MDEL" = "1537" ] || PASS=0
[ "$(( ${#ECHO_VAL} - ${#VFY} ))" -ge 2048 ] 2>/dev/null || PASS=0
curl -s --max-time 10 "$GATE/componentz" | grep -q '"tracegate"' || PASS=0
curl -s --max-time 10 "$MESH/componentz" | grep -q '"meshd"' || PASS=0

# ---------- ⑦ 阶段 1 交付：repro 复现脚本（可执行） ----------
say "⑦ 阶段1交付：repro/F1~F4.sh"
cat > "$OPS/repro/F1.sh" <<'EOS'
#!/bin/bash
# F1 复现：16384B 单自定义 header 打入口（修复前 400/431——完整行 16402B 超 16k 单缓冲）
curl -s -o /dev/null -w 'entry_big=%{http_code}\n' --max-time 10 \
  -H "X-Verify-Token: $(head -c 16384 /dev/zero | tr '\0' 'x')" http://127.0.0.1:80/api/v1/profile
EOS
cat > "$OPS/repro/F2.sh" <<'EOS'
#!/bin/bash
# F2 复现：直连后端（修复前 431——配额 8192 编译期固化）
curl -s -o /dev/null -w 'backend_big=%{http_code}\n' --max-time 10 \
  -H "X-Debug-Trace: $(head -c 16384 /dev/zero | tr '\0' 'x')" http://127.0.0.1:9000/api/v1/profile
curl -s --max-time 10 -H "X-Debug-Trace: $(head -c 16384 /dev/zero | tr '\0' 'x')" \
  http://127.0.0.1:9000/api/v1/profile | head -c 200; echo
EOS
cat > "$OPS/repro/F3.sh" <<'EOS'
#!/bin/bash
# F3 复现：注入链计数与规格偏差（修复前 span_bytes=384 → delta≠769）
N="vfy$(date +%s%N)"
curl -s -o /dev/null --max-time 10 -H "X-Trace-Context: $N" http://127.0.0.1:80/api/v1/profile
sleep 1
grep 'GATESTAT' /var/log/tracegate.log | grep 'verdict=PASS' | tail -n1
grep 'MESHSTAT' /var/log/meshd.log | grep 'verdict=PASS' | tail -n1
EOS
cat > "$OPS/repro/F4.sh" <<'EOS'
#!/bin/bash
# F4 复现：审计旁路容量信号（修复前 MESSAGE_TOO_LARGE / broker 限额 16384）
grep -c 'kafka produce failed' /var/log/backend.log 2>/dev/null || true
grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties
EOS
chmod 755 "$OPS/repro/"*.sh

# ---------- ⑧ 阶段 2 交付：证据采集（四面，原始数据） ----------
say "⑧ 阶段2交付：tools 采集四面证据"
bash "$TOOLS/collect_nginx.sh" >/dev/null 2>&1 || warn "F1 采集失败"
bash "$TOOLS/collect_backend.sh" >/dev/null 2>&1 || warn "F2 采集失败"
bash "$TOOLS/collect_trace.sh" >/dev/null 2>&1 || warn "F3 采集失败"
bash "$TOOLS/collect_kafka.sh" >/dev/null 2>&1 || warn "F4 采集失败"

# ---------- ⑨ 诊断报告（每面三行：根因/证据路径/前后数值） ----------
say "⑨ 诊断报告"
NG_AFTER="$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | sed -E 's/;.*//')"
cat > "$OPS/diagnosis_report.md" <<EOF
# 431 事件诊断报告（4 面 / 2 阶段）

容量参数（params.env）：LIM=${LIM}B，WARN_RATIO=${RATIO}%——nginx 配置与声明已与之一致。

## F1（nginx 入口）
- 根因：server 级 snippet 的 large_client_header_buffers 16k 对 16402B 完整 header 行不足，且与 http 级配置漂移
- 证据：evidence/F1_nginx_T.txt
- 修复前后数值对比：${NG_BEFORE:-4 16k} → ${NG_AFTER:-4 ${LIM}}（生效单缓冲 == params LIM=${LIM}B）
## F2（backend）
- 根因：业务配额 8192 经 go:embed 编译期固化进二进制，框架层 MaxHeaderBytes 1<<13 与退役存档同样残留 8192——改磁盘不重启/不重编译均不生效
- 证据：evidence/F2_backend_status.txt
- 修复前后数值对比：直连后端大探针 ${INIT_B:-431} → ${FINAL_B:-200}（配额 8192 → ${QUOTA_MAX}）
## F3（tracegate 注入链）
- 根因：max_header_bytes 10240 过小 + 带宽节省专项将 span_bytes 下调至 384，注入链增幅缩水
- 证据：evidence/F3_span_count.txt
- 修复前后数值对比：span_bytes ${SPAN_BEFORE:-384} → 768（gate 计数恢复恰 769 / mesh 恰 1537 / baggage 512；本轮实测 ${GDEL}/${MDEL}/${MBAG:-0}）
## F4（kafka 审计旁路）
- 根因：broker message.max.bytes ${KAF_BEFORE:-16384} 过小，全量头快照审计事件被 MESSAGE_TOO_LARGE 拒绝（异步容量信号，区别于同步 431）
- 证据：evidence/F4_kafka_audit.txt
- 修复前后数值对比：message.max.bytes ${KAF_BEFORE:-16384} → ${KAF_MAX}（动态生效 + 静态落盘防重启回退）
EOF

say "交付: repro/$(ls "$OPS/repro" | tr '\n' ' ') evidence/$(ls "$EV" | tr '\n' ' ')"
if [ "$PASS" = "1" ]; then
  say "结果: PASS —— 四面修复完成，两阶段交付齐备"
  exit 0
fi
warn "结果: FAIL —— 见上方自验输出"
exit 1
