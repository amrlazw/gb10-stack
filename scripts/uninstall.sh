#!/usr/bin/env bash
# gb10-stack uninstall — pull the whole stack off this box.
#
#   bash uninstall.sh --plan         # zero-write dry run (shows every step)
#   bash uninstall.sh                # remove services, containers, config, files.
#                                    #   KEEPS: open-webui volume (your RAG data),
#                                    #   Docker images, and the 35B HF weight cache
#                                    #   -> a re-install is fast and your collections survive.
#   bash uninstall.sh --purge        # additionally wipes the open-webui volume,
#                                    #   Docker images, the 35B weights, and the
#                                    #   observability packages. Nothing to come back to.
#   bash uninstall.sh --yes          # skip the UNINSTALL confirmation prompt
#
# Idempotent: every step tolerates an already-absent component. No `set -e`:
# a cleanup script must not die on the first thing that is already gone.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR="$(pwd)"

GB_PLAN=0; GB_FORCE=0; GB_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) GB_PLAN=1 ;;
    --purge) GB_PURGE=1 ;;
    --yes)  GB_YES=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
GB_PURGE="${GB_PURGE:-0}"
export GBPLAN="$GB_PLAN"

source "$REPO_DIR/scripts/common.sh"

echo "════════════════════════════════════════════════════"
if [ "$GB_PLAN" = "1" ]; then MODE="PLAN (zero writes)"; else MODE="LIVE"; fi
echo " gb10-stack UNINSTALL | mode: ${MODE}"
if [ "$GB_PURGE" = "1" ]; then
  echo " | purge: YES — data, images, weights and observability will be destroyed"
else
  echo " | keeps: RAG volume + Docker images + 35B weight cache (fast re-install)"
fi
echo "════════════════════════════════════════════════════"

# ── confirmation ─────────────────────────────────────────────────────────
if [ "$GB_PLAN" != "1" ] && [ "$GB_YES" != "1" ]; then
  echo
  if [ "$GB_PURGE" = "1" ]; then
    echo "WARNING: --purge destroys the Open WebUI volume (all RAG collections),"
    echo "the Docker images, and the ~22 GB 35B weight cache."
  fi
  echo -n "Type UNINSTALL to proceed: "
  read -r CONF
  [ "$CONF" = "UNINSTALL" ] || { echo "aborted."; exit 0; }
fi

step() { echo "── $1"; }

# ── 1. systemd units ─────────────────────────────────────────────────────
step "systemd units"
for u in qwen38-35b.service open-webui.service open-webui-proxy.service; do
  if [ "$GB_PLAN" = "1" ]; then
    plan "systemctl disable --now + remove /etc/systemd/system/$u"
  else
    run_root "systemctl disable --now $u 2>/dev/null || true"
    run_root "rm -f /etc/systemd/system/$u"
    ok "unit $u stopped & removed"
  fi
done
run_root "systemctl daemon-reload"

step "mission-control user unit"
MC_UNIT="$HOME/.config/systemd/user/mission-control.service"
if [ "$GB_PLAN" = "1" ]; then
  plan "systemctl --user disable --now mission-control.service; remove $MC_UNIT"
else
  systemctl --user disable --now mission-control.service 2>/dev/null || true
  rm -f "$MC_UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  ok "mission-control user unit removed"
fi

# ── 2. containers ────────────────────────────────────────────────────────
step "docker containers"
for c in qwen38-35b qwen38-sglang open-webui open-webui-proxy dcgm-exporter; do
  if [ "$GB_PLAN" = "1" ]; then
    plan "docker rm -f $c (if present)"
  else
    docker rm -f "$c" >/dev/null 2>&1 && ok "container $c removed" || ok "container $c not present (skipped)"
  fi
done

# ── 3. files & config ────────────────────────────────────────────────────
step "files & config"
for p in "$HOME/mission-control" "$HOME/.config/qwen38" "$HOME/.gb10-stack" \
         "$HOME/Desktop/DGX-Mission-Control.desktop"; do
  if [ "$GB_PLAN" = "1" ]; then
    plan "rm -rf $p (if present)"
  else
    [ -e "$p" ] && rm -rf "$p" && ok "removed $p" || ok "$p not present (skipped)"
  fi
done

# ── 4. purge tier ────────────────────────────────────────────────────────
if [ "$GB_PURGE" = "1" ]; then
  step "PURGE: data, images, weights, observability packages"
  if [ "$GB_PLAN" = "1" ]; then
    plan "docker volume rm open-webui (ALL RAG collections destroyed)"
    plan "docker rmi: sglang, open-webui, nginx:alpine, dcgm-exporter"
    plan "rm -rf 35B HF weight cache (~22 GB)"
    plan "apt-get remove prometheus prometheus-node-exporter grafana"
  else
    docker volume rm open-webui >/dev/null 2>&1 && ok "volume open-webui destroyed" || ok "volume open-webui not present (skipped)"
    run_root "docker rmi lmsysorg/sglang ghcr.io/open-webui/open-webui:main nginx:alpine nvidia/dcgm-exporter:latest 2>/dev/null || true"
    ok "docker images removed"
    rm -rf "$HOME/.cache/huggingface/hub/models--nvidia--Qwen3.6-35B-A3B-NVFP4"
    ok "35B weight cache removed (~22 GB)"
    run_root "DEBIAN_FRONTEND=noninteractive apt-get remove -y prometheus prometheus-node-exporter grafana 2>/dev/null || true"
    ok "observability packages removed"
  fi
else
  echo
  echo "  kept (fast re-install, data preserved):"
  echo "    - open-webui Docker volume (your RAG collections)"
  echo "    - Docker images (SGLang, Open WebUI, nginx)"
  echo "    - 35B HF weight cache (~22 GB)"
  echo "  run with --purge to destroy all of the above."
fi

echo
echo "════════════════════════════════════════════════════"
if [ "$GB_PLAN" = "1" ]; then
  echo " PLAN complete (zero writes). Re-run without --plan to execute."
else
  echo " UNINSTALL complete. Re-install any time with:"
  echo "   curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash"
fi
echo "════════════════════════════════════════════════════"
