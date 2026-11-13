#!/bin/bash
# 431 任务验题脚本（平台 tests/test.sh）
# 判定：端到端 + 双层真实修改（防伪造）+ 边界/输入覆盖 + 防线（门禁/预警）+ 综合归因报告
# 行为正确性以探针（不同输入/边界）判定；源码/配置扫描仅作"修改真实发生"的辅助证据。
# 测试依赖：bash/curl/nginx(仅 -T 读配置)/grep/awk/sed —— 均为环境镜像自带（见
# environment/Dockerfile），无 Python/pip 依赖，无需在测试时额外安装。
# 评分策略（3.7）：全部检查为硬性必要条件，采用 0/1 二值判定（无加权部分分）——
# 任一检查失败即 reward=0，通过即 1；题面"判定总则"已声明该语义。reward.txt 总是被
# 覆盖写入（0 或 1），不存在留空或沿用上次结果（3.5）。进程退出码与 reward 一致
# （全过 exit 0 / 任一失败 exit 1），最终判定仍以 reward.txt 为准。
# v3.2（反绕过加固）：
#   a) 探针自定义头名运行期随机化——防观测/门禁按固定头名特判；
#   b) 门禁分源注入的标记字段（路径/UA/体量/pid 等）逐轮随机化 + 源顺序随机化 +
#      轮间随机插入清理复检 + 末态终检——"固定标记特判"与"跨轮有状态/按轮次脚本化"
#      的门禁无法通过，只有按时间窗解析三类日志的通用 431 拦截才能全数通过；
#   c) 预警探针锚定随机化（P=THRESH+512+R，R 运行期随机）+ 告警内容断言改为
#      [P, P+512] 探针锚定窗——回显 THRESH/LIM/THRESH+512 等契约常量的假观测不通过。
REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier /var/log/nginx
# 版本自证：trial 日志与 /logs/verifier/version.txt 明示本次验题契约版本与环境构建戳，
# 用于排查平台侧旧包/旧镜像缓存（若 trial 日志无此行，说明平台未运行当前 test.sh）
CONTRACT_VERSION="431-contract-v5.0-multinode (2767871+G: edge/mesh 矩阵+计数+注入, 2026-11-13)"
echo "[verifier] contract=$CONTRACT_VERSION"
printf '%s\n' "$CONTRACT_VERSION" > /logs/verifier/version.txt 2>/dev/null || true
[ -f /app/.task_build_stamp ] && echo "[verifier] env_build=$(cat /app/.task_build_stamp 2>/dev/null)"
PASS=1
ok()   { echo "[verifier] ok   : $1"; }
fail() { echo "[verifier] FAIL : $1"; PASS=0; }

ENTRY="http://127.0.0.1:80"
UP="http://127.0.0.1:9000"
PROBE_BYTES=16384
big=$(head -c $PROBE_BYTES /dev/zero | tr '\0' 'x')
# 探针自定义头名运行期随机化（长度与示例同量级）：观测/门禁若按固定头名（如
# X-Verify-Token）特判告警，将无法对本轮探针产生告警——必须按"任意请求头实测体量"通用观测。
VHDR="X-Vrf-$(head -c 6 /dev/urandom 2>/dev/null | od -An -tx1 | tr -dc 'a-f0-9')"
case "$VHDR" in X-Vrf-??*) : ;; *) VHDR="X-Vrf-$RANDOM$RANDOM" ;; esac

# 随机化辅助（§4 门禁标记与 §5 预警锚定共用）：优先 /dev/urandom，异常时退化为 $RANDOM
rnd_hex() { local t; t="$(head -c 6 /dev/urandom 2>/dev/null | od -An -tx1 | tr -dc 'a-f0-9')"; [ -n "$t" ] || t="$RANDOM$RANDOM"; printf '%s' "$t"; }
rnd_num() { local n; n="$(head -c 2 /dev/urandom 2>/dev/null | od -An -tu2 | tr -dc '0-9')"; [ -n "$n" ] || n="$RANDOM"; printf '%s' "$n"; }
rnd_pid() { printf '%d' $(( 1000 + $(rnd_num) % 9000 )); }
rnd_cid() { printf '%d' $(( 100 + $(rnd_num) % 900 )); }
rnd_len() { printf '%d' $(( 20000 + $(rnd_num) % 60000 )); }
clean_logs() {
  local lg
  for lg in /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/hdrsize.log; do
    [ -f "$lg" ] && : > "$lg"
  done
}

