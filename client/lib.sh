# Shared helpers for the omarchy-* client commands.
#
# Source this after setting nothing in particular; every path it needs has a
# default and an environment override.

RESOLVER="${OMARCHY_RESOLVER:-http://127.0.0.1:8080}"
PLUGIN_DIR="${OMARCHY_PLUGIN_DIR:-$(realpath "${BASH_SOURCE[0]%/*}")/plugins}"
STATE_FILE="${OMARCHY_STATE:-$HOME/.local/state/omarchy/installed.json}"
PUBKEY="${OMARCHY_RESOLVER_PUBKEY:-$HOME/.config/omarchy/resolver.pub}"
INSECURE="${OMARCHY_INSECURE:-0}"

# Seconds before giving up on the resolver. An unbounded wait is a denial of
# service that needs nothing more than a socket that accepts and never answers.
HTTP_TIMEOUT="${OMARCHY_HTTP_TIMEOUT:-10}"

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

# --------------------------------------------------------------- validation
#
# Everything below this line exists because the resolver is not trusted. It is
# a network service that names things a privileged package manager then acts
# on, so its answers are input, not instructions.

# A backend name is turned into a path and executed. Without this check a
# resolver answering with "../../../tmp/payload" gets arbitrary code run as the
# user, and that user can drive a package manager as root. Plain identifiers
# only, no dots, no slashes.
valid_backend() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

# Package names are passed as argv elements rather than through a shell, so
# quoting is not the exposure. Leading dashes are: a name like "--config" turns
# into an option to whatever privileged tool receives it. Control characters
# are refused because nothing legitimate uses them and they hide what a prompt
# is really showing the user.
valid_package() {
  local p="$1"
  [[ -n "$p" && ${#p} -le 256 ]] || return 1
  [[ "$p" != -* ]] || return 1
  [[ "$p" != *[$'\n\r\t\0']* ]] || return 1
  return 0
}

# Resolve the plugin path and confirm it really sits inside the plugin
# directory. The regex above should make this impossible; a second check costs
# nothing and this is the failure that ends with somebody's machine owned.
plugin_path() {
  local backend="$1" path resolved dir
  valid_backend "$backend" || return 1
  path="$PLUGIN_DIR/$backend"
  [[ -f "$path" && -x "$path" ]] || return 1
  resolved=$(realpath -- "$path" 2>/dev/null) || return 1
  dir=$(realpath -- "$PLUGIN_DIR" 2>/dev/null) || return 1
  [[ "$resolved" == "$dir"/* ]] || return 1
  printf '%s' "$resolved"
}

# Check a whole route before anything acts on it.
validate_route() {
  local route="$1" backend pkg
  backend=$(jq -r '.backend // empty' <<<"$route")

  if ! valid_backend "$backend"; then
    echo "${RED}✗${NC} resolver returned an illegal backend name: $(jq -r '.backend' <<<"$route" | head -c 60)" >&2
    return 1
  fi

  while IFS= read -r pkg; do
    if ! valid_package "$pkg"; then
      echo "${RED}✗${NC} resolver returned an illegal package name: $(head -c 60 <<<"$pkg")" >&2
      return 1
    fi
  done < <(jq -r '.packages[]? // empty' <<<"$route")

  return 0
}

# ------------------------------------------------------------ authentication

# Fetch a resolver response and refuse it unless it is signed by the key this
# machine has pinned.
#
# The resolver decides what a privileged package manager installs. That makes
# it exactly as sensitive as a package signing key, and it gets the same
# treatment: the answer is signed, the client verifies against a pinned public
# key, and an unverifiable answer is discarded rather than acted on. TLS alone
# is not enough, because a signature also survives a terminating proxy and a
# compromised CDN.
resolver_get() {
  local path="$1" body_file sig_file headers sig

  body_file=$(mktemp)
  sig_file=$(mktemp)
  headers=$(mktemp)

  if ! curl -fsS --proto '=http,https' --max-time "$HTTP_TIMEOUT" \
    -D "$headers" -o "$body_file" "$RESOLVER$path" 2>/dev/null; then
    rm -f "$body_file" "$sig_file" "$headers"
    return 2
  fi

  if [[ "$INSECURE" == "1" ]]; then
    cat "$body_file"
    rm -f "$body_file" "$sig_file" "$headers"
    return 0
  fi

  if [[ ! -r "$PUBKEY" ]]; then
    echo "${RED}✗${NC} no pinned resolver key at $PUBKEY" >&2
    echo "${DIM}  Pin one, or set OMARCHY_INSECURE=1 to accept unsigned answers.${NC}" >&2
    rm -f "$body_file" "$sig_file" "$headers"
    return 3
  fi

  sig=$(grep -i '^x-route-signature:' "$headers" | tr -d '\r' | cut -d' ' -f2-)
  if [[ -z "$sig" ]]; then
    echo "${RED}✗${NC} resolver answered without a signature" >&2
    rm -f "$body_file" "$sig_file" "$headers"
    return 3
  fi

  if ! printf '%s' "$sig" | base64 -d >"$sig_file" 2>/dev/null; then
    echo "${RED}✗${NC} resolver signature is not valid base64" >&2
    rm -f "$body_file" "$sig_file" "$headers"
    return 3
  fi

  if ! openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin \
    -in "$body_file" -sigfile "$sig_file" >/dev/null 2>&1; then
    echo "${RED}✗${NC} resolver signature does not verify against $PUBKEY" >&2
    echo "${DIM}  Refusing to act on it. This is what a spoofed resolver looks like.${NC}" >&2
    rm -f "$body_file" "$sig_file" "$headers"
    return 3
  fi

  cat "$body_file"
  rm -f "$body_file" "$sig_file" "$headers"
  return 0
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

  # The state file is on disk and could have been tampered with, so a backend
  # read back out of it gets the same scrutiny as one off the network.
  plugin=$(plugin_path "$backend") || return 2
  "$plugin" probe >/dev/null 2>&1 || return 2

  while IFS= read -r pkg; do
    "$plugin" installed "$pkg" >/dev/null 2>&1 || return 1
  done < <(jq -r '.packages[]' <<<"$record")

  return 0
}
