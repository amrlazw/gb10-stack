#!/usr/bin/env bash
# Module 30 — Observability (ESM-gated).
#  Prometheus 2.45+esm: 3 scrape jobs — node :9100, dcgm :9400, engine :30000/metrics
#  node-exporter 1.7+esm + collector timers (apt, ipmitool, mellanox-hca-temp, nvme, smartmon)
#  DCGM exporter docker nvidia/dcgm-exporter:latest -> :9400 (bridge)
#  Loki + Alloy + Grafana (ESM) for logs/dashboards.
# Requires Ubuntu Pro attached (`sudo pro attach <token>`) — the one external
# dependency of the whole package. Preflight checks `pro status` and refuses
# cleanly with instructions when ESM is absent.

MIN_FREE_GB=8

mod_install() {
  local port_27b="${PORT:-30000}"

  # ── ESM gate ───────────────────────────────────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "check: pro status (ESM required)"
  else
    if ! sudo pro status --format json 2>/dev/null | grep -qE '"active" *: *true|esm.*active.*true'; then
      warn "Ubuntu Pro not active — ESM packages (prometheus, grafana, loki, alloy, node-exporter) will not install."
      warn "Attach first, then rerun this module:"
      warn "  sudo pro attach <token>          (one-time; token from https://ubuntu.com/pro)"
      warn "  bash $GBREPO_DIR/install.sh --module observability"
      return 0
    fi
    ok "ESM active"
  fi

  # ── packages ───────────────────────────────────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "sudo apt-get install prometheus prometheus-node-exporter grafana loki alloy"
  else
    run_root "DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus prometheus-node-exporter grafana loki alloy"
    ok "ESM observability packages installed"
  fi

  # ── prometheus scrape config (3 jobs, templatized engine port) ────────
  if [ "$GBPLAN" = "1" ]; then
    plan "write /etc/prometheus/prometheus.yml (3 jobs)"
  else
    local prom_cfg=/etc/prometheus/prometheus.yml
    if [ -f "$prom_cfg" ]; then
      # Don't clobber a working config: append the engine job only if missing.
      if ! grep -q "job_name: engine" "$prom_cfg"; then
        cp -a "$prom_cfg" "${prom_cfg}.gbstack.bak"
        cat >> "$prom_cfg" <<EOF
  - job_name: engine
    static_configs:
      - targets: ['localhost:$port_27b']
    metrics_path: /metrics
EOF
        ok "prometheus.yml: engine job appended (backup: ${prom_cfg}.gbstack.bak)"
      else
        ok "prometheus.yml: engine job already present"
      fi
    else
      write_root "$prom_cfg" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['localhost:9100']
  - job_name: dcgm
    static_configs:
      - targets: ['localhost:9400']
  - job_name: engine
    static_configs:
      - targets: ['localhost:$port_27b']
    metrics_path: /metrics
EOF
      ok "prometheus.yml written (3 jobs)"
    fi
    run_root "systemctl restart prometheus"
  fi

  # ── node-exporter collector units (ESM ships static units; enable them) ─
  local collectors="prometheus-node-exporter-apt.service prometheus-node-exporter-ipmitool-sensor.service prometheus-node-exporter-mellanox-hca-temp.service prometheus-node-exporter-nvme.service prometheus-node-exporter-smartmon.service"
  if [ "$GBPLAN" = "1" ]; then
    plan "enable node-exporter collectors: $collectors"
  else
    for u in $collectors; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
        run_root "systemctl enable $u"
      else
        info "collector not present (hardware mismatch?): $u — skipping"
      fi
    done
    run_root "systemctl restart prometheus-node-exporter"
    ok "node-exporter collectors enabled"
  fi

  # ── DCGM exporter (docker, bridge, :9400) ─────────────────────────────
  if [ "$GBPLAN" = "1" ]; then
    plan "docker run dcgm-exporter -> :9400"
  else
    if docker ps -a --format '{{.Names}}' | grep -qx dcgm-exporter; then
      ok "dcgm-exporter present — starting"
      docker start dcgm-exporter >/dev/null
    else
      docker run -d --name dcgm-exporter --restart unless-stopped \
        -p 9400:9400 \
        nvidia/dcgm-exporter:latest >/dev/null
      ok "dcgm-exporter started (:9400)"
    fi
  fi

  # ── grafana provisioning: point datasources at prometheus + loki ──────
  if [ "$GBPLAN" = "1" ]; then
    plan "grafana datasources: prometheus :9090, loki :3100"
  else
    local gdir=/etc/grafana/provisioning/datasources
    mkdir -p "$gdir"
    write_root "$gdir/gb10-stack.yaml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://localhost:3100
EOF
    run_root "systemctl restart grafana-server"
    ok "grafana datasources provisioned (Prometheus default, Loki)"
  fi

  ok "observability stack: prometheus :9090, node :9100, dcgm :9400, grafana :3000, loki :3100"
}