# ---------- 0) 环境在线 ----------
curl -s -o /dev/null --max-time 5 "$ENTRY/" || fail "入口不可达"
curl -s -o /dev/null --max-time 5 "$UP/" || fail "后端不可达"
# hdrsize.log 既有内容清空（第 1 节结构断言只认本轮流量；可重复验题）
[ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
nginx -s reopen 2>/dev/null || true

# ---------- 1) 端到端：超长 header 与常规请求行为一致（多路由/多层） ----------
entry_big=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$ENTRY/api/v1/profile")
entry_norm=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ENTRY/api/v1/profile")
[ "$entry_big" = "200" ] && ok "入口超长header → 200" || fail "入口超长header → $entry_big"
[ "$entry_norm" = "200" ] && ok "入口常规请求 → 200" || fail "入口常规请求 → $entry_norm"
health_big=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$ENTRY/healthz")
[ "$health_big" = "200" ] && ok "入口/healthz超长header → 200" || fail "入口/healthz超长header → $health_big"
direct=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$UP/api/v1/profile")
[ "$direct" = "200" ] && ok "直连后端超长header → 200" || fail "直连后端超长header → $direct"
# 直连 /healthz 同路径口径（题面第 1 节"同路径"含 /api/v1/profile 与 /healthz 两个路由），
# 防止只对业务路由放行超长 header 的局部修复
direct_hb=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$UP/healthz")
[ "$direct_hb" = "200" ] && ok "直连后端/healthz超长header → 200" || fail "直连后端/healthz超长header → $direct_hb"
srv=$(curl -s -D - -o /dev/null --max-time 10 "$ENTRY/api/v1/profile" | grep -i '^server:' | head -n1)
echo "$srv" | grep -qi nginx && ok "入口为 nginx 反代" || fail "入口响应缺 Server: nginx"
# 响应体特征（防"桩替换"式作弊：必须是真实应用在服务，而非只回 200 的替身）
body=$(curl -s --max-time 10 "$ENTRY/api/v1/profile")
echo "$body" | grep -q '"msg":"ok"' && ok "业务路由响应体特征匹配" || fail "业务路由响应体异常（疑似应用被替换）"
hb=$(curl -s --max-time 10 -H "${VHDR}: $big" "$ENTRY/healthz" | tr -d '[:space:]')
[ "$hb" = "ok" ] && ok "/healthz 响应体特征匹配" || fail "/healthz 响应体异常（疑似应用被替换）"
# hdrsize 观测日志（题面固定格式 $msec $status $request_length "$request"）：必须存在，
# 且**末行**必须是本轮最后一个探针（入口 /healthz + 超长 header）的记录：status=200、
# request_length ≥ 16400（≈探针+行开销）、msec 新鲜（≥ now-120）——证明观测覆盖全部路由
# （而非只挂业务路由）且即时落盘（未缓冲延迟）。第 0 节已清空日志，末行即本轮流量。
hs_ok=0
hs_line=""
for i in 1 2 3 4 5; do
  hs_line=$(tail -n 1 /var/log/nginx/hdrsize.log 2>/dev/null)
  now=$(date +%s)
  if printf '%s' "$hs_line" | awk -v now="$now" \
       '$1 ~ /^[0-9]+(\.[0-9]+)?$/ && $1+0 >= now-120 && $2 == 200 && $3+0 >= 16400 { f=1 } END { exit !f }'; then
    hs_ok=1
    break
  fi
  sleep 1
done
RL_MEAS=$(printf '%s' "$hs_line" | awk '{print $3+0}')
[ "$hs_ok" = "1" ] && ok "hdrsize.log 观测接入且末行为本轮探针记录（status=200, request_length=${RL_MEAS}B）" \
  || fail "hdrsize.log 缺失/末行非本轮超长探针记录（须全路由挂载 log_format \$msec \$status \$request_length 并即时落盘）"

# ---------- 2) 双层真实修改（防伪造辅助证据；行为判定见 1/3 节） ----------
# L1 下限 32768B = 2×16384B（探针值）：完整 header 行口径之外必须再预留 ≥1 倍增长余量
# （题面背景：Trace 上下文随跳数继续增长）——"刚好够用"的容量判不通过。
NG_BUF=$(nginx -T 2>/dev/null | grep -E '^[[:space:]]*large_client_header_buffers[[:space:]]' | head -n1 | awk '{gsub(/;/,""); print $3}')
NG_BUF_B=$(printf '%s' "$NG_BUF" | awk '{v=$1; if (v ~ /[kK]$/) {sub(/[kK]$/,"",v); print v*1024} else if (v ~ /[mM]$/) {sub(/[mM]$/,"",v); print v*1048576} else print v}')
if [ -n "$NG_BUF_B" ] && [ "$NG_BUF_B" -ge 32768 ] 2>/dev/null; then
  ok "nginx large_client_header_buffers=${NG_BUF}（生效配置，单缓冲 ≥32768B=2×探针）"
else
  fail "nginx header 缓冲余量不足（当前=${NG_BUF:-无}，单缓冲需 ≥32768B，含增长余量）"
fi
# 按题面第 2 节口径：对 /app/backend 全部文本文件做 8192 字面匹配 (^|[^0-9])8192([^0-9]|$)，
# 命中即不通过（不限定必须跟随 MaxHeaderBytes/max_header_bytes 字样——那比题面更窄，
# 会放过残留在注释或其他限额位里的原故障值）。
if grep -rqIE '(^|[^0-9])8192([^0-9]|$)' /app/backend \
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.candbak' --exclude='*.orig' \
    --exclude='*.old' --exclude='*.backup' --exclude='*.disabled' 2>/dev/null; then
  fail "后端侧 header 限额仍残留原故障值 8192（/app/backend 源码/配置字面扫描命中）"
else
  ok "后端侧 header 限额已真实调整（源码/配置扫描，题面字面匹配口径）"
fi

# ---------- 3) 边界与输入覆盖（以解题者声明的限额为基准） ----------
LIMENV="/app/ops/header_limits.env"
LIM=""
if [ -f "$LIMENV" ]; then
  LIM=$(sed -n 's/^NGINX_LARGE_HEADER_BUFFER_BYTES=//p' "$LIMENV" | head -n1 | tr -dc '0-9')
  # 3.1 声明一致性：LIM 必须与 nginx 生效单缓冲一致（k/M 折算后相等）
  if [ -n "$LIM" ] && [ -n "$NG_BUF_B" ] && [ "$LIM" -eq "$NG_BUF_B" ] 2>/dev/null; then
    ok "声明 LIM 与 nginx 生效单缓冲一致（${LIM}B）"
  else
    fail "声明 LIM(${LIM:-缺}) 与 nginx 生效单缓冲(${NG_BUF_B:-无}) 不一致"
  fi
  # 3.1b 直连容量耦合：后端限额必须与声明限额同级扩容，而不是刚好越过 16KiB 探针——
  #      直连后端发送 LIM-2048B 探针必须 200（预留 ~2KB 组头开销余量防误拒）
  if [ -n "$LIM" ] && [ "$LIM" -gt 18432 ] && [ "$LIM" -le 1048576 ]; then
    cbig=$(head -c $(( LIM - 2048 )) /dev/zero | tr '\0' 'x')
    couple_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $cbig" "$UP/api/v1/profile")
    [ "$couple_code" = "200" ] && ok "直连后端容量耦合（LIM-2048B 探针）→ 200" \
      || fail "后端限额未同步扩至声明限额同级：直连 LIM-2048B 探针 → $couple_code"
  fi
  # 3.2 上边界：超过声明上限的请求必须仍被拒绝（限额语义仍在，而非一放了之）
  if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] && [ "$LIM" -le 1048576 ]; then
    over=$(( LIM + 4096 ))
    obig=$(head -c $over /dev/zero | tr '\0' 'x')
    over_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $obig" "$ENTRY/api/v1/profile")
    case "$over_code" in
      200|000) fail "超上限请求未被拒绝（status=$over_code）" ;;
      *)       ok "超上限请求仍被拒绝（status=$over_code）" ;;
    esac
  else
    echo "[verifier] note : LIM 缺失/超 1MB，跳过上边界检查"
  fi
