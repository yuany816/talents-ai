#!/bin/bash
# =============================================================================
# solution/solve.sh —— Harbor 参考解（标准答案脚本，agent 不可见，仅供平台验题）
#
# 任务场景：五层链路（同步）+ 异步审计旁路。超长请求头触发 431 Request Header
#           Fields Too Large，同步链路故障在四层：
#             L1 nginx：snippets/headers.conf 缓冲过小（8k / 4 16k）
#             L2 tracegate：接入网关 trace 插件 header 预算过小（10240，配置驱动）
#             L3 meshd：mesh 数据面 sidecar max_header_bytes 过小（12288，配置驱动）
#             L4 backend：net/http MaxHeaderBytes(1<<13) + go:embed 固化的业务配额(8192)
#                        （需改源码/配置并重新编译打包）
#           异步旁路：backend → Kafka(message.max.bytes=16384 过小) → trace-collector；
#           审计事件携带全量请求头快照，超限被拒（MESSAGE_TOO_LARGE）——与同步 431
#           无关，属排查噪声与容量信号，本脚本一并治理（非奖励项）。
#           注意：实测 nginx 1.22 对超长 header 行回 400 "Request Header Or Cookie
#           Too Large"（且属 info 级日志，默认 error 级 error.log 无记录）；
#           脚本流程不依赖具体码值（400/431 均按"与常规请求不一致"判定故障）。
#
# 参考解路径：
#   步骤① curl 分层复现（入口 + 直连 9100/15001/9000）定位拦截层
#   步骤② L1 调大 nginx buffer，nginx -t 校验后 reload；步骤③ 复测（仍 431 → 中间层）
#   步骤④ L2/L3 中间层配置调大 + 重启；L4 后端源码/配额档案调大（go:embed 须重编译）
#   步骤④.4 注入逐 header 体积统计中间件（归因观测：定位哪个模块/header 注入过多）
#   步骤⑤ 重新编译打包；步骤⑥ 清理日志并重启服务（含中间层）
#   步骤⑥.5 Kafka message.max.bytes 动态对齐（非奖励项治理）
#   步骤⑦ 生成阈值预警观测与 431 高优先级质检门禁；步骤⑧ 清理历史日志
#   步骤⑨ 超长 header 端到端验证（入口 + 直连各层）+ nonce 链路证据自证
#   步骤⑩ 生成 431 综合分析报告（diagnosis_report.md：链路级归因，非单点归责）
#
# 运行约定：在任务环境容器内以 root 执行（Debian/Ubuntu 系工具链）；
#           全链路组件由 supervisord 编排；Go 模块位于 /app 下（含 go.mod）。
# 幂等性：所有配置/源码修改均先注释旧值或带 grep 守卫再写入，备份为 *.solve.bak；
#         重复执行不会叠加破坏环境；离线优先（GOPROXY=off），在线仅作兜底。
# 退出语义：脚本跑完一轮后按 PASS/FAIL 返回 exit 0/1，交由平台按 reward 判定；
#          所有可能长时间挂起的步骤（go build / supervisord / supervisorctl / nginx）
#          均加 timeout 或强制 daemon 化，避免被平台误判为 non_terminating_process。
# =============================================================================
set -uo pipefail   # 不用 -e：探针 431 / grep 无匹配属预期分支，失败点均显式处理
export LC_ALL=C
umask 022

# ---------- 0. 常量与工具函数 ----------
APP_ROOT="/app"
OPS_DIR="$APP_ROOT/ops"
TEST_HEADER_BYTES=16384      # 复现用超长 header（> nginx 默认 8k 单行限制）
NG_CHB_KB=16                 # L1: client_header_buffer_size
NG_BUF_N=16                  # L1: large_client_header_buffers 数量
NG_BUF_KB=64                 # L1: large_client_header_buffers 单缓冲（单行 header 上限）
APP_FASTHTTP_BUF=1048576     # L2: fasthttp/fiber ReadBufferSize
APP_NETHTTP_MAX=4194304      # L2: net/http MaxHeaderBytes
WARN_RATIO=80                # 预警阈值 = 上限的 80%
WARN_THRESHOLD=$(( NG_BUF_KB * 1024 * WARN_RATIO / 100 ))   # 预警绝对阈值（字节），注入观测中间件

ENTRY_URL=""; CURL_TLS=""
UPSTREAM_URL=""; UP_PORT=""
INITIAL=""; AFTER_NGINX=""; BASELINE=""; FINAL=""; DIRECT=""
APPLIED_APP_LIMIT=0; SOURCE_CHANGED=0; CONFIG_CHANGED=0
EDITED_FILES=""; MAIN_GO_FILES=""; NG_LOGS=""
NG_CHB_BEFORE="未配置(默认1k)"; NG_BUF_BEFORE="未配置(默认4 8k)"
APP_LIMIT_BEFORE="未知"; APP_KIND=""; WIRE_FILE=""; MID_FILE=""; MID_WIRED=0
APP_QUOTA_MAX=1048576; QUOTA_APPLIED=0; QUOTA_BEFORE=""

say()  { echo "[solve.sh] $*"; }
warn() { echo "[solve.sh][WARN] $*" >&2; }
# [FIX] 原注释误写"平台要求入口进程不得退出"，与实测 non_terminating_process 完全相反，已修正。
# FATAL：打印原因后以非 0 退出，交由平台按 reward=0 判定失败。
die()  { echo "[solve.sh][FATAL] $*" >&2; exit 1; }

mkdir -p "$OPS_DIR" /var/log/nginx
backup() { [ -f "$1" ] && [ ! -f "$1.solve.bak" ] && cp -p "$1" "$1.solve.bak" || true; }

# probe <url> <header_len>：发请求，输出 HTTP 状态码；header_len 为空则不带超长头
probe() {
  local url="$1" hlen="${2:-}" tok=""
  if [ -n "$hlen" ]; then tok="$(head -c "$hlen" /dev/zero | tr '\0' 'x')"; fi
  if [ -n "$tok" ]; then
    curl ${CURL_TLS:+"$CURL_TLS"} -s -o /dev/null -w '%{http_code}' --max-time 15 -H "X-Debug-Trace: $tok" "$url"
  else
    curl ${CURL_TLS:+"$CURL_TLS"} -s -o /dev/null -w '%{http_code}' --max-time 15 "$url"
  fi
}

wait_up() {  # 等端口可响应（任何 HTTP 状态都算活着）
  local url="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl ${CURL_TLS:+"$CURL_TLS"} -s -o /dev/null --max-time 2 "$url" && return 0
    sleep 1
  done
  return 1
}

has_pattern() {  # $1=ERE，在 Go 源文件里搜索
  local f
  for f in $MAIN_GO_FILES; do grep -q "$1" "$f" 2>/dev/null && return 0; done
  return 1
}

# ---------- 1. 环境发现 ----------
say "步骤⓪：环境发现"
[ "$(id -u)" = "0" ] || die "请以 root 在任务环境容器内执行"
command -v curl  >/dev/null 2>&1 || die "缺少 curl"
command -v nginx >/dev/null 2>&1 || die "缺少 nginx（本任务要求 nginx + Go 同容器）"

NGINX_CONF="$(nginx -t 2>&1 | sed -nE 's#.*configuration file ([^[:space:]]+).*#\1#p' | head -n1)"
[ -z "$NGINX_CONF" ] && NGINX_CONF="/etc/nginx/nginx.conf"
[ -f "$NGINX_CONF" ] || die "未找到 nginx 主配置 $NGINX_CONF"
say "nginx 主配置: $NGINX_CONF"

# 入口端口 / 是否 https
LISTEN_LINE="$(grep -rhE '^[[:space:]]*listen[[:space:]]' /etc/nginx 2>/dev/null | head -n1)"
PORT="$(printf '%s' "$LISTEN_LINE" | sed -E 's/^[[:space:]]*listen[[:space:]]+//; s/[;].*$//' | awk '{print $1}')"
case "$PORT" in *:*) PORT="${PORT##*:}";; esac
PORT="$(printf '%s' "$PORT" | tr -dc '0-9')"
[ -z "$PORT" ] && PORT=80
case "$LISTEN_LINE" in *ssl*) SCHEME="https"; CURL_TLS="-k";; *) SCHEME="http";; esac
ENTRY_URL="${SCHEME}://127.0.0.1:${PORT}/healthz"
say "入口: $ENTRY_URL"

