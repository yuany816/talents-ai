#!/bin/bash
# =============================================================================
# /app/collect_evidence.sh —— 独立判分证据自动采集（作答环境内置）
#
# 按作答环境实际状态探测并生成 /app/ops/evidence/ 六个证据文件（题面"验题契约"
# 的逐文件 schema）。运行后请核对输出取值与实际配置一致；观测路径不同的部分
# 可手工修正——判分只按 schema 读取。幂等：每轮覆盖重写。
#
# 依赖：bash/curl/nginx -T（作答环境镜像自带）；需 root（读 nginx 配置与组件日志）。
# =============================================================================
export LC_ALL=C
set -u

OPS=/app/ops; EV=$OPS/evidence
ENTRY=http://127.0.0.1:80            # 判分契约口径：入口反代 :80 / 后端 :9000
BE=http://127.0.0.1:9000
TG=http://127.0.0.1:9100; MS=http://127.0.0.1:15001
H=/tmp/.ce_hdr
mkdir -p "$EV" 2>/dev/null || true

say() { echo "[collect] $*"; }

# 大探针经完整头行文件投递（含字段名与结尾换行——curl 会静默丢弃无冒号的 -H 行），
# 并规避内核单参数 ~128KB 上限
status() {  # $1=url $2=header_value_bytes（0/空=不带超长头）
  local url="$1" n="$2"
  if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
    printf 'X-Verify-Token: %s\n' "$(head -c "$n" /dev/zero | tr '\0' 'x')" > "$H"
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "@$H" "$url"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url"
  fi
}

# ---------- LIM 取值：header_limits.env 声明优先，回退 nginx -T 生效单缓冲 ----------
LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$OPS/header_limits.env" 2>/dev/null | head -n1 | tr -dc '0-9')
if [ -z "$LIM" ]; then
  LIM=$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 \
        | awk '{gsub(/;/,""); print $3}' \
        | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
fi
[ -n "$LIM" ] || { say "WARN: LIM 不可得（header_limits.env 未填且 nginx -T 失败），按 65536 兜底"; LIM=65536; }
say "declared LIM=${LIM}B"

# ---------- ① nginx_T.txt ----------
nginx -T > "$EV/nginx_T.txt" 2>&1 || say "WARN: nginx -T 失败，证据可能不完整"

# ---------- ② curl_entry.txt / curl_backend.txt ----------
ev_srv="$(curl -s -D - -o /dev/null --max-time 15 "$ENTRY/api/v1/profile" \
  | grep -i '^server:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
ev_body="$(curl -s --max-time 15 "$ENTRY/api/v1/profile" | head -n1)"
status "$ENTRY/healthz" 16384 >/dev/null   # 预热头文件
ev_hbody="$(curl -s --max-time 15 -H "@$H" "$ENTRY/healthz" | tr -d '[:space:]')"
ev_be_body="$(curl -s --max-time 15 -H "@$H" "$BE/api/v1/profile" | head -n1)"
cat > "$EV/curl_entry.txt" <<EOF
entry_big_status=$(status "$ENTRY/api/v1/profile" 16384)
entry_norm_status=$(status "$ENTRY/api/v1/profile" 0)
healthz_big_status=$(status "$ENTRY/healthz" 16384)
server_header=${ev_srv}
profile_body=${ev_body}
healthz_body=${ev_hbody}
EOF
cat > "$EV/curl_backend.txt" <<EOF
backend_big_status=$(status "$BE/api/v1/profile" 16384)
profile_body=${ev_be_body}
EOF

# ---------- ③ upper_boundary.txt：双侧边界探针 ----------
BELOW=$(( LIM - 1024 )); [ "$BELOW" -lt 16384 ] && BELOW=16384
ABOVE=$(( LIM + 4096 ))
cat > "$EV/upper_boundary.txt" <<EOF
declared_lim=${LIM}
below_probe_bytes=${BELOW}
below_status=$(status "$ENTRY/api/v1/profile" "$BELOW")
above_probe_bytes=${ABOVE}
above_status=$(status "$ENTRY/api/v1/profile" "$ABOVE")
EOF

# ---------- ④ span_count.txt：一次性 nonce 注入链 + 逐层精确计数 ----------
NONCE="vfy$(date +%s%N)"
ECHO_VAL="$(curl -s -D - -o /dev/null --max-time 15 -H "X-Trace-Context: $NONCE" "$ENTRY/api/v1/profile" 2>/dev/null \
  | grep -i '^x-trace-context:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
GL="$(grep 'GATESTAT' /var/log/tracegate.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
ML="$(grep 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
read -r GI GO <<< "$(printf '%s' "$GL" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B.*/\1 \2/p')"
read -r MI MO MBAG <<< "$(printf '%s' "$ML" | sed -nE 's/.*trace_in=([0-9]+)B trace_out=([0-9]+)B baggage=([0-9]+)B.*/\1 \2 \3/p')"
cat > "$EV/span_count.txt" <<EOF
nonce=${NONCE}
echo=${ECHO_VAL}
gate_trace_delta=$(( ${GO:-0} - ${GI:-0} ))
mesh_trace_delta=$(( ${MO:-0} - ${MI:-0} ))
baggage_bytes=${MBAG:-0}
EOF

# ---------- ⑤ kafka_audit.txt：探活 + 指纹 + 限额 + 审计事件标记自证 ----------
KTCP=0
for _ in 1 2 3; do
  if timeout 3 bash -c 'exec 3<> /dev/tcp/127.0.0.1/9092' 2>/dev/null; then KTCP=1; break; fi
  sleep 2
done
MARK="kaf$(date +%s%N)"
status "$ENTRY/api/v1/profile" 16384 >/dev/null
curl -s -o /dev/null --max-time 15 -H "@$H" -H "X-Case-Marker: $MARK" "$ENTRY/api/v1/profile" 2>/dev/null || true
AUDIT=missing
for _ in $(seq 1 9); do
  sleep 5
  if grep -q "$MARK" /var/log/trace_events.log 2>/dev/null; then AUDIT=ok; break; fi
done
KAF_STATIC="$(grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties 2>/dev/null | head -n1 | cut -d= -f2 | tr -dc '0-9')"
KAF_DYN="$(timeout 20 /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9092 \
  --entity-type brokers --entity-name 1 --describe 2>/dev/null \
  | grep -oE 'message\.max\.bytes=[0-9]+' | head -n1 | cut -d= -f2)"
cat > "$EV/kafka_audit.txt" <<EOF
kafka_tcp=$([ "$KTCP" = "1" ] && echo ok || echo fail)
tracegate_componentz=$(curl -s --max-time 5 "$TG/componentz" 2>/dev/null)
meshd_componentz=$(curl -s --max-time 5 "$MS/componentz" 2>/dev/null)
kafka_message_max_bytes=${KAF_DYN:-${KAF_STATIC:-0}}
kafka_message_max_bytes_static=${KAF_STATIC:-0}
audit_event_marker=${MARK}
audit_event_recorded=${AUDIT}
EOF

# ---------- 结果摘要（请逐项核对与实际配置一致） ----------
say "生成完成：$(ls "$EV" | tr '\n' ' ')"
grep -H . "$EV/upper_boundary.txt" "$EV/span_count.txt" "$EV/kafka_audit.txt" 2>/dev/null | sed 's/^/[collect] /'
say "请核对以上取值与你的实际配置一致（如观测实现路径不同，手工修正对应文件）。"
exit 0