else
  fail "缺少预警参数文件 /app/ops/header_limits.env"
fi

# ---------- 4) 防线：质检门禁（干净日志通过；分源注入 431 逐源拦截；防固定标记/有状态特判；可重复） ----------
GATE="/app/ops/quality_gate.sh"
if [ -x "$GATE" ]; then
  run_gate() { bash "$GATE" >/dev/null 2>&1; }
  gate_expect0() { if run_gate; then ok "$1"; else fail "$2"; fi; }
  gate_expect1() { if run_gate; then fail "$2"; else ok "$1"; fi; }

  # 4.1 干净日志：重放一轮常规流量，门禁必须放行
  clean_logs
  nginx -s reopen 2>/dev/null || true
  curl -s -o /dev/null --max-time 10 -H "${VHDR}: $big" "$ENTRY/api/v1/profile"
  sleep 1
  gate_expect0 "质检门禁：干净日志通过（exit 0）" "质检门禁：干净日志被误拦截"
  # 4.2 防误拦（时间窗语义）：历史（1 小时前）431 样本（三种日志各一，标记随机）+ 当天
  #     无关错误样本 → 门禁必须放行——431 拦截须具备时间窗语义（仅拦窗口内），无脑全量
  #     grep 的门禁不通过。历史样本路径同样取 /api/v1/* 随机串：使拦截判别的唯一依据是
  #     时间戳解析，而非路径/UA 等可被特判的字段。
  clean_logs
  echo "127.0.0.1 - - [$(date -d '1 hour ago' '+%d/%b/%Y:%H:%M:%S +0000')] \"GET /api/v1/$(rnd_hex) HTTP/1.1\" 431 0 \"-\" \"$(rnd_hex)\"" >> /var/log/nginx/access.log
  [ -f /var/log/nginx/hdrsize.log ] && echo "$(date -d '1 hour ago' +%s).000 431 $(rnd_len) \"GET /api/v1/$(rnd_hex) HTTP/1.1\"" >> /var/log/nginx/hdrsize.log
  echo "$(date -d '1 hour ago' '+%Y/%m/%d %H:%M:%S') [info] $(rnd_pid)#$(rnd_pid): *$(rnd_cid) client sent too long header line while reading client request headers, client: 127.0.0.1, server: _, request: \"GET /api/v1/$(rnd_hex) HTTP/1.1\"" >> /var/log/nginx/error.log
  echo "$(date '+%Y/%m/%d %H:%M:%S') [error] $(rnd_pid)#$(rnd_pid): *$(rnd_cid) upstream timed out (110: Connection timed out) while reading response header from upstream, client: 127.0.0.1" >> /var/log/nginx/error.log
  gate_expect0 "质检门禁：历史 431/无关错误样本未误拦（exit 0）" "质检门禁：历史 431 被误拦（须时间窗语义，仅拦窗口内的 431）"
  # 4.3 分源注入：三类日志源**逐源独立**验证拦截（对应审题缺口"门禁须分别证明各日志源
  #     有效"）。每轮注入前其余日志清空、注入后清理恢复；源顺序运行期随机化、轮间随机
  #     插入"清理复检"（约 1/2 概率），末轮再做终态复检——**有状态门禁**（一旦拦截恒拦截、
  #     按固定轮次脚本化应答）无法预知本轮是否为注入轮，必须真实解析日志才能正确应答。
  for src in $(shuf -e access hdrsize error 2>/dev/null || printf 'access\nhdrsize\nerror'); do
    clean_logs
    case "$src" in
      access)
        echo "127.0.0.1 - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET /api/v1/$(rnd_hex) HTTP/1.1\" 431 0 \"-\" \"$(rnd_hex)\"" >> /var/log/nginx/access.log ;;
      hdrsize)
        if [ ! -f /var/log/nginx/hdrsize.log ]; then
          echo "[verifier] note : hdrsize.log 不存在（题面允许），跳过该来源拦截验证"
          continue
        fi
        echo "$(date +%s).000 431 $(rnd_len) \"GET /api/v1/$(rnd_hex) HTTP/1.1\"" >> /var/log/nginx/hdrsize.log ;;
      error)
        echo "$(date '+%Y/%m/%d %H:%M:%S') [info] $(rnd_pid)#$(rnd_pid): *$(rnd_cid) client sent too long header line while reading client request headers, client: 127.0.0.1, server: _, request: \"GET /api/v1/$(rnd_hex) HTTP/1.1\"" >> /var/log/nginx/error.log ;;
    esac
    gate_expect1 "质检门禁：$src 来源拦截生效（窗口内 431）" "质检门禁：$src 注入窗口内 431 后未拦截"
    if [ $(( $(rnd_num) % 2 )) = 0 ]; then
      clean_logs
      gate_expect0 "质检门禁：轮间清理复归放行（exit 0）" "质检门禁：轮间清理后仍拦截（跨轮残留状态）"
    fi
  done
  # 4.4 终态复检：全部清空 + reopen 后门禁必须重新回到放行态——
  #     防跨轮残留状态（"见过 431 之后恒拦截"），同时保障可重复验题
  clean_logs
  nginx -s reopen 2>/dev/null || true
  gate_expect0 "质检门禁：清理后复归通过（exit 0）" "质检门禁：日志清理后仍拦截（门禁存在跨轮残留状态）"
