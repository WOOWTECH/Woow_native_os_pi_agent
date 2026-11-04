# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 2: rootfs/bin/pi-agent -- the control command, on WSL.
CTL_SRC="$REPO/rootfs/bin/pi-agent"

# ctl_world NAME [wsl|plain] -- the script sits where it does in an install
# ($PI_AGENT_HOME/bin), next to a pi-agent-win stub that records what it is asked.
ctl_world() {
  sandbox "$1"
  cp "$CTL_SRC" "$S/pa/bin/pi-agent"; chmod +x "$S/pa/bin/pi-agent"
  printf '%s\n' '#!/bin/bash' "echo \"\$*\" >> \"$S/win-calls\"" 'exit "${PA_TEST_WIN_RC:-0}"' > "$S/pa/bin/pi-agent-win"
  chmod +x "$S/pa/bin/pi-agent-win"
  mkdir -p "$S/runuser/$(id -u)"
  # Always a Linux machine, whatever runs the suite: on a Mac the script would take its
  # launchd branch and ask the real launchd.
  stub uname 'case "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac'
  if [ "${2:-wsl}" = plain ]; then
    printf 'Linux version 6.8.0-45-generic (buildd@lcy02) #45-Ubuntu SMP\n' > "$S/proc-version"
  fi
}
csbx() { sbx PA_RUN_USER_DIR="$S/runuser" "$@"; }

# open: on WSL the browser is a Windows one, and Windows reaches pi-web as localhost.
ctl_world ctl-open
run csbx "$S/pa/bin/pi-agent" open
eq "open: on WSL, hands the URL to pi-agent-win" "open http://localhost:30141" "$(cat "$S/win-calls" 2>/dev/null)"
eq "open: exit 0" "0" "$rc"

ctl_world ctl-open-port
run csbx PI_WEB_PORT=30142 "$S/pa/bin/pi-agent" open
eq "open: follows PI_WEB_PORT" "open http://localhost:30142" "$(cat "$S/win-calls" 2>/dev/null)"

ctl_world ctl-open-fails
run csbx PA_TEST_WIN_RC=3 "$S/pa/bin/pi-agent" open
has "open: when Windows cannot be reached, still prints the URL" "http://localhost:30141" "$out"
eq  "open: and does not fail the command" "0" "$rc"

ctl_world ctl-open-plain plain
stub xdg-open "echo \"\$*\" >> \"$S/xdg-calls\""
run csbx "$S/pa/bin/pi-agent" open
eq "open: elsewhere, xdg-open as before" "http://127.0.0.1:30141" "$(cat "$S/xdg-calls" 2>/dev/null)"
eq "open: elsewhere, pi-agent-win is not involved" "" "$(cat "$S/win-calls" 2>/dev/null)"

# doctor: the WSL checks live in pi-agent-win; pi-agent only routes to them.
ctl_world ctl-doctor
run csbx PA_TEST_WIN_RC=5 "$S/pa/bin/pi-agent" doctor
eq "doctor: on WSL, runs pi-agent-win doctor" "doctor" "$(cat "$S/win-calls" 2>/dev/null)"
eq "doctor: and returns its verdict" "5" "$rc"

ctl_world ctl-doctor-plain plain
run csbx "$S/pa/bin/pi-agent" doctor
has "doctor: elsewhere, says it is WSL only" "WSL" "$out"
eq  "doctor: elsewhere, is not a success" "64" "$rc"

# systemd --user needs XDG_RUNTIME_DIR. `wsl.exe -u USER --exec ...` is not a PAM login,
# so a session started that way has none, and `pi-agent status` would say "not running
# under systemd" about a service that is running.
ctl_world ctl-xdg
stub systemctl 'echo "XDG=${XDG_RUNTIME_DIR:-}"'
run csbx "$S/pa/bin/pi-agent" status
has "status: derives XDG_RUNTIME_DIR from the uid when the session has none" "XDG=$S/runuser/$(id -u)" "$out"

ctl_world ctl-xdg-set
stub systemctl 'echo "XDG=${XDG_RUNTIME_DIR:-}"'
run csbx XDG_RUNTIME_DIR=/somewhere/else "$S/pa/bin/pi-agent" status
has "status: keeps an XDG_RUNTIME_DIR the session already has" "XDG=/somewhere/else" "$out"

ctl_world ctl-xdg-none
stub systemctl 'echo "XDG=${XDG_RUNTIME_DIR:-unset}"'
run sbx PA_RUN_USER_DIR="$S/no-such-dir" "$S/pa/bin/pi-agent" status
has "status: invents nothing where there is no /run/user (macOS)" "XDG=unset" "$out"

# A machine where 30141 is taken installs on another port, and the install remembers it: `wsl.exe --exec pi-agent ...` starts
# with an empty environment. Found on a real PC: `pi-agent url` said 30141, where a different pi-web was listening.
ctl_world ctl-port-file
printf '30142\n' > "$S/pa/pi-web-port"
run csbx "$S/pa/bin/pi-agent" url
eq "url: follows the port the install recorded" "http://127.0.0.1:30142" "$out"
run csbx "$S/pa/bin/pi-agent" open
eq "open: follows the port the install recorded" "open http://localhost:30142" "$(cat "$S/win-calls" 2>/dev/null)"
run csbx PI_WEB_PORT=30199 "$S/pa/bin/pi-agent" url
eq "url: an explicit PI_WEB_PORT still wins" "http://127.0.0.1:30199" "$out"

ctl_world ctl-port-none
run csbx "$S/pa/bin/pi-agent" url
eq "url: without a record, the default" "http://127.0.0.1:30141" "$out"

ctl_world ctl-port-garbage
printf 'not a port\n' > "$S/pa/pi-web-port"
run csbx "$S/pa/bin/pi-agent" url
eq "url: a record that is not a number is ignored" "http://127.0.0.1:30141" "$out"
