#!/usr/bin/env bash
# Shared helpers + canonical paths for the native Pi Agent installer.

: "${PI_AGENT_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}"
export PI_AGENT_HOME

PA_NODE_DIR="$PI_AGENT_HOME/node"
PA_PIWEB_DIR="$PI_AGENT_HOME/piweb"
PA_PLUGINS_DIR="$PI_AGENT_HOME/plugins"
PA_PASEO_RUNTIME_DIR="$PI_AGENT_HOME/paseo-runtime"
PA_PASEO_WEB_DIR="$PI_AGENT_HOME/paseo-web"
PA_OMNIGENT_DIR="$PI_AGENT_HOME/omnigent"
PA_CLIS_DIR="$PI_AGENT_HOME/clis"
PA_BIN_DIR="$PI_AGENT_HOME/bin"
PA_DATA_DIR="$PI_AGENT_HOME/data"
PA_HOME_DIR="$PI_AGENT_HOME/home"
PA_LOG_DIR="$PI_AGENT_HOME/logs"
PA_TMP_DIR="$PI_AGENT_HOME/tmp"

log()  { printf '\033[1;36m[pi-agent]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[pi-agent] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pi-agent] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

PA_NODE() { "$PA_NODE_DIR/bin/node" "$@"; }
PA_NPM()  { "$PA_NODE_DIR/bin/node" "$PA_NODE_DIR/bin/npm" "$@"; }

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else die "no sha256 tool found"; fi
}

# fetch_verify URL SHA256 DEST
fetch_verify() {
  local url="$1" sha="$2" dest="$3" got
  log "download $(basename "$dest")"
  curl -fSL --retry 5 --retry-all-errors "$url" -o "$dest" || die "download failed: $url"
  got="$(sha256_of "$dest")"
  [ "$got" = "$sha" ] || die "sha256 mismatch for $(basename "$dest"): expected $sha got $got"
}

pa_os() {
  case "$(uname -s)" in
    Linux)  if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    Darwin) echo macos ;;
    *)      echo unknown ;;
  esac
}
pa_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             echo unknown ;;
  esac
}