else
  fail "缺少质检门禁 /app/ops/quality_gate.sh"
fi

# ---------- 5) 防线：预警观测（近阈值告警 + 小请求不误报） ----------
if [ -f "$LIMENV" ]; then
  RATIO=$(sed -n 's/^WARN_RATIO=//p' "$LIMENV" | head -n1 | tr -dc '0-9'); [ -n "$RATIO" ] || RATIO=80
  # WARN_RATIO 有效范围 [50,90]：超范围则阈值/探针关系无法保证（高比例会截短探针到阈值以下）
  if [ "$RATIO" -lt 50 ] 2>/dev/null || [ "$RATIO" -gt 90 ] 2>/dev/null; then
    fail "header_limits.env 的 WARN_RATIO=$RATIO 超出有效范围 [50,90]"
    RATIO=80
  fi
  if [ -n "$LIM" ] && [ "$LIM" -gt 4096 ] 2>/dev/null; then
    THRESH=$(( LIM * RATIO / 100 ))
    # 预警探针锚定随机化：P = THRESH+512+R（R 运行期随机、取值不预先承诺）。R 上界由
    # LIM−THRESH−2560 推得 ⟹ P ≤ LIM−2048：探针不越过 §3.1b 已验证的后端可接受线，
    # 不会被 431 拒掉导致 5.2 误判。R 不可预知 ⟹ 按"题面常量"伪造的观测值
    # （THRESH / LIM / THRESH+512+固定偏移）必然落在 5.3 的探针锚定窗之外。
    RMAX=$(( LIM - THRESH - 2560 )); [ "$RMAX" -lt 256 ] && RMAX=256
    RINC=$(( 256 + $(rnd_num) % ( RMAX - 255 ) ))
    PROBE2=$(( THRESH + 512 + RINC )); CAP=$(( LIM - 1024 )); [ "$PROBE2" -gt "$CAP" ] && PROBE2=$CAP
    # 清理日志增量后进入静默窗口（观测需容忍截断）
    [ -f /var/log/nginx/hdrsize.log ] && : > /var/log/nginx/hdrsize.log
    nginx -s reopen 2>/dev/null || true
    sleep 2
    before=$(wc -l < /app/ops/warnings.log 2>/dev/null || echo 0)
    # 5.1 静默检查：常规请求（远低于阈值）10s 内不得产生告警
    curl -s -o /dev/null --max-time 10 "$ENTRY/api/v1/profile"
    sleep 10
    mid=$(wc -l < /app/ops/warnings.log 2>/dev/null || echo 0)
    [ "$mid" -eq "$before" ] && ok "预警观测：常规请求无误报" || fail "预警观测：常规请求触发误报"
    # 5.2 近阈值请求：两次探针（立即 + ~9s 后），30s 内行数必须增加
    p2=$(head -c $PROBE2 /dev/zero | tr '\0' 'x')
    curl -s -o /dev/null --max-time 10 -H "${VHDR}: $p2" "$ENTRY/api/v1/profile"
    hit=0
    for i in $(seq 1 10); do
      sleep 3
      after=$(wc -l < /app/ops/warnings.log 2>/dev/null || echo 0)
      if [ "$after" -gt "$mid" ]; then hit=1; break; fi
      if [ "$i" = "3" ]; then
        curl -s -o /dev/null --max-time 10 -H "${VHDR}: $p2" "$ENTRY/api/v1/profile"
      fi
    done
    [ "$hit" = "1" ] && ok "预警观测：接近阈值请求已产生告警（${PROBE2}B ≥ ${THRESH}B）" || fail "预警观测：30s 内未产生告警"
    # 5.3 告警内容：末条告警行必须携带实测请求头字节数（十进制整数 ∈ [P, P+512]，P=本轮
    #     探针 PROBE2）——真实观测必 ≥ 探针值（至多再加组头开销约 200B）；THRESH / LIM /
    #     THRESH+512±固定偏移（可预知常量）与日期/时间戳/pid 分量均不可能落在窗内——
    #     杀掉"定时器/固定文本/回显契约常量"式假观测
    ALO=$PROBE2; AHI=$(( PROBE2 + 512 ))
    wline=$(tail -n 1 /app/ops/warnings.log 2>/dev/null)
    if printf '%s' "$wline" | grep -oE '[0-9]+' | awk -v lo="$ALO" -v hi="$AHI" '$1+0>=lo && $1+0<=hi { f=1 } END { exit !f }'; then
      ok "预警观测：告警行含实测请求体量（∈[${ALO},${AHI}]B，探针锚定窗）"
    else
      fail "预警观测：告警行缺少实测字节数（须含 ∈[${ALO},${AHI}] 的十进制整数；回显阈值/上限/契约常量均不在窗内）"
    fi
  else
    fail "header_limits.env 缺少 NGINX_LARGE_HEADER_BUFFER_BYTES（或值 ≤ 4096）"
  fi
