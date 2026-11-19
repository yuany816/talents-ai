#!/bin/bash
# F1 修复：nginx 生效单缓冲对齐 params LIM（全指令一致）后 reload
LIM=$(sed -n 's/^LIM=//p' /app/ops/params.env | head -n1 | tr -dc '0-9'); : "${LIM:=65536}"
sed -i -E 's/^([[:space:]]*)(client_header_buffer_size|large_client_header_buffers)/\1# disabled: &/' /etc/nginx/snippets/headers.conf
sed -i -E "s/^(large_client_header_buffers[[:space:]]+)[0-9]+[[:space:]]+[0-9kKmM]+;/\14 ${LIM};/" /etc/nginx/nginx.conf
nginx -t && nginx -s reload
