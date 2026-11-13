FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
# 历史环境变量
ENV MAX_HEADER_KB=64

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx golang-go curl vim less procps supervisor logrotate strace \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app /logs/verifier /var/log/nginx /var/log/supervisor /app/ops

# 环境版本戳：验题日志读取它以自证环境镜像未被平台缓存复用（换版本时同步改 v 标记）
RUN echo "task431-env v5-multinode $(date -u +%FT%TZ)" > /app/.task_build_stamp

# Go 后端源码（含故障：业务配额限额过小 + 标准库限额与 Trace 体量"对齐"），预编译可运行二进制
COPY backend /app/backend
RUN cd /app/backend && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o backend .

# 门禁 HTTP shim（/via-gate 的 auth_request 预检后端；重逻辑在 /app/ops/quality_gate.sh，由解题者提供）
COPY gate-shim /opt/gate-shim
RUN cd /opt/gate-shim && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o /usr/local/bin/gate-shim . \
    && rm -rf /opt/gate-shim

# 跨层矩阵节点：edge-sim（云 LB/CDN 语义，ALB 硬限制，恒 400，不可配置）与
# mesh-sim（Envoy 语义：max_request_headers_kb / max_headers_count 可配置限额，
# 每请求注入 ~8KiB span 上下文；配置落盘 /etc/mesh-sim/config.yaml，修改后须重启生效）
COPY edge-sim /opt/edge-sim
RUN cd /opt/edge-sim && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o /usr/local/bin/edge-sim . \
    && rm -rf /opt/edge-sim
COPY mesh-sim /opt/mesh-sim
RUN mkdir -p /etc/mesh-sim \
    && cd /opt/mesh-sim && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o /usr/local/bin/mesh-sim . \
    && mv /opt/mesh-sim/config.yaml /etc/mesh-sim/config.yaml && rm -rf /opt/mesh-sim

# nginx 站点配置（故障：未显式配置 header 缓冲；含 L3 跨层矩阵路由 /direct /via-backend /via-gate）
COPY nginx/app.conf /etc/nginx/conf.d/app.conf
RUN rm -f /etc/nginx/sites-enabled/default

# logrotate 规则（C：rename 轮转 → *.1 → *.2，gzip 由验题/运维触发；不带 compress，USRT reopen 交 postrotate）
COPY logrotate-app.conf /etc/logrotate.d/app
RUN chmod 0644 /etc/logrotate.d/app

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