else
  fail "缺少预警参数文件 /app/ops/header_limits.env"
fi

# ---------- 6) 修复持久性（服务经 supervisorctl 重启后修复仍生效；防手工进程/不落盘配置） ----------
if command -v supervisorctl >/dev/null 2>&1; then
  if supervisorctl restart backend >/dev/null 2>&1 && supervisorctl restart nginx >/dev/null 2>&1; then
    rcode=000
    for i in $(seq 1 20); do
      rcode=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ENTRY/healthz" 2>/dev/null)
      [ "$rcode" = "200" ] && break
      sleep 1
    done
    if [ "$rcode" = "200" ]; then
      ok "服务重启后恢复在线（${i}s）"
      re_big=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$ENTRY/api/v1/profile")
      [ "$re_big" = "200" ] && ok "重启后入口超长header → 200（修复持久）" || fail "重启后修复失效：入口超长header → $re_big"
      re_dir=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$UP/api/v1/profile")
      [ "$re_dir" = "200" ] && ok "重启后直连超长header → 200（修复持久）" || fail "重启后修复失效：直连超长header → $re_dir"
      if [ -n "$LIM" ] && [ "$LIM" -gt 18432 ] && [ "$LIM" -le 1048576 ]; then
        re_cpl=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $cbig" "$UP/api/v1/profile")
        [ "$re_cpl" = "200" ] && ok "重启后直连容量耦合（LIM-2048B）→ 200" || fail "重启后后端限额失效：直连 LIM-2048B 探针 → $re_cpl"
      fi
    else
      fail "服务重启后 20s 内未恢复在线（healthz=$rcode）"
    fi
  else
    fail "supervisorctl restart backend/nginx 失败（服务须由 supervisord 按题面约定管理）"
  fi
