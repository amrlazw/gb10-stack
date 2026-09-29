#!/usr/bin/env bash
# mission-control.sh — standalone DGX Mission Control installer (no repo clone).
#
#   curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/mission-control.sh | bash
#
# Pulls server.py + static UI directly from the GitHub raw CDN into ~/mission-control,
# generates mc.json from detected components, installs the systemd --user unit on
# 127.0.0.1:8765 and creates the desktop shortcut. Idempotent: re-running updates
# the dashboard in place (mc.json is regenerated, remote_pin is preserved).
#
# The full stack installer (install.sh) does the same module 40 work; this script
# exists so a box can get the dashboard without checking out the repository.
set -uo pipefail

BASE="https://raw.githubusercontent.com/amrlazw/gb10-stack/main/templates/mission-control"
MC_HOME="$HOME/mission-control"
MC_PORT="${MC_PORT:-8765}"
UNIT="$HOME/.config/systemd/user/mission-control.service"
DESKTOP_FILE="$HOME/Desktop/DGX-Mission-Control.desktop"

info() { printf "\033[1;34m[mission-control]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[mission-control] WARNING:\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[mission-control] ERROR:\033[0m %s\n" "$*" >&2; }

# ── 0. preflight ──────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1   || { err "curl not found — install it first (sudo apt install curl)."; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 not found — Mission Control is stdlib-only but still needs python3."; exit 1; }

# ── 1. fetch dashboard files from the raw CDN (no git, no clone) ─────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
files=( "server.py" "static/index.html" "static/fonts/inter.woff2" "static/fonts/jetbrains-mono.woff2" "static/fonts/space-grotesk.woff2" )
info "fetching ${#files[@]} files from $BASE"
for f in "${files[@]}"; do
  dest="$TMP/$f"
  mkdir -p "$(dirname "$dest")"
  for attempt in 1 2 3; do
    if curl -fsSL --retry 2 --retry-connrefused -o "$dest" "$BASE/$f"; then break; fi
    [ "$attempt" -eq 3 ] && { err "download failed: $f"; exit 1; }
    sleep 2
  done
done
# never replace a running dashboard with a broken download
python3 -m py_compile "$TMP/server.py" || { err "downloaded server.py failed syntax check — aborting."; exit 1; }
info "download complete, server.py syntax OK"

# ── 2. stage into ~/mission-control (preserve remote_pin) ────────────────
info "installing -> $MC_HOME"
mkdir -p "$MC_HOME/static/fonts"
cp -f "$TMP/server.py" "$MC_HOME/server.py"
cp -f "$TMP/static/index.html" "$MC_HOME/static/index.html"
cp -f "$TMP"/static/fonts/*.woff2 "$MC_HOME/static/fonts/"
chmod +x "$MC_HOME/server.py"

# ── 3. remote PIN (6 digits, mode 600 — keep existing on re-run) ─────────
if [ ! -f "$MC_HOME/remote_pin" ]; then
  python3 -c 'import secrets; print(f"{secrets.randbelow(10**6):06d}")' > "$MC_HOME/remote_pin"
  chmod 600 "$MC_HOME/remote_pin"
  info "remote PIN generated (view: cat $MC_HOME/remote_pin)"
else
  info "remote PIN preserved"
fi

# ── 4. generate mc.json from what is ACTUALLY on this box ────────────────
python3 - "$MC_HOME/mc.json" <<'PY'
import json, subprocess, sys
out = sys.argv[1]
def sh(cmd):
    try: return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15).stdout
    except Exception: return ""
svcs = []
units = sh("systemctl list-unit-files --no-pager 2>/dev/null") + sh("systemctl --user list-unit-files --no-pager 2>/dev/null")
if "qwen38-35b.service" in units:
    svcs.append({"id":"llm35b","cat":"model","name":"Qwen3.6-35B-A3B","engine":"SGLang · NVFP4 MoE","port":30000,"kind":"sys","unit":"qwen38-35b.service","need_gb":70})
if "open-webui" in sh("docker ps -a --format '{{.Names}}' 2>/dev/null").split():
    svcs.append({"id":"webui","cat":"app","name":"Open WebUI","engine":"chat · qwen3.6-35b","port":80,"kind":"docker","containers":["open-webui","open-webui-proxy"],"need_gb":2,"url":"http://localhost/"})
ts = ""
if sh("command -v tailscale"):
    try: ts = json.loads(sh("tailscale status --json 2>/dev/null")).get("Self",{}).get("DNSName","").rstrip(".")
    except Exception: ts = ""
json.dump({"services": svcs, "tailnet_origin": ("https://"+ts+":8443") if ts else ""}, open(out,"w"), indent=1)
print(f"mc.json: {len(svcs)} service(s) detected -> {out}")
PY

# ── 5. systemd --user unit on 127.0.0.1:8765 ─────────────────────────────
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<EOF
[Unit]
Description=DGX Mission Control (local dashboard on 127.0.0.1:$MC_PORT)
After=default.target

[Service]
ExecStart=/usr/bin/python3 $MC_HOME/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now mission-control.service || { err "failed to start mission-control.service"; exit 1; }

# linger: dashboard must survive logout on a headless box (needs sudo, once)
if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
  if command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
    info "linger enabled for $USER"
  else
    warn "could not enable linger (needs: sudo loginctl enable-linger $USER) — dashboard runs only while your session is logged in"
  fi
fi

# ── 6. desktop shortcut ──────────────────────────────────────────────────
mkdir -p "$HOME/Desktop"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Exec=xdg-open http://127.0.0.1:$MC_PORT
Name=DGX Mission Control
Comment=NVIDIA GB10 Mission Control Dashboard & RAG Studio
Icon=utilities-system-monitor
Categories=System;Utility;Development;
EOF
chmod +x "$DESKTOP_FILE"
# NOTE: persisting DING's `metadata::trusted` flag needs a live user session;
# on a fresh box run over SSH this can no-op. No problem: server.py
# self-heals the shortcut + flag on first session boot (5-min retry loop).
command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true

# ── 7. health check ──────────────────────────────────────────────────────
ok=""
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MC_PORT/" 2>/dev/null || true)
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 1
done

echo
if [ -n "$ok" ]; then
  printf "\033[1;32m"
  echo "  DGX MISSION CONTROL IS LIVE"
  echo "  Dashboard:   http://127.0.0.1:$MC_PORT"
  echo "  Desktop:     DGX Mission Control shortcut (click it)"
  echo "  Remote PIN:  cat $MC_HOME/remote_pin   (for the remote access page)"
  echo "  Health:      systemctl --user status mission-control"
  echo "  Uninstall:   systemctl --user disable --now mission-control && rm -rf $MC_HOME $UNIT $DESKTOP_FILE"
  printf "\033[0m\n"
else
  warn "dashboard not responding yet — check: journalctl --user -u mission-control -n 20 --no-pager"
  exit 1
fi
