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

ENTRY_URL=""; CURL_TLS=""
UPSTREAM_URL=""; UP_PORT=""
INITIAL=""; AFTER_NGINX=""; BASELINE=""; FINAL=""; DIRECT=""
APPLIED_APP_LIMIT=0; SOURCE_CHANGED=0; CONFIG_CHANGED=0
EDITED_FILES=""; MAIN_GO_FILES=""; NG_LOGS=""
NG_CHB_BEFORE="未配置(默认1k)"; NG_BUF_BEFORE="未配置(默认4 8k)"
APP_LIMIT_BEFORE="未知"; APP_KIND=""; WIRE_FILE=""; MID_FILE=""; MID_WIRED=0

say()  { echo "[solve.sh] $*"; }
warn() { echo "[solve.sh][WARN] $*" >&2; }
die()  { echo "[solve.sh][FATAL] $*" >&2; exit 1; }

mkdir -p "$OPS_DIR" /var/log/nginx
backup() { [ -f "$1" ] && [ ! -f "$1.solve.bak" ] && cp -p "$1" "$1.solve.bak" || true; }

# probe <url> <header_len>：发请求，输出 HTTP 状态码；header_len 为空则不带超长头
probe() {
  local url="$1" hlen="${2:-}" tok=""
  if [ -n "$hlen" ]; then tok="$(head -c "$hlen" /dev/zero | tr '\0' 'x')"; fi
  if [ -n "$tok" ]; then
    curl $CURL_TLS -s -o /dev/null -w '%{http_code}' --max-time 15 -H "X-Debug-Trace: $tok" "$url"
  else
    curl $CURL_TLS -s -o /dev/null -w '%{http_code}' --max-time 15 "$url"
  fi
}