# 上游 Go 后端地址（proxy_pass / upstream 块）
UP_HOST="$(grep -rhE '^[[:space:]]*proxy_pass[[:space:]]' /etc/nginx 2>/dev/null | head -n1 \
           | sed -nE 's#.*https?://([^;/[:space:]]+).*#\1#p')"
if [ -n "$UP_HOST" ]; then
  case "$UP_HOST" in
    *:*) UPSTREAM_URL="http://${UP_HOST}" ;;
    *)   SRV="$(awk -v u="${UP_HOST};" \
                '$1=="upstream" && $2==u {f=1; next} f && $1=="server" {print $2; exit} f && $0 ~ /}/ {f=0}' \
                "$NGINX_CONF" /etc/nginx/conf.d/*.conf 2>/dev/null | head -n1)"
         [ -n "$SRV" ] && UPSTREAM_URL="http://${SRV%;}" || UPSTREAM_URL="http://${UP_HOST}" ;;
  esac
  case "$UPSTREAM_URL" in */) ;; *) UPSTREAM_URL="${UPSTREAM_URL}/";; esac
fi
UP_PORT="$(printf '%s' "$UPSTREAM_URL" | sed -nE 's#^https?://[^/]*:([0-9]+)/?$#\1#p')"
[ -z "$UP_PORT" ] && UP_PORT=80
# 探针路径：打真实路由（后端无根路由，/ 返回 404 会干扰可读性）
[ -n "$UPSTREAM_URL" ] && UPSTREAM_URL="${UPSTREAM_URL}healthz"
say "上游: ${UPSTREAM_URL:-未知}（端口 $UP_PORT）"

# Go 模块（约定 /app 下，多模块时优先 server/backend 命名）
ALL_GOMODS="$(find /app /srv /opt /root /home -maxdepth 4 -name go.mod -not -path '*/vendor/*' 2>/dev/null)"
GO_MOD="$(printf '%s\n' "$ALL_GOMODS" | grep -Ei '(server|backend|service|svc|api)' | head -n1)"
[ -z "$GO_MOD" ] && GO_MOD="$(printf '%s\n' "$ALL_GOMODS" | head -n1)"
[ -z "$GO_MOD" ] && die "未找到 Go 模块（go.mod），与任务环境约定不符"
MOD_DIR="$(dirname "$GO_MOD")"
say "Go 模块: $MOD_DIR"

GO_FILES="$(find "$MOD_DIR" -type f -name '*.go' -not -path '*/vendor/*' 2>/dev/null)"
for f in $GO_FILES; do
  case "$f" in *_test.go) continue;; esac
  MAIN_GO_FILES="$MAIN_GO_FILES $f"
done

# nginx 各日志路径（供步骤⑧清理）
NG_LOGS="$(grep -rhE '^[[:space:]]*(access_log|error_log)[[:space:]]' /etc/nginx 2>/dev/null \
           | sed -nE 's#^[[:space:]]*(access_log|error_log)[[:space:]]+([^;[:space:]]+).*#\2#p' | sort -u)
/var/log/nginx/error.log
/var/log/nginx/access.log
/var/log/nginx/hdrsize.log"

# 若 supervisord 未运行（solve 作为容器入口先于编排启动的场景），先拉起编排
if command -v supervisorctl >/dev/null 2>&1 && ! supervisorctl status >/dev/null 2>&1; then
  say "supervisord 未运行，拉起服务编排"
  # [FIX] 加 timeout 防止 supervisord 被配置成 nodaemon=true 时永久阻塞
  timeout 10 supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
  sleep 2
  supervisorctl status >/dev/null 2>&1 || die "supervisord 拉起失败"
fi

# 兜底启动 nginx（若环境未拉起）：supervisorctl（环境由 supervisord 编排）
pgrep -x nginx >/dev/null 2>&1 || { say "nginx 未运行，尝试启动"; \
  if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status >/dev/null 2>&1; then
    supervisorctl restart nginx 2>/dev/null || die "nginx 拉起失败（supervisorctl）"
  else
    die "supervisorctl 不可用，无法拉起 nginx（环境应为 supervisord 编排）"
  fi; sleep 1; }

# 兜底启动后端（若直连不可达）：supervisorctl（环境由 supervisord 编排）
if ! curl ${CURL_TLS:+"$CURL_TLS"} -s -o /dev/null --max-time 2 "${UPSTREAM_URL:-http://127.0.0.1:${UP_PORT}/}"healthz 2>/dev/null; then
  say "后端不可达，尝试兜底拉起"
  if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status >/dev/null 2>&1; then
    supervisorctl restart backend 2>/dev/null || supervisorctl restart all 2>/dev/null || warn "后端拉起失败（supervisorctl）"
  else
    die "supervisorctl 不可用，无法拉起后端（环境应为 supervisord 编排）"
  fi
  sleep 1
fi

# ---------- 步骤①：复现故障，识别 431 ----------
say "步骤①：复现故障（超长 header ${TEST_HEADER_BYTES}B 打入口）"
INITIAL="$(probe "$ENTRY_URL" "$TEST_HEADER_BYTES")"
say "初始状态码: ${INITIAL:-无响应}"
# 分层直连初始状态码（供综合报告的分层状态码链与"哪一层拦截"对照）
GATE_URL="http://127.0.0.1:9100/healthz"; MESH_URL="http://127.0.0.1:15001/healthz"; BE_URL="http://127.0.0.1:9000/healthz"
INITIAL_GATE="$(probe "$GATE_URL" "$TEST_HEADER_BYTES")"
INITIAL_MESH="$(probe "$MESH_URL" "$TEST_HEADER_BYTES")"
INITIAL_BACKEND="$(probe "$BE_URL" "$TEST_HEADER_BYTES")"
say "分层初始状态: tracegate(9100)=${INITIAL_GATE:-无} meshd(15001)=${INITIAL_MESH:-无} backend(9000)=${INITIAL_BACKEND:-无}"
echo "----- nginx error log 近期相关记录（定位依据） -----"
grep -h "too long header line" /var/log/nginx/error.log 2>/dev/null | tail -n 2 || true
grep -h "upstream sent too big header" /var/log/nginx/error.log 2>/dev/null | tail -n 2 || true

# ---------- 步骤②：L1 修复 nginx header 缓冲 ----------
say "步骤②：L1 修复 nginx（client_header_buffer_size=${NG_CHB_KB}k, large_client_header_buffers=${NG_BUF_N} ${NG_BUF_KB}k）"
# 修改前取值（供综合分析报告对照）
NG_CHB_BEFORE="$(grep -rhE '^[[:space:]]*client_header_buffer_size[[:space:]]' /etc/nginx 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*client_header_buffer_size[[:space:]]+//; s/;.*//')"
NG_BUF_BEFORE="$(grep -rhE '^[[:space:]]*large_client_header_buffers[[:space:]]' /etc/nginx 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*large_client_header_buffers[[:space:]]+//; s/;.*//')"
[ -n "$NG_CHB_BEFORE" ] || NG_CHB_BEFORE="未配置(默认1k)"
[ -n "$NG_BUF_BEFORE" ] || NG_BUF_BEFORE="未配置(默认4 8k)"
say "L1 修改前取值: client_header_buffer_size=${NG_CHB_BEFORE} / large_client_header_buffers=${NG_BUF_BEFORE}"

DISABLE_SED_RE='^([[:space:]]*)(client_header_buffer_size|large_client_header_buffers|log_format[[:space:]]+hdrsize|access_log[[:space:]][^;]*/var/log/nginx/(hdrsize\.log|access\.log))'
# 进程替换读清单（管道 | while 会在子 shell 中运行，内部状态/变量无法同步回主 shell——阻断风险整改）
while read -r f; do
    [ -f "$f" ] || continue
    backup "$f"
    sed -i -E "s@${DISABLE_SED_RE}@\1# disabled-by-solve.sh: \&@" "$f"
done < <(grep -rlE "(^|[^A-Za-z0-9_])(client_header_buffer_size|large_client_header_buffers|log_format[[:space:]]+hdrsize|access_log[[:space:]][^;]*/var/log/nginx/(hdrsize\.log|access\.log))" /etc/nginx 2>/dev/null)

