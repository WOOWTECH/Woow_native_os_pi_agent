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

# What the installer needs from apt on Debian/Ubuntu. install.sh's preflight installs
# it with sudo; scripts/wsl-root-setup.sh installs it as root in a fresh WSL distro.
PA_APT_PACKAGES="ca-certificates curl git gnupg jq openssh-client xz-utils build-essential python3 python3-venv python3-pip util-linux tmux procps"

log()  { printf '\033[1;36m[pi-agent]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[pi-agent] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pi-agent] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# The scoped Node has to be on PATH for anything npm spawns, not just for the
# npm process itself: a package's lifecycle script runs through `sh -c` and calls
# a bare `node` (claude-code's install.cjs does). On a host that happens to have
# a system Node this works by accident; on a clean macOS there is none, and the
# install fails with `sh: node: command not found`.
PA_NODE() { PATH="$PA_NODE_DIR/bin:$PATH" "$PA_NODE_DIR/bin/node" "$@"; }
# Five tries instead of npm's two: one lost connection among a thousand tarballs ended an install on a slow network.
PA_NPM()  { PATH="$PA_NODE_DIR/bin:$PATH" npm_config_fetch_retries="${npm_config_fetch_retries:-5}" "$PA_NODE_DIR/bin/node" "$PA_NODE_DIR/bin/npm" "$@"; }

# Total RAM in MiB (Linux /proc/meminfo, macOS sysctl).
pa_ram_mib() {
  if [ -r /proc/meminfo ]; then awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo
  else s="$(sysctl -n hw.memsize 2>/dev/null)"; [ -n "$s" ] && echo $((s / 1048576)) || echo 4096
  fi
}

# How many parallel workers the Next.js build may use, and how big the V8 heap
# may get. The build is the one memory-hungry step in the whole install, and the
# machines this runs on are not CI boxes -- an 8 GB laptop with the user's own
# work open is a normal target, and the default (one worker per core, heap sized
# from total RAM) is what makes a build swap the machine to a standstill.
pa_build_workers() {
  local mib; mib="$(pa_ram_mib)"
  if   [ "$mib" -lt 6000 ];  then echo 1
  elif [ "$mib" -lt 12000 ]; then echo 2
  else echo 3; fi
}
pa_build_heap_mib() {
  local mib; mib="$(pa_ram_mib)"
  if   [ "$mib" -lt 6000 ];  then echo 1536
  elif [ "$mib" -lt 12000 ]; then echo 2560
  else echo 4096; fi
}

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

# Portable shims for the places GNU and BSD userland differ. macOS ships bash
# 3.2 (no mapfile), BSD stat/sed, and no GNU coreutils, so anything below is
# what the installer uses instead of the Linux-only spelling.

# File mode in octal, e.g. 600.
pa_stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# Homebrew is optional, and a non-login shell (ssh, launchd) does not have it on
# PATH even when it is installed, so look where it actually lives.
pa_brew() {
  if command -v brew >/dev/null 2>&1; then command -v brew; return 0; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}

# True when this Mac's /usr/bin/python3 is only the Command Line Tools stub: no
# python3 in the Command Line Tools, and none in the developer directory
# xcode-select points at (CLT or Xcode.app). Running the stub opens the
# "install the command line developer tools?" dialog, and so do xcrun and git
# on such a Mac -- so none of them is run to find out; this only looks at files
# and asks xcode-select, which reports and never prompts.
# PI_AGENT_CLT_DIR exists for tests, to stand in for a Mac without the tools.
pa_macos_python3_is_stub() {
  [ "$(uname -s)" = Darwin ] || return 1
  [ -e /usr/bin/python3 ] || return 1
  local clt="${PI_AGENT_CLT_DIR:-/Library/Developer/CommandLineTools}" dev
  [ -x "$clt/usr/bin/python3" ] && return 1
  if dev="$(xcode-select -p 2>/dev/null)" && [ -n "$dev" ] && [ -x "$dev/usr/bin/python3" ]; then
    return 1
  fi
  return 0
}

pa_os() {
  case "$(uname -s)" in
    Linux)  if grep -qiE '(microsoft|wsl)' "${PA_WSL_PROC_VERSION:-/proc/version}" 2>/dev/null; then echo wsl; else echo linux; fi ;;
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
