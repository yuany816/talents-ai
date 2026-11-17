#!/bin/bash
# 容器入口：每 trial 随机生成容量参数（防硬编码），再移交 supervisord。
# 追加参数（Harbor keepalive）由本脚本忽略——supervisord 不接受位置参数。
LIM=$(( 17408 + RANDOM % 48128 ))    # 17408..65535：恒放行 16384B 探针，上边界 LIM+4096 仍可被拒
RATIO=$(( 50 + RANDOM % 41 ))        # 50..90：预警阈值百分比
mkdir -p /app/ops/repro /app/ops/fix /app/ops/evidence
cat > /app/ops/params.env <<EOF
LIM=${LIM}
WARN_RATIO=${RATIO}
EOF
chmod 644 /app/ops/params.env
echo "[entrypoint] params.env: LIM=${LIM} WARN_RATIO=${RATIO}"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
