#!/usr/bin/env bash
# What runs as root inside a freshly imported Ubuntu distro, before Pi Agent itself is
# installed as an ordinary user. Called by the Windows-side installer
# (windows/install-wsl.ps1) as `wsl.exe -d <distro> -u root --exec ...`.
#
#   wsl-root-setup.sh configure --user NAME --interop on|off
#                     [--win-system32 /mnt/c/Windows/System32] [--installer-src DIR]
#   wsl-root-setup.sh packages          the apt prerequisites (the list install.sh checks)
#   wsl-root-setup.sh linger --user NAME [--timeout SECONDS]
#                                       keep NAME's systemd manager running and wait for its bus
#
# `configure` is for a DEDICATED distro: it owns /etc/wsl.conf and overwrites it. It
# takes effect only after the distro is restarted (`wsl --terminate`), because
# systemd=true is read at boot. Every subcommand is safe to run again.
#
# The places it writes can be redirected (PA_ETC, PA_RUN_USER_DIR) and the root check
# skipped (PA_ALLOW_NONROOT=1), which is how tests/wsl.sh runs it without touching the
# machine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"

ETC="${PA_ETC:-/etc}"

usage_error() { echo "wsl-root-setup: $*" >&2; exit 2; }
valid_user() {   # a plain account name, never root
  case "$1" in ""|root|*[!a-z0-9_-]*|[0-9-]*) return 1 ;; esac
  [ "${#1}" -le 31 ]
}

[ "$(id -u)" = 0 ] || [ -n "${PA_ALLOW_NONROOT:-}" ] || die "wsl-root-setup must run as root (wsl.exe -d <distro> -u root)"

cmd="${1:-}"; if [ $# -gt 0 ]; then shift; fi
user=""; interop=""; sys32=""; src="/opt/pi-agent-installer"; timeout=60
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage_error "$1 needs a value"
  case "$1" in
    --user)          user="$2" ;;
    --interop)       interop="$2" ;;
    --win-system32)  sys32="$2" ;;
    --installer-src) src="$2" ;;
    --timeout)       timeout="$2" ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift 2
done

cmd_configure() {
  local uid home dest pa_home flag
  valid_user "$user" || usage_error "--user must be a plain lower-case account name, not root: '$user'"
  case "$interop" in on|off) ;; *) usage_error "--interop must be on or off" ;; esac
  case "$sys32" in ""|/*) ;; *) usage_error "--win-system32 must be an absolute path" ;; esac

  # The account. No password is set: nobody logs in as it, and without one it has no sudo.
  if ! getent passwd "$user" >/dev/null; then
    useradd -m -s /bin/bash "$user"
  fi
  uid="$(getent passwd "$user" | cut -d: -f3)"
  home="$(getent passwd "$user" | cut -d: -f6)"

  # [interop] enabled=false closes the Windows side completely. appendWindowsPath=false
  # keeps the whole Windows PATH out of Linux: a Windows node, npm or git must not be
  # found by accident. The few Windows directories agents may use are added by
  # pi-agent-env.sh, from windows-interop.env.
  if [ "$interop" = on ]; then flag=true; else flag=false; fi
  mkdir -p "$ETC"
  cat > "$ETC/wsl.conf" <<EOF
# Written by Pi Agent (scripts/wsl-root-setup.sh). This distro is dedicated to it.
[boot]
systemd=true

[user]
default=$user

[interop]
enabled=$flag
appendWindowsPath=false
EOF

  # The first-run prompt and cloud-init would ask for a user name on the first
  # interactive shell: we have already made the user.
  if [ -f "$ETC/wsl-distribution.conf" ]; then
    mv -f "$ETC/wsl-distribution.conf" "$ETC/wsl-distribution.conf.disabled"
  fi
  mkdir -p "$ETC/cloud"
  : > "$ETC/cloud/cloud-init.disabled"

  # Marks the distro as ours: the Windows-side installer will not reuse, nor remove, one
  # without it.
  {
    echo "installer=$(cat "$src/VERSION" 2>/dev/null || echo unknown)"
    echo "user=$user"
  } > "$ETC/pi-agent-distro"

  # The installer the Windows side unpacked, now owned by the user who will run it.
  dest="$home/pi-agent-installer"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$src/." "$dest/"
  chown -R "$user:$user" "$dest"

  # Where Windows is, for pi-agent-env.sh and pi-agent-win. Only while interop is on.
  pa_home="$home/.local/share/pi-agent"
  if [ "$interop" = on ] && [ -n "$sys32" ]; then
    mkdir -p "$pa_home"
    printf 'PA_WIN_SYSTEM32=%s\n' "$sys32" > "$pa_home/windows-interop.env"
    chown -R "$user:$user" "$home/.local"
  else
    rm -f "$pa_home/windows-interop.env"
  fi

  echo "configured uid=$uid"
}

# The prerequisites install.sh checks for, plus dbus-user-session: without it
# `systemctl --user` has no bus to talk to on a minimal Ubuntu.
cmd_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends $PA_APT_PACKAGES dbus-user-session
  echo "packages ok"
}

# Keep the user's systemd manager running with nobody logged in -- the service has to
# survive the last terminal closing -- and wait for its bus: the installer's
# `systemctl --user` needs it a moment later.
cmd_linger() {
  local uid bus deadline
  valid_user "$user" || usage_error "--user must be a plain lower-case account name, not root: '$user'"
  case "$timeout" in ""|*[!0-9]*) usage_error "--timeout must be a number of seconds" ;; esac
  getent passwd "$user" >/dev/null || die "no such user: $user"
  uid="$(getent passwd "$user" | cut -d: -f3)"
  loginctl enable-linger "$user"
  bus="${PA_RUN_USER_DIR:-/run/user}/$uid/bus"
  deadline=$((SECONDS + timeout))
  while [ ! -e "$bus" ]; do
    [ "$SECONDS" -lt "$deadline" ] || die "the user bus $bus did not come up within ${timeout}s: systemd --user for $user is not running"
    sleep 1
  done
  echo "linger uid=$uid"
}

case "$cmd" in
  configure) cmd_configure ;;
  packages)  cmd_packages ;;
  linger)    cmd_linger ;;
  *) usage_error "usage: wsl-root-setup.sh {configure|packages|linger} ..." ;;
esac
