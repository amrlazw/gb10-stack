#!/usr/bin/env bash
# gb10-stack installer — orchestrator.
#
#   bash install.sh                      # default option (option-1, full non-vision)
#   bash install.sh --plan               # zero-write dry run (safe on any box, incl. the reference)
#   bash install.sh --option option-1    # pick a manifest option
#   bash install.sh --force              # ignore completed-module state
#   bash install.sh --module rag         # run only one module (repair mode)
#
# Convention: NO root in front of this script. sudo is called only for the
# specific steps that need it (never `curl | sudo bash`, never piped user
# input through sudo — that incident orphaned an API key on the reference
# box, 2026-09-13).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_DIR="$(pwd)"

# ── arg parse ────────────────────────────────────────────────────────────
GB_OPT=""; GB_PLAN=0; GB_FORCE=0; GB_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)   GB_PLAN=1 ;;
    --force)  GB_FORCE=1 ;;
    --module) GB_ONLY="$2"; shift ;;
    --option) GB_OPT="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

# ── root refusal (before ANY write; see 2026-09-13 incident) ────────────
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
  echo "ERROR: this installer was piped into sudo. Refusing before any write." >&2
  echo "  re-run without sudo in front: curl -fsSL <REPO_URL>/get.sh | bash" >&2
  exit 1
fi

export GBSTACK_HOME="${GBSTACK_HOME:-$HOME/.gb10-stack}"
export GBPLAN="$GB_PLAN" GBFORCE="$GB_FORCE" GBREPO_DIR="$REPO_DIR"

source "$REPO_DIR/scripts/common.sh"

# ── manifest read (bash+awk; no yq dependency) ──────────────────────────
MANIFEST="$REPO_DIR/config/options.yaml"
read_manifest() {  # read_manifest <option-id>  -> sets GB_MODULES, GB_MIN_FREE
  local id="${1:-}"
  if [ -z "$id" ]; then
    id=$(awk '/^  - id:/{v=$3} /default: true/{print v; exit}' "$MANIFEST")
  fi
  [ -n "$id" ] || { echo "no option id given and no default in manifest" >&2; exit 1; }
  if ! awk -v id="$id" '/^  - id:/ && $3==id {found=1} END {exit !found}' "$MANIFEST"; then
    echo "option not found in manifest: $id" >&2; exit 1
  fi
  GB_MODULES=$(awk -v id="$id" '
    /^  - id:/ { on = ($3 == id) }
    on && /^    modules:/ { inmod=1; next }
    on && inmod {
      if ($0 ~ /^[[:space:]]+- /) { gsub(/^[[:space:]]+-[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); if ($0 != "") print $0 }
      else if ($0 !~ /^[[:space:]]*$/) inmod=0
    }
  ' "$MANIFEST")
  GB_MIN_FREE=$(awk '/^  min_free_gb:/{print $2; exit}' "$MANIFEST")
  GB_MIN_FREE="${GB_MIN_FREE:-135}"
}
read_manifest "$GB_OPT"

if [ -n "$GB_ONLY" ]; then
  GB_MODULES="$GB_ONLY"
fi
[ -n "$GB_MODULES" ] || { echo "no modules selected" >&2; exit 1; }

echo "════════════════════════════════════════════════════════"
echo " gb10-stack  |  option: ${GB_OPT:-default}"
[ "$GB_PLAN" = "1" ] && echo " MODE: PLAN (zero writes — nothing below is executed)"
echo " modules: $(echo "$GB_MODULES" | tr '\n' ' ')"
echo " min free: ${GB_MIN_FREE} GB"
echo "════════════════════════════════════════════════════════"

# ── preflight (always; read-only in plan mode) ──────────────────────────
preflight() {
  info "preflight: hardware & disk"
  if is_gb10; then ok "GB10-class hardware ($(nproc) cores, driver $(driver_version))"; else
    warn "hardware does not look like GB10 — continuing (images are GB10-tuned)"
  fi
  local free; free=$(disk_free_gb "$HOME")
  if [ -z "$free" ] || [ "$free" -lt "$GB_MIN_FREE" ]; then
    die "need ${GB_MIN_FREE} GB free on $HOME, found ${free:-?} GB. Free disk or lower min_free_gb."
  fi
  ok "disk: ${free} GB free (need ${GB_MIN_FREE})"
  if [ "$GB_PLAN" != "1" ]; then
    command -v sudo >/dev/null || die "sudo is required for system steps"
    docker_ok || die "docker daemon not reachable (start it or check group membership)"
  fi
}
preflight

# ── module runner ───────────────────────────────────────────────────────
declare -a RAN=()
for mod in $GB_MODULES; do
  MFILE="$REPO_DIR/modules/$mod.sh"
  [ -f "$MFILE" ] || die "module not found: $MFILE (have: $(ls "$REPO_DIR/modules" | tr '\n' ' '))"
  if [ "$GB_PLAN" != "1" ] && is_done "$mod"; then
    info "skip $mod (already done — use --force to rerun)"
    continue
  fi
  echo ""
  echo "── module: $mod"
  # shellcheck disable=SC1090
  source "$MFILE"
  type mod_install >/dev/null 2>&1 || die "module $mod does not define mod_install()"
  if [ -n "${MIN_FREE_GB:-}" ]; then
    local_free=$(disk_free_gb "$HOME")
    if [ -n "$local_free" ] && [ "$local_free" -lt "$MIN_FREE_GB" ]; then
      die "module $mod needs ${MIN_FREE_GB} GB free, found ${local_free} GB"
    fi
  fi
  mod_install
  [ "$GB_PLAN" = "1" ] || mark_done "$mod"
  RAN+=("$mod")
done

# ── summary ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
if [ "$GB_PLAN" = "1" ]; then
  echo " PLAN complete: $(echo "${RAN[*]:-none}" | tr ' ' ', ') (zero writes)"
  echo " Re-run without --plan to execute."
else
  echo " install complete: $(echo "${RAN[*]:-none}" | tr ' ' ', ')"
  echo " Next: bash $REPO_DIR/scripts/verify.sh   (ledger: all checks must PASS)"
fi
echo "════════════════════════════════════════════════════════"