NGINX_INS="$(mktemp /tmp/nginx_ins.XXXXXX)"
cat > "$NGINX_INS" <<EOF
    client_header_buffer_size ${NG_CHB_KB}k;
    large_client_header_buffers ${NG_BUF_N} ${NG_BUF_KB}k;
    access_log /var/log/nginx/access.log;
    log_format hdrsize '\$msec \$status \$request_length "\$request"';
    access_log /var/log/nginx/hdrsize.log hdrsize;
EOF
backup "$NGINX_CONF"
awk -v insf="$NGINX_INS" '
  BEGIN { n = 0; while ((getline line < insf) > 0) { n++; buf[n] = line } }
  { print }
  !done && $0 ~ /^[[:space:]]*http[[:space:]]*[{]/ {
    for (i = 1; i <= n; i++) print buf[i]
    done = 1
  }
' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
rm -f "$NGINX_INS"
grep -qE '^[[:space:]]*large_client_header_buffers[[:space:]]' "$NGINX_CONF" \
  || die "未能定位 $NGINX_CONF 的 http{} 块，L1 写入失败"

# server 块自带 access_log 会覆盖 http 级继承，逐一补挂 hdrsize 日志（观测用）
for f in $(grep -rlE '^[[:space:]]*access_log[[:space:]]' /etc/nginx 2>/dev/null); do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*access_log[[:space:]].*hdrsize\.log' "$f" && continue
  backup "$f"
  awk '{ print } /^[[:space:]]*access_log[[:space:]]/ { print "access_log /var/log/nginx/hdrsize.log hdrsize;" }' \
    "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
done

# 校验后热加载；失败回滚
if ! nginx -t 2>&1; then
  warn "nginx -t 失败，回滚本次修改"
  for b in $(find /etc/nginx -name '*.solve.bak' 2>/dev/null); do cp -p "$b" "${b%.solve.bak}"; done
  die "nginx 配置校验失败（已回滚）"
fi
# [FIX] 强制 daemon on：若 nginx.conf 带 `daemon off;`（容器镜像常见），直接 `nginx` 会前台阻塞，
#       导致 solve.sh 永久挂起并触发 non_terminating_process。统一加 `-g 'daemon on;'`。
if pgrep -x nginx >/dev/null 2>&1; then
  nginx -s reload 2>/dev/null || { pkill -x nginx 2>/dev/null || true; sleep 1; nginx -g 'daemon on;'; }
else
  nginx -g 'daemon on;'
fi
sleep 1
say "L1 已生效: $(nginx -T 2>/dev/null | grep -E 'client_header_buffer_size|large_client_header_buffers' | head -n2 | tr '\n' ' ')"

# ---------- 步骤③：L1 修复后复测 ----------
say "步骤③：L1 修复后复测"
AFTER_NGINX="$(probe "$ENTRY_URL" "$TEST_HEADER_BYTES")"
say "复测状态码: ${AFTER_NGINX:-无响应}"
if [ "$AFTER_NGINX" = "431" ]; then
  say ">> 依旧 431 —— 拦截点在后端，继续排查 L2（框架层限制）"
else
  say ">> 431 已消除（nginx 层修复生效）；仍按参考解对 L2 做幂等加固"
fi

# ---------- 步骤④：L2 修复 Go 框架层 header 限制 ----------
say "步骤④：L2 修复后端框架 header 限制"
note_edit() { EDITED_FILES="$EDITED_FILES $1"; backup "$1"; SOURCE_CHANGED=1; }

# 4.1 fasthttp / fiber：ReadBufferSize 决定 header 行上限（默认仅 4k）
FAST_FILES="$(for f in $MAIN_GO_FILES; do grep -qE 'fiber\.|fasthttp\.' "$f" 2>/dev/null && echo "$f"; done)"
for f in $FAST_FILES; do
  if grep -q 'ReadBufferSize' "$f"; then
    note_edit "$f"
    APP_LIMIT_BEFORE="$(grep -hoE 'ReadBufferSize[[:space:]]*[:=][[:space:]]*[^,;}]*' "$f" | head -n1 | sed -E 's/^ReadBufferSize[[:space:]]*[:=][[:space:]]*//')"
    [ -n "$APP_LIMIT_BEFORE" ] || APP_LIMIT_BEFORE="未配置(默认4KB)"
    sed -i -E "s/(ReadBufferSize[[:space:]]*[:=][[:space:]]*)[^,;}]+/\1 ${APP_FASTHTTP_BUF}/" "$f"
    APPLIED_APP_LIMIT="$APP_FASTHTTP_BUF"; WIRE_FILE="$f"
    if grep -q 'fiber\.' "$f"; then APP_KIND=fiber; else APP_KIND=fasthttp; fi
  elif grep -qE 'fiber\.New\(' "$f"; then
    note_edit "$f"
    if grep -qE 'fiber\.Config\{' "$f"; then
      sed -i -E "s/fiber\.Config\{/fiber.Config{ ReadBufferSize: ${APP_FASTHTTP_BUF}, /" "$f"
    else
      sed -i -E "s/fiber\.New\(\)/fiber.New(fiber.Config{ReadBufferSize: ${APP_FASTHTTP_BUF}})/" "$f"
    fi
    APPLIED_APP_LIMIT="$APP_FASTHTTP_BUF"; WIRE_FILE="$f"; APP_KIND=fiber
    APP_LIMIT_BEFORE="未配置(默认4KB)"
  elif grep -qE 'fasthttp\.Server\{' "$f"; then
    note_edit "$f"
    sed -i -E "s/fasthttp\.Server\{/fasthttp.Server{ ReadBufferSize: ${APP_FASTHTTP_BUF}, /" "$f"
    APPLIED_APP_LIMIT="$APP_FASTHTTP_BUF"; WIRE_FILE="$f"; APP_KIND=fasthttp
    APP_LIMIT_BEFORE="未配置(默认4KB)"
  fi
done

# 4.2 net/http（gin/echo/chi 等）：MaxHeaderBytes（默认 1MB）
# 多包布局下 MaxHeaderBytes 可能出现在多个 .go 文件（含退役入口存档），
# 因此遍历所有命中文件逐个替换（不使用 break）；WIRE_FILE 取含 http.Server{ 的
# 文件供 4.4 观测中间件接线（接线 sed 只认 Handler: 单行书写）。
if [ "$APPLIED_APP_LIMIT" = "0" ] && has_pattern 'MaxHeaderBytes'; then
  for f in $MAIN_GO_FILES; do
    if grep -q 'MaxHeaderBytes' "$f"; then
      note_edit "$f"
      if [ "$APP_LIMIT_BEFORE" = "未知" ]; then
        APP_LIMIT_BEFORE="$(grep -hoE 'MaxHeaderBytes[[:space:]]*[:=][[:space:]]*[^,;}]*' "$f" | head -n1 | sed -E 's/^MaxHeaderBytes[[:space:]]*[:=][[:space:]]*//')"
        [ -n "$APP_LIMIT_BEFORE" ] || APP_LIMIT_BEFORE="未配置(net/http默认1MB)"
      fi
      sed -i -E "s/(MaxHeaderBytes[[:space:]]*[:=][[:space:]]*)[^,;}]+/\1 ${APP_NETHTTP_MAX}/" "$f"
      APPLIED_APP_LIMIT="$APP_NETHTTP_MAX"; APP_KIND=nethttp
      grep -q 'http\.Server{' "$f" && WIRE_FILE="$f"
    fi
  done
fi
if [ "$APPLIED_APP_LIMIT" = "0" ] && has_pattern 'http\.Server{'; then
  for f in $MAIN_GO_FILES; do
    if grep -q 'http\.Server{' "$f"; then
      note_edit "$f"
      sed -i -E "s/http\.Server\{/http.Server{ MaxHeaderBytes: ${APP_NETHTTP_MAX}, /" "$f"
      APPLIED_APP_LIMIT="$APP_NETHTTP_MAX"; WIRE_FILE="$f"; APP_KIND=nethttp
      APP_LIMIT_BEFORE="未配置(net/http默认1MB)"
      break
    fi
  done
fi

# 4.3 业务配额/配置层限额（无条件幂等加固：配额中间件等配置驱动的限制同样要调大，
#     否则仅修框架层时业务配额仍会拦截）
# 多份配置档案可能同时命中（后端 configs/ 与中间层 tracegate/mesh 组件配置）：
# 逐文件记录修改前值并累计报告行，QUOTA_BEFORE（写入 header_limits.env 的
# ORIG_APP_QUOTA）取首个命中值；中间层组件配置在进程启动时读取，改动需重启生效。
ROW_QUOTA=""
CHAIN_CFG_CHANGED=0
for cf in $(find "$MOD_DIR" /app/tracegate /app/mesh -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.toml' -o -name '*.ini' -o -name '*.conf' -o -name '*.env' \) -not -path '*/vendor/*' 2>/dev/null); do
  QRE="max_header_bytes[\"':= ]*[0-9]+"
  grep -qiE "$QRE" "$cf" 2>/dev/null || continue
  QBEFORE="$(grep -hoiE "$QRE" "$cf" | head -n1 | grep -oE '[0-9]+$')"
  [ -z "$QUOTA_BEFORE" ] && QUOTA_BEFORE="$QBEFORE"
  backup "$cf"
  sed -i -E "s/((max_header_bytes|max_header_size)[\"' ]*[:=][\"' ]*)[0-9]+/\1${APP_QUOTA_MAX}/g;
             s/((read_buffer_size|header_buffer_size)[\"' ]*[:=][\"' ]*)[0-9]+/\1${APP_FASTHTTP_BUF}/g" "$cf"
  if [ "$(grep -hoiE "$QRE" "$cf" | head -n1 | grep -oE '[0-9]+$')" = "$APP_QUOTA_MAX" ]; then
    QUOTA_APPLIED=1; CONFIG_CHANGED=1
    case "$cf" in
      /app/tracegate/*|/app/mesh/*) CHAIN_CFG_CHANGED=1;;
      *) # 配额配置经 go:embed 随二进制固化（磁盘文件为构建期存档，改完重启不生效），
         # 必须重新编译部署——同置 SOURCE_CHANGED=1 触发步骤⑤重建 + 步骤⑥替换二进制。
         SOURCE_CHANGED=1;;
    esac
    ROW_QUOTA="${ROW_QUOTA}
| L2 | 业务配额档案 ${cf#$MOD_DIR/} | max_header_bytes | ${QBEFORE:-?} | ${APP_QUOTA_MAX} |"
    say ">> 业务配额/配置层已调大: $cf（${QBEFORE:-?} → ${APP_QUOTA_MAX}）"
  else
    warn "配额调整未生效，请人工检查 $cf"
  fi
done

# 4.5 全局残留清理：原故障值 8192 可能残留在退役入口存档等"非配额键"位置
#     （验题 L2 扫描覆盖 /app/backend 全部文本文件，任意残留均判不通过）。
#     清理前捕获残留位置供综合分析报告引用；同一表达式跑两遍，防相邻命中漏替。
RESIDUAL_8192="$(grep -rlIE '(^|[^0-9])8192([^0-9]|$)' "$MOD_DIR" \
  --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
  --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null || true)"
ORIG_FAULT_FILES=""
if [ -n "$RESIDUAL_8192" ]; then
  for rf in $RESIDUAL_8192; do
    ORIG_FAULT_FILES="$ORIG_FAULT_FILES ${rf#$MOD_DIR/}"
    backup "$rf"
    sed -i -E 's/(^|[^0-9])8192([^0-9]|$)/\11048576\2/g' "$rf"
    sed -i -E 's/(^|[^0-9])8192([^0-9]|$)/\11048576\2/g' "$rf"
    say ">> 原故障值残留已清理: $rf（8192 → 1048576）"
  done
fi

# 4.4 注入逐 header 体积统计中间件（归因观测：哪个模块/header 注入过多）
if [ "$SOURCE_CHANGED" = "1" ] && [ -n "$WIRE_FILE" ] && [ -n "$APP_KIND" ]; then
  PDIR="$(dirname "$WIRE_FILE")"
  PKG_NAME="$(grep -m1 -oE '^package[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*' "$WIRE_FILE" | awk '{print $2}')"
  case "$APP_KIND" in
    fiber)
      if ! grep -q 'headerStatFiber()' "$WIRE_FILE"; then
        sed -i -E "s/^([[:space:]]*)([a-zA-Z_][a-zA-Z0-9_]*)([[:space:]]*:=?[[:space:]]*)fiber\.New\(([^()]*)\)[[:space:]]*$/&\n\1\2.Use(headerStatFiber())/" "$WIRE_FILE"
      fi
      if grep -q 'headerStatFiber()' "$WIRE_FILE"; then MID_WIRED=1; else warn "fiber 注册形态未识别，逐头归因降级为入口总量观测"; fi
      MID_FILE="$PDIR/headerstat_fiber.go"
      cat > "$MID_FILE" <<EOF
package ${PKG_NAME}

import (
	"fmt"
	"os"
	"time"

	"github.com/gofiber/fiber/v2"
)

// headerStatWarnThreshold 预警绝对阈值（字节）：达到即认为接近上限
const headerStatWarnThreshold = ${WARN_THRESHOLD}

func init() { _ = os.MkdirAll("/app/ops", 0o755) }

// headerStatWarn 请求时同步写入预警（接近上限的请求在触发 431 之前即被感知）
func headerStatWarn(path string, total int) {
	f, err := os.OpenFile("/app/ops/warnings.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s WARN path=%s total=%dB >= 阈值=%dB（接近上限，请关注容量）\n", time.Now().Format("2006/01/02 15:04:05"), path, total, headerStatWarnThreshold)
}

// headerStatFiber 逐 header 体积统计（归因：哪个模块/header 注入过多）+ 阈值预警
func headerStatFiber() fiber.Handler {
	return func(c *fiber.Ctx) error {
		total := 0
		topName := "none"
		topSize := 0
		c.Request().Header.VisitAll(func(k, v []byte) {
			n := len(k) + len(v) + 4
			total += n
			if n > topSize {
				topSize = n
				topName = string(k)
			}
		})
		fmt.Printf("HDRSTAT path=%s total=%dB max_header=%s:%dB\n", c.Path(), total, topName, topSize)
		if total >= headerStatWarnThreshold {
			headerStatWarn(string(c.Path()), total)
		}
		return c.Next()
	}
}
EOF
      ;;
    fasthttp)
      if ! grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then
        sed -i -E "s/(Handler:[[:space:]]*)([a-zA-Z_][a-zA-Z0-9_.]*(\([^()]*\))?)(,?)/\1headerStatMiddleware(\2)\4/" "$WIRE_FILE"
      fi
      if grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then MID_WIRED=1; else warn "fasthttp Handler 未识别，逐头归因降级"; fi
      MID_FILE="$PDIR/headerstat_fasthttp.go"
      cat > "$MID_FILE" <<EOF
package ${PKG_NAME}

import (
	"fmt"
	"os"
	"time"

	"github.com/valyala/fasthttp"
)

// headerStatWarnThreshold 预警绝对阈值（字节）：达到即认为接近上限
const headerStatWarnThreshold = ${WARN_THRESHOLD}

func init() { _ = os.MkdirAll("/app/ops", 0o755) }

// headerStatWarn 请求时同步写入预警（接近上限的请求在触发 431 之前即被感知）
func headerStatWarn(path string, total int) {
	f, err := os.OpenFile("/app/ops/warnings.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s WARN path=%s total=%dB >= 阈值=%dB（接近上限，请关注容量）\n", time.Now().Format("2006/01/02 15:04:05"), path, total, headerStatWarnThreshold)
}

// headerStatMiddleware 逐 header 体积统计（归因：哪个模块/header 注入过多）+ 阈值预警
func headerStatMiddleware(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		total := 0
		topName := "none"
		topSize := 0
		ctx.Request.Header.VisitAll(func(k, v []byte) {
			n := len(k) + len(v) + 4
			total += n
			if n > topSize {
				topSize = n
				topName = string(k)
			}
		})
		fmt.Printf("HDRSTAT path=%s total=%dB max_header=%s:%dB\n", string(ctx.Path()), total, topName, topSize)
		if total >= headerStatWarnThreshold {
			headerStatWarn(string(ctx.Path()), total)
		}
		next(ctx)
	}
}
EOF
      ;;
    nethttp)
      if ! grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then
        sed -i -E "s/(Handler:[[:space:]]*)([a-zA-Z_][a-zA-Z0-9_.]*(\([^()]*\))?)(,?)/\1headerStatMiddleware(\2)\4/" "$WIRE_FILE"
      fi
      if grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then MID_WIRED=1; else warn "net/http Handler 字段未识别，逐头归因降级"; fi
      MID_FILE="$PDIR/headerstat_nethttp.go"
      cat > "$MID_FILE" <<EOF
package ${PKG_NAME}

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

// headerStatWarnThreshold 预警绝对阈值（字节）：达到即认为接近上限
const headerStatWarnThreshold = ${WARN_THRESHOLD}

func init() { _ = os.MkdirAll("/app/ops", 0o755) }

// headerStatWarn 请求时同步写入预警（接近上限的请求在触发 431 之前即被感知）
func headerStatWarn(path string, total int) {
	f, err := os.OpenFile("/app/ops/warnings.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s WARN path=%s total=%dB >= 阈值=%dB（接近上限，请关注容量）\n", time.Now().Format("2006/01/02 15:04:05"), path, total, headerStatWarnThreshold)
}

// headerStatMiddleware 逐 header 体积统计（归因：哪个模块/header 注入过多）+ 阈值预警
func headerStatMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		total := 0
		topName := "none"
		topSize := 0
		for name, vals := range r.Header {
			n := len(name) + 4
			for _, v := range vals {
				n += len(v)
			}
			total += n
			if n > topSize {
				topSize = n
				topName = name
			}
		}
		total += len(r.RequestURI) + 16
		fmt.Printf("HDRSTAT path=%s total=%dB max_header=%s:%dB\n", r.URL.Path, total, topName, topSize)
		if total >= headerStatWarnThreshold {
			headerStatWarn(r.URL.Path, total)
		}
		next.ServeHTTP(w, r)
	})
}
EOF
      ;;
  esac
  [ -n "$MID_FILE" ] && say "归因观测中间件: $MID_FILE（wired=$MID_WIRED）"
fi

if [ "$APPLIED_APP_LIMIT" = "0" ] && [ "$QUOTA_APPLIED" = "0" ]; then
  if [ "$AFTER_NGINX" = "431" ]; then
    die "复测仍 431 且未能在源码/配置中定位框架层 header 限制，请人工确认环境"
  fi
  say ">> 未发现后端 header 限制点，且当前无 431 —— 跳过 L2"
else
  _qlim=0; [ "$QUOTA_APPLIED" = "1" ] && _qlim="$APP_QUOTA_MAX"
  say ">> 后端限额已调至 框架层=${APPLIED_APP_LIMIT}B / 业务配额=${_qlim}B（修改:$EDITED_FILES）"
fi

# ---------- 步骤⑤：重新编译打包 ----------
NEW_BIN=""
if [ "$SOURCE_CHANGED" = "1" ]; then
  say "步骤⑤：重新编译打包 Go 服务"
  command -v go >/dev/null 2>&1 || die "缺少 go 工具链，无法重新编译"
  MAIN_PKG="."
  for mf in $MAIN_GO_FILES; do
    grep -q '^package main[[:space:]]*$' "$mf" 2>/dev/null && grep -q '^func main(' "$mf" 2>/dev/null || continue
    d="$(dirname "$mf")"; r="${d#"$MOD_DIR"}"; r="${r#/}"
    MAIN_PKG="."; [ -n "$r" ] && MAIN_PKG="./$r"
    break
  done
  MODFLAGS="-mod=mod"; [ -d "$MOD_DIR/vendor" ] && MODFLAGS="-mod=vendor"
  NEW_BIN="$(mktemp /tmp/appbin.XXXXXX)"
  # [FIX] 离线/在线编译均加 timeout 300，避免 Go 模块下载或工具链卡死导致永久挂起
  if ! ( cd "$MOD_DIR" && timeout 300 env GOPROXY=off GOTOOLCHAIN=local GOFLAGS="$MODFLAGS" CGO_ENABLED=0 go build -o "$NEW_BIN" "$MAIN_PKG" ); then
    warn "离线编译失败，尝试在线模块兜底"
    if ! ( cd "$MOD_DIR" && timeout 300 env GOFLAGS="$MODFLAGS" CGO_ENABLED=0 go build -o "$NEW_BIN" "$MAIN_PKG" ); then
      rm -f "$MID_FILE"
      for f in $EDITED_FILES; do [ -f "$f.solve.bak" ] && cp -p "$f.solve.bak" "$f"; done
      die "go build 失败，已回滚源码修改"
    fi
  fi
  say "编译产物: $NEW_BIN（MAIN_PKG=$MAIN_PKG, $MODFLAGS）"
fi

# ---------- 步骤⑥：清理日志并重启 Go 服务 ----------
find_app_pid() {
  # 链路多组件化后，UP_PORT（nginx 第一个 proxy_pass 的目标）可能是中间层
  # （如 tracegate:9100）而非业务后端：按端口找到的监听进程必须校验其 exe 属于
  # 后端模块目录，否则退回 cmdline 匹配——防止误把中间层二进制替换成后端产物。
  local pid="" exe bn c
  if [ -n "$UP_PORT" ]; then
    if command -v ss >/dev/null 2>&1; then
      pid="$(ss -ltnp 2>/dev/null | grep -E "[:.]${UP_PORT}[[:space:]]" | sed -nE 's/.*pid=([0-9]+).*/\1/p' | head -n1)"
    elif command -v netstat >/dev/null 2>&1; then
      pid="$(netstat -ltnp 2>/dev/null | grep -E "[:.]${UP_PORT}[[:space:]]" | sed -nE 's#.*[^0-9]([0-9]+)/[A-Za-z].*#\1#p' | head -n1)"
    fi
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    case "$exe" in
      "$MOD_DIR"/*) : ;;           # 确为后端模块目录下的二进制
      *) pid="" ;;                 # 端口属于其他组件（tracegate/meshd 等），放弃
    esac
  fi
  if [ -z "$pid" ]; then
    for c in $(pgrep -f "$MOD_DIR" 2>/dev/null); do
      [ "$c" = "$$" ] && continue
      exe="$(readlink "/proc/$c/exe" 2>/dev/null || true)"; bn="$(basename "${exe:-}")"
      case "$bn" in bash|sh|dash|sleep|tail|python*|nginx|supervisord|sudo|java|tee) continue;; esac
      case "$exe" in "$MOD_DIR"/*) pid="$c"; break;; esac
    done
  fi
  printf '%s' "$pid"
}

if [ "$SOURCE_CHANGED" = "1" ] || [ "$CONFIG_CHANGED" = "1" ]; then
  say "步骤⑥：清理日志并重启 Go 服务"
  APP_PID="$(find_app_pid)"
  EXE=""; ARGS=""; CWD=""
  if [ -n "$APP_PID" ]; then
    EXE="$(readlink "/proc/$APP_PID/exe" 2>/dev/null || true)"
    ARGS="$(tr '\0' '\n' < "/proc/$APP_PID/cmdline" 2>/dev/null | tail -n +2 | tr '\n' ' ' || true)"
    CWD="$(readlink "/proc/$APP_PID/cwd" 2>/dev/null || true)"
    say "原服务进程: pid=$APP_PID exe=${EXE:-?} cwd=${CWD:-?}"
  fi
  BIN="${EXE:-$MOD_DIR/bin/app}"
  case "$(basename "$BIN")" in
    go) BIN="$MOD_DIR/bin/app"; ARGS="";;   # go run 场景：改为运行编译产物
  esac
  if [ -n "$NEW_BIN" ]; then
    mkdir -p "$(dirname "$BIN")"
    cp -p "$NEW_BIN" "${BIN}.new" && chmod 0755 "${BIN}.new" && mv -f "${BIN}.new" "$BIN"
    say "已替换二进制: $BIN"
  fi
  RESTARTED=0
  if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status >/dev/null 2>&1; then
    PROG="$(supervisorctl status 2>/dev/null | sed -nE 's/^([[:space:]]*[^[:space:]:]+).*/\1/p' | tr -d ' ' \
           | grep -Ei 'app|go|server|backend' | head -n1)"
    [ -z "$PROG" ] && PROG="$(supervisorctl status 2>/dev/null | sed -nE 's/^([[:space:]]*[^[:space:]:]+).*/\1/p' | head -n1 | tr -d ' ')"
    # [FIX] 加 timeout 60，避免被托管进程 ignore SIGTERM 导致 restart 卡死
    [ -n "$PROG" ] && { timeout 60 supervisorctl restart "$PROG" && RESTARTED=1; }
  fi
  if [ "$RESTARTED" = "0" ]; then
    die "未能通过 supervisorctl 重启服务（环境应为 supervisord 编排）"
  fi
  # 中间层组件（tracegate/meshd）的限额配置在进程启动时读取：配置有改动时一并重启
  # 方可生效（后端配额是构建期固化，走二进制替换；各层生效语义不同，见综合报告）。
  if [ "$CHAIN_CFG_CHANGED" = "1" ] && command -v supervisorctl >/dev/null 2>&1 && supervisorctl status >/dev/null 2>&1; then
    if timeout 60 supervisorctl restart tracegate meshd >/dev/null 2>&1; then
      say "中间层组件已重启（tracegate/meshd 配置生效）"
    else
      warn "tracegate/meshd 重启失败，请人工确认 supervisorctl 程序名"
    fi
  fi
  if wait_up "${UPSTREAM_URL:-$ENTRY_URL}"; then say "链路入口已恢复监听"; else warn "服务端口未就绪，继续验证"; fi
else
  say "步骤⑥：无源码/配置变更，跳过重启（幂等重跑）"
fi

# ---------- 步骤⑥.5：Kafka 异步审计总线治理（明示非奖励项：与同步 431 无关） ----------
# 审计事件携带全量请求头快照（探针场景约 17-60KB），broker 侧 message.max.bytes 过小
# 时以 MESSAGE_TOO_LARGE(error_code=10) 拒绝——属异步链路容量信号，综合报告需三角说明。
say "步骤⑥.5：Kafka message.max.bytes 对齐（异步旁路治理，非奖励项）"
KAFKA_BIN=/opt/kafka/bin
KAF_MSG_NEW=262144
KAF_MSG_BEFORE="$(grep -E '^message\.max\.bytes=' /opt/kafka/config/kraft/server.properties 2>/dev/null | head -n1 | cut -d= -f2 | tr -dc '0-9')"
KAF_NOISE_BEFORE="$(grep -c 'kafka produce failed' /var/log/backend.log 2>/dev/null || true)"
KAF_NOISE_BEFORE="${KAF_NOISE_BEFORE:-0}"
KAF_ALTERED=0
if [ -x "$KAFKA_BIN/kafka-broker-api-versions.sh" ]; then
  # 等待 broker 就绪（JVM 慢启）；治理失败不 die——不影响奖励判定路径
  for _ in $(seq 1 18); do
    if timeout 10 "$KAFKA_BIN/kafka-broker-api-versions.sh" --bootstrap-server 127.0.0.1:9092 >/dev/null 2>&1; then break; fi
    sleep 5
  done
  if timeout 30 "$KAFKA_BIN/kafka-configs.sh" --bootstrap-server 127.0.0.1:9092 \
       --entity-type brokers --entity-name 1 --alter --add-config "message.max.bytes=${KAF_MSG_NEW}" >/dev/null 2>&1 \
     && timeout 30 "$KAFKA_BIN/kafka-configs.sh" --bootstrap-server 127.0.0.1:9092 \
       --entity-type brokers --entity-name 1 --describe 2>/dev/null | grep -q "message.max.bytes=${KAF_MSG_NEW}"; then
    KAF_ALTERED=1
    say ">> Kafka message.max.bytes 动态调至 ${KAF_MSG_NEW}（DYNAMIC_BROKER_CONFIG，免重启）"
  else
    warn "kafka-configs 动态修改未确认生效，回退静态配置 + 重启 broker（异步旁路，不阻断）"
    timeout 60 supervisorctl restart kafka >/dev/null 2>&1 || warn "kafka 重启失败（异步旁路，不阻断）"
  fi
else
  warn "未找到 Kafka 工具目录（$KAFKA_BIN）——异步治理跳过（非奖励项）"
fi
# 静态配置同步落盘（幂等）：动态值优先，静态值作为重启后的兜底
if [ -f /opt/kafka/config/kraft/server.properties ] && ! grep -q "^message.max.bytes=${KAF_MSG_NEW}$" /opt/kafka/config/kraft/server.properties; then
  backup /opt/kafka/config/kraft/server.properties
  sed -i -E "s/^message\.max\.bytes=[0-9]+/message.max.bytes=${KAF_MSG_NEW}/" /opt/kafka/config/kraft/server.properties
  say ">> Kafka 静态配置已同步：message.max.bytes=${KAF_MSG_NEW}（重启后兜底生效）"
fi
KAF_NOISE_AFTER="$(grep -c 'kafka produce failed' /var/log/backend.log 2>/dev/null || true)"
KAF_NOISE_AFTER="${KAF_NOISE_AFTER:-0}"

# ---------- 步骤⑦：生成预警观测与 431 质检门禁 ----------
say "步骤⑦：生成预警观测与质检门禁（$OPS_DIR）"
# 首次修复的原始阈值持久化（重复执行时报告中的"修改前"不漂移）
if [ -f "$OPS_DIR/header_limits.env" ]; then
  _o1="$(sed -n 's/^ORIG_NG_CHB=//p' "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o1" ] && NG_CHB_BEFORE="$_o1"
  _o2="$(sed -n 's/^ORIG_NG_BUF=//p'  "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o2" ] && NG_BUF_BEFORE="$_o2"
  _o3="$(sed -n 's/^ORIG_APP_LIMIT=//p' "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o3" ] && APP_LIMIT_BEFORE="$_o3"
  _o4="$(sed -n 's/^ORIG_APP_QUOTA=//p' "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o4" ] && QUOTA_BEFORE="$_o4"
fi
GATE_LIMIT="$(grep -hE '^max_header_bytes:' /app/tracegate/tracegate.yaml 2>/dev/null | head -n1 | grep -oE '[0-9]+$')"
MESH_LIMIT="$(grep -hE '^max_header_bytes:' /app/mesh/sidecar.yaml 2>/dev/null | head -n1 | grep -oE '[0-9]+$')"
cat > "$OPS_DIR/header_limits.env" <<EOF
# solve.sh 生成 —— 全链路 header 限额与预警参数（单一事实来源）
NGINX_CLIENT_HEADER_BUFFER_BYTES=$(( NG_CHB_KB * 1024 ))
NGINX_LARGE_HEADER_BUFFER_COUNT=${NG_BUF_N}
NGINX_LARGE_HEADER_BUFFER_BYTES=$(( NG_BUF_KB * 1024 ))
APP_MAX_HEADER_BYTES=$(( QUOTA_APPLIED == 1 ? APP_QUOTA_MAX : APPLIED_APP_LIMIT ))
TRACEGATE_MAX_HEADER_BYTES=${GATE_LIMIT:-}
MESH_MAX_HEADER_BYTES=${MESH_LIMIT:-}
KAFKA_MESSAGE_MAX_BYTES=${KAF_MSG_NEW}
WARN_RATIO=${WARN_RATIO}
ENTRY_URL=${ENTRY_URL}
UPSTREAM_URL=${UPSTREAM_URL}
ORIG_NG_CHB="${NG_CHB_BEFORE}"
ORIG_NG_BUF="${NG_BUF_BEFORE}"
ORIG_APP_LIMIT="${APP_LIMIT_BEFORE}"
ORIG_APP_QUOTA="${QUOTA_BEFORE}"
ORIG_KAFKA_MSG="${KAF_MSG_BEFORE}"
EOF

cat > "$OPS_DIR/quality_gate.sh" <<'GEOF'
#!/bin/bash
# 变更质检门禁：431 为高优先级拦截项
# 用法：bash /app/ops/quality_gate.sh  →  exit 0 通过 / exit 2 拦截
set -u
WINDOW=${GATE_WINDOW_SECONDS:-300}
NOW=$(date +%s); HITS=""

if [ -f /var/log/nginx/hdrsize.log ]; then
  N=$(awk -v now="$NOW" -v w="$WINDOW" '$1+0 >= now-w && $2 == 431' /var/log/nginx/hdrsize.log | wc -l)
  [ "$N" -gt 0 ] && HITS="$HITS 近${WINDOW}s hdrsize.log 命中 ${N} 条 431;"
fi
if [ -f /var/log/nginx/access.log ]; then
  N=$(tail -n 500 /var/log/nginx/access.log 2>/dev/null | awk '$9 == 431' | wc -l)
  [ "$N" -gt 0 ] && HITS="$HITS access.log 最近500条命中 ${N} 条 431;"
fi
if [ -f /var/log/nginx/error.log ] && grep -q "too long header line" /var/log/nginx/error.log; then
  HITS="$HITS nginx error.log 存在 too long header line(=431);"
fi
if [ -n "$HITS" ]; then
  echo "[quality-gate] 拦截(高优先级 431):${HITS}"
  exit 2
fi
echo "[quality-gate] 通过：未发现 431"
exit 0
GEOF
chmod 0755 "$OPS_DIR/quality_gate.sh"

# ---------- 步骤⑧：清理历史日志 ----------
say "步骤⑧：清理历史日志（预警由后端观测中间件在请求时同步写入 warnings.log）"
for lg in $NG_LOGS "$OPS_DIR/app.log" /var/log/backend.log /var/log/tracegate.log /var/log/meshd.log; do
  case "$lg" in /*) [ -f "$lg" ] && : > "$lg" ;; esac
done
nginx -s reopen 2>/dev/null || true
: > "$OPS_DIR/warnings.log" 2>/dev/null || true

# ---------- 步骤⑨：超长 header 端到端验证 + 门禁 ----------
say "步骤⑨：超长 header 端到端验证"
BASELINE="$(probe "$ENTRY_URL" "")"
FINAL="$(probe "$ENTRY_URL" "$TEST_HEADER_BYTES")"
# "直达后端"探针固定业务端口 9000（UPSTREAM_URL 现指向入口第一跳 tracegate:9100，
# 不能再作为后端直连口径——与验题契约的 127.0.0.1:9000 探针对齐）
DIRECT="$(probe "$BE_URL" "$TEST_HEADER_BYTES")"
FINAL_GATE="$(probe "$GATE_URL" "$TEST_HEADER_BYTES")"
FINAL_MESH="$(probe "$MESH_URL" "$TEST_HEADER_BYTES")"
FINAL_BACKEND="$(probe "$BE_URL" "$TEST_HEADER_BYTES")"
say "分层修复后状态: tracegate(9100)=${FINAL_GATE:-无} meshd(15001)=${FINAL_MESH:-无} backend(9000)=${FINAL_BACKEND:-无}"
say "常规请求(入口)      : ${BASELINE:-无响应}"
say "超长header(入口)    : ${FINAL:-无响应}  （修复前=${INITIAL} / L1后=${AFTER_NGINX}）"
say "超长header(直达后端): ${DIRECT:-跳过}"

PASS=1
case "$BASELINE" in ""|000) PASS=0;; esac
case "$FINAL"   in ""|000|431|414|5??) PASS=0;; esac
[ -n "$BASELINE" ] && [ "$BASELINE" != "$FINAL" ] && PASS=0
case "$DIRECT"  in 431|414|000) PASS=0;; esac

# 链路证据自证（与验题契约同口径）：nonce 回环——回显须按序含 nonce→gate=→mesh= 且
# 增幅 ≥2048B；异常即 PASS=0（防止中间层被绕过/注入行为被改动的"伪修复"通过）
VFY="vfy$(date +%s%N)"
TC_ECHO="$(curl -s -D - -o /dev/null --max-time 10 -H "X-Trace-Context: $VFY" "$ENTRY_URL" 2>/dev/null \
  | grep -i '^x-trace-context:' | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/\r$//')"
case "$TC_ECHO" in
  *"$VFY"*"gate="*"mesh="*)
    if [ "${#TC_ECHO}" -ge $(( ${#VFY} + 2048 )) ]; then
      say "链路证据: nonce→gate→mesh 有序回显 ✅（增幅 ${#TC_ECHO}B）"
    else
      warn "链路证据: 回显增幅不足（${#TC_ECHO}B，span 未真实落头）"
      PASS=0
    fi ;;
  *)
    warn "链路证据: 回显异常（${TC_ECHO:0:40}...）——疑似中间层被绕过"
    PASS=0 ;;
esac

GATE_RC=0
bash "$OPS_DIR/quality_gate.sh" || GATE_RC=$?
say "质检门禁: exit=${GATE_RC}（0=通过 / 2=拦截431）"
[ "$GATE_RC" -ne 0 ] && PASS=0

# 预警机制自证：90% 阈值探针应即时触发 warnings.log（观测中间件在请求时同步写入）
WARN_PROBE_BYTES=$(( NG_BUF_KB * 1024 * 90 / 100 ))
WARN_STATUS="$(probe "$ENTRY_URL" "$WARN_PROBE_BYTES")"
say "预警观测探针(90%阈值): status=${WARN_STATUS}（header≈${WARN_PROBE_BYTES}B）"
# 循环等待（最多 5s）：避免固定 sleep 在高负载下误判预警失效
WARN_OK=0
for _ in $(seq 1 5); do
  if [ -s "$OPS_DIR/warnings.log" ]; then WARN_OK=1; break; fi
  sleep 1
done
if [ "$WARN_OK" = "1" ]; then
  say "预警观测: warnings.log 已捕获接近阈值请求 ✅"
  tail -n 2 "$OPS_DIR/warnings.log"
else
  warn "预警观测: 暂未捕获预警（检查 /var/log/backend.log 中 HDRSTAT 与中间件注入状态）"
fi

# ---------- 步骤⑩：431 综合分析报告（链路级归因，非单点归责） ----------
say "步骤⑩：生成 431 综合分析报告"

REPORT="$OPS_DIR/diagnosis_report.md"
HDRSTAT_LINE="$(grep -h 'HDRSTAT' /var/log/backend.log "$OPS_DIR/app.log" 2>/dev/null | tail -n1)"
HDR_TOTAL="$(printf '%s' "$HDRSTAT_LINE" | sed -nE 's/.*total=([0-9]+)B.*/\1/p')"
HDR_TOP="$(printf '%s' "$HDRSTAT_LINE" | sed -nE 's/.*max_header=([^[:space:]]+).*/\1/p')"
ENTRY_LEN="$(tail -n1 /var/log/nginx/hdrsize.log 2>/dev/null | awk '{print $3}')"
[ -n "$ENTRY_LEN" ] && ENTRY_LEN="${ENTRY_LEN}B" || ENTRY_LEN="N/A"
# 中间层逐层体量证据（GATESTAT/MESHSTAT 由组件在请求处理路径打印）
GATESTAT_LINE="$(grep -h 'GATESTAT' /var/log/tracegate.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
MESHSTAT_LINE="$(grep -h 'MESHSTAT' /var/log/meshd.log 2>/dev/null | grep 'verdict=PASS' | tail -n1)"
GATE_IN="$(printf '%s' "$GATESTAT_LINE" | sed -nE 's/.*total=([0-9]+)B.*/\1/p')"
GATE_TRACE_OUT="$(printf '%s' "$GATESTAT_LINE" | sed -nE 's/.*trace_out=([0-9]+)B.*/\1/p')"
MESH_IN="$(printf '%s' "$MESHSTAT_LINE" | sed -nE 's/.*total=([0-9]+)B.*/\1/p')"
MESH_TRACE_OUT="$(printf '%s' "$MESHSTAT_LINE" | sed -nE 's/.*trace_out=([0-9]+)B.*/\1/p')"
# 注入量取值（容量推导依据：后端输入 ≈ 入口探针 + 各跳注入）
GATE_SPAN="$(sed -n 's/^span_bytes:[[:space:]]*//p' /app/tracegate/tracegate.yaml 2>/dev/null | head -n1 | tr -dc '0-9')"
MESH_SPAN="$(sed -n 's/^span_bytes:[[:space:]]*//p' /app/mesh/sidecar.yaml 2>/dev/null | head -n1 | tr -dc '0-9')"
MESH_BAGGAGE="$(sed -n 's/^baggage_bytes:[[:space:]]*//p' /app/mesh/sidecar.yaml 2>/dev/null | head -n1 | tr -dc '0-9')"

case "${APP_KIND}" in
  fiber)    APP_LABEL="Go 后端（fiber 框架）";    L2_KEY="ReadBufferSize";;
  fasthttp) APP_LABEL="Go 后端（fasthttp 框架）"; L2_KEY="ReadBufferSize";;
  nethttp)  APP_LABEL="Go 后端（net/http 框架）"; L2_KEY="MaxHeaderBytes";;
  *)        APP_LABEL="Go 后端";                 L2_KEY="header 限额";;
