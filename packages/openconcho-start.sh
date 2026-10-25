#!/bin/sh
# Configure the upstream nginx image; frontend assets remain unmodified.
set -eu
umask 077
: "${OPENCONCHO_API_TOKEN:?Missing backend token}"
: "${OPENCONCHO_HTPASSWD:?Missing login hash}"
# Reject nginx/shell metacharacters rather than risk logging malformed secrets.
case "$OPENCONCHO_API_TOKEN" in *[!A-Za-z0-9_.-]*) exit 1;; esac
case "$OPENCONCHO_HTPASSWD" in viewer:\$2[aby]\$*) ;; *) exit 1;; esac
case "$OPENCONCHO_HTPASSWD" in *[!A-Za-z0-9./:\$]*) exit 1;; esac
mkdir -p /tmp/cosmos-openconcho
printf '%s\n' "$OPENCONCHO_HTPASSWD" > /tmp/cosmos-openconcho/htpasswd
printf 'proxy_set_header Authorization "Bearer %s";\n' "$OPENCONCHO_API_TOKEN" > /tmp/cosmos-openconcho/backend-auth.conf
unset OPENCONCHO_API_TOKEN OPENCONCHO_HTPASSWD
exec nginx -c /opt/cosmos-nginx.conf -g 'daemon off;'
