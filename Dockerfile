# syntax=docker/dockerfile:1
# =============================================================================
# Dograh AI â€” all-in-one container for the Chabokan "Docker" service, v2
# (one container, one exposed HTTP port 80, managed Postgres + Redis outside).
#
# v2 = v1 Ø¨Ø¯ÙˆÙ† ÙˆØ§Ø¨Ø³ØªÚ¯ÛŒ Ø¨Ù‡ Ø§ÛŒÙ…ÛŒØ¬ docker.chabokan.net/dograhai/minio
#      (Ù…ÛŒØ±ÙˆØ± Ú†Ø§Ø¨Ú©Ø§Ù† Ø¨Ø±Ø§ÛŒ Ø¢Ù† Ø§ÛŒÙ…ÛŒØ¬ Ø®Ø·Ø§ÛŒ 503 upstream_unavailable Ø¯Ø§Ø¯).
#      Ø¨Ø§ÛŒÙ†Ø±ÛŒ MinIO Ø¯Ø± Ø²Ù…Ø§Ù† Ø¨ÛŒÙ„Ø¯ Ø§Ø² dl.min.io Ø¯Ø§Ù†Ù„ÙˆØ¯ Ù…ÛŒØ´ÙˆØ¯.
#
# Inside: UI :3010 | API :8000 | MinIO :9000 (data on /data) | nginx :80
# Routes: /api/v1/... -> API | /voice-audio/... -> MinIO | rest -> UI
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 â€” Next.js UIØŒ Ø¨Ø±Ø§ÛŒ glibc Ø¨ÛŒÙ„Ø¯ Ù…ÛŒØ´ÙˆØ¯ (Ø±Ø§Ù†ØªØ§ÛŒÙ… Debian Ø§Ø³ØªØŒ Ù†Ù‡ Alpine)
# -----------------------------------------------------------------------------
# Ø§ÛŒÙ…ÛŒØ¬ Ø±Ø³Ù…ÛŒ Docker Hub Â«nodeÂ» Ø§Ø² Ø·Ø±ÛŒÙ‚ Ù…ÛŒØ±ÙˆØ± Ú†Ø§Ø¨Ú©Ø§Ù†
# Ø§Ú¯Ø± pull Ø´Ú©Ø³Øª Ø®ÙˆØ±Ø¯: docker.chabokan.net/library/node:22-slim Ø±Ø§ Ø§Ù…ØªØ­Ø§Ù† Ú©Ù†
FROM docker.chabokan.net/node:22-slim AS ui-build

ARG DOGRAH_REF=main

ENV NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_NODE_ENV=oss \
    BACKEND_URL=http://127.0.0.1:8000

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

# ÙÙ‚Ø· Ù…Ø®Ø²Ù† dograh Ù„Ø§Ø²Ù… Ø§Ø³ØªØ› Ø³Ø§Ø¨â€ŒÙ…Ø§Ú˜ÙˆÙ„ pipecat Ø¨Ø±Ø§ÛŒ Ø¨ÛŒÙ„Ø¯ UI Ù„Ø§Ø²Ù… Ù†ÛŒØ³Øª.
RUN git clone --depth 1 --branch "${DOGRAH_REF}" https://github.com/dograh-hq/dograh.git /src

WORKDIR /src/ui
RUN npm ci --no-audit --no-fund

ENV NODE_OPTIONS=--max-old-space-size=4096
RUN npm run build

# -----------------------------------------------------------------------------
# Stage 2 â€” runtime = Ø§ÛŒÙ…ÛŒØ¬ Ø±Ø³Ù…ÛŒ dograh-api + nginx + UI + MinIO
# -----------------------------------------------------------------------------
FROM docker.chabokan.net/dograhai/dograh-api:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

# --- MinIO server binary (Ø¨Ù‡ Ø¬Ø§ÛŒ Ú©Ø´ÛŒØ¯Ù† Ø§ÛŒÙ…ÛŒØ¬ minio) --------------------------
# Ø³Ù‡ Ù…Ù†Ø¨Ø¹ Ù¾Ø´Øª Ø³Ø± Ù‡Ù… Ø§Ù…ØªØ­Ø§Ù† Ù…ÛŒâ€ŒØ´ÙˆØ¯Ø› Ø§ÙˆÙ„ÛŒ Ù…Ø¹Ù…ÙˆÙ„Ø§Ù‹ Ú©Ø§ÙÛŒ Ø§Ø³Øª.
RUN set -eux; \
    url1="https://dl.min.io/server/minio/release/linux-amd64/minio"; \
    url2="https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2025-04-22T22-12-26Z"; \
    if ! curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 600 "$url1" -o /usr/local/bin/minio; then \
      curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 600 "$url2" -o /usr/local/bin/minio; \
    fi; \
    chmod +x /usr/local/bin/minio; \
    /usr/local/bin/minio --version

# Next.js standalone output + static assets + public files
COPY --from=ui-build /src/ui/.next/standalone /app/ui
COPY --from=ui-build /src/ui/.next/static     /app/ui/.next/static
COPY --from=ui-build /src/ui/public           /app/ui/public

# --- nginx: ÛŒÚ© Ø³Ø±ÙˆØ±ØŒ Ø³Ù‡ upstream ---------------------------------------------
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

# --- entrypoint: MinIO + UI + nginx + API Ø¯Ø± ÛŒÚ© Ø¯Ø±Ø®Øª Ù¾Ø±ÙˆØ³Ù‡ -------------------
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
  '# alembic upgrade headØŒ Ø³Ù¾Ø³ uvicorn + arq worker (+ Ø³ÛŒÙ†Ú¯Ù„ØªÙˆÙ†â€ŒÙ‡Ø§ÛŒ Ø§Ø®ØªÛŒØ§Ø±ÛŒ)' \
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
  '# Ø§Ú¯Ø± Ù‡Ø± Ù¾Ø±ÙˆØ³Ù‡â€ŒØ§ÛŒ Ø¨Ù…ÛŒØ±Ø¯ØŒ Ú©Ø§Ù†ØªÛŒÙ†Ø± Ù‡Ù… Ù¾Ø§ÛŒÛŒÙ† Ø¨ÛŒØ§ÛŒØ¯ ØªØ§ Ú†Ø§Ø¨Ú©Ø§Ù† ØªÙ…ÛŒØ² Ø±ÛŒâ€ŒØ§Ø³ØªØ§Ø±Øª Ú©Ù†Ø¯' \
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