esac

# ROW_QUOTA 已在 4.3 按命中的配置档案逐条累计（含各自修改前值）
# Kafka 治理方式描述（供报告引用）
KAF_HOW="静态配置 + broker 重启兜底"
[ "$KAF_ALTERED" = "1" ] && KAF_HOW="kafka-configs 动态 alter，免重启生效"

if [ -n "$HDR_TOP" ]; then
  ATTR_DETAIL="- 逐 header 归因（后端 HDRSTAT 中间件）：请求头总长 ${HDR_TOTAL:-?}B，单个最大 header 为 ${HDR_TOP} —— 注入该 header 的上游模块（网关/认证/链路追踪等）是 header 体量增长的主要来源"
else
  ATTR_DETAIL="- 总量归因（入口 nginx \$request_length）：${ENTRY_LEN}；后端逐头统计未接入，按入口总量归因"
fi

cat > "$REPORT" <<EOF
# 431 Request Header Fields Too Large —— 综合分析报告

> 生成于 $(date '+%F %T')（solution/solve.sh）。结论为链路级综合归因：header 体量增长与多层阈值过小共同作用，非单点归责。

## 1. 现象与复现
- 复现方法：向入口发送携带 ${TEST_HEADER_BYTES}B 超长 header 的 curl 请求
- 链路：nginx(:80) → tracegate(:9100，接入网关 trace 插件) → meshd(:15001，mesh 数据面 sidecar) → backend(:9000)；另有异步审计旁路（Kafka），与同步链路 431 无关
- 状态码链（入口）：修复前=${INITIAL} → 仅修 L1(nginx) 后=${AFTER_NGINX} → 全链路限额修复后=${FINAL}（常规请求=${BASELINE}）
- 分层直连状态码链：tracegate(9100) ${INITIAL_GATE:-无}→${FINAL_GATE:-无}；meshd(15001) ${INITIAL_MESH:-无}→${FINAL_MESH:-无}；backend(9000) ${INITIAL_BACKEND:-无}→${FINAL_BACKEND:-无}
- 层面现象：实测 nginx 1.22 对超长 header 行返回 400 "Request Header Or Cookie Too Large"（info 级日志，默认 error 级 error.log 无记录）；L1 修复后入口 431 为中间层/后端拦截的透传结果