else
  fail "supervisorctl 不可用（题面约定的服务管理入口缺失）"
fi

# ---------- 6.5) 跨层多节点矩阵（G：edge-sim ALB 语义 / mesh-sim Envoy 语义 + 计数维度） ----------
# 链路：client → edge-sim(:8080, 云 LB 硬限, 恒 400) → mesh-sim(:8082, Envoy 语义,
# 可配置 max_request_headers_kb / max_headers_count, 每请求注入 ~8194B span) → nginx(:80) → 后端。
# 杀伤点：任何一层的"修复"都不会传导到其他层；错误码语义各异（400=ALB 硬限 / 431=网格语义）；
# 计数维度与字节数完全独立（120×100B 总量仅 ~14K 也会被 mesh 拒）。
EDGE="http://127.0.0.1:8080"
MESH="http://127.0.0.1:8082"
MESHCONF="/etc/mesh-sim/config.yaml"
# G0 节点在线（TCP/HTTP 存活即可：200/400/431 都证明节点活着；000=连接失败=节点缺失）
edge_online=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$EDGE/healthz")
mesh_online=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$MESH/healthz")
[ "$edge_online" != "000" ] && ok "edge-sim(:8080) 节点在线（status=$edge_online）" || fail "edge-sim(:8080) 节点不可达——云 LB 模拟层缺失"
[ "$mesh_online" != "000" ] && ok "mesh-sim(:8082) 节点在线（status=$mesh_online）" || fail "mesh-sim(:8082) 节点不可达——网格模拟层缺失"
# G1 全链路 16384 探针：edge → mesh(注入) → nginx → 后端 全部 200
g1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $big" "$EDGE/api/v1/profile")
[ "$g1" = "200" ] && ok "全链路超长header（edge 链）→ 200" || fail "全链路（edge→mesh→nginx→后端）超长header → $g1（各层限额须同步扩容）"
# G1b 注入观测：G1 请求在 nginx hdrsize.log 的 request_length 须含 mesh 注入体量
# （~8194B span：nginx 视野 ≈ 16384+8194+行开销 ≈ 24.6K）——容量评估未计入注入的方案此格失败
inject_ok=0
for i in 1 2 3 4 5; do
  if tail -n 20 /var/log/nginx/hdrsize.log 2>/dev/null | awk -v lo=$(( 16384 + 8194 - 256 )) -v hi=$(( 16384 + 8194 + 4096 )) \
       '$1 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 == 200 && $3+0 >= lo && $3+0 <= hi { f=1 } END { exit !f }'; then
    inject_ok=1; break
  fi
  sleep 1
