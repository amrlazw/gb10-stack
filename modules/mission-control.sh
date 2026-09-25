#!/usr/bin/env bash
# Module 40 — DGX Mission Control (homegrown, stdlib-only).
#  server.py: 1s sampling, 5-min history, HMAC login + remote PIN, controls
#             services by kind (llm=docker, sys=systemd, user=systemd --user).
#  PACKAGING: server.py ships with a config loader — the component list comes
#             from mc.json GENERATED at install time from detected components
#             (scripts/gen-services.sh). Vision entries never appear because
#             their units don't exist on a non-vision box.
#  Runs as a systemd --user unit; exposed tailnet-only via module 50 funnel.

MIN_FREE_GB=1

mod_install() {
  local user="$GB_USER"
  local mc_home="$HOME/mission-control"
  local mc_port="${MC_PORT:-8765}"

  # ── 1. install server + static assets ──────────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "install mission-control -> $mc_home (server.py + static/)"
  else
    mkdir -p "$mc_home"
    cp -a "$GBREPO_DIR/templates/mission-control/." "$mc_home/"
    chmod +x "$mc_home/server.py"
    ok "mission-control installed -> $mc_home"
  fi

  # ── 2. generate mc.json from detected components ───────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "generate $mc_home/mc.json from detected components (vision excluded by construction)"
  else
    MC_HOME="$mc_home" PORT_27B="${PORT:-30000}" PORT_35B="${PORT_35B:-30002}" \
      bash "$GBREPO_DIR/scripts/gen-services.sh"
    ok "mc.json generated (non-vision components only)"
  fi

  # ── 3. remote PIN (random on first install; 600 perms) ─────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "generate remote_pin (6 digits, mode 600) in $mc_home"
  else
    if [ ! -f "$mc_home/remote_pin" ]; then
      python3 -c 'import secrets; print(f"{secrets.randbelow(10**6):06d}")' > "$mc_home/remote_pin"
      chmod 600 "$mc_home/remote_pin"
      ok "remote PIN generated (view it: cat $mc_home/remote_pin)"
    else
      ok "remote PIN already present"
    fi
  fi

  # ── 4. systemd --user unit ─────────────────────────────────────────────
  local unit="$HOME/.config/systemd/user/mission-control.service"
  if [ "$GBPLAN" = "1" ]; then
    plan "write user unit: $unit"
  else
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Unit]
Description=DGX Mission Control (local dashboard on 127.0.0.1:$mc_port)
After=default.target

[Service]
ExecStart=/usr/bin/python3 $mc_home/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now mission-control.service
    # linger so the user unit survives logout on a headless box
    if ! loginctl show-user "$user" 2>/dev/null | grep -q "^Linger=yes"; then
      run_root "loginctl enable-linger $user"
      ok "linger enabled for $user (mission control survives logout)"
    fi
    ok "mission-control.service running (:$mc_port)"
  fi

  info "Mission Control: http://127.0.0.1:$mc_port (tailnet URL after module 50)"
}