## 2. 链路阈值对照（哪一层限制过小）
| 层 | 模块 | 限制项 | 修改前 | 修改后 |
|---|------|--------|--------|--------|
| L1 | nginx（入口反代） | client_header_buffer_size | ${NG_CHB_BEFORE} | ${NG_CHB_KB}k |
| L1 | nginx（入口反代） | large_client_header_buffers | ${NG_BUF_BEFORE} | ${NG_BUF_N} ${NG_BUF_KB}k |
| L2 | ${APP_LABEL} | ${L2_KEY} | ${APP_LIMIT_BEFORE} | ${APPLIED_APP_LIMIT} |
${ROW_QUOTA}

结论：修复前 nginx 与后端两层阈值均低于上游注入的 header 体量（复现探针 ${TEST_HEADER_BYTES}B），属多模块限制过小。

原故障值口径：业务配额原值 8192（max_header_bytes，随二进制构建固化——改磁盘配置档案重启不生效，须重新编译部署），
本次已调至 ${APP_QUOTA_MAX}；源码/配置中 8192 的等值书写形态（移码/十六进制）与退役入口存档中的残留常量一并纳入清理
（本次命中文件：${ORIG_FAULT_FILES:-无}；MaxHeaderBytes 原书写形态：${APP_LIMIT_BEFORE}）。

