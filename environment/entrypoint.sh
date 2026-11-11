#!/bin/bash
# 环境入口（有限初始化，必然终止）：
#   1. 幂等拉起 nginx + backend（已在运行则跳过）
#   2. 有界就绪检查（≤15s）
#   3. exec "$@" —— 转交容器主命令（Dockerfile CMD keepalive，如 sleep infinity）
#
# 本脚本不含任何无限循环/守护逻辑（扫描器 non_terminating_process 整改）：
#   - 单独执行（无参数）：初始化后 exec 空命令 → 直接退出 0，可重复执行；
#   - 由容器运行（ENTRYPOINT + CMD）：初始化后 exec CMD，长驻由容器主进程承担；
#   - 非 root：立即快速失败（FATAL），不悬挂。
# 服务意外退出的恢复方式：重新执行本脚本（幂等），或由容器编排重启。
set -u

die(){ echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# ---- 非 root 快速失败 ----
[ "$(id -u)" = "0" ] || die "需要 root 运行（nginx 需绑 80、需写 /var/log 与 /app）"

mkdir -p /var/log/nginx /logs/verifier /app/ops

# ---- 后端（幂等启动）----
cd /app/backend || die "/app/backend 不存在"
if ! pgrep -x backend >/dev/null 2>&1; then
  nohup ./backend >>/var/log/backend.log 2>&1 < /dev/null &
  disown 2>/dev/null || true
  echo "[entrypoint] backend 已启动"
fi

# ---- nginx（幂等启动，配置先校验）----
if ! nginx -t >/dev/null 2>&1; then
  die "nginx 配置校验失败（nginx -t）"
fi
if ! pgrep -x nginx >/dev/null 2>&1; then
  nginx || die "nginx 启动失败"
  echo "[entrypoint] nginx 已启动"
fi

# ---- 就绪检查（有界等待，不悬挂）----
ready=""
for i in $(seq 1 15); do
  if curl -s -o /dev/null --max-time 2 http://127.0.0.1:9000/healthz; then ready=1; break; fi
  sleep 1
done
[ -n "$ready" ] || die "后端就绪检查超时（127.0.0.1:9000/healthz 不可达）"
echo "[entrypoint] 环境就绪（backend + nginx）"

# ---- 转交容器主命令（无参数时无命令 → 退出 0）----
if [ "$#" -gt 0 ]; then
  exec "$@"
fi
exit 0
