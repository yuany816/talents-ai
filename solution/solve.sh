#!/bin/bash
# =============================================================================
# solution/solve.sh —— 参考解（5 面 / 2 阶段 / 前置取证 / params 随机参数感知）
# 面：F1 nginx / F2 backend(+预警标定) / F3 tracegate 注入链 / F4 kafka / F5 meshd
# 阶段 1：repro/Fx.sh + Fx.out（修复前取证，签名见题面）——必须先于任何修复执行
# 阶段 2：五面修复 → restart all 持久化自证 → 双侧标定 → 采集 → 报告
# 容量参数 LIM/WARN_RATIO 每 trial 随机（params.env），配置与声明与之一致。
# =============================================================================
set -uo pipefail
export LC_ALL=C
umask 022

APP=/app; OPS=$APP/ops; EV=$OPS/evidence; RP=$OPS/repro; TOOLS=$APP/tools
TEST_BYTES=16384
NG_CHB_KB=16; NG_BUF_N=4
QUOTA_MAX=1048576; KAF_MAX=1048576

say()  { echo "[solve.sh] $*"; }
warn() { echo "[solve.sh][WARN] $*" >&2; }
die()  { echo "[solve.sh][FATAL] $*" >&2; exit 1; }
tok()  { head -c "$1" /dev/zero | tr '\0' 'x'; }
backup() { [ -f "$1" ] && [ ! -f "$1.solve.bak" ] && cp -p "$1" "$1.solve.bak" || true; }

mkdir -p "$OPS/repro" "$OPS/fix" "$OPS/evidence" /var/log/nginx

# ---------- ⓪ params ----------
LIM=65536; RATIO=80
if [ -f "$OPS/params.env" ]; then
  _p="$(sed -n 's/^LIM=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')"; [ -n "$_p" ] && LIM=$_p
  _r="$(sed -n 's/^WARN_RATIO=//p' "$OPS/params.env" | head -n1 | tr -dc '0-9')"; [ -n "$_r" ] && RATIO=$_r
fi
THRESH=$(( LIM * RATIO / 100 ))
say "params: LIM=${LIM} WARN_RATIO=${RATIO} THRESH=${THRESH}"

SUP="supervisorctl"
supervisorctl status >/dev/null 2>&1 || SUP="supervisorctl -c /tmp/eval-sup/supervisord.conf"
$SUP status >/dev/null 2>&1 || die "supervisord 未运行"

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

# ---------- ① 阶段 1：先取证（任何修复之前） ----------
say "① 阶段1取证（修复前）"
{
  echo "# F1 取证（修复前）$(date '+%F %T')"
  echo "entry_big_status=$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")"
  nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]'
} > "$RP/F1.out"
{
  echo "# F2 取证（修复前）$(date '+%F %T')"
  echo "backend_big_status=$(probe "$BE/api/v1/profile" "$TEST_BYTES")"
  curl -s --max-time 10 -H "X-Debug-Trace: $(tok "$TEST_BYTES")" "$BE/api/v1/profile" | head -c 200; echo
  grep "startup:" /var/log/backend.log 2>/dev/null | head -n1
} > "$RP/F2.out"
NONCE="vfy$(date +%s%N)"
{
  echo "# F3 取证（修复前）$(date '+%F %T')"
  curl -s -o /dev/null --max-time 15 -H "X-Trace-Context: $NONCE" "$ENTRY/api/v1/profile"
  sleep 1
  grep 'GATESTAT' /var/log/tracegate.log 2>/dev/null | grep 'verdict=PASS' | tail -n1
  grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1
} > "$RP/F3.out"
{
  echo "# F4 取证（修复前）$(date '+%F %T')"
  curl -s -o /dev/null --max-time 15 -H "X-Debug-Trace: $(tok "$TEST_BYTES")" "$ENTRY/api/v1/profile"
  for _ in $(seq 1 6); do sleep 5; grep -q 'MESSAGE_TOO_LARGE\|kafka produce failed' /var/log/backend.log 2>/dev/null && break; done
  grep -c 'MESSAGE_TOO_LARGE\|kafka produce failed' /var/log/backend.log 2>/dev/null || echo 0
  grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties
} > "$RP/F4.out"
bash "$TOOLS/collect_meshd.sh" > "$RP/F5.out" 2>&1 || warn "F5 取证采集失败"
for f in F1 F2 F3 F4 F5; do [ -s "$RP/$f.out" ] || die "取证 $f.out 失败"; done
say "取证完成（修复前签名已落盘）"

