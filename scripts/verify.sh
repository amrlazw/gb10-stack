#!/usr/bin/env bash
# gb10-stack verify.sh — the "done" ledger. Every check must PASS.
# Read-only: never starts/stops services, never writes (exit code = # fails).
# Usage: bash verify.sh [option-id]   (defaults to option-1)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR="$(pwd)"
export GBSTACK_HOME="${GBSTACK_HOME:-$HOME/.gb10-stack}"

PASS=0; FAIL=0; SKIP=0
p() { printf ' \033[1;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
f() { printf ' \033[1;31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
s() { printf ' \033[1;33mskip\033[0m  %s\n' "$1"; SKIP=$((SKIP+1)); }

check() { # check <description> <cmd...>
  local desc="$1"; shift
  if [ "$1" = "-" ]; then s "$desc (opt-in component)"; return; fi
  if "$@" >/dev/null 2>&1; then p "$desc"; else f "$desc"; fi
}
port_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
unit_active() {
  local u="$1" scope="${2:-system}"
  if [ "$scope" = "user" ]; then
    systemctl --user is-active --quiet "$u"
  else
    systemctl is-active --quiet "$u"
  fi
}

echo "gb10-stack verify — $(date -u +%Y-%m-%dT%H:%M:%SZ) — $(hostname)"
echo "────────────────────────────────────────────────────────"

# ── L0: base ────────────────────────────────────────────────────────────
check "docker daemon up" docker info
check "nvidia driver present" nvidia-smi

# ── L1: LLM serving (Flagship 35B NVFP4 MoE) ───────────────────────────
check "35B engine healthy (:30000 /health)" curl -sf -m 3 http://127.0.0.1:30000/health
check "35B unit active (qwen38-35b.service)" unit_active qwen38-35b.service
check "api-key file present (~/.config/qwen38/api-key)" test -r "$HOME/.config/qwen38/api-key"

# ── L2: RAG ─────────────────────────────────────────────────────────────
check "open-webui container running" test "$(docker ps --format '{{.Names}}' | grep -cx open-webui)" = 1
check "open-webui-proxy container running" test "$(docker ps --format '{{.Names}}' | grep -cx open-webui-proxy)" = 1
check "webui reachable via proxy (:80)" curl -sf -m 3 -o /dev/null http://127.0.0.1:80/
check "webui reachable (:3000)" curl -sf -m 3 -o /dev/null http://127.0.0.1:3000/
check "rag tools installed" test -x "$HOME/.gb10-stack/rag/tools/ingest.py"
check "rag config present" test -f "$HOME/.gb10-stack/rag/rag.json"

# ── L3: observability (ESM — skip cleanly when not attached) ────────────
if sudo pro status --format json 2>/dev/null | grep -qE '"active" *: *true'; then
  check "prometheus up (:9090)" curl -sf -m 3 -o /dev/null http://127.0.0.1:9090/-/healthy
  check "node-exporter up (:9100)" port_open 9100
  check "dcgm-exporter up (:9400)" port_open 9400
  check "grafana up (:3000)" port_open 3000
else
  s "observability (ESM not attached — sudo pro attach <token>)"
fi

# ── L4: mission control ─────────────────────────────────────────────────
check "mission control user unit active" unit_active mission-control.service user
check "mission control up (:8765)" port_open 8765
check "mc.json generated" test -f "$HOME/mission-control/mc.json"
check "mc.json has no vision entries" bash -c "! grep -qE 'arcade|vlm|faceswap|moondream' $HOME/mission-control/mc.json"
check "desktop shortcut present" test -f "$HOME/Desktop/DGX-Mission-Control.desktop"

# ── L5: integrity ───────────────────────────────────────────────────────
check "no leftover .gbstack.bak in /etc (or inspect them)" bash -c "! ls /etc/*.gbstack.bak 2>/dev/null | grep -q ."
check "state file consistent" test -f "$GBSTACK_HOME/state"

echo "────────────────────────────────────────────────────────"
echo "RESULT: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" = 0 ] && echo "DONE — every required check passed" || echo "NOT DONE — fix the FAIL rows above"
exit "$FAIL"