done
[ "$inject_ok" = "1" ] && ok "mesh span 注入已计入 nginx 视野（request_length ≈ 探针+8194B）" \
  || fail "hdrsize 未见 mesh 注入体量的记录（须 ∈[探针+8194−256, 探针+8194+4096]——网格 span 注入不可忽略）"
# G2 计数维度：120 个 ~100B header（总量仅 ~14K）经全链路 → 200
# （mesh max_headers_count 默认 100：计数超限 431——与字节数完全独立的失败维度）
cnt_ok=1
cnt_args=()
for n in $(seq 0 119); do cnt_args+=(-H "X-Vrf-Cnt-$n: $(printf 'c%.0s' $(seq 1 100))"); done
g2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${cnt_args[@]}" "$EDGE/api/v1/profile")
[ "$g2" = "200" ] && ok "计数探针（120×100B，总量~14K）全链路 → 200" || fail "计数维度未放行（120 header → $g2；mesh max_headers_count 须同步扩容）"
# G3 全链路容量耦合（LIM 基准）：mesh 注入吃掉 ~8KiB 预算——全链路容量 = L − 注入 − 行开销。
# 多头探针：5×((LIM−10240)/5)（每头 ≤16KiB 以通过 edge 单头硬限——单头 16K 硬限下
# 全链路容量本就必须多头承载），nginx 视野 ≈ LIM−2048 < LIM，必须 200
g3=""
if [ -n "$LIM" ] && [ "$LIM" -gt 30720 ] && [ "$LIM" -le 1048576 ]; then
  g3sz=$(( (LIM - 10240) / 5 ))
  gp=$(head -c $g3sz /dev/zero | tr '\0' 'x')
  g3args=()
  for n in 0 1 2 3 4; do g3args+=(-H "X-Vrf-Cap-$n: $gp"); done
  g3=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${g3args[@]}" "$EDGE/api/v1/profile")
  [ "$g3" = "200" ] && ok "全链路容量耦合（5×(LIM−10240)/5 经 edge 链）→ 200" \
    || fail "全链路容量缺口：5×(LIM−10240)/5 经 edge 链 → $g3（mesh 限额须 ≥ LIM−8192，nginx 视野含注入体量）"
fi
# G4 edge 硬限语义（不可修层，恒 400）：单 header 20480B > 16384B 硬限 → 恰好 400（非 431）
g4=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "${VHDR}: $(head -c 20480 /dev/zero | tr '\0' 'x')" "$EDGE/api/v1/profile")
[ "$g4" = "400" ] && ok "edge 硬限语义保持：单头 20K → 400（ALB 语义，不可配置）" \
  || fail "edge 硬限语义被破坏：单头 20K → $g4（预期恒 400——云 LB 硬限制不可调）"
# G5 edge 总量硬限：90 个 ~900B header（总 ~82K > 64K）→ 恰好 400
g5args=()
for n in $(seq 0 89); do g5args+=(-H "X-Vrf-Tot-$n: $(printf 't%.0s' $(seq 1 900))"); done
g5=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${g5args[@]}" "$EDGE/api/v1/profile")
[ "$g5" = "400" ] && ok "edge 总量硬限保持：90×900B（~82K）→ 400" \
  || fail "edge 总量硬限被破坏：~82K 总量 → $g5（预期恒 400）"
# G6 mesh 声明一致性（静态，配额文件即声明）：max_request_headers_kb*1024 ≥ LIM−8192 且
# max_headers_count ≥ 120——网格层不得成为链路容量瓶颈（与 §3.1 LIM 声明一致同风格）
if [ -f "$MESHCONF" ]; then
  MT=$(sed -n 's/^[[:space:]]*max_request_headers_kb:[[:space:]]*//p' "$MESHCONF" | head -n1 | tr -dc '0-9')
  MC=$(sed -n 's/^[[:space:]]*max_headers_count:[[:space:]]*//p' "$MESHCONF" | head -n1 | tr -dc '0-9')
  if [ -n "$MT" ] && [ -n "$MC" ]; then
    if { [ -z "$LIM" ] || [ "$(( MT * 1024 ))" -ge "$(( LIM - 8192 ))" ] 2>/dev/null; } \
       && [ "$MC" -ge 120 ] 2>/dev/null; then
      ok "mesh 声明一致（max_request_headers_kb=${MT}KB ≥ LIM−8192, max_headers_count=${MC} ≥ 120）"
    else
      fail "mesh 限额未与链路同步扩容（max_request_headers_kb=${MT}KB / max_headers_count=${MC}；须 ≥ LIM−8192 与 ≥120）"
    fi
  else
    fail "mesh 配置可读但缺少字段（/etc/mesh-sim/config.yaml 须含 max_request_headers_kb / max_headers_count）"
  fi
