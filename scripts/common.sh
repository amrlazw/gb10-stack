#!/usr/bin/env bash
# gb10-stack — shared helpers for all modules.
# Every mutation goes through run_cmd / run_root / write_file / write_root so
# that --plan mode is genuinely zero-write: in plan mode these print instead
# of executing. Modules must NOT call sudo/cp/systemctl/docker directly.

set -euo pipefail

GBSTACK_HOME="${GBSTACK_HOME:-$HOME/.gb10-stack}"
GBSTATE_FILE="$GBSTACK_HOME/state"
GBPLAN="${GBPLAN:-0}"       # set by install.sh (exported) when --plan
GBFORCE="${GBFORCE:-0}"     # set by install.sh (exported) when --force
GBREPO_DIR="${GBREPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export GBSTACK_HOME GBSTATE_FILE GBPLAN GBFORCE GBREPO_DIR
# The user who owns the box (never root by convention; SUDO_USER when the
# installer was invoked through a sudoed parent — the root-refusal in
# install.sh already blocks the piped-sudo case before we get here).
GB_USER="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || whoami)}}"
export GB_USER

# ── colors (off when not a tty) ──────────────────────────────────────────
if [ -t 1 ]; then C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_C=$'\033[1;36m'; C_0=$'\033[0m'; else C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""; fi

info()  { printf '%s[gb10-stack]%s %s\n' "$C_C" "$C_0" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()   { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
plan()  { printf '%s[plan]%s (would) %s\n' "$C_Y" "$C_0" "$*"; }

# ── state (resume support) ───────────────────────────────────────────────
mark_done() {  # mark_done <module>
  mkdir -p "$GBSTACK_HOME"
  echo "$1 $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GBSTATE_FILE"
  ok "state: $1 marked done"
}
is_done() {  # is_done <module> -> 0 if completed and not forcing
  [ "$GBFORCE" = "1" ] && return 1
  [ -f "$GBSTATE_FILE" ] || return 1
  grep -q "^$1 " "$GBSTATE_FILE"
}

# ── mutation helpers (plan-aware) ────────────────────────────────────────
# All mutation goes through these four. In plan mode they only print.
# Arguments are passed as a single string and eval'd, so embedded quoting
# (run_root "cp -a '$a' '$b'") works. Paths are installer-controlled.
run_cmd() {  # run_cmd '<cmd> [args]'
  if [ "$GBPLAN" = "1" ]; then plan "run: $1"; else eval "$1"; fi
}
run_root() {  # run_root '<cmd> [args]'  — via sudo, never piped user input
  if [ "$GBPLAN" = "1" ]; then plan "sudo: $1"; else eval "sudo -p '[gb10-stack] password for $USER: ' $1"; fi
}
# write_file <dest> <<'EOF'  — write file as current user (content on stdin)
write_file() {
  local dest="$1"
  if [ "$GBPLAN" = "1" ]; then
    local lines; lines=$(wc -l < /dev/stdin)
    plan "write: $dest ($lines lines)"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
}
# write_root <dest> <<'EOF'  — stage to temp, move with sudo, backup existing
write_root() {
  local dest="$1"
  if [ "$GBPLAN" = "1" ]; then
    local lines; lines=$(wc -l < /dev/stdin)
    plan "sudo write: $dest ($lines lines)"
    return 0
  fi
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$dest" ]; then
    run_root "cp -a '$dest' '${dest}.gbstack.bak'"
  fi
  run_root "install -m 644 '$tmp' '$dest'"
  rm -f "$tmp"
}

# ── detection helpers (read-only, always safe in plan mode) ──────────────
disk_free_gb() {  # disk_free_gb <path>
  df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'
}
is_gb10() {
  local cpu
  cpu=$(lscpu 2>/dev/null | awk -F: '/Model name|CPU model/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
  case "$cpu" in *Blackwell*|*GB10*|*Grace*) return 0;; esac
  local cores; cores=$(nproc 2>/dev/null || echo 0)
  [ "$cores" = "20" ] && grep -qi aarch64 /proc/cpuinfo && return 0
  return 1
}
driver_version() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1; }
docker_ok() { docker info >/dev/null 2>&1; }

# ── module contract ──────────────────────────────────────────────────────
# Each modules/<name>.sh defines:
#   MOD_NAME="<name>"
#   MIN_FREE_GB=<int>          (module-level disk preflight)
#   mod_install()              (the work — must use the helpers above)
# install.sh calls mod_install and then mark_done.
