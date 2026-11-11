#!/bin/bash
set -e
mkdir -p /var/log/nginx /logs/verifier
cd /app/backend
nohup ./backend >>/var/log/backend.log 2>&1 &
exec nginx -g 'daemon off;'
