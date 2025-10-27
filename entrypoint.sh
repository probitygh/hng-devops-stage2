#!/bin/sh
set -e

echo "Starting Nginx with Active Pool: ${ACTIVE_POOL}"

envsubst '${ACTIVE_POOL}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf

nginx -t
exec nginx -g 'daemon off;'