#!/usr/bin/env bash
# Module 20 — RAG (Open WebUI + nginx proxy + config-driven rag-prep tools).
#  Open WebUI: ghcr.io/open-webui/open-webui:main, host network, named volume
#              open-webui -> /app/backend/data, 12 GB cap. Embeddings run
#              in-process (sentence-transformers) — nothing external to wire.
#  nginx: nginx:alpine, host network, :80 + :3000 -> 127.0.0.1:8080, websocket
#         upgrade, 500M body. Booth auto-login session is OPT-IN (default off).
#  rag-prep: convert.py / ingest.py / eval.py, all read a single config file
#            (~/.gb10-stack/rag/rag.json). No client content ships in the repo.
#
# Env: GB_BOOTH_SESSION=1 to bake a shared demo-admin session into nginx.

MIN_FREE_GB=25   # webui image 4.6 GB + nginx + headroom

mod_install() {
  local user="$GB_USER"
  local cfg_dir="$HOME/.gb10-stack/rag"
  local port_webui="${WEBUI_PORT:-8080}"
  local port_27b="${PORT:-30000}"
  local api_key_file="$HOME/.config/qwen38/api-key"

  mkdir -p "$cfg_dir"

  # ── Container Image Pre-pull ───────────────────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "docker pull ghcr.io/open-webui/open-webui:main && docker pull nginx:alpine"
  else
    if ! docker image inspect ghcr.io/open-webui/open-webui:main >/dev/null 2>&1; then
      info "Pulling Open WebUI container image..."
      docker pull ghcr.io/open-webui/open-webui:main
      ok "Open WebUI image pulled"
    fi
    if ! docker image inspect nginx:alpine >/dev/null 2>&1; then
      info "Pulling Nginx container image..."
      docker pull nginx:alpine
      ok "Nginx image pulled"
    fi
  fi

  # ── 1. Open WebUI container (idempotent) ───────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "docker run --name open-webui --network host -v open-webui:/app/backend/data --memory 12g ghcr.io/open-webui/open-webui:main (see env below)"
  else
    if docker ps -a --format '{{.Names}}' | grep -qx open-webui; then
      ok "open-webui container already present — starting"
      docker start open-webui >/dev/null
    else
      info "starting Open WebUI (host network, named volume, 12 GB cap)"
      # API key for the local 35B engine.
      local webui_api_key=""
      [ -r "$api_key_file" ] && webui_api_key=$(cat "$api_key_file")
      docker run -d --name open-webui --network host \
        --restart unless-stopped \
        -v open-webui:/app/backend/data \
        --memory 12g \
        -e "OPENAI_API_BASE_URL=http://localhost:$port_27b/v1" \
        -e "OPENAI_API_KEY=${webui_api_key}" \
        -e "OPEN_WEBUI_DEFAULT_MODELS=qwen3.6-35b" \
        -e "RAG_EMBEDDING_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2" \
        -e "USE_EMBEDDING_MODEL_DOCKER=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2" \
        -e "AUXILIARY_EMBEDDING_MODEL=TaylorAI/bge-micro-v2" \
        -e "USE_AUXILIARY_EMBEDDING_MODEL_DOCKER=TaylorAI/bge-micro-v2" \
        -e "HF_HOME=/app/backend/data/cache/embedding/models" \
        -e "SENTENCE_TRANSFORMERS_HOME=/app/backend/data/cache/embedding/models" \
        -e "TIKTOKEN_CACHE_DIR=/app/backend/data/cache/tiktoken" \
        -e "WHISPER_MODEL=base" -e "WHISPER_MODEL_DIR=/app/backend/data/cache/whisper/models" \
        -e "PORT=$port_webui" \
        -e "WEBUI_AUTH=True" \
        -e "ENABLE_LOGIN_FORM=${GB_WEBUI_LOGIN_FORM:-True}" \
        -e "ENABLE_SIGNUP=${GB_WEBUI_SIGNUP:-True}" \
        -e "DEFAULT_USER_ROLE=admin" \
        -e "ANONYMIZED_TELEMETRY=false" -e "DO_NOT_TRACK=true" -e "SCARF_NO_ANALYTICS=true" \
        ghcr.io/open-webui/open-webui:main >/dev/null
      ok "open-webui started (:$port_webui)"
    fi
  fi

  # ── 2. nginx proxy (idempotent) ────────────────────────────────────────
  local nginx_conf="$cfg_dir/nginx-webui.conf"
  # Generate from template; booth session is opt-in.
  local booth_cookie=""
  if [ "${GB_BOOTH_SESSION:-0}" = "1" ]; then
    # Caller must set GB_BOOTH_EMAIL / GB_BOOTH_NAME / GB_BOOTH_COOKIE.
    booth_cookie="${GB_BOOTH_COOKIE:-}"
    [ -z "$booth_cookie" ] && warn "GB_BOOTH_SESSION=1 but no GB_BOOTH_COOKIE — leaving session out (login required)"
  fi

  local booth_identity=""
  if [ -n "$booth_cookie" ]; then
    booth_identity="
            # Trusted-header auth (Open WebUI): identity for the shared booth session.
            proxy_set_header X-User-Email \"${GB_BOOTH_EMAIL:-demo@localhost}\";
            proxy_set_header X-User-Name \"${GB_BOOTH_NAME:-Local Station}\";
            proxy_set_header X-User-Role \"admin\";
            proxy_set_header Cookie \"token=$booth_cookie; \$http_cookie\";
            add_header Set-Cookie \"token=$booth_cookie; Path=/; Max-Age=1209600; SameSite=Lax\" always;"
  fi

  write_file "$nginx_conf" <<EOF
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Page + /static branding: browsers re-check every load. Fingerprinted
    # bundles (/_app/immutable/) keep normal caching.
    map \$uri \$revalidate {
        ~^/_app/immutable/  "";
        default             "no-cache";
    }

    upstream openwebui_backend {
        server 127.0.0.1:$port_webui;
    }

    server {
        listen 80;
        listen [::]:80;
        listen 3000;
        listen [::]:3000;
        server_name _;

        client_max_body_size 500M;

        location / {
            proxy_pass http://openwebui_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;$booth_identity
            add_header Cache-Control \$revalidate always;
        }
    }
}
EOF

  if [ "$GBPLAN" = "1" ]; then
    plan "docker run --name open-webui-proxy --network host -v $nginx_conf:/etc/nginx/nginx.conf:ro nginx:alpine"
  else
    if docker ps -a --format '{{.Names}}' | grep -qx open-webui-proxy; then
      ok "open-webui-proxy container present — restarting with new conf"
      docker rm -f open-webui-proxy >/dev/null 2>&1 || true
    fi
    docker run -d --name open-webui-proxy --network host \
      --restart unless-stopped \
      -v "$nginx_conf:/etc/nginx/nginx.conf:ro" \
      nginx:alpine >/dev/null
    ok "open-webui-proxy started (:80, :3000 -> :$port_webui)"
  fi

  # ── 3. rag-prep tools (config-driven, generic) ─────────────────────────
  local tools_dir="$cfg_dir/tools"
  for t in ingest.py eval.py convert.py; do
    if [ "$GBPLAN" = "1" ]; then plan "install rag tool: $tools_dir/$t"; else
      install -m 755 "$GBREPO_DIR/templates/rag/$t" "$tools_dir/$t"
    fi
  done
  ok "rag-prep tools installed -> $tools_dir/"

  # ── 4. rag config (template for the buyer to fill) ─────────────────────
  if [ ! -f "$cfg_dir/rag.json" ]; then
    if [ "$GBPLAN" = "1" ]; then plan "write rag config template: $cfg_dir/rag.json"; else
      cat > "$cfg_dir/rag.json" <<EOF
{
  "_comment": "gb10-stack RAG config. Fill corpus + collections + ingest account, then run tools/ingest.py.",
  "base": "http://localhost:$port_webui",
  "ingest_account": { "email": "", "password": "" },
  "corpus_root": "~/rag-corpus",
  "collections": {
    "01_library": "Library One",
    "02_library": "Library Two"
  },
  "convert": {
    "in_dir": "~/rag-corpus/raw",
    "out_dir": "~/rag-corpus/md",
    "redact": []
  },
  "eval": { "qa_file": "~/rag-corpus/eval-qa.json" }
}
EOF
    fi
    ok "rag config template written -> $cfg_dir/rag.json (fill corpus + account, then run tools/ingest.py)"
  else
    ok "rag config already present -> $cfg_dir/rag.json"
  fi

  # ── 5. user units for both containers (survive reboot) ────────────────
  for name in open-webui open-webui-proxy; do
    local unit="/etc/systemd/system/${name}.service"
    if [ "$GBPLAN" = "1" ]; then plan "write user unit: $unit (docker start $name)"; else
      write_root "$unit" <<EOF
[Unit]
Description=$name (docker)
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
ExecStart=/usr/bin/docker start $name
ExecStop=/usr/bin/docker stop $name

[Install]
WantedBy=multi-user.target
EOF
      run_root "systemctl daemon-reload"
      run_root "systemctl enable ${name}.service"
    fi
  done
  ok "reboot units enabled: open-webui.service, open-webui-proxy.service"
}
