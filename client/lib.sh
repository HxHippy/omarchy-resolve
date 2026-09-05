# Shared helpers for the omarchy-* client commands.
#
# Source this after setting nothing in particular; every path it needs has a
# default and an environment override.

RESOLVER="${OMARCHY_RESOLVER:-http://127.0.0.1:8080}"
PLUGIN_DIR="${OMARCHY_PLUGIN_DIR:-$(realpath "${BASH_SOURCE[0]%/*}")/plugins}"
STATE_FILE="${OMARCHY_STATE:-$HOME/.local/state/omarchy/installed.json}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# What are we? The os id decides which routes even apply, so an Omarchy box has
# to identify as omarchy and not merely as arch, or it never sees the routes we
# host ourselves.
detect_os() {
  if [[ -n "${OMARCHY_FORCE_OS:-}" ]]; then
    echo "$OMARCHY_FORCE_OS"
    return
  fi
  if [[ -d /usr/share/omarchy ]] || command -v omarchy >/dev/null 2>&1; then
    echo omarchy
    return
  fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    (. /etc/os-release && echo "${ID:-unknown}")
    return
  fi
  case "$(uname -s)" in
  Darwin) echo macos ;;
  *) echo unknown ;;
  esac
}

detect_arch() {
  if [[ -n "${OMARCHY_FORCE_ARCH:-}" ]]; then
    echo "$OMARCHY_FORCE_ARCH"
    return
  fi
  case "$(uname -m)" in
  x86_64 | amd64) echo x86_64 ;;
  aarch64 | arm64) echo aarch64 ;;
  *) uname -m ;;
  esac
}

state_init() {
  mkdir -p "$(dirname "$STATE_FILE")"
  [[ -f "$STATE_FILE" ]] || echo '{}' >"$STATE_FILE"
}

# Write through a temp file so an interrupted run cannot leave a truncated
# state file behind. Losing the record of who owns a package is worse than
# never having written it.
state_write() {
  local filter="$1"; shift
  local tmp
  state_init
  tmp=$(mktemp)
  if jq "$@" "$filter" "$STATE_FILE" >"$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

state_record() {
  local name="$1" backend="$2" trust="$3"; shift 3
  state_write '.[$n] = {backend: $b, trust: $t, packages: $p, installed: $d}' \
    --arg n "$name" --arg b "$backend" --arg t "$trust" \
    --argjson p "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    --arg d "$(date -Is)"
}

state_forget() {
  state_write 'del(.[$n])' --arg n "$1"
}

state_get() {
  state_init
  jq -c --arg n "$1" '.[$n] // empty' "$STATE_FILE"
}

state_names() {
  state_init
  jq -r 'keys[]' "$STATE_FILE"
}

# Ask the backend whether every package in a record is still present. This is
# what makes the state file a hint rather than a claim: if someone removed the
# thing by hand, the backend is believed and the record is not.
record_is_live() {
  local record="$1" backend plugin pkg
  backend=$(jq -r '.backend' <<<"$record")
  plugin="$PLUGIN_DIR/$backend"

  [[ -x "$plugin" ]] || return 2
  "$plugin" probe >/dev/null 2>&1 || return 2

  while IFS= read -r pkg; do
    "$plugin" installed "$pkg" >/dev/null 2>&1 || return 1
  done < <(jq -r '.packages[]' <<<"$record")

  return 0
}
