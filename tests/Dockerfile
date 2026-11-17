# 判分环境（Harbor 独立判分：以 tests/ 为构建目录）
# 判分只读取 /app/ops/ 交付产物（task.toml artifacts），不发实时探针：
# 依赖 bash/curl/coreutils/grep/awk/sed，无 nginx/go/kafka 等服务组件。
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl coreutils grep gawk sed \
    && rm -rf /var/lib/apt/lists/*

# /app 承接交付目录 /app/ops/（Harbor 按声明路径还原 artifacts）；/logs/verifier 写 reward
RUN mkdir -p /app /logs/verifier

COPY . /tests/
RUN chmod 755 /tests/test.sh