else
  fail "mesh 配置缺失（/etc/mesh-sim/config.yaml）"
fi

# ---------- 7) 综合分析报告（结构化要求见题面"产物 schema"；数值对照+实质归因为硬断言） ----------
RPT="/app/ops/diagnosis_report.md"
if [ -s "$RPT" ]; then
  grep -qE '归因|综合' "$RPT" && ok "综合分析报告存在（含归因结论）" || fail "报告缺归因结论"
  grep -qE 'large_client_header_buffers|MaxHeaderBytes|ReadBufferSize' "$RPT" \
    && ok "报告含各层限额对照" || fail "报告未覆盖各层限额对照"
  # 状态码链：须含"修复前"表述且呈现分层链（箭头连接）
  grep -qE '状态码链|修复前' "$RPT" && grep -qE '→|->' "$RPT" \
    && ok "报告含状态码链（修复前→分层修复后）" || fail "报告缺状态码链（修复前/修复后链条）"
  # 数值对照：须同时含原故障值 8192、生效的新限额数值（LIM=题面声明值）与实测探针体量 16384
  grep -q '8192' "$RPT" && grep -q "${LIM:-65536}" "$RPT" && grep -q '16384' "$RPT" \
    && ok "报告含限额数值对照（8192 → 新值）及实测探针体量（16384）" \
    || fail "报告缺数值对照（缺 8192 / 新限额 ${LIM:-65536} / 实测体量 16384 任一）"
  # 实测数值：报告须含对 16384B 探针的**入口实测 request_length**（nginx $request_length 口径，
  # 完整请求行+头字节）：∈[16403, RL+200]（16403=行开销下限，排除探针字面值 16384 与
  # THRESH/LIM 等模板数字；±200B 容差覆盖探针头名/客户端差异）——只抄模板不实测不通过
  if [ -n "$RL_MEAS" ] && [ "$RL_MEAS" -ge 16403 ] 2>/dev/null \
     && grep -oE '[0-9]+' "$RPT" | awk -v lo=16403 -v hi=$(( RL_MEAS + 200 )) '$1+0>=lo && $1+0<=hi { f=1 } END { exit !f }'; then
    ok "报告含入口实测 request_length（∈[16403, $(( RL_MEAS + 200 ))]B）"
  else
    fail "报告缺入口实测 request_length（须含 ∈[16403, 实测+200] 的整数字节，\$request_length 口径）"
  fi
  # 实质归因：须含量化观测证据 + "谁注入过多"与"哪层限制过小"两类归因表述
  grep -qE 'HDRSTAT|max_header|request_length' "$RPT" \
    && grep -qE '注入|增长' "$RPT" && grep -qE '过小|未同步|未扩容' "$RPT" \
    && ok "报告含实质归因（量化证据+两侧归因）" || fail "报告缺实质归因（量化证据/注入侧/限制侧）"
  grep -qiE '余量|sizing' "$RPT" \
    && ok "报告含容量取值依据（增长余量/sizing）" || fail "报告缺容量取值依据（余量/sizing）"
  # 多节点归因（G）：报告须解释 edge（云 LB 硬限→400）与 mesh（网格语义→431/计数/注入）的层差异
  if grep -qiE 'mesh|网格|边车|sidecar' "$RPT" && grep -qiE 'edge|边缘|alb|cdn' "$RPT" \
     && grep -q '400' "$RPT" && grep -q '431' "$RPT"; then
    ok "报告含多节点层语义归因（edge/mesh + 400/431 区分）"
  else
    fail "报告缺多节点归因（须解释 edge 硬限 400 与 mesh 431/计数/span 注入的层语义差异）"
  fi
else
  fail "缺少综合分析报告 /app/ops/diagnosis_report.md"
fi

# ---------- 结果 ----------
echo "$PASS" > "$REWARD_FILE"
echo "[verifier] reward=$PASS"
# 退出语义：进程退出码与 reward 保持一致（全部通过 exit 0 / 任一检查失败 exit 1），
# 不再无条件 exit 0；最终判定仍以 reward.txt 为准（题面"判定总则"），退出码作一致性信号。
if [ "$PASS" = "1" ]; then
  exit 0
fi
exit 1
