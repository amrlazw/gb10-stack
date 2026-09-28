#!/usr/bin/env bash
# Module 10 — LLM serving (Flagship 35B NVFP4 MoE Solo Architecture).
#  Model: nvidia/Qwen3.6-35B-A3B-NVFP4 (MoE architecture, ~22.2 GB weights).
#  Engine: SGLang official release (lmsysorg/sglang), host networking.
#  Memory profile: --memory 70g, --mem-fraction-static 0.60.
#    Leaves ~50 GB guaranteed unified headroom for Ubuntu, Open WebUI, and desktop.
#    Zero OOM contention (27B and vision models left completely out of baseline).
#  Port: 127.0.0.1:30000 (standard OpenAI/Anthropic API entrypoint).

MIN_FREE_GB=75   # 35B weights (~23 GB) + SGLang image + cache + headroom

mod_install() {
  local user="$GB_USER"
  local home_dir="$HOME"
  local qwen_cfg="$HOME/.config/qwen38"
  local port_35b="${PORT:-30000}"
  local launch35="$qwen_cfg/launch-35b.sh"
  local unit35="/etc/systemd/system/qwen38-35b.service"
  local image35="lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1"
  local model35="nvidia/Qwen3.6-35B-A3B-NVFP4"
  local rev35="1355db6a052410cfd62085d94b58866fd0f2c3c5"

  info "35B lane: setting up Qwen3.6-35B-A3B NVFP4 on SGLang (port $port_35b)"

  # ── Configuration & Security ───────────────────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "ensure dir: $qwen_cfg (mode 700)"
    plan "generate API key if missing -> $qwen_cfg/api-key (mode 600)"
  else
    mkdir -p "$qwen_cfg" && chmod 700 "$qwen_cfg"
    if [ ! -s "$qwen_cfg/api-key" ]; then
      python3 -c "import secrets; print(secrets.token_urlsafe(24))" > "$qwen_cfg/api-key"
      chmod 600 "$qwen_cfg/api-key"
      ok "generated API key -> $qwen_cfg/api-key"
    else
      ok "existing API key kept -> $qwen_cfg/api-key"
    fi
    mkdir -p "$qwen_cfg/sglang-cache"
  fi

  # ── Render 35B launch script ───────────────────────────────────────────
  # Solo GB10 tuning: --mem-fraction-static 0.60 gives ~50 GB dedicated KV pool
  # while keeping ~50 GB completely unreserved for OS, Open WebUI, and RAG.
  write_file "$launch35" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/docker run --rm --name qwen38-35b --gpus all \\
  --memory 70g --memory-swap 70g --shm-size 16g --network host --ipc=host \\
  -e TORCHINDUCTOR_CACHE_DIR=/cache/inductor \\
  -e HF_HUB_OFFLINE=1 \\
  -v $home_dir/.config/qwen38/sglang-cache:/cache \\
  -v $home_dir/.cache/huggingface:/root/.cache/huggingface \\
  -v $home_dir/.config/qwen38:/out \\
  $image35 \\
  python3 -m sglang.launch_server \\
    --trust-remote-code --model-path $model35 --revision $rev35 --tp-size 1 \\
    --served-model-name qwen3.6-35b \\
    --mem-fraction-static 0.60 \\
    --attention-backend flashinfer --chunked-prefill-size 8192 \\
    --disable-prefill-cuda-graph --cuda-graph-max-bs 8 \\
    --disable-flashinfer-autotune \\
    --moe-runner-backend flashinfer_cutlass \\
    --max-running-requests 8 \\
    --reasoning-parser qwen3 --tool-call-parser qwen3_coder \\
    --api-key "\$(cat $home_dir/.config/qwen38/api-key)" \\
    --host 0.0.0.0 --port $port_35b
EOF

  if [ "$GBPLAN" != "1" ]; then
    chmod 755 "$launch35"
  fi

  # ── Render systemd unit (autonomous start, zero dependencies on 27B) ───
  write_root "$unit35" <<EOF
[Unit]
Description=Qwen3.6-35B-A3B NVFP4 (SGLang, solo 70g cap), OpenAI API :$port_35b
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=$user
Group=$user
ExecStartPre=-/usr/bin/docker rm -f qwen38-35b
ExecStart=/bin/bash $launch35
ExecStop=-/usr/bin/docker stop -t 20 qwen38-35b
Restart=always
SuccessExitStatus=137 143
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  if [ "$GBPLAN" = "1" ]; then
    plan "systemctl daemon-reload && systemctl enable --now qwen38-35b.service"
  else
    run_root "systemctl daemon-reload"
    run_root "systemctl enable qwen38-35b.service"
    run_root "systemctl restart qwen38-35b.service"
    ok "35B systemd service active on port $port_35b (standalone, zero OOM risk)"
  fi
}
