FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
# 历史环境变量
ENV MAX_HEADER_KB=64
# 配额 profile 选择器（v1 规划项，仅供启动日志展示，见 backend/internal/config 说明）
ENV HEADER_LIMIT_PROFILE=prod

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx golang-go curl vim less procps supervisor openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app /logs/verifier /var/log/nginx /var/log/supervisor /var/lib/kafka/data

# Go 后端源码（多包布局，含退役入口存档与配置档案），并预编译出可运行二进制
# （配额配置经 //go:embed 随构建固化进二进制，见 /app/backend/internal/config）
COPY backend /app/backend
RUN cd /app/backend && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o backend .

# NG 插件进程（tracegate：接入网关 trace 插件，header 预算见 tracegate.yaml）
COPY tracegate /app/tracegate
RUN cd /app/tracegate && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o tracegate .

# mesh 数据面 sidecar（meshd：随业务实例部署，限额见 sidecar.yaml）
COPY mesh /app/mesh
RUN cd /app/mesh && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o meshd .

# Kafka（KRaft 单节点，异步链路审计总线）：构建期下载 + sha512 校验 + 解包 + 预格式化存储
ENV KAFKA_VERSION=3.7.2
RUN set -eux; \
    curl -fsSL --retry 3 --connect-timeout 30 -o /tmp/kafka.tgz \
      "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz"; \
    curl -fsSL --retry 3 --connect-timeout 30 -o /tmp/kafka.tgz.sha512 \
      "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz.sha512"; \
    expect="$(awk 'NR==1{sub(/^[^:]*:/,"")} {gsub(/[[:space:]]/,""); printf "%s",$0}' /tmp/kafka.tgz.sha512 | tr 'A-F' 'a-f')"; \
    actual="$(sha512sum /tmp/kafka.tgz | awk '{print $1}')"; \
    [ -n "$expect" ] && [ "$expect" = "$actual" ]; \
    mkdir -p /opt/kafka; \
    tar -xzf /tmp/kafka.tgz --strip-components=1 -C /opt/kafka; \
    rm -f /tmp/kafka.tgz /tmp/kafka.tgz.sha512

COPY kafka/server.properties /opt/kafka/config/kraft/server.properties
RUN /opt/kafka/bin/kafka-storage.sh format \
      -t 4L6g3nShT-eMCtK--X-Xsw \
      -c /opt/kafka/config/kraft/server.properties --ignore-formatted

COPY kafka/start_kafka.sh /opt/kafka/start_kafka.sh
RUN chmod 0755 /opt/kafka/start_kafka.sh

# nginx 站点配置与 header 缓冲调优 snippet（GW-1187 专项变更引入 include）
COPY nginx/app.conf /etc/nginx/conf.d/app.conf
COPY nginx/headers.conf /etc/nginx/snippets/headers.conf
RUN rm -f /etc/nginx/sites-enabled/default

# error log 提到 info 级：header 超限证据（client sent too long header line）可见，供排查定位
RUN sed -i 's#error_log /var/log/nginx/error.log;#error_log /var/log/nginx/error.log info;#' /etc/nginx/nginx.conf

# 独立判分交付 scaffolding：预创建交付目录（含 evidence/），预置四产物空模板
# （header_limits.env / quality_gate.sh(644 不可执行) / diagnosis_report.md / README.md，
# 内容为注释示例，不计分），并内置证据采集脚本 /app/collect_evidence.sh（题面 README 说明用法）
RUN mkdir -p /app/ops/evidence
COPY ops-template/. /app/ops/
RUN chmod 0644 /app/ops/header_limits.env /app/ops/quality_gate.sh \
               /app/ops/diagnosis_report.md /app/ops/README.md \
    && chmod 0755 /app/ops/evidence
COPY collect_evidence.sh /app/collect_evidence.sh
RUN chmod 0755 /app/collect_evidence.sh

# 服务编排：容器主进程 = supervisord（前台驻留 + autorestart 守护），
# 不使用自制启动脚本（避免非终止脚本/常驻进程扫描风险）
COPY supervisor-app.conf /etc/supervisor/conf.d/app.conf

WORKDIR /app
EXPOSE 80
# Harbor 的 compose 运行时会向 ENTRYPOINT 追加 keepalive command；
# supervisord 不接受位置参数（追加即 exit 2），故用 bash -c 固定脚本形态忽略追加参数。
ENTRYPOINT ["/bin/bash", "-c", "exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf"]
