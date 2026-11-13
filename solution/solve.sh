#!/bin/bash
# =============================================================================
# solution/solve.sh —— Harbor 参考解（标准答案脚本，agent 不可见，仅供平台验题）
#
# 任务场景：入口 nginx 反代 + Go 后端（同容器）。超长请求头触发
#           431 Request Header Fields Too Large，故障在两层：
#             L1 nginx：client_header_buffer_size / large_client_header_buffers 过小
#             L2 Go 框架：fasthttp/fiber ReadBufferSize 或 net/http MaxHeaderBytes 过小
#                        （L1 修复后依旧 431，需改源码并重新编译打包）
#           注意：实测 nginx 1.22 对超长 header 行回 400 "Request Header Or Cookie
#           Too Large"（且属 info 级日志，默认 error 级 error.log 无记录），
#           431 由 Go/net-http 后端返回；脚本流程不依赖具体码值（400/431 均按
#           "与常规请求不一致" 判定故障），L2 修复无条件幂等执行。
#
# 参考解路径：
#   步骤① curl 复现 431，查 nginx error log 定位 L1 → 调大 buffer，nginx -t 校验后 reload
#   步骤③ L1 复测仍 431 → 排查后端源码，找到框架限制 → 调大阈值（步骤④）
#   步骤⑤ 重新编译打包；步骤⑥ 清理日志后重启 Go 服务
#   步骤⑨ 超长 header curl 端到端验证（入口 + 直连后端）
#   步骤⑦⑧ 增加阈值预警观测（watchdog）与 431 高优先级质检门禁（quality gate）
#   步骤④.4 注入逐 header 体积统计中间件（归因观测：定位哪个模块/header 注入过多）
#   步骤⑩ 生成 431 综合分析报告（diagnosis_report.md：链路级归因，非单点归责）
#
# 运行约定：在任务环境容器内以 root 执行（Debian/Ubuntu 系工具链）；
#           nginx 与 Go 服务同容器；Go 模块位于 /app 下（含 go.mod）。
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
APP_NETHTTP_MAX=$(( NG_BUF_KB * 1024 ))  # L2: net/http MaxHeaderBytes（L3: 三层统一 == L）
WARN_RATIO=80                # 预警阈值 = 上限的 80%
WARN_THRESHOLD=$(( NG_BUF_KB * 1024 * WARN_RATIO / 100 ))   # 预警绝对阈值（字节），注入观测中间件

