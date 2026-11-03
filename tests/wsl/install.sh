# Seam 4: install.sh -- the WSL preflight and the service stage.
INSTALL="$REPO/install.sh"

# install_world NAME [plain] -- a machine where every prerequisite is already there
# (so preflight does not try apt), a Linux uname whatever runs the suite, and a
# systemctl that behaves like the real one: `--user` fails without XDG_RUNTIME_DIR.
install_world() {
  sandbox "$1"
  stub uname 'case "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac'
  for c in curl git gpg jq ssh xz make g++ python3 flock tmux; do stub "$c" 'exit 0'; done
  stub loginctl 'exit 0'
  stub systemctl "echo \"\$*\" >> \"$S/systemctl-calls\"; case \"\$*\" in *show-environment*) [ -n \"\${XDG_RUNTIME_DIR:-}\" ] || { echo 'Failed to connect to bus' >&2; exit 1; } ;; esac"
  mkdir -p "$S/systemd" "$S/runuser/$(id -u)"
  if [ "${2:-wsl}" = plain ]; then
    printf 'Linux version 6.8.0-45-generic (buildd@lcy02) #45-Ubuntu SMP\n' > "$S/proc-version"
  fi
}
isbx() { sbx PA_WSL_SYSTEMD_DIR="$S/systemd" PA_RUN_USER_DIR="$S/runuser" "$@"; }

# The data and the agents' state would sit on a Windows drive: slow (9p), and no Linux
# permissions -- the Omnigent plugin insists on mode 0600 for its receipts.
install_world inst-mnt
run isbx PI_AGENT_HOME=/mnt/c/Users/me/pi-agent PA_WSL_MNT_ROOT=/mnt "$INSTALL" preflight
[ "$rc" != 0 ] && ok "preflight: refuses an install on a Windows drive" || no "preflight: refuses an install on a Windows drive" "$out"
has   "preflight: says why" "Windows drive" "$out"
lacks "preflight: and does not go on" "preflight OK" "$out"

# No systemd: the service cannot restart itself, but a try-out still works.
install_world inst-nosystemd
rmdir "$S/systemd"
run isbx "$INSTALL" preflight
eq  "preflight: carries on without systemd" "0" "$rc"
has "preflight: but warns, and says how to turn it on" "systemd=true" "$out"

install_world inst-systemd
run isbx "$INSTALL" preflight
eq    "preflight: fine with systemd" "0" "$rc"
lacks "preflight: says nothing about systemd then" "systemd=true" "$out"

install_world inst-plain plain
rmdir "$S/systemd"
run isbx "$INSTALL" preflight
eq    "preflight: plain Linux is not told about WSL settings" "0" "$rc"
lacks "preflight: no WSL advice on plain Linux" "systemd=true" "$out"

# service: `wsl.exe -u USER --exec ...` is not a login -- no XDG_RUNTIME_DIR, no USER.
install_world inst-service
run isbx "$INSTALL" service
eq  "service: completes in an environment with no XDG_RUNTIME_DIR and no USER" "0" "$rc"
has "service: enables the unit through systemd --user" "service enabled" "$out"
has "service: tells where Windows finds pi-web" "http://localhost:30141" "$out"
[ -f "$S/home/.config/systemd/user/pi-web.service" ] && ok "service: writes the unit" || no "service: writes the unit"
has "service: systemctl --user was reached with a runtime dir" "enable --now pi-web.service" "$(cat "$S/systemctl-calls" 2>/dev/null)"

install_world inst-service-plain plain
run isbx XDG_RUNTIME_DIR="$S/runuser/$(id -u)" USER=me "$INSTALL" service
eq    "service: plain Linux still works" "0" "$rc"
lacks "service: and does not talk about Windows" "localhost" "$out"