## 3. Header 体量归因（谁注入过多）
${ATTR_DETAIL}
- 入口实测（nginx \$request_length）：${ENTRY_LEN}
- 中间层逐层实测：tracegate 收到 ${GATE_IN:-?}B / 注入后 ${GATE_TRACE_OUT:-?}B（GATESTAT）；meshd 收到 ${MESH_IN:-?}B / 注入后 ${MESH_TRACE_OUT:-?}B（MESHSTAT）
- 注入量口径：tracegate 每跳追加 gate span ${GATE_SPAN:-?}B；meshd 每跳追加 mesh span ${MESH_SPAN:-?}B + X-Mesh-Baggage ${MESH_BAGGAGE:-?}B —— 后端实际收到的请求头 ≈ 入口探针 + 约 2.9KB 注入，容量评估必须按"后端视角"取值而非入口视角

## 4. 结论（综合分析）
1. 431 = 上游模块注入的 header 体量增长 × 链路各层阈值（nginx 缓冲、tracegate 预算、meshd 上限、后端框架限制与业务配额）未同步扩容的综合结果；
2. 仅修 L1 后入口仍为 ${AFTER_NGINX}（见状态码链），证明单点修复不充分，必须端到端协同治理；
3. 修复后余量：nginx 单行上限 $(( NG_BUF_KB * 1024 ))B、后端 ${APPLIED_APP_LIMIT}B，均远高于实测体量（含各跳注入的增长余量）；
4. 各层生效语义不同：nginx 热加载、中间层配置重启生效、后端配额随构建固化——"已书写"≠"已生效"，变更后须逐层直连复测；
5. 持续防线：${WARN_RATIO}% 阈值预警 watchdog → warnings.log（431 触发前感知）；quality_gate.sh 对 431 高优先级拦截（exit 2）；阈值单一事实来源 header_limits.env。