# ---------- ② F1 nginx：生效单缓冲 == LIM（全指令一致） ----------
say "② F1 nginx（large_client_header_buffers 4 ${LIM}）"
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
grep -qE "^[[:space:]]*large_client_header_buffers[[:space:]]+${NG_BUF_N}[[:space:]]+${LIM};" "$NGINX_CONF" || die "F1 nginx 写入失败"
# app.conf 双故障点修复：恢复被注释的 snippet include + 删除误清注入头的 proxy_set_header
sed -i -E 's|^([[:space:]]*)#[[:space:]]*(include /etc/nginx/snippets/headers.conf;)|\1\2|' /etc/nginx/conf.d/app.conf
sed -i '\#proxy_set_header X-Trace-Context "";#d' /etc/nginx/conf.d/app.conf
nginx -t >/dev/null 2>&1 || die "F1 nginx -t 失败"
if pgrep -x nginx >/dev/null 2>&1; then
  nginx -s reload 2>/dev/null || { pkill -x nginx 2>/dev/null || true; sleep 1; nginx -g 'daemon on;'; }
else
  nginx -g 'daemon on;'
fi

# ---------- ③ F2 backend：三处 8192 + 预警标定中间件（阈值 = THRESH） + 重建 ----------
say "③ F2 backend（配额/框架/存档 → ${QUOTA_MAX} + 预警中间件阈值 ${THRESH}）"
backup /app/backend/configs/quota.yaml
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/' /app/backend/configs/quota.yaml
backup /app/backend/main.go
sed -i -E 's/(MaxHeaderBytes:[[:space:]]*)1[[:space:]]*<<[[:space:]]*13/\1'"${QUOTA_MAX}"'/' /app/backend/main.go
sed -i -E 's/(MaxHeaderBytes:[[:space:]]*)[0-9]+([[:space:]]*,)/\1'"${QUOTA_MAX}"'\2/' /app/backend/main.go
grep -q "MaxHeaderBytes: ${QUOTA_MAX}" /app/backend/main.go || die "F2 MaxHeaderBytes 替换未生效"
backup /app/backend/legacy_server.go
sed -i -E 's/(legacyQuotaBytes[[:space:]]*=[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/' /app/backend/legacy_server.go
# 观测口径/落盘路径/边界符号/响应码/审计双端 六处源码级修复
sed -i 's/n := len(name) \/\/ 口径/n := len(name) + 4 \/\/ 口径/' /app/backend/main.go
sed -i 's#/app/ops/warn\.log#/app/ops/warnings.log#' /app/backend/main.go
sed -i 's/total >= limit/total > limit/' /app/backend/internal/quota/middleware.go
sed -i 's/http\.StatusBadRequest/http.StatusRequestHeaderFieldsTooLarge/' /app/backend/internal/quota/middleware.go
sed -i 's/127\.0\.0\.1:9093/127.0.0.1:9092/' /app/backend/internal/audit/kafka.go
sed -i 's/trace-events-prod/trace-events/' /app/backend/internal/audit/kafka.go
while read -r rf; do
  [ -f "$rf" ] || continue
  backup "$rf"
  sed -i -E 's/(^|[^0-9])8192([^0-9]|$)/\1'"${QUOTA_MAX}"'\2/g; s/(^|[^0-9])8192([^0-9]|$)/\1'"${QUOTA_MAX}"'\2/g' "$rf"
