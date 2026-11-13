FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
# 历史环境变量
ENV MAX_HEADER_KB=64

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx golang-go curl vim less procps supervisor \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app /logs/verifier /var/log/nginx /var/log/supervisor

# 环境版本戳：验题日志读取它以自证环境镜像未被平台缓存复用（换版本时同步改 v 标记）
RUN echo "task431-env v3 $(date -u +%FT%TZ)" > /app/.task_build_stamp

# Go 后端源码（含故障：业务配额限额过小），并预编译出可运行二进制
COPY backend /app/backend
RUN cd /app/backend && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o backend .

# nginx 站点配置（故障：未显式配置 header 缓冲，默认 1k / 4 8k）
COPY nginx/app.conf /etc/nginx/conf.d/app.conf
RUN rm -f /etc/nginx/sites-enabled/default

# error log 提到 info 级：header 超限证据（client sent too long header line）可见，供排查定位
RUN sed -i 's#error_log /var/log/nginx/error.log;#error_log /var/log/nginx/error.log info;#' /etc/nginx/nginx.conf

# 服务编排：容器主进程 = supervisord（前台驻留 + autorestart 守护），
# 不使用自制启动脚本（避免非终止脚本/常驻进程扫描风险）
COPY supervisor-app.conf /etc/supervisor/conf.d/app.conf

WORKDIR /app
EXPOSE 80
# Harbor 的 compose 运行时会向 ENTRYPOINT 追加 keepalive command；
# supervisord 不接受位置参数（追加即 exit 2），故用 bash -c 固定脚本形态忽略追加参数。
ENTRYPOINT ["/bin/bash", "-c", "exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf"]
