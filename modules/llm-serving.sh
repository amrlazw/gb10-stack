#!/usr/bin/env bash
# Module 10 — LLM serving.
#  27B lane: DELEGATED to upstream dgx-spark-qwen38 (MIT) via its get.sh one-liner.
#            Upstream owns image, engine, keepalive proxy (:30001), Spark Cockpit (:30090).
#  35B lane: second SGLang unit, dual-live with P1 ordering (boots only after 27B healthy).
#            Shares the 27B API key file (~/.config/qwen38/api-key).
#  Flash 176B lane: opt-in only (GB_FLASH=1), +225 GB — never default.
#
# Env: GB_FLASH=1 to add the 176B lane. Ports tunable via PORT / PROXY_PORT (27B).

MIN_FREE_GB=110   # 27B image 38.6 GB + HF cache ~28 GB + 35B weights + headroom

mod_install() {
  local user="$GB_USER"
  local home_dir="$HOME"
  local qwen_cfg="$HOME/.config/qwen38"

  # ── 27B lane: delegate to upstream (idempotent — get.sh reuses the clone) ──
  if [ -f "$qwen_cfg/api-key" ] && systemctl list-unit-files 2>/dev/null | grep -q "^qwen38-sglang.service"; then
    ok "27B lane already installed (qwen38-sglang.service present) — skipping upstream"
  else
    info "27B lane: delegating to upstream dgx-spark-qwen38 (one-liner, MIT)"
    if [ "$GBPLAN" = "1" ]; then
      plan "curl -fsSL https://raw.githubusercontent.com/hasso5703/dgx-spark-qwen38/main/get.sh | bash -s --  (PORT=30000 PROXY_PORT=30001)"
    else
      # Upstream refuses sudo in front itself; we are a normal user here.
      curl -fsSL "https://raw.githubusercontent.com/hasso5703/dgx-spark-qwen38/main/get.sh" \
        | env PORT=30000 PROXY_PORT=30001 bash -s --
      ok "27B lane delegated to upstream (engine :30000, keepalive :30001, cockpit :30090)"
    fi
  fi

  # ── 35B lane: second unit, dual-live with health-ordered boot ────────────
  local port_35b="${PORT_35B:-30002}"
  local launch35="$qwen_cfg/launch-35b.sh"
  local unit35="/etc/systemd/system/qwen38-35b.service"
  local image35="lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1"
  local model35="nvidia/Qwen3.6-35B-A3B-NVFP4"
  local rev35="1355db6a052410cfd62085d94b58866fd0f2c3c5"

  # The 35B lane reads the SAME api-key the 27B lane generated. If upstream
  # hasn't created it yet (plan mode / fresh), we still template the path.
  write_file "$launch35" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/docker run --rm --name qwen38-35b --gpus all \
  --memory 60g --memory-swap 60g --shm-size 16g --network host --ipc=host \
  -e TORCHINDUCTOR_CACHE_DIR=/cache/inductor \
  -e HF_HUB_OFFLINE=1 \
  -v $home_dir/.config/qwen38/sglang-cache:/cache \
  -v $home_dir/.cache/huggingface:/root/.cache/huggingface \
  -v $home_dir/.config/qwen38:/out \
  $image35 \
  python3 -m sglang.launch_server \
    --trust-remote-code --model-path $model35 --revision $rev35 --tp-size 1 \
    --served-model-name qwen3.6-35b \
    --mem-fraction-static 0.45 \
    --attention-backend flashinfer --chunked-prefill-size 8192 \
    --disable-prefill-cuda-graph --cuda-graph-max-bs 8 \
    --disable-flashinfer-autotune \
    --moe-runner-backend flashinfer_cutlass \
    --max-running-requests 8 \
    --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
    --api-key "\$(cat $home_dir/.config/qwen38/api-key)" \
    --host 0.0.0.0 --port $port_35b
EOF

  # 35B unit — P1 ordering: wait up to 6 min for the 27B lane (:30000) health.
  local port_27b="${PORT:-30000}"
  write_root "$unit35" <<EOF
[Unit]
Description=Qwen3.6-35B-A3B NVFP4 (SGLang, capped docker), OpenAI API :$port_35b
# P1 dual-live ordering: boot only after the 27B lane is up AND healthy
# (SGLang sizes pools off free-at-boot memory; starting together would
# over-reserve and fail the min-viable check). ExecStartPre waits up to
# 6 min for :$port_27b health.
After=network-online.target docker.service qwen38-sglang.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=$user
Group=$user
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 72); do curl -s -m 2 http://127.0.0.1:$port_27b/health >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1'
ExecStart=/bin/bash $home_dir/.config/qwen38/launch-35b.sh
ExecStop=-/usr/bin/docker stop -t 20 qwen38-35b
Restart=always
# docker kills SGLang with SIGKILL (137) or SIGTERM (143) on a plain stop;
# that is a clean stop, not a failure (same convention as qwen38-sglang.service)
SuccessExitStatus=137 143
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

  if [ "$GBPLAN" != "1" ]; then
    chmod +x "$launch35"
    run_root "systemctl daemon-reload"
    run_root "systemctl enable qwen38-35b.service"
    # Don't start here if the 27B lane isn't up yet; the unit's ordering
    # handles boot. Start now only if 27B is already healthy.
    if curl -s -m 2 "http://127.0.0.1:$port_27b/health" >/dev/null 2>&1; then
      run_root "systemctl start qwen38-35b.service"
      ok "35B lane started (dual-live with 27B)"
    else
      info "35B lane enabled; will start at boot after 27B is healthy (or run: sudo systemctl start qwen38-35b.service)"
    fi
  fi
  ok "35B lane: unit $unit35, launch $launch35 (port $port_35b)"

  # ── Flash 176B lane (opt-in) ────────────────────────────────────────────
  if [ "${GB_FLASH:-0}" = "1" ]; then
    info "Flash 176B lane (opt-in): delegating to upstream flash lane (+225 GB)"
    if [ "$GBPLAN" = "1" ]; then
      plan "MODEL_CHOICE=flash curl -fsSL .../get.sh | bash -s --  (upstream flash lane)"
    else
      env MODEL_CHOICE=flash curl -fsSL "https://raw.githubusercontent.com/hasso5703/dgx-spark-qwen38/main/get.sh" | bash -s --
    fi
  else
    info "Flash 176B lane: skipped (set GB_FLASH=1 to enable; +225 GB)"
  fi
}
