# syntax=docker/dockerfile:1
# =============================================================================
# Dograh AI - all-in-one image for a single-container PaaS (Chabokan Docker).
# Build this image in CI and push to a registry; the PaaS service then only
# needs:   FROM <registry>/dograh-allinone:latest
#
# Inside: Next.js UI :3010 | FastAPI API :8000 | MinIO :9000 (data=/data)
#         nginx :80  ->  /api/v1 -> API | /voice-audio -> MinIO | rest -> UI
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 - build the Next.js UI for glibc (runtime below is Debian-based)
# -----------------------------------------------------------------------------
FROM node:22-slim AS ui-build

ARG DOGRAH_REF=main

ENV NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_NODE_ENV=oss \
    BACKEND_URL=http://127.0.0.1:8000

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

# Only the repo is needed for the UI build (pipecat submodule is not).
RUN git clone --depth 1 --branch "${DOGRAH_REF}" https://github.com/dograh-hq/dograh.git /src

WORKDIR /src/ui
RUN npm ci --no-audit --no-fund

ENV NODE_OPTIONS=--max-old-space-size=4096
RUN npm run build

# -----------------------------------------------------------------------------
# Stage 2 - runtime: official dograh-api image + nginx + UI + MinIO
# -----------------------------------------------------------------------------
FROM dograhai/dograh-api:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

# MinIO server binary (two sources, first usually works)
RUN set -eux; \
    url1="https://dl.min.io/server/minio/release/linux-amd64/minio"; \
    url2="https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2025-04-22T22-12-26Z"; \
    if ! curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 600 "$url1" -o /usr/local/bin/minio; then \
      curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 600 "$url2" -o /usr/local/bin/minio; \
    fi; \
    chmod +x /usr/local/bin/minio; \
    /usr/local/bin/minio --version

COPY --from=ui-build /src/ui/.next/standalone /app/ui
COPY --from=ui-build /src/ui/.next/static     /app/ui/.next/static
COPY --from=ui-build /src/ui/public           /app/ui/public

# nginx: one server, three upstreams
RUN printf '%s\n' \
  'server {' \
  '    listen 80 default_server;' \
  '    server_name _;' \
  '    client_max_body_size 100M;' \
  '' \
  '    location /api/v1/ {' \
  '        proxy_pass http://127.0.0.1:8000;' \
  '        proxy_http_version 1.1;' \
  '        proxy_set_header Upgrade $http_upgrade;' \
  '        proxy_set_header Connection "upgrade";' \
  '        proxy_set_header Host $host;' \
  '        proxy_set_header X-Real-IP $remote_addr;' \
  '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
  '        proxy_set_header X-Forwarded-Proto https;' \
  '        proxy_read_timeout 3600s;' \
  '        proxy_send_timeout 3600s;' \
  '        proxy_buffering off;' \
  '    }' \
  '' \
  '    location /voice-audio/ {' \
  '        proxy_pass http://127.0.0.1:9000/voice-audio/;' \
  '        proxy_http_version 1.1;' \
  '        proxy_set_header Host $host;' \
  '        proxy_buffering off;' \
  '    }' \
  '' \
  '    location / {' \
  '        proxy_pass http://127.0.0.1:3010;' \
  '        proxy_http_version 1.1;' \
  '        proxy_set_header Upgrade $http_upgrade;' \
  '        proxy_set_header Connection "upgrade";' \
  '        proxy_set_header Host $host;' \
  '        proxy_set_header X-Real-IP $remote_addr;' \
  '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
  '        proxy_set_header X-Forwarded-Proto https;' \
  '        proxy_read_timeout 3600s;' \
  '        proxy_send_timeout 3600s;' \
  '    }' \
  '}' \
  > /etc/nginx/conf.d/dograh.conf

# entrypoint: MinIO + UI + nginx + API in one process tree
RUN printf '%s\n' \
  '#!/bin/bash' \
  'set -u' \
  'echo "[dograh] starting all-in-one container"' \
  '' \
  ': "${MINIO_ACCESS_KEY:=minioadmin}"' \
  ': "${MINIO_SECRET_KEY:=minioadmin}"' \
  ': "${BACKEND_URL:=http://127.0.0.1:8000}"' \
  'export MINIO_ROOT_USER="$MINIO_ACCESS_KEY"' \
  'export MINIO_ROOT_PASSWORD="$MINIO_SECRET_KEY"' \
  'export BACKEND_URL' \
  'mkdir -p /data' \
  '/usr/local/bin/minio server /data --address 127.0.0.1:9000 --console-address 127.0.0.1:9001 &' \
  'MINIO_PID=$!' \
  '' \
  'cd /app/ui || exit 1' \
  'HOSTNAME=127.0.0.1 PORT=3010 NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 node server.js &' \
  'UI_PID=$!' \
  'cd /app || exit 1' \
  '' \
  'nginx -g "daemon off;" &' \
  'NGINX_PID=$!' \
  '' \
  '/app/scripts/start_services_docker.sh &' \
  'API_PID=$!' \
  '' \
  'term() {' \
  '  echo "[dograh] received stop signal"' \
  '  kill -TERM "$MINIO_PID" "$UI_PID" "$NGINX_PID" "$API_PID" 2>/dev/null' \
  '  sleep 3' \
  '  exit 0' \
  '}' \
  'trap term TERM INT' \
  '' \
  'wait -n' \
  'echo "[dograh] a process exited - shutting the container down"' \
  'kill -TERM "$MINIO_PID" "$UI_PID" "$NGINX_PID" "$API_PID" 2>/dev/null' \
  'sleep 3' \
  'exit 1' \
  > /entrypoint.sh \
 && chmod +x /entrypoint.sh

ENV HOSTNAME=0.0.0.0 \
    PORT=3010 \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    DEPLOYMENT_MODE=oss \
    AUTH_PROVIDER=local \
    PYTHONPATH=/app \
    LOG_TO_FILE=false

EXPOSE 80

CMD ["/entrypoint.sh"]