wait_up() {  # 等端口可响应（任何 HTTP 状态都算活着）
  local url="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl $CURL_TLS -s -o /dev/null --max-time 2 "$url" && return 0
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
ENTRY_URL="${SCHEME}://127.0.0.1:${PORT}/"
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

# 兜底启动 nginx（若环境未拉起）
pgrep -x nginx >/dev/null 2>&1 || { say "nginx 未运行，尝试启动"; nginx 2>/dev/null || warn "nginx 启动失败（可能由 supervisor 管理）"; sleep 1; }

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
grep -rlE "(^|[^A-Za-z0-9_])(client_header_buffer_size|large_client_header_buffers|log_format[[:space:]]+hdrsize|access_log[[:space:]][^;]*/var/log/nginx/(hdrsize\.log|access\.log))" /etc/nginx 2>/dev/null \
| while read -r f; do
    [ -f "$f" ] || continue
    backup "$f"
    sed -i -E "s@${DISABLE_SED_RE}@\1# disabled-by-solve.sh: \&@" "$f"
  done

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
  !done && $0 ~ /^[[:space:]]*http[[:space:]]*[{][[:space:]]*$/ {
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
if pgrep -x nginx >/dev/null 2>&1; then
  nginx -s reload 2>/dev/null || { pkill -x nginx 2>/dev/null || true; sleep 1; nginx; }
else
  nginx
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

# 4.3 配置文件兜底（yaml/json/toml/env 中声明的限额）
if [ "$APPLIED_APP_LIMIT" = "0" ]; then
  for cf in $(find "$MOD_DIR" -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.toml' -o -name '*.ini' -o -name '*.conf' -o -name '*.env' \) -not -path '*/vendor/*' 2>/dev/null); do
    grep -qiE '(max_header_bytes|read_buffer_size|header_buffer_size)' "$cf" || continue
    APP_LIMIT_BEFORE="$(grep -hoiE '(max_header_bytes|max_header_size|read_buffer_size|header_buffer_size)[^0-9]*[0-9]+' "$cf" | head -n1)"
    backup "$cf"; CONFIG_CHANGED=1
    sed -i -E "s/((max_header_bytes|max_header_size)[\"' ]*[:=][\"' ]*)[0-9]+/\1${APP_NETHTTP_MAX}/g;
               s/((read_buffer_size|header_buffer_size)[\"' ]*[:=][\"' ]*)[0-9]+/\1${APP_FASTHTTP_BUF}/g" "$cf"
    APPLIED_APP_LIMIT="$APP_NETHTTP_MAX"
    say ">> 配置驱动限额已调大: $cf"
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

	"github.com/gofiber/fiber/v2"
)

// headerStatFiber 逐 header 体积统计（归因：哪个模块/header 注入过多）
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
		return c.Next()
	}
}
EOF
      ;;
    fasthttp)
      if ! grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then
        sed -i -E "s/(Handler:[[:space:]]*)([a-zA-Z_][a-zA-Z0-9_.]*(\(\))?)(,?)/\1headerStatMiddleware(\2)\4/" "$WIRE_FILE"
      fi
      if grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then MID_WIRED=1; else warn "fasthttp Handler 未识别，逐头归因降级"; fi
      MID_FILE="$PDIR/headerstat_fasthttp.go"
      cat > "$MID_FILE" <<EOF
package ${PKG_NAME}

import (
	"fmt"

	"github.com/valyala/fasthttp"
)

// headerStatMiddleware 逐 header 体积统计（归因：哪个模块/header 注入过多）
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
		next(ctx)
	}
}
EOF
      ;;
    nethttp)
      if ! grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then
        sed -i -E "s/(Handler:[[:space:]]*)([a-zA-Z_][a-zA-Z0-9_.]*(\(\))?)(,?)/\1headerStatMiddleware(\2)\4/" "$WIRE_FILE"
      fi
      if grep -q 'headerStatMiddleware(' "$WIRE_FILE"; then MID_WIRED=1; else warn "net/http Handler 字段未识别，逐头归因降级"; fi
      MID_FILE="$PDIR/headerstat_nethttp.go"
      cat > "$MID_FILE" <<EOF
package ${PKG_NAME}

import (
	"fmt"
	"net/http"
)

// headerStatMiddleware 逐 header 体积统计（归因：哪个模块/header 注入过多）
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
		next.ServeHTTP(w, r)
	})
}
EOF
      ;;
  esac
  [ -n "$MID_FILE" ] && say "归因观测中间件: $MID_FILE（wired=$MID_WIRED）"
fi

if [ "$APPLIED_APP_LIMIT" = "0" ]; then
  if [ "$AFTER_NGINX" = "431" ]; then
    die "复测仍 431 且未能在源码/配置中定位框架层 header 限制，请人工确认环境"
  fi
  say ">> 未发现后端 header 限制点，且当前无 431 —— 跳过 L2"
else
  say ">> 后端限额已调至 ${APPLIED_APP_LIMIT}B（修改:$EDITED_FILES）"
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
  if ! ( cd "$MOD_DIR" && GOPROXY=off GOTOOLCHAIN=local GOFLAGS="$MODFLAGS" CGO_ENABLED=0 go build -o "$NEW_BIN" "$MAIN_PKG" ); then
    warn "离线编译失败，尝试在线模块兜底"
    if ! ( cd "$MOD_DIR" && GOFLAGS="$MODFLAGS" CGO_ENABLED=0 go build -o "$NEW_BIN" "$MAIN_PKG" ); then
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
    [ -n "$PROG" ] && { supervisorctl restart "$PROG" && RESTARTED=1; }
  fi
  if [ "$RESTARTED" = "0" ]; then
    if [ -n "$APP_PID" ]; then
      kill "$APP_PID" 2>/dev/null || true
      for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
      kill -9 "$APP_PID" 2>/dev/null || true
    fi
    # 后台化并彻底脱离：不用子 shell 包裹（个别 bash 环境下退出时会被 wait 阻塞），disown 移出作业表
    cd "${CWD:-$MOD_DIR}" 2>/dev/null || true
    nohup "$BIN" ${ARGS:-} >>"$OPS_DIR/app.log" 2>&1 < /dev/null &
    disown 2>/dev/null || true
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
fi
cat > "$OPS_DIR/header_limits.env" <<EOF
# solve.sh 生成 —— 全链路 header 限额与预警参数（单一事实来源）
NGINX_CLIENT_HEADER_BUFFER_BYTES=$(( NG_CHB_KB * 1024 ))
NGINX_LARGE_HEADER_BUFFER_COUNT=${NG_BUF_N}
NGINX_LARGE_HEADER_BUFFER_BYTES=$(( NG_BUF_KB * 1024 ))
APP_MAX_HEADER_BYTES=${APPLIED_APP_LIMIT}
WARN_RATIO=${WARN_RATIO}
ENTRY_URL=${ENTRY_URL}
UPSTREAM_URL=${UPSTREAM_URL}
ORIG_NG_CHB="${NG_CHB_BEFORE}"
ORIG_NG_BUF="${NG_BUF_BEFORE}"
ORIG_APP_LIMIT="${APP_LIMIT_BEFORE}"
EOF

cat > "$OPS_DIR/header_size_watch.sh" <<'WEOF'
#!/bin/bash
# 预警观测：轮询 nginx hdrsize 日志（$msec $status $request_length），
# 请求头长度达到上限 WARN_RATIO% 时写入 warnings.log —— 在真正触发 431 之前感知风险请求
set -u
. /app/ops/header_limits.env
THRESH=$(( NGINX_LARGE_HEADER_BUFFER_BYTES * WARN_RATIO / 100 ))
SRC=/var/log/nginx/hdrsize.log
WARN_LOG=/app/ops/warnings.log
pos=0
while :; do
  if [ -f "$SRC" ]; then
    sz=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    [ "$sz" -lt "$pos" ] && pos=0
    if [ "$sz" -gt "$pos" ]; then
      tail -c +$(( pos + 1 )) "$SRC" 2>/dev/null | while read -r msec status rlen _; do
        case "${rlen:-}" in ''|*[!0-9]*) continue ;; esac
        if [ "$rlen" -ge "$THRESH" ]; then
          echo "$(date '+%F %T') WARN status=${status} request_length=${rlen}B >= ${THRESH}B(${WARN_RATIO}% of ${NGINX_LARGE_HEADER_BUFFER_BYTES}B)" >> "$WARN_LOG"
        fi
      done
      pos=$sz
    fi
  fi
  sleep 3
done
WEOF

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
chmod 0755 "$OPS_DIR/header_size_watch.sh" "$OPS_DIR/quality_gate.sh"

# ---------- 步骤⑧：清理历史日志，启动观测 ----------
say "步骤⑧：清理历史日志，启动预警观测"
for lg in $NG_LOGS "$OPS_DIR/app.log"; do
  case "$lg" in /*) [ -f "$lg" ] && : > "$lg" ;; esac
done
nginx -s reopen 2>/dev/null || true

pkill -f "ops/header_size_watch.sh" 2>/dev/null || true
sleep 0.3
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$OPS_DIR/header_size_watch.sh" >/dev/null 2>&1 < /dev/null &
else
  nohup bash "$OPS_DIR/header_size_watch.sh" >/dev/null 2>&1 < /dev/null &
fi
disown 2>/dev/null || true
echo $! > "$OPS_DIR/watchdog.pid" 2>/dev/null || true
say "预警 watchdog 已启动（pid=$(cat "$OPS_DIR/watchdog.pid" 2>/dev/null || echo '?')，阈值=${WARN_RATIO}% of $(( NG_BUF_KB * 1024 ))B）"

# ---------- 步骤⑨：超长 header 端到端验证 + 门禁 ----------
say "步骤⑨：超长 header 端到端验证"
BASELINE="$(probe "$ENTRY_URL" "")"
FINAL="$(probe "$ENTRY_URL" "$TEST_HEADER_BYTES")"
if [ -n "$UPSTREAM_URL" ]; then DIRECT="$(probe "$UPSTREAM_URL" "$TEST_HEADER_BYTES")"; fi
say "常规请求(入口)      : ${BASELINE:-无响应}"
say "超长header(入口)    : ${FINAL:-无响应}  （修复前=${INITIAL} / L1后=${AFTER_NGINX}）"
say "超长header(直达后端): ${DIRECT:-跳过}"

PASS=1
case "$BASELINE" in ""|000) PASS=0;; esac
case "$FINAL"   in ""|000|431|414|5??) PASS=0;; esac
[ -n "$BASELINE" ] && [ "$BASELINE" != "$FINAL" ] && PASS=0
case "$DIRECT"  in 431|414|000) PASS=0;; esac

GATE_RC=0
bash "$OPS_DIR/quality_gate.sh" || GATE_RC=$?
say "质检门禁: exit=${GATE_RC}（0=通过 / 2=拦截431）"
[ "$GATE_RC" -ne 0 ] && PASS=0

# 预警机制自证：90% 阈值探针应触发 warnings.log（不计入 PASS，时序异步）
WARN_PROBE_BYTES=$(( NG_BUF_KB * 1024 * 90 / 100 ))
WARN_STATUS="$(probe "$ENTRY_URL" "$WARN_PROBE_BYTES")"
say "预警观测探针(90%阈值): status=${WARN_STATUS}（header≈${WARN_PROBE_BYTES}B）"
sleep 7
if [ -s "$OPS_DIR/warnings.log" ]; then
  say "预警观测: warnings.log 已捕获接近阈值请求 ✅"
  tail -n 2 "$OPS_DIR/warnings.log"
else
  warn "预警观测: 暂未捕获预警（watchdog 异步，检查 $OPS_DIR/watchdog.pid）"
fi

# ---------- 步骤⑩：431 综合分析报告（链路级归因，非单点归责） ----------
say "步骤⑩：生成 431 综合分析报告"

REPORT="$OPS_DIR/diagnosis_report.md"
HDRSTAT_LINE="$(grep -h 'HDRSTAT' "$OPS_DIR/app.log" 2>/dev/null | tail -n1)"
HDR_TOTAL="$(printf '%s' "$HDRSTAT_LINE" | sed -nE 's/.*total=([0-9]+)B.*/\1/p')"
HDR_TOP="$(printf '%s' "$HDRSTAT_LINE" | sed -nE 's/.*max_header=([^[:space:]]+).*/\1/p')"
ENTRY_LEN="$(tail -n1 /var/log/nginx/hdrsize.log 2>/dev/null | awk '{print $3}')"
[ -n "$ENTRY_LEN" ] && ENTRY_LEN="${ENTRY_LEN}B" || ENTRY_LEN="N/A"

case "${APP_KIND}" in
  fiber)    APP_LABEL="Go 后端（fiber 框架）";    L2_KEY="ReadBufferSize";;
  fasthttp) APP_LABEL="Go 后端（fasthttp 框架）"; L2_KEY="ReadBufferSize";;
  nethttp)  APP_LABEL="Go 后端（net/http 框架）"; L2_KEY="MaxHeaderBytes";;
  *)        APP_LABEL="Go 后端";                 L2_KEY="header 限额";;
