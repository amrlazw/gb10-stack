#!/usr/bin/env bash
# gen-services.sh — generate mission-control/mc.json from what is ACTUALLY on this box.
# Runs at install time (module 40) and any time after components change.
# Vision workloads (arcade, VLM webUI, faceswap, moondream) are never listed:
# a component appears only if its unit/container/port is detected.
set -euo pipefail

MC_HOME="${MC_HOME:-$HOME/mission-control}"
OUT="$MC_HOME/mc.json"
PORT_27B="${PORT_27B:-30000}"
PORT_35B="${PORT:-30000}"

# tailscale MagicDNS name (e.g. box.tailabcd12.ts.net) — empty when not on tailnet
TS_DOMAIN=""
if command -v tailscale >/dev/null 2>&1; then
  TS_DOMAIN=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))
except Exception: print("")' 2>/dev/null || true)
fi
rurl() { # rurl <port-or-empty>
  if [ -n "$TS_DOMAIN" ]; then
    [ -n "${1:-}" ] && echo "https://$TS_DOMAIN:$1/" || echo "https://$TS_DOMAIN/"
  else
    echo ""
  fi
}
unit_up() { # unit_up <unit> [system]  — unit exists (system or user)
  if systemctl list-unit-files 2>/dev/null | grep -q "^$1 "; then return 0; fi
  systemctl --user list-unit-files 2>/dev/null | grep -q "^$1 "
}
container_exists() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

SERVICES="[]"
add() { # add '<json-object>'
  SERVICES=$(echo "$SERVICES" | python3 -c 'import json,sys; a=json.load(sys.stdin); a.append(json.loads(sys.argv[1])); print(json.dumps(a))' "$1")
}

# ── 35B Flagship Solo Lane (gb10-stack: systemd unit qwen38-35b.service) ───
if unit_up qwen38-35b.service; then
  add "{\"id\":\"llm35b\",\"cat\":\"model\",\"name\":\"Qwen3.6-35B-A3B\",\"engine\":\"SGLang · NVFP4 MoE\",\"port\":$PORT_35B,\"kind\":\"sys\",\"unit\":\"qwen38-35b.service\",\"need_gb\":70}"
fi

# ── Open WebUI (docker) ───────────────────────────────────────────────────
if container_exists open-webui; then
  add "{\"id\":\"webui\",\"cat\":\"app\",\"name\":\"Open WebUI\",\"engine\":\"chat · qwen3.6-35b\",\"port\":80,\"kind\":\"docker\",\"containers\":[\"open-webui\",\"open-webui-proxy\"],\"need_gb\":2,\"url\":\"http://localhost/\",\"remote_url\":\"$(rurl 10000)\"}"
fi

# ── (future opt-in lanes append here; vision and remote desktop absent) ───

mkdir -p "$MC_HOME"
python3 -c 'import json,sys
svcs = json.loads(sys.argv[1])
json.dump({"services": svcs, "tailnet_origin": ("https://" + sys.argv[2] + ":8443") if sys.argv[2] else ""},
          open(sys.argv[3], "w"), indent=1)
print(f"mc.json: {len(svcs)} services -> {sys.argv[3]}")' "$SERVICES" "$TS_DOMAIN" "$OUT"
