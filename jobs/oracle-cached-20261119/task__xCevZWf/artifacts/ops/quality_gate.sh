#!/bin/bash
[ -f /var/log/nginx/access.log ] && grep -qE '(^|[^0-9])431([^0-9]|$)' /var/log/nginx/access.log && exit 1
[ -f /var/log/nginx/hdrsize.log ] && awk '$2 == 431' /var/log/nginx/hdrsize.log | grep -q . && exit 1
exit 0