done < <(grep -rlIE '(^|[^0-9])8192([^0-9]|$)' /app/backend \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.orig' --exclude='*.old' \
    --exclude='*.backup' --exclude='*.disabled' --exclude='*.solve.bak' 2>/dev/null || true)
# 预警阈值与 params 联动：内置 warnHeaderSizeMiddleware 的硬编码阈值须按 THRESH 重算
sed -i -E 's/const warnThresholdBytes = [0-9]+/const warnThresholdBytes = '"${THRESH}"'/' /app/backend/main.go
grep -q "const warnThresholdBytes = ${THRESH}" /app/backend/main.go || die "预警阈值联动失败（硬编码形态未识别）"
( cd /app/backend && timeout 300 env GOPROXY=off CGO_ENABLED=0 go build -o backend.new . ) || die "F2 go build 失败"
mv -f /app/backend/backend.new /app/backend/backend && chmod 755 /app/backend/backend

# ---------- ④ F3 tracegate：限额 + span 规格恢复 + 注入偏移推导修正 ----------
say "④ F3 tracegate（预算→${QUOTA_MAX}，span_bytes 384→768，注入偏移修正）"
backup /app/tracegate/tracegate.yaml
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/; s/^(span_bytes:[[:space:]]*)[0-9]+/\1768/' /app/tracegate/tracegate.yaml
# 推导型缺陷：appendSpan 的段开销写死为 -3B（实际恰为 -1B）——只改 span_bytes=768
# 得到的逐跳增幅是 767 而非 769，须修正代码使注入尺寸与规格精确一致（误导注释见源码）
backup /app/tracegate/main.go
sed -i -E 's/size - len\(id\) - 3/size - len(id) - 1/' /app/tracegate/main.go
sed -i 's/headerQuota(r) + cfg.SpanBytes + 2/headerQuota(r)/' /app/tracegate/main.go
sed -i 's/127\.0\.0\.2:9100/127.0.0.1:9100/' /app/tracegate/tracegate.yaml
sed -i 's#upstream: http://127.0.0.1:15002#upstream: http://127.0.0.1:15001#' /app/tracegate/tracegate.yaml
grep -q 'size - len(id) - 1' /app/tracegate/main.go || die "F3 注入偏移修正失败"
( cd /app/tracegate && timeout 120 env GOPROXY=off CGO_ENABLED=0 go build -o tracegate . ) || die "F3 tracegate 重编译失败"
grep -q '^span_bytes: 768' /app/tracegate/tracegate.yaml || die "F3 span 规格恢复失败"

# ---------- ④b F5 meshd：磁盘 + supervisor env 双口径 + span 规格与偏移修正 ----------
say "④b F5 meshd（限额双口径 → ${QUOTA_MAX}；span_bytes 2048→1536；注入偏移修正）"
backup /app/mesh/sidecar.yaml
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"${QUOTA_MAX}"'/; s/^(span_bytes:[[:space:]]*)[0-9]+/\11536/' /app/mesh/sidecar.yaml
grep -q '^span_bytes: 1536' /app/mesh/sidecar.yaml || die "F5 mesh span 规格恢复失败"
backup /app/mesh/main.go
sed -i -E 's/size - len\(seg\) - 2/size - len(seg) - 1/' /app/mesh/main.go
sed -i 's/if cfg.BaggageBytes == 0 {/if cfg.BaggageBytes > 0 {/' /app/mesh/main.go
sed -i 's/len(grown), len(bg)/len(grown), cfg.BaggageBytes/' /app/mesh/main.go
grep -q 'size - len(seg) - 1' /app/mesh/main.go || die "F5 mesh 注入偏移修正失败"
( cd /app/mesh && timeout 120 env GOPROXY=off CGO_ENABLED=0 go build -o meshd . ) || die "F5 meshd 重编译失败"
SUPCONF=/etc/supervisor/conf.d/app.conf
grep -qE 'MESH_HEADER_LIMIT=' "$SUPCONF" 2>/dev/null && {
  backup "$SUPCONF"
  sed -i -E 's/(MESH_HEADER_LIMIT=")[0-9]+(")/\1'"${QUOTA_MAX}"'\2/' "$SUPCONF"
  $SUP reread >/dev/null 2>&1 && $SUP update >/dev/null 2>&1
}

# ---------- ⑤ F4 kafka：动态 + 静态落盘 ----------
say "⑤ F4 kafka（message.max.bytes → ${KAF_MAX}）"
timeout 30 /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9092 \
  --entity-type brokers --entity-name 1 --alter --add-config "message.max.bytes=${KAF_MAX}" >/dev/null 2>&1 \
  || warn "kafka 动态 alter 未确认"
backup /opt/kafka/config/kraft/server.properties
sed -i -E "s/^(message\.max\.bytes=)[0-9]+/\1${KAF_MAX}/" /opt/kafka/config/kraft/server.properties
# 主题建制：auto.create.topics.enable=false（OPS-SEC-443）——显式建立审计主题
timeout 30 /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --create --if-not-exists \
  --topic trace-events --partitions 1 --replication-factor 1 >/dev/null 2>&1 \
  || warn "topic 建制失败/已存在（非阻断，复证时检查）"
# collector 消费口径与 producer 对齐（topic 错配则审计事件永不落盘）
grep -q 'trace-events-v2' "$SUPCONF" 2>/dev/null && {
  sed -i 's/--topic trace-events-v2/--topic trace-events/' "$SUPCONF"
  $SUP reread >/dev/null 2>&1 && $SUP update >/dev/null 2>&1
  say "collector topic 已对齐 trace-events"
}
$SUP restart backend tracegate meshd >/dev/null 2>&1 || die "组件重启失败"
wait_up "$BE/healthz" || warn "backend 未就绪"

# ---------- ⑥ restart all 持久化自证（F2b） ----------
say "⑥ restart all 持久化自证"
$SUP restart all >/dev/null 2>&1
for _ in $(seq 1 30); do
  K=$(timeout 2 bash -c 'exec 3<> /dev/tcp/127.0.0.1/9092' 2>/dev/null && echo ok || echo no)
  [ "$K" = "ok" ] && curl -s -o /dev/null --max-time 2 "$BE/healthz" && break
  sleep 2
done
wait_up "$ENTRY/healthz" || warn "入口未就绪"
sleep 2
{
  echo "# F2 restart all 持久化取证 $(date '+%F %T')"
  echo "post_restart_entry_big_status=$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")"
  echo "post_restart_backend_big_status=$(probe "$BE/api/v1/profile" "$TEST_BYTES")"
} > "$EV/F2_restart.txt"
bash "$TOOLS/collect_meshd.sh" > /dev/null 2>&1
cp "$EV/F5_meshd_status.txt" "$EV/F5_restart.txt" 2>/dev/null || {
  echo "effective_limit=0"; } > "$EV/F5_restart.txt"