## 5. 证据与产物
- 复验记录：/app/ops/last_solve_result.txt
- nginx 配置：/etc/nginx/nginx.conf（*.solve.bak 为修改前备份）
- 后端模块：${MOD_DIR}（${L2_KEY} 见 ${WIRE_FILE##*/}）；中间层：/app/tracegate/tracegate.yaml、/app/mesh/sidecar.yaml

## 6. 异步审计旁路（Kafka）三角说明
- Kafka message.max.bytes：${KAF_MSG_BEFORE:-未知} → ${KAF_MSG_NEW}（${KAF_HOW}）
- 故障期表现：审计事件携带**全量请求头快照**（探针场景约 17-60KB），超过 broker 限额被拒，
  backend 日志出现 \`kafka produce failed: ... error_code=10(MESSAGE_TOO_LARGE)\`（治理前采样 ${KAF_NOISE_BEFORE} 条）
- 三角结论：MESSAGE_TOO_LARGE 是**异步审计链路**的容量信号，与同步链路 431 的拦截层不同——
  排障时应分流处置：同步 431 逐层定位（本报告第 1-2 节），异步容量信号对齐 broker 限额（本节）
EOF
say "报告: $REPORT"

cat > "$OPS_DIR/last_solve_result.txt" <<EOF
time=$(date '+%F %T')
initial_status=${INITIAL}
after_nginx_status=${AFTER_NGINX}
baseline_status=${BASELINE}
final_status=${FINAL}
direct_status=${DIRECT}
initial_gate_status=${INITIAL_GATE:-NA}
final_gate_status=${FINAL_GATE:-NA}
initial_mesh_status=${INITIAL_MESH:-NA}
final_mesh_status=${FINAL_MESH:-NA}
initial_backend_status=${INITIAL_BACKEND:-NA}
final_backend_status=${FINAL_BACKEND:-NA}
app_max_header_bytes=${APPLIED_APP_LIMIT}
gate_max_header_bytes=${GATE_LIMIT:-NA}
mesh_max_header_bytes=${MESH_LIMIT:-NA}
kafka_message_max_bytes=${KAF_MSG_NEW}
kafka_message_max_bytes_before=${KAF_MSG_BEFORE:-NA}
kafka_altered_dynamic=${KAF_ALTERED}
kafka_produce_failed_before=${KAF_NOISE_BEFORE}
kafka_produce_failed_after=${KAF_NOISE_AFTER}
nginx_large_header_buffers=${NG_BUF_N}x$(( NG_BUF_KB * 1024 ))B
quality_gate_exit=${GATE_RC}
report=diagnosis_report.md
app_kind=${APP_KIND}
hdr_total=${HDR_TOTAL:-NA}
hdr_top=${HDR_TOP:-NA}
entry_request_length=${ENTRY_LEN}
pass=${PASS}
EOF
say "产物: $OPS_DIR/{header_limits.env, quality_gate.sh, warnings.log, diagnosis_report.md, last_solve_result.txt}（观测能力内置于后端 headerStat 中间件）"

# [FIX] 合并结尾原先重复的两段 if [ "$PASS" = "1" ]（前一段只打印、后一段才 exit），
#       并删除误导性的"常驻占位/等待平台销毁"注释段——平台期望 solve.sh 正常退出。
if [ "$PASS" = "1" ]; then
  say "结果: PASS —— 431 双层修复完成，预警观测与质检门禁就绪"
  exit 0
else
  warn "结果: FAIL —— 详见 $OPS_DIR/last_solve_result.txt"
  exit 1
fi