ENTRY_URL=""; CURL_TLS=""
UPSTREAM_URL=""; UP_PORT=""
INITIAL=""; AFTER_NGINX=""; BASELINE=""; FINAL=""; DIRECT=""
APPLIED_APP_LIMIT=0; SOURCE_CHANGED=0; CONFIG_CHANGED=0
EDITED_FILES=""; MAIN_GO_FILES=""; NG_LOGS=""
NG_CHB_BEFORE="未配置(默认1k)"; NG_BUF_BEFORE="未配置(默认4 8k)"
APP_LIMIT_BEFORE="未知"; APP_KIND=""; WIRE_FILE=""; MID_FILE=""; MID_WIRED=0
APP_QUOTA_MAX=$(( NG_BUF_KB * 1024 )); QUOTA_APPLIED=0  # L3: 业务配额 == L（单一事实来源）

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
if [ "$APPLIED_APP_LIMIT" = "0" ] && has_pattern 'MaxHeaderBytes'; then
  for f in $MAIN_GO_FILES; do
    if grep -q 'MaxHeaderBytes' "$f"; then
      note_edit "$f"
      APP_LIMIT_BEFORE="$(grep -hoE 'MaxHeaderBytes[[:space:]]*[:=][[:space:]]*[^,;}]*' "$f" | head -n1 | sed -E 's/^MaxHeaderBytes[[:space:]]*[:=][[:space:]]*//')"
      [ -n "$APP_LIMIT_BEFORE" ] || APP_LIMIT_BEFORE="未配置(net/http默认1MB)"
      sed -i -E "s/(MaxHeaderBytes[[:space:]]*[:=][[:space:]]*)[^,;}]+/\1 ${APP_NETHTTP_MAX}/" "$f"
      APPLIED_APP_LIMIT="$APP_NETHTTP_MAX"; WIRE_FILE="$f"; APP_KIND=nethttp
      break
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
for cf in $(find "$MOD_DIR" -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.toml' -o -name '*.ini' -o -name '*.conf' -o -name '*.env' \) -not -path '*/vendor/*' 2>/dev/null); do
  QRE="max_header_bytes[\"':= ]*[0-9]+"
  grep -qiE "$QRE" "$cf" 2>/dev/null || continue
  QUOTA_BEFORE="$(grep -hoiE "$QRE" "$cf" | head -n1 | grep -oE '[0-9]+$')"
  backup "$cf"
  sed -i -E "s/((max_header_bytes|max_header_size)[\"' ]*[:=][\"' ]*)[0-9]+/\1${APP_QUOTA_MAX}/g;
             s/((read_buffer_size|header_buffer_size)[\"' ]*[:=][\"' ]*)[0-9]+/\1${APP_FASTHTTP_BUF}/g" "$cf"
  if [ "$(grep -hoiE "$QRE" "$cf" | head -n1 | grep -oE '[0-9]+$')" = "$APP_QUOTA_MAX" ]; then
    QUOTA_APPLIED=1; CONFIG_CHANGED=1
    say ">> 业务配额/配置层已调大: $cf（${QUOTA_BEFORE:-?} → ${APP_QUOTA_MAX}）"
  else
    warn "配额调整未生效，请人工检查 $cf"
  fi
done

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

# ---------- 步骤④.7：网格层（mesh-sim）限额同步扩容（G 矩阵：总量+计数双维度） ----------
say "步骤④.7：mesh-sim 限额同步扩容（max_request_headers_kb / max_headers_count）"
MESH_CONF="/etc/mesh-sim/config.yaml"
MESH_TOTAL_KB=$(( NG_BUF_KB + 64 ))   # 须 ≥ L−8192（mesh 自身注入 ~8KiB + 网格不得成为瓶颈）
MESH_COUNT=256                        # 须 ≥ 120（计数维度：120×100B 探针）
if [ -f "$MESH_CONF" ]; then
  MESH_BEFORE="$(grep -E 'max_request_headers_kb|max_headers_count' "$MESH_CONF" | tr -s ' \n' ' ')"
  backup "$MESH_CONF"
  sed -i -E "s/^([[:space:]]*max_request_headers_kb[[:space:]]*:[[:space:]]*)[0-9]+/\1${MESH_TOTAL_KB}/;
             s/^([[:space:]]*max_headers_count[[:space:]]*:[[:space:]]*)[0-9]+/\1${MESH_COUNT}/" "$MESH_CONF"
  say "mesh 修改前: ${MESH_BEFORE:-无}"
  if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status >/dev/null 2>&1; then
    timeout 60 supervisorctl restart mesh-sim >/dev/null 2>&1 || warn "mesh-sim 重启失败（请人工检查）"
    sleep 1
  fi
  say "mesh 修改后: $(grep -E 'max_request_headers_kb|max_headers_count' "$MESH_CONF" | tr -s ' \n' ' ')"
else
  warn "未找到 $MESH_CONF（环境无 mesh-sim 节点？跳过网格层扩容）"
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
  local pid="" exe bn
  if [ -n "$UP_PORT" ]; then
    if command -v ss >/dev/null 2>&1; then
      pid="$(ss -ltnp 2>/dev/null | grep -E "[:.]${UP_PORT}[[:space:]]" | sed -nE 's/.*pid=([0-9]+).*/\1/p' | head -n1)"
    elif command -v netstat >/dev/null 2>&1; then
      pid="$(netstat -ltnp 2>/dev/null | grep -E "[:.]${UP_PORT}[[:space:]]" | sed -nE 's#.*[^0-9]([0-9]+)/[A-Za-z].*#\1#p' | head -n1)"
    fi
  fi
  if [ -z "$pid" ]; then
    for c in $(pgrep -f "$MOD_DIR" 2>/dev/null); do
      [ "$c" = "$$" ] && continue
      exe="$(readlink "/proc/$c/exe" 2>/dev/null || true)"; bn="$(basename "${exe:-}")"
      case "$bn" in bash|sh|dash|sleep|tail|python*|nginx|supervisord|sudo) continue;; esac
      pid="$c"; break
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
  if wait_up "${UPSTREAM_URL:-$ENTRY_URL}"; then say "Go 服务已恢复监听"; else warn "服务端口未就绪，继续验证"; fi