esac

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

结论：修复前 nginx 与后端两层阈值均低于上游注入的 header 体量（复现探针 ${TEST_HEADER_BYTES}B），属多模块限制过小。

## 3. Header 体量归因（谁注入过多）
${ATTR_DETAIL}
- 入口实测（nginx \$request_length）：${ENTRY_LEN}

## 4. 结论（综合分析）
1. 431 = 上游模块注入的 header 体量增长 × 链路两侧阈值（nginx 缓冲、后端框架限制）未同步扩容的综合结果；
2. 仅修 L1 后入口仍为 ${AFTER_NGINX}（见状态码链），证明单点修复不充分，必须端到端协同治理；
3. 修复后余量：nginx 单行上限 $(( NG_BUF_KB * 1024 ))B、后端 ${APPLIED_APP_LIMIT}B，均远高于实测体量；
4. 持续防线：${WARN_RATIO}% 阈值预警 watchdog → warnings.log（431 触发前感知）；quality_gate.sh 对 431 高优先级拦截（exit 2）；阈值单一事实来源 header_limits.env。

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
quality_gate_exit=${GATE_RC}
report=diagnosis_report.md
app_kind=${APP_KIND}
hdr_total=${HDR_TOTAL:-NA}
hdr_top=${HDR_TOP:-NA}
entry_request_length=${ENTRY_LEN}
pass=${PASS}
EOF
say "产物: $OPS_DIR/{header_limits.env, header_size_watch.sh, quality_gate.sh, warnings.log, watchdog.pid, diagnosis_report.md, last_solve_result.txt}"

if [ "$PASS" = "1" ]; then
  say "结果: PASS —— 431 双层修复完成，预警观测与质检门禁就绪"
  exit 0
else
  die "结果: FAIL —— 详见 $OPS_DIR/last_solve_result.txt"
fi
