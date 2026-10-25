# nginx deployment settings only; no changes to the upstream SPA or API methods.
{
  lib,
  writeText,
  listenAddress,
  port,
  upstream ? "http://127.0.0.1:8000",
}:
writeText "cosmos-openconcho-nginx.conf" ''
  worker_processes 1;
  pid /tmp/cosmos-openconcho/nginx.pid;
  error_log /dev/stderr crit;
  events { worker_connections 256; }
  http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    access_log off;
    sendfile on;
    client_body_temp_path /tmp/cosmos-openconcho/client;
    proxy_temp_path /tmp/cosmos-openconcho/proxy;
    fastcgi_temp_path /tmp/cosmos-openconcho/fastcgi;
    uwsgi_temp_path /tmp/cosmos-openconcho/uwsgi;
    scgi_temp_path /tmp/cosmos-openconcho/scgi;
    client_max_body_size 16m;
    server {
      listen ${listenAddress}:${toString port};
      ${lib.optionalString (listenAddress != "127.0.0.1") "listen 127.0.0.1:${toString port};"}
      root /usr/share/nginx/html;
      index index.html;
      auth_basic "OpenConcho";
      auth_basic_user_file /tmp/cosmos-openconcho/htpasswd;
      auth_delay 250ms;
      add_header X-Content-Type-Options nosniff always;
      add_header Referrer-Policy no-referrer always;
      add_header Content-Security-Policy "connect-src 'self'; img-src 'self' data: blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'" always;
      location = /healthz {
        auth_basic off;
        default_type text/plain;
        return 200 "ok\n";
      }
      location ^~ /api/ {
        # Fixed local target, not a browser-selected upstream. All API methods
        # remain available; this is intentionally NOT a read-only gateway.
        proxy_pass ${upstream}/;
        include /tmp/cosmos-openconcho/backend-auth.conf;
        proxy_set_header Host $proxy_host;
        proxy_set_header X-Honcho-Upstream "";
        proxy_set_header Cookie "";
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 300s;
      }
      location = /config.js {
        alias /opt/cosmos-config.js;
        expires -1;
      }
      location / {
        try_files $uri $uri/ /index.html;
        expires -1;
      }
    }
  }
''
