FROM talents-ai-env:tmux
ENV DEBIAN_FRONTEND=noninteractive
ENV MAX_HEADER_KB=64
ENV HEADER_LIMIT_PROFILE=prod

RUN mkdir -p /app /logs/verifier /var/log/nginx /var/log/supervisor /var/lib/kafka/data

# Go 后端源码更新并重新编译
COPY backend /app/backend
RUN cd /app/backend && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o backend .

# tracegate 更新并重新编译
COPY tracegate /app/tracegate
RUN cd /app/tracegate && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o tracegate .

# meshd 更新并重新编译
COPY mesh /app/mesh
RUN cd /app/mesh && GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0 go build -o meshd .

# kafka 配置更新（Kafka 已在基础镜像中安装于 /opt/kafka）
COPY kafka/server.properties /opt/kafka/config/kraft/server.properties
COPY kafka/start_kafka.sh /opt/kafka/start_kafka.sh
RUN chmod 0755 /opt/kafka/start_kafka.sh

# nginx 配置更新
COPY nginx/app.conf /etc/nginx/conf.d/app.conf
COPY nginx/admin.conf /etc/nginx/conf.d/admin.conf
COPY nginx/headers.conf /etc/nginx/snippets/headers.conf
RUN rm -f /etc/nginx/sites-enabled/default
RUN sed -i 's#error_log /var/log/nginx/error.log;#error_log /var/log/nginx/error.log info;#' /etc/nginx/nginx.conf

# 判分交付 scaffolding
RUN mkdir -p /app/ops/repro /app/ops/fix /app/ops/evidence
COPY ops-template/. /app/ops/
RUN chmod 0644 /app/ops/diagnosis_report.md /app/ops/README.md \
    && chmod 0755 /app/ops/repro /app/ops/fix /app/ops/evidence
COPY tools/ /app/tools/
RUN chmod 0755 /app/tools/*.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh

COPY supervisor-app.conf /etc/supervisor/conf.d/app.conf

# 预装 trae-agent（需要 Python 3.12，需从源码编译）
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip wget build-essential libssl-dev zlib1g-dev libffi-dev libbz2-dev liblzma-dev libreadline-dev libsqlite3-dev && rm -rf /var/lib/apt/lists/* \
    && wget -q https://www.python.org/ftp/python/3.12.7/Python-3.12.7.tgz -O /tmp/python.tgz \
    && tar -xzf /tmp/python.tgz -C /tmp && cd /tmp/Python-3.12.7 \
    && ./configure --prefix=/usr/local 2>&1 | tail -1 \
    && make -j$(nproc) 2>&1 | tail -1 && make install 2>&1 | tail -1 \
    && rm -rf /tmp/python.tgz /tmp/Python-3.12.7
COPY trae-agent /tmp/trae-agent
RUN pip3 install --break-system-packages "pydantic>=2.0,<2.10" "docker>=7.1.0" "pexpect>=4.9.0" /tmp/trae-agent && rm -rf /tmp/trae-agent && trae-cli --help

WORKDIR /app
EXPOSE 80
ENTRYPOINT ["/app/entrypoint.sh"]