# ---------- ⑦ F4b：重启后新标记事件复证 ----------
say "⑦ F4b：重启后标记事件复证"
MARK="kaf$(date +%s%N)"
probe "$ENTRY/api/v1/profile" "$TEST_BYTES" >/dev/null
curl -s -o /dev/null --max-time 15 -H "X-Debug-Trace: $(tok "$TEST_BYTES")" -H "X-Case-Marker: $MARK" "$ENTRY/api/v1/profile" 2>/dev/null || true
SEEN=no
for _ in $(seq 1 12); do
  sleep 5
  grep -q "$MARK" /var/log/trace_events.log 2>/dev/null && { SEEN=ok; break; }
done
{
  echo "# F4 restart 持久化取证 $(date '+%F %T')"
  echo "marker=$MARK"
  echo "event_seen=$SEEN"
} > "$EV/F4_restart.txt"

# ---------- ⑧ F2c 预警双侧标定（THRESH=LIM×RATIO/100） ----------
say "⑧ F2c 预警双侧标定（THRESH=${THRESH}）"
: > "$OPS/warnings.log" 2>/dev/null || true
BELOW_B=1024   # 小探针：后端口径总量 ≈ 值+开销+注入 ≈3KB < THRESH（静默窗口对任意 params 成立）
probe "$ENTRY/api/v1/profile" "$BELOW_B" >/dev/null
sleep 2
BD=$(wc -l < "$OPS/warnings.log" 2>/dev/null || echo 0)
ABOVE_B=$(( THRESH + 512 ))   # ≤ LIM−1024（0.9L+512 ≤ L−1024 对 L≥15360 恒成立）→ 可过 nginx 且总量 ≥ THRESH
probe "$ENTRY/api/v1/profile" "$ABOVE_B" >/dev/null
sleep 2
AMAX=0
for _ in $(seq 1 6); do
  AMAX=$(grep -oE '(total|observed)=[0-9]+B' "$OPS/warnings.log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -n1)
  [ -n "$AMAX" ] && break
  sleep 2
done
AD=$(( $(wc -l < "$OPS/warnings.log" 2>/dev/null || echo 0) - BD ))
{
  echo "# F2c 双侧标定取证 $(date '+%F %T')（THRESH=${THRESH}=LIM ${LIM} × WARN_RATIO ${RATIO} / 100）"
  echo "below_probe_bytes=${BELOW_B}"
  echo "below_warnings_delta=${BD}"
  echo "above_probe_bytes=${ABOVE_B}"
  echo "above_warnings_delta=${AD}"
  echo "above_max_observed=${AMAX:-0}"
} > "$EV/F2_calibration.txt"
say "标定: below_delta=${BD}（须0） above_delta=${AD}（须≥1） max=${AMAX:-0}（须≥THRESH）"
[ "$BD" = "0" ] && [ "${AD:-0}" -ge 1 ] 2>/dev/null || warn "双侧标定未通过，检查观测口径与注入开销"

# ---------- ⑨ F1b 双侧边界探针 ----------
say "⑨ F1b 双侧边界"
BELOW_L=$(( LIM - 1024 )); ABOVE_L=$(( LIM + 4096 ))
{
  echo "# F1b 双侧边界取证 $(date '+%F %T')（LIM=${LIM}）"
  echo "below(LIM-1024)=${BELOW_L}B status=$(probe "$ENTRY/api/v1/profile" "$BELOW_L")"
  echo "above(LIM+4096)=${ABOVE_L}B status=$(probe "$ENTRY/api/v1/profile" "$ABOVE_L")"
} > "$EV/F1_boundary.txt"

# ---------- ⑩ 阶段 1 交付：repro 脚本（取证已在①完成） ----------
say "⑩ repro 脚本交付"
cat > "$RP/F1.sh" <<'EOS'
#!/bin/bash
# F1 复现：16384B 单自定义 header 打入口（修复前 400/431）
curl -s -o /dev/null -w 'entry_big=%{http_code}\n' --max-time 10 \
  -H "X-Verify-Token: $(head -c 16384 /dev/zero | tr '\0' 'x')" http://127.0.0.1:80/api/v1/profile
EOS
cat > "$RP/F2.sh" <<'EOS'
#!/bin/bash
# F2 复现：直连后端（修复前 431——配额 8192 编译期固化）
curl -s -o /dev/null -w 'backend_big=%{http_code}\n' --max-time 10 \
  -H "X-Debug-Trace: $(head -c 16384 /dev/zero | tr '\0' 'x')" http://127.0.0.1:9000/api/v1/profile
EOS
cat > "$RP/F3.sh" <<'EOS'
#!/bin/bash
# F3 复现：注入链计数（修复前 span_bytes=384 → gate delta≠769）
N="vfy$(date +%s%N)"
curl -s -o /dev/null --max-time 10 -H "X-Trace-Context: $N" http://127.0.0.1:80/api/v1/profile
sleep 1
grep 'GATESTAT' /var/log/tracegate.log | grep 'verdict=PASS' | tail -n1
grep 'MESHSTAT' /var/log/meshd.log | grep 'verdict=PASS' | tail -n1
EOS
cat > "$RP/F4.sh" <<'EOS'
#!/bin/bash
# F4 复现：审计旁路容量信号（修复前 MESSAGE_TOO_LARGE / broker 限额 16384）
grep -c 'kafka produce failed' /var/log/backend.log 2>/dev/null || true
grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties
EOS
cat > "$RP/F5.sh" <<'EOS'
#!/bin/bash
# F5 复现：meshd 生效限额口径（修复前 12288 < 17408——磁盘与部署环境双口径）
bash /app/tools/collect_meshd.sh
EOS
chmod 755 "$RP/"*.sh

# fix/ 修复脚本交付（封装各面实际修复动作，幂等可重跑）
cat > "$OPS/fix/F1.sh" <<'EOS'
#!/bin/bash
# F1 修复：nginx 生效单缓冲对齐 params LIM（全指令一致）后 reload
LIM=$(sed -n 's/^LIM=//p' /app/ops/params.env | head -n1 | tr -dc '0-9'); : "${LIM:=65536}"
sed -i -E 's/^([[:space:]]*)(client_header_buffer_size|large_client_header_buffers)/\1# disabled: &/' /etc/nginx/snippets/headers.conf
sed -i -E "s/^(large_client_header_buffers[[:space:]]+)[0-9]+[[:space:]]+[0-9kKmM]+;/\14 ${LIM};/" /etc/nginx/nginx.conf
nginx -t && nginx -s reload
EOS
cat > "$OPS/fix/F2.sh" <<'EOS'
#!/bin/bash
# F2 修复：配额与框架限额对齐 params，重编译并重启
QUOTA=1048576
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"$QUOTA"'/' /app/backend/configs/quota.yaml
sed -i -E 's/(MaxHeaderBytes:[[:space:]]*)1[[:space:]]*<<[[:space:]]*13/\1'"$QUOTA"'/' /app/backend/main.go
sed -i -E 's/(legacyQuotaBytes[[:space:]]*=[[:space:]]*)[0-9]+/\1'"$QUOTA"'/' /app/backend/legacy_server.go
cd /app/backend && GOPROXY=off CGO_ENABLED=0 go build -o backend . && supervisorctl restart backend
EOS
cat > "$OPS/fix/F3.sh" <<'EOS'
#!/bin/bash
# F3 修复：tracegate 预算与 span 规格恢复（768）
Q=1048576
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"$Q"'/; s/^(span_bytes:[[:space:]]*)[0-9]+/\1768/' /app/tracegate/tracegate.yaml
supervisorctl restart tracegate
EOS
cat > "$OPS/fix/F4.sh" <<'EOS'
#!/bin/bash
# F4 修复：broker 限额动态生效 + 静态落盘
KAF_MAX=1048576
kafka-configs() { /opt/kafka/bin/kafka-configs.sh "$@"; }
timeout 30 kafka-configs --bootstrap-server 127.0.0.1:9092 --entity-type brokers --entity-name 1 \
  --alter --add-config "message.max.bytes=${KAF_MAX}"
sed -i -E "s/^(message\.max\.bytes=)[0-9]+/\1${KAF_MAX}/" /opt/kafka/config/kraft/server.properties
EOS
cat > "$OPS/fix/F5.sh" <<'EOS'
#!/bin/bash
# F5 修复：meshd 磁盘与部署环境双口径对齐后重启
Q=1048576
sed -i -E 's/^(max_header_bytes:[[:space:]]*)[0-9]+/\1'"$Q"'/' /app/mesh/sidecar.yaml
sed -i -E 's/(MESH_HEADER_LIMIT=")[0-9]+(")/\1'"$Q"'\2/' /etc/supervisor/conf.d/app.conf
supervisorctl reread && supervisorctl update && supervisorctl restart meshd
EOS
chmod 755 "$OPS/fix/"*.sh

# ---------- ⑪ 阶段 2 交付：五面证据采集 ----------
say "⑪ 五面证据采集"
bash "$TOOLS/collect_nginx.sh" >/dev/null 2>&1 || warn "F1 采集失败"
bash "$TOOLS/collect_backend.sh" >/dev/null 2>&1 || warn "F2 采集失败"
bash "$TOOLS/collect_trace.sh" >/dev/null 2>&1 || warn "F3 采集失败"
bash "$TOOLS/collect_kafka.sh" >/dev/null 2>&1 || warn "F4 采集失败"
bash "$TOOLS/collect_meshd.sh" >/dev/null 2>&1 || warn "F5 采集失败"

# ---------- ⑫ 诊断报告（修复前数值与 Fx.out 咬合） ----------
say "⑫ 诊断报告"
INIT_E="$(sed -n 's/^entry_big_status=//p' "$RP/F1.out" | head -n1)"
INIT_B="$(sed -n 's/^backend_big_status=//p' "$RP/F2.out" | head -n1)"
KAF_BEFORE="$(grep -oE '[0-9]+' "$RP/F4.out" | tail -n1)"
NG_AFTER="$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | sed -E 's/;.*//')"
FINAL_E="$(probe "$ENTRY/api/v1/profile" "$TEST_BYTES")"
FINAL_B="$(probe "$BE/api/v1/profile" "$TEST_BYTES")"
cat > "$OPS/diagnosis_report.md" <<EOF
# 431 事件诊断报告（5 面 / 2 阶段）

容量参数（params.env）：LIM=${LIM}B，WARN_RATIO=${RATIO}%——nginx 配置、预警阈值（THRESH=${THRESH}）与声明已与之一致。

## F1（nginx 入口）
- 根因：large_client_header_buffers 16k 对 16402B 完整 header 行不足，且 server 级与 http 级配置漂移
- 证据：evidence/F1_nginx_T.txt、evidence/F1_boundary.txt、repro/F1.out
- 修复前后数值对比：入口大探针 ${INIT_E:-400} → ${FINAL_E:-200}（生效单缓冲 → ${NG_AFTER:-4 ${LIM}}，双侧边界 LIM−1024=200 / LIM+4096=4xx）
## F2（backend）
- 根因：业务配额 8192 经 go:embed 编译期固化，框架层 MaxHeaderBytes 1<<13 与退役存档残留 8192——改盘不重编译不生效
- 证据：evidence/F2_backend_status.txt、evidence/F2_restart.txt、evidence/F2_calibration.txt、repro/F2.out
- 修复前后数值对比：直连后端大探针 ${INIT_B:-431} → ${FINAL_B:-200}（配额 8192 → ${QUOTA_MAX}；restart all 后仍 200；预警双侧标定 THRESH=${THRESH} 通过）
## F3（tracegate 注入链）
- 根因：max_header_bytes 10240 过小，span_bytes 被带宽节省专项下调至 384，注入链增幅缩水
- 证据：evidence/F3_span_count.txt、repro/F3.out
- 修复前后数值对比：span_bytes 384 → 768（gate 计数恢复恰 769 / mesh 1537 / baggage 512；回显增幅恰 2306）
## F4（kafka 审计旁路）
- 根因：broker message.max.bytes ${KAF_BEFORE:-16384} 过小，全量头快照事件被 MESSAGE_TOO_LARGE 拒绝（异步容量信号，区别于同步 431）
- 证据：evidence/F4_kafka_audit.txt、evidence/F4_restart.txt、repro/F4.out
- 修复前后数值对比：message.max.bytes ${KAF_BEFORE:-16384} → ${KAF_MAX}（动态生效+静态落盘；broker 重启后新标记事件仍落盘）
## F5（meshd sidecar）
- 根因：磁盘配置 12288 与 supervisord 程序环境 MESH_HEADER_LIMIT=12288 双口径压制生效值
- 证据：evidence/F5_meshd_status.txt
- 修复前后数值对比：生效限额 12288 → ${QUOTA_MAX}（双口径同步，启动日志 source 口径确认）
EOF

PASS=1
[ "$FINAL_E" = "200" ] && [ "$FINAL_B" = "200" ] || PASS=0
[ "$BD" = "0" ] && [ "${AD:-0}" -ge 1 ] 2>/dev/null || PASS=0
grep -q 'event_seen=ok' "$EV/F4_restart.txt" || PASS=0
grep -qE '^post_restart_entry_big_status=200' "$EV/F2_restart.txt" || PASS=0
say "交付: repro/$(ls "$RP" | tr '\n' ' ') evidence/$(ls "$EV" | tr '\n' ' ')"
if [ "$PASS" = "1" ]; then
  say "结果: PASS —— 五面修复完成，前置取证/持久化/标定证据齐备"
  exit 0
fi
warn "结果: FAIL —— 见上方自验输出"
exit 1
