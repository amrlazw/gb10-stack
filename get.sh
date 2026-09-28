#!/usr/bin/env bash
# gb10-stack one-liner bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash
#
# Private repo: pass a GitHub token (fine-grained, Contents:Read on this repo):
#   GB10_TOKEN=*** curl -fsSL https://raw.githubusercontent.com/amrlazw/gb10-stack/main/get.sh | bash
#
# NEVER pipe this into sudo. install.sh refuses root itself before any write,
# and calls sudo only for the steps that need it (same convention as the
# upstream dgx-spark-qwen38 installer — piped sudo once moved $HOME to /root
# and orphaned the API key, 2026-09-13).

set -euo pipefail

REPO_URL="${GB10_REPO_URL:-https://github.com/amrlazw/gb10-stack}"
DEFAULT_DIR="$HOME/gb10-stack"

if [ "$(id -u)" = "0" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    printf '\n\033[1;31mERROR:\033[0m do not pipe this into "sudo bash" (your login is %s).\n\n' "$SUDO_USER" >&2
    printf '  Under sudo, HOME is /root: the clone, generated keys and all units\n  would point at /root, and every client reading ~/.config/qwen38/api-key\n  would get 401 from a perfectly healthy engine.\n\n  run : curl -fsSL %s/get.sh | bash\n' "$REPO_URL" >&2
    exit 1
  fi
  if [ "${ALLOW_ROOT:-0}" != "1" ]; then
    printf '\n\033[1;31mERROR:\033[0m run this as the user who will use the box, not as root.\n' >&2
    printf '  if this box genuinely has no other user: ALLOW_ROOT=1 before the pipe.\n' >&2
    exit 1
  fi
fi

if ! command -v git >/dev/null 2>&1; then
  echo "── git not found — installing git..."
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git
fi

# Case 1: already inside a clone of this repo -> use it.
DIR="${DIR:-}"
if [ -z "$DIR" ] && TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
  ORIGIN=$(git -C "$TOP" remote get-url origin 2>/dev/null || true)
  case "$ORIGIN" in *amrlazw/gb10-stack*) DIR="$TOP" ;; esac
fi

# Case 2: default location — reuse an existing clone or create one.
if [ -z "$DIR" ]; then
  DIR="$DEFAULT_DIR"
  if [ -d "$DIR/.git" ]; then
    :
  elif [ -e "$DIR" ]; then
    echo "ERROR: $DIR exists but is not a clone of this repo. Move it, or rerun with DIR=/path/to/clone" >&2
    exit 1
  else
    CLONE_URL="$REPO_URL"
    if [ -n "${GB10_TOKEN:-}" ]; then
      CLONE_URL=$(printf '%s' "$REPO_URL" | sed "s#https://#https://x-access-token:${GB10_TOKEN}@#")
    fi
    echo "── Cloning gb10-stack into $DIR"
    git clone -q "$CLONE_URL" "$DIR" || {
      echo "ERROR: clone failed. For a private repo pass a token: GB10_TOKEN=*** curl ... | bash" >&2
      exit 1
    }
  fi
fi

DIR_ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null | sed 's#//[^@]*@#//#' || true)
case "$DIR_ORIGIN" in
  *amrlazw/gb10-stack*) : ;;
  *) echo "ERROR: $DIR is not a clone of gb10-stack (origin: ${DIR_ORIGIN:-none}). Refusing to touch it." >&2; exit 1 ;;
esac

echo "── Repo: $DIR"
git -C "$DIR" fetch -q origin main 2>/dev/null || true

# Everything below is user-level; sudo is never here.
exec bash "$DIR/install.sh" "$@"