else
  say "步骤⑥：无源码/配置变更，跳过重启（幂等重跑）"
fi

# ---------- 步骤⑦：生成预警观测与 431 质检门禁 ----------
say "步骤⑦：生成预警观测与质检门禁（$OPS_DIR）"
# 首次修复的原始阈值持久化（重复执行时报告中的"修改前"不漂移）
if [ -f "$OPS_DIR/header_limits.env" ]; then
  _o1="$(sed -n 's/^ORIG_NG_CHB=//p' "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o1" ] && NG_CHB_BEFORE="$_o1"
  _o2="$(sed -n 's/^ORIG_NG_BUF=//p'  "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o2" ] && NG_BUF_BEFORE="$_o2"
  _o3="$(sed -n 's/^ORIG_APP_LIMIT=//p' "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o3" ] && APP_LIMIT_BEFORE="$_o3"
  _o4="$(sed -n 's/^ORIG_APP_QUOTA=//p' "$OPS_DIR/header_limits.env" | head -n1 | tr -d '"')"; [ -n "$_o4" ] && QUOTA_BEFORE="$_o4"
fi
cat > "$OPS_DIR/header_limits.env" <<EOF
# solve.sh 生成 —— 全链路 header 限额与预警参数（单一事实来源）
NGINX_CLIENT_HEADER_BUFFER_BYTES=$(( NG_CHB_KB * 1024 ))
NGINX_LARGE_HEADER_BUFFER_COUNT=${NG_BUF_N}
NGINX_LARGE_HEADER_BUFFER_BYTES=$(( NG_BUF_KB * 1024 ))
APP_MAX_HEADER_BYTES=$(( QUOTA_APPLIED == 1 ? APP_QUOTA_MAX : APPLIED_APP_LIMIT ))
MESH_MAX_REQUEST_HEADERS_KB=${MESH_TOTAL_KB}
MESH_MAX_HEADERS_COUNT=${MESH_COUNT}
WARN_RATIO=${WARN_RATIO}
ENTRY_URL=${ENTRY_URL}
UPSTREAM_URL=${UPSTREAM_URL}
ORIG_NG_CHB="${NG_CHB_BEFORE}"
ORIG_NG_BUF="${NG_BUF_BEFORE}"
ORIG_APP_LIMIT="${APP_LIMIT_BEFORE}"
ORIG_APP_QUOTA="${QUOTA_BEFORE}"
EOF

cat > "$OPS_DIR/quality_gate.sh" <<'GEOF'
#!/bin/bash
# 变更质检门禁（L3 多模式）：
#   quality_gate.sh            等价 --check：无状态窗口检查（L2 语义，/via-gate 预检用）
#   quality_gate.sh --check    同上
#   quality_gate.sh --replay [file]
#                              断点续读：按 gate_state.json 的 (inode,offset) 消费增量；
#                              rename 轮转产物（*.1/*.2/*.gz）按 inode/名称迁移续读，
#                              gzip 流式解压不落盘；truncate 从 0 重读不重复计数；
#                              事件时间窗 1h（窗外事件跳过）；状态原子写（tmp+rename）。
# 退出：--check 0 通过 / 2 拦截；--replay 0 成功 / 非 0 处理故障。
set -u
umask 022
export LC_ALL=C
STATE=/app/ops/gate_state.json
WINDOW=${GATE_WINDOW_SECONDS:-600}
NOW=${EPOCHSECONDS:-0}
MODE=check; BENCH_FILE=""
case "${1:-}" in
  --check) MODE=check ;;
  --replay) MODE=replay; BENCH_FILE="${2:-}" ;;
esac

