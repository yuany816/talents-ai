FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx golang-go curl vim less procps \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app /logs/verifier /var/log/nginx

# Go 后端源码（含故障：框架层 header 限制过小），并预编译出可运行二进制
COPY backend /app/backend
RUN cd /app/backend && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o backend .

# nginx 站点配置（故障：未显式配置 header 缓冲，默认 1k / 4 8k）
COPY nginx/app.conf /etc/nginx/conf.d/app.conf
RUN rm -f /etc/nginx/sites-enabled/default

# error log 提到 info 级：header 超限证据（client sent too long header line）可见，供排查定位
RUN sed -i 's#error_log /var/log/nginx/error.log;#error_log /var/log/nginx/error.log info;#' /etc/nginx/nginx.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app
EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
