FROM talents-ai-env:tmux
ENV DEBIAN_FRONTEND=noninteractive MAX_HEADER_KB=64 HEADER_LIMIT_PROFILE=prod KAFKA_VERSION=3.7.2
# 复用已安装的系统依赖与 Kafka 3.7.2，重建当前题包全部源码和初始配置。
RUN test -f /opt/kafka/libs/kafka_2.13-3.7.2.jar \
    && dpkg-query -W nginx golang-go curl vim less procps supervisor openjdk-17-jre-headless \
    && rm -rf /app/backend /app/tracegate /app/mesh /app/ops /app/tools /var/lib/kafka/data \
    && rm -f /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/default /etc/supervisor/conf.d/*.conf \
    && mkdir -p /app /logs/verifier /var/log/nginx /var/log/supervisor /var/lib/kafka/data
COPY backend /app/backend
RUN cd /app/backend && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o backend .
COPY tracegate /app/tracegate
RUN cd /app/tracegate && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o tracegate .
COPY mesh /app/mesh
RUN cd /app/mesh && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o meshd .
COPY kafka/server.properties /opt/kafka/config/kraft/server.properties
RUN /opt/kafka/bin/kafka-storage.sh format -t 4L6g3nShT-eMCtK--X-Xsw -c /opt/kafka/config/kraft/server.properties --ignore-formatted
COPY kafka/start_kafka.sh /opt/kafka/start_kafka.sh
RUN chmod 0755 /opt/kafka/start_kafka.sh
COPY nginx/app.conf /etc/nginx/conf.d/app.conf
COPY nginx/admin.conf /etc/nginx/conf.d/admin.conf
COPY nginx/headers.conf /etc/nginx/snippets/headers.conf
RUN sed -i 's#error_log /var/log/nginx/error.log;#error_log /var/log/nginx/error.log info;#' /etc/nginx/nginx.conf
RUN mkdir -p /app/ops/repro /app/ops/fix /app/ops/evidence
COPY ops-template/. /app/ops/
RUN chmod 0644 /app/ops/diagnosis_report.md /app/ops/README.md && chmod 0755 /app/ops/repro /app/ops/fix /app/ops/evidence
COPY tools/ /app/tools/
RUN chmod 0755 /app/tools/*.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh
COPY supervisor-app.conf /etc/supervisor/conf.d/app.conf
WORKDIR /app
EXPOSE 80
ENTRYPOINT ["/app/entrypoint.sh"]