sget() {  # sget <source-key> <field> → 值（缺失为 0）
  [ -f "$STATE" ] || { echo 0; return; }
  grep -o "\"$1\":{[^}]*}" "$STATE" 2>/dev/null | grep -o "\"$2\":[0-9-]*" | grep -o -- "-\?[0-9]*$" | head -n1
}

check_mode() {  # 无状态窗口检查（L2 兼容语义）
  local HITS="" N
  if [ -f /var/log/nginx/hdrsize.log ]; then
    N=$(awk -v now="$NOW" -v w="$WINDOW" '$1+0>=now-w && $2==431' /var/log/nginx/hdrsize.log | wc -l)
    [ "$N" -gt 0 ] && HITS="$HITS hdrsize:${N};"
  fi
  if [ -f /var/log/nginx/access.log ]; then
    N=$(tail -n 2000 /var/log/nginx/access.log 2>/dev/null | awk -v now="$NOW" -v w="$WINDOW" '
      function m2i(m,s,p){s="Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec";p=index(s,m);return p>0?int((p-1)/4)+1:0}
      {t=$4;gsub(/^\[/,"",t);split(t,a,/[:\/]/);e=mktime(a[3]" "m2i(a[2])" "a[1]" "a[4]" "a[5]" "a[6]);
       if(e+0>=now-w && $9==431)c++} END{print c+0}')
    [ "$N" -gt 0 ] && HITS="$HITS access:${N};"
  fi
  if [ -f /var/log/nginx/error.log ]; then
    N=$(grep "too long header line" /var/log/nginx/error.log 2>/dev/null | awk -v now="$NOW" -v w="$WINDOW" '
      {split($1,d,"/");split($2,t,":");e=mktime(d[1]" "d[2]" "d[3]" "t[1]" "t[2]" "t[3]);
       if(e+0>=now-w)c++} END{print c+0}')
    [ "$N" -gt 0 ] && HITS="$HITS error:${N};"
  fi
  if [ -n "$HITS" ]; then echo "[quality-gate] 拦截(窗口内 431):${HITS}"; return 2; fi
  echo "[quality-gate] 通过：窗口内无 431"; return 0
}

# 单文件流式解析：fmt=access(ts=$4 combined,status=$9) / error(ts=$1 $2,标记行) / hdrsize(ts=$1,status=$2)
# 输出：新增 431 计数；skip 字节前的内容跳过（断点续读）
stream_count() {  # stream_count <file> <fmt> <skip>
  zcat -f "$1" 2>/dev/null | tail -c "+$(( $3 + 1 ))" | awk -v fmt="$2" -v now="$NOW" -v w="$WINDOW" '
    function m2i(m,s,p){s="Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec";p=index(s,m);return p>0?int((p-1)/4)+1:0}
    fmt=="hdrsize" { if ($1+0>=now-w && $2==431) c++; next }
    fmt=="error"   { if ($0 !~ /too long header line/) next;
                     split($1,d,"/");split($2,t,":");e=mktime(d[1]" "d[2]" "d[3]" "t[1]" "t[2]" "t[3]);
                     if(e+0>=now-w)c++; next }
    { t=$4;gsub(/^\[/,"",t);split(t,a,/[:\/]/);e=mktime(a[3]" "m2i(a[2])" "a[1]" "a[4]" "a[5]" "a[6]);
      if(e+0>=now-w && $9==431)c++ }
    END{print c+0}'
}

replay_mode() {  # 断点续读
  local rc=0 base ino sz off cnt tot_art n key fi
  local tmp="$STATE.tmp$$"
  declare -A RI RO      # rotated: name→inode/offset（运行期账本，落盘回写）
  # 载入已有 rotated 条目（name 无 .gz 后缀）
  if [ -f "$STATE" ]; then
    while IFS= read -r k; do
      RI["$k"]=$(grep -o "\"$k\":{[^}]*}" "$STATE" | grep -o "\"inode\":[0-9]*" | grep -o "[0-9]*$")
      RO["$k"]=$(grep -o "\"$k\":{[^}]*}" "$STATE" | grep -o "\"offset\":[0-9]*" | grep -o "[0-9]*$")
    done < <(grep -o '"rotated":{[^}]*}' "$STATE" 2>/dev/null | grep -oE '"/var/log/nginx/[^"]*"' | tr -d '"' | tr '\n' ' ')
  fi
  for base in /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/hdrsize.log; do
    fmt=access; [ "${base##*/}" = "error.log" ] && fmt=error; [ "${base##*/}" = "hdrsize.log" ] && fmt=hdrsize
    off=$(sget "${base}" offset); cnt=$(sget "${base}" count_431); ino=$(sget "${base}" inode)
    # 轮转产物：最旧在前（*.2.gz/*.2 → *.1.gz/*.1）
    for f in "$base.2.gz" "$base.2" "$base.1.gz" "$base.1"; do
      [ -f "$f" ] || continue
      key=${f%.gz}
      if [ -z "${RO[$key]:-}" ]; then
        fi=$(stat -c %i "$f" 2>/dev/null || echo 0)
        if [ "$fi" = "$ino" ]; then off=$off   # 轮转前的"当前文件"→ 以源 offset 续读（不丢不重）
        else off=0; fi                         # 未知产物：从头（其内容未被计数过）
        RI["$key"]=$fi; RO["$key"]=0
      fi
      n=$(stream_count "$f" "$fmt" "${RO[$key]}") || rc=1
      cnt=$(( cnt + n ))
      tot_art=$(( RO[$key] + $(stat -c %s "$f") ))
      RO["$key"]=$(( RO[$key] + $(zcat -f "$f" 2>/dev/null | wc -c) ))
    done
    # 当前文件
    if [ -f "$base" ]; then
      fi=$(stat -c '%i %s' "$base"); in=${fi%% *}; sz=${fi##* }
      if [ "$in" = "$ino" ]; then
        [ "$sz" -lt "${off:-0}" ] && off=0     # truncate：从 0 重读，已计不重
      else
        off=0; ino=$in                          # 新文件（轮转/重建）
      fi
      n=$(stream_count "$base" "$fmt" "${off:-0}") || rc=1
      cnt=$(( cnt + n )); off=$(( ${off:-0} + $(tail -c "+$(( ${off:-0} + 1 ))" "$base" 2>/dev/null | wc -c) ))
    fi
    NKEY="${base//\//\\/}"
    printf -v SJ '%s "%s":{"inode":%d,"offset":%d,"count_431":%d},' "$SJ" "$base" "$ino" "$off" "$cnt"
  done
  RJSON=""
  for k in "${!RO[@]}"; do printf -v RJSON '%s"%s":{"inode":%d,"offset":%d},' "$RJSON" "$k" "${RI[$k]}" "${RO[$k]}"; done
  RJSON=${RJSON%,}
  SJ=${SJ%,}
  { printf '{"version":1,"window":%d,"sources":{%s},"rotated":{%s}}\n' "$WINDOW" "${SJ:-}" "$RJSON" > "$tmp"; } && mv -f "$tmp" "$STATE" || rc=1
  return $rc
}

case "$MODE" in
  check)  check_mode; exit $? ;;
  replay) [ -n "$BENCH_FILE" ] && { [ -f "$BENCH_FILE" ] || exit 3; n=$(stream_count "$BENCH_FILE" access 0); echo "[quality-gate] bench: 窗口内 431 = $n"; exit 0; }
          replay_mode; exit $? ;;
esac
GEOF
chmod 0755 "$OPS_DIR/quality_gate.sh"

# ---------- 步骤⑧：清理历史日志 ----------
say "步骤⑧：清理历史日志（预警由后端观测中间件在请求时同步写入 warnings.log）"
for lg in $NG_LOGS "$OPS_DIR/app.log" /var/log/backend.log; do
  case "$lg" in /*) [ -f "$lg" ] && : > "$lg" ;; esac
done
nginx -s reopen 2>/dev/null || true
: > "$OPS_DIR/warnings.log" 2>/dev/null || true

# ---------- 步骤⑨：超长 header 端到端验证 + 门禁 ----------
say "步骤⑨：超长 header 端到端验证"
BASELINE="$(probe "$ENTRY_URL" "")"
FINAL="$(probe "$ENTRY_URL" "$TEST_HEADER_BYTES")"
if [ -n "$UPSTREAM_URL" ]; then DIRECT="$(probe "$UPSTREAM_URL" "$TEST_HEADER_BYTES")"; fi
say "常规请求(入口)      : ${BASELINE:-无响应}"
say "超长header(入口)    : ${FINAL:-无响应}  （修复前=${INITIAL} / L1后=${AFTER_NGINX}）"
say "超长header(直达后端): ${DIRECT:-跳过}"

# 全链路（edge→mesh→nginx→后端）验证：G 矩阵（16384 探针 + 120×100B 计数探针）
EDGE_URL="http://127.0.0.1:8080/api/v1/profile"
EDGE_FINAL="$(probe "$EDGE_URL" "$TEST_HEADER_BYTES")"
CNT_ARGS=""; for n in $(seq 0 119); do CNT_ARGS="$CNT_ARGS -H X-Vrf-Cnt-$n:$(printf 'c%.0s' $(seq 1 100))"; done
EDGE_COUNT="$(curl ${CURL_TLS:+"$CURL_TLS"} -s -o /dev/null -w '%{http_code}' --max-time 15 $CNT_ARGS "$EDGE_URL" 2>/dev/null)"
say "超长header(全链路 edge 链): ${EDGE_FINAL:-无响应}（mesh 注入 ~8KiB 计入 nginx 视野）"
say "计数探针(全链路 120×100B)  : ${EDGE_COUNT:-无响应}（mesh max_headers_count 须 ≥120）"

PASS=1
case "$BASELINE" in ""|000) PASS=0;; esac
case "$FINAL"   in ""|000|431|414|5??) PASS=0;; esac
[ -n "$BASELINE" ] && [ "$BASELINE" != "$FINAL" ] && PASS=0
case "$DIRECT"  in 431|414|000) PASS=0;; esac
case "$EDGE_FINAL" in 200) : ;; *) PASS=0;; esac   # 全链路须 200（400=某层仍拒，431=网格层未扩容）
case "$EDGE_COUNT" in 200) : ;; *) PASS=0;; esac

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
# 入口实测必须取 16384B 复现探针的 request_length：报告前补发一枚该规格探针再取 hdrsize
# 末行（直接取末行会读到预警观测探针 ~90% 阈值体量的记录，实测口径错位）
_p="$(head -c "$TEST_HEADER_BYTES" /dev/zero | tr '\0' 'x')"
curl ${CURL_TLS:+"$CURL_TLS"} -s -o /dev/null --max-time 15 -H "X-Debug-Trace: $_p" "$ENTRY_URL" 2>/dev/null || true
sleep 1
ENTRY_LEN="$(tail -n1 /var/log/nginx/hdrsize.log 2>/dev/null | awk '{print $3}')"
[ -n "$ENTRY_LEN" ] && ENTRY_LEN="${ENTRY_LEN}B" || ENTRY_LEN="N/A"

case "${APP_KIND}" in
  fiber)    APP_LABEL="Go 后端（fiber 框架）";    L2_KEY="ReadBufferSize";;
  fasthttp) APP_LABEL="Go 后端（fasthttp 框架）"; L2_KEY="ReadBufferSize";;
  nethttp)  APP_LABEL="Go 后端（net/http 框架）"; L2_KEY="MaxHeaderBytes";;
  *)        APP_LABEL="Go 后端";                 L2_KEY="header 限额";;
esac

ROW_QUOTA=""
if [ "$QUOTA_APPLIED" = "1" ]; then
  ROW_QUOTA="| L2 | ${APP_LABEL}（业务配额中间件，启动时从配置加载） | max_header_bytes | ${QUOTA_BEFORE:-?} | ${APP_QUOTA_MAX} |"
fi
ROW_MESH="| G | mesh-sim（服务网格语义模拟，Envoy 风格字段） | max_request_headers_kb / max_headers_count | ${MESH_BEFORE:-60 / 100（默认）} | ${MESH_TOTAL_KB:-N/A} / ${MESH_COUNT:-N/A} |"
ROW_EDGE="| G | edge-sim（云 LB/CDN 语义模拟） | 单 header 值/请求行/头总量 | 硬限制 16KiB / 16KiB / 64KiB | **不可配置**（超限恒 400，非 431） |"

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
- 状态码链：修复前=${INITIAL} → 仅修 L1(nginx) 后=${AFTER_NGINX} → L1+L2 修复后=${FINAL}（常规请求=${BASELINE}）
- 层面现象：实测 nginx 1.22 对超长 header 行返回 400 "Request Header Or Cookie Too Large"（info 级日志，默认 error 级 error.log 无记录）；431 由后端框架返回，入口观察到的 431 是后端拦截的透传结果

## 2. 链路阈值对照（哪一侧限制过小）
| 层 | 模块 | 限制项 | 修改前 | 修改后 |
|---|------|--------|--------|--------|
| L1 | nginx（入口反代） | client_header_buffer_size | ${NG_CHB_BEFORE} | ${NG_CHB_KB}k |
| L1 | nginx（入口反代） | large_client_header_buffers | ${NG_BUF_BEFORE} | ${NG_BUF_N} ${NG_BUF_KB}k |
| L2 | ${APP_LABEL} | ${L2_KEY} | ${APP_LIMIT_BEFORE} | ${APPLIED_APP_LIMIT} |
${ROW_QUOTA}
${ROW_MESH}
${ROW_EDGE}

结论：修复前 nginx 与后端两层阈值均低于上游注入的 header 体量（复现探针 ${TEST_HEADER_BYTES}B），属多模块限制过小。

## 3. Header 体量归因（谁注入过多）
${ATTR_DETAIL}
- 入口实测（nginx \$request_length）：${ENTRY_LEN}

## 4. 结论（综合分析）
1. 431 = 上游模块注入的 header 体量增长 × 链路两侧阈值（nginx 缓冲、后端框架限制）未同步扩容的综合结果；
2. 仅修 L1 后入口仍为 ${AFTER_NGINX}（见状态码链），证明单点修复不充分，必须端到端协同治理；
3. 修复后余量：nginx 单行上限 $(( NG_BUF_KB * 1024 ))B、后端 ${APPLIED_APP_LIMIT}B，均远高于实测体量；
4. 持续防线：${WARN_RATIO}% 阈值预警 watchdog → warnings.log（431 触发前感知）；quality_gate.sh 对 431 高优先级拦截（exit 2）；阈值单一事实来源 header_limits.env。
5. 多节点语义（edge/mesh）：mesh 每请求注入 ~8KiB span 上下文（不可关闭）——全链路有效容量 = nginx 单缓冲 − 注入 − 行开销，容量评估计入注入体量；edge 为云 LB 硬限（单头 16KiB/总量 64KiB → 恒 400），错误码语义必须区分：400 = ALB 硬限、431 = 网格/后端语义拒绝；mesh 计数维度（max_headers_count）与字节数独立，120×100B 请求仅 ~14K 也会被计数拒绝。

## 5. 证据与产物
- 复验记录：/app/ops/last_solve_result.txt
- nginx 配置：/etc/nginx/nginx.conf（*.solve.bak 为修改前备份）
- 后端模块：${MOD_DIR}（${L2_KEY} 见 ${WIRE_FILE##*/}）
EOF
say "报告: $REPORT"

cat > "$OPS_DIR/last_solve_result.txt" <<EOF
time=$(date '+%F %T')
initial_status=${INITIAL}
after_nginx_status=${AFTER_NGINX}
baseline_status=${BASELINE}
final_status=${FINAL}
direct_status=${DIRECT}
app_max_header_bytes=${APPLIED_APP_LIMIT}
nginx_large_header_buffers=${NG_BUF_N}x$(( NG_BUF_KB * 1024 ))B
mesh_limits=${MESH_TOTAL_KB:-NA}KB/${MESH_COUNT:-NA}count
edge_final=${EDGE_FINAL:-NA}
edge_count=${EDGE_COUNT:-NA}
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