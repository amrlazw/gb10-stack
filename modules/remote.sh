#!/usr/bin/env bash
# Module 50 — Remote access.
#  Tailscale: up (idempotent) + tailnet-only funnels:
#     :10000 -> 127.0.0.1:80    (Open WebUI via nginx proxy)
#     :8443  -> 127.0.0.1:8765  (Mission Control)
#  Sunshine: headless remote desktop — delegated to upstream sunshine-setup
#            (seanGSISG) via its documented one-liner; GB_SUNSHINE=0 to skip.
#  ssh: prints the tailnet IP for onboarding; does NOT modify sshd config.

MIN_FREE_GB=1

mod_install() {
  local user="$GB_USER"
  local mc_port="${MC_PORT:-8765}"

  # ── 1. tailscale up (idempotent) ───────────────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "tailscale up (if not already) + funnels :10000 -> :80, :8443 -> :$mc_port (tailnet-only)"
  else
    if ! command -v tailscale >/dev/null 2>&1; then
      run_root "curl -fsSL https://tailscale.com/install.sh | sh"
    fi
    if tailscale status >/dev/null 2>&1; then
      ok "tailscale already up"
    else
      # Interactive auth: the user approves on their device. Run in foreground.
      sudo tailscale up --hostname="$(hostname -s)"
      ok "tailscale up"
    fi
    TS_IP=$(tailscale ip -4 2>/dev/null || true)

    # serve: bind public ports to local services (idempotent — re-running
    # re-points the same port). NOTE: `tailscale serve` ports are reachable
    # from the internet by default (auth is per-service: Open WebUI login,
    # Mission Control PIN). To make them TAILNET-ONLY, restrict with ufw:
    #   sudo ufw allow from <tailscale-cidr> to any port 10000,8443 proto tcp
    # (the reference box runs tailnet-only via firewall; this module ships the
    # serve rules and documents the restriction — it does not silently open
    # the box to the internet without saying so.)
    sudo tailscale serve 10000 80
    sudo tailscale serve 8443 "$mc_port"
    info "serve rules: :10000 -> :80 (webui), :8443 -> :$mc_port (mission control)"
    warn "serve ports are internet-reachable by default — add the ufw tailnet-only rule above to close that."
    info "tailnet IP: ${TS_IP:-?}"
    info "ssh onboarding:  ssh $user@${TS_IP:-<tailscale-ip>}"
  fi

  # ── 2. Sunshine (headless remote desktop) — delegated ──────────────────
  if [ "${GB_SUNSHINE:-1}" = "1" ]; then
    if [ "$GBPLAN" = "1" ]; then
      plan "delegate: sunshine-setup one-liner (seanGSISG/sunshine-setup, upstream)"
    else
      if systemctl --user is-enabled sunshine.service >/dev/null 2>&1 || pgrep -x sunshine >/dev/null 2>&1; then
        ok "sunshine already present — skipping"
      else
        info "installing Sunshine (delegated to upstream sunshine-setup)"
        # Upstream one-liner (MIT); it handles the user unit + headless config.
        if curl -fsSL "https://raw.githubusercontent.com/seanGSISG/sunshine-setup/main/sunshine-setup.sh" -o /tmp/sunshine-setup.sh 2>/dev/null && [ -s /tmp/sunshine-setup.sh ]; then
          bash /tmp/sunshine-setup.sh || warn "sunshine-setup failed — install manually: https://github.com/seanGSISG/sunshine-setup"
          rm -f /tmp/sunshine-setup.sh
        else
          warn "could not fetch sunshine-setup — install manually: https://github.com/seanGSISG/sunshine-setup"
        fi
      fi
    fi
  else
    info "sunshine: skipped (GB_SUNSHINE=0)"
  fi
}
