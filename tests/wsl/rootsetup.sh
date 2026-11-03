# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 5: scripts/wsl-root-setup.sh -- what runs as root inside the new distro.
ROOTSETUP="$REPO/scripts/wsl-root-setup.sh"

# root_world NAME -- /etc, /home and /run/user redirected into the sandbox; useradd,
# apt-get, loginctl and chown replaced by stand-ins that leave a record. getent answers
# from a "user database" (files under $S/users).
root_world() {
  sandbox "$1"
  mkdir -p "$S/etc" "$S/homes" "$S/runuser" "$S/users" "$S/src"
  printf '0.9.9\n' > "$S/src/VERSION"
  printf '#!/bin/bash\necho installer\n' > "$S/src/install.sh"
  mkdir -p "$S/src/scripts"; printf 'x\n' > "$S/src/scripts/marker"
  stubf getent <<'STUB'
#!/bin/bash
[ "$1" = passwd ] && [ -f "@S@/users/$2" ] || exit 2
echo "$2:x:$(cat "@S@/users/$2"):$(cat "@S@/users/$2")::@S@/homes/$2:/bin/bash"
STUB
  stubf useradd <<'STUB'
#!/bin/bash
echo "$*" >> "@S@/useradd-calls"
for a in "$@"; do name="$a"; done
echo 1000 > "@S@/users/$name"; mkdir -p "@S@/homes/$name"
STUB
  stubf chown <<'STUB'
#!/bin/bash
echo "$*" >> "@S@/chown-calls"
STUB
  stubf apt-get <<'STUB'
#!/bin/bash
echo "frontend=${DEBIAN_FRONTEND:-} $*" >> "@S@/apt-calls"
STUB
  stubf loginctl <<'STUB'
#!/bin/bash
echo "$*" >> "@S@/loginctl-calls"
[ -n "${PA_TEST_NO_BUS:-}" ] || { mkdir -p "@S@/runuser/1000"; : > "@S@/runuser/1000/bus"; }
STUB
}
rsbx() { sbx PA_ALLOW_NONROOT=1 PA_ETC="$S/etc" PA_HOME_ROOT="$S/homes" PA_RUN_USER_DIR="$S/runuser" "$@"; }

# configure: the first half of turning a freshly imported Ubuntu into a Pi Agent host.
root_world root-configure
printf '[oobe]\ncommand = /usr/lib/wsl/oobe.sh\n' > "$S/etc/wsl-distribution.conf"
run rsbx "$ROOTSETUP" configure --user piagent --interop on --win-system32 /mnt/d/Windows/System32 --installer-src "$S/src"
eq "configure: succeeds" "0" "$rc"
eq "configure: reports the uid as its last line" "configured uid=1000" "$(printf '%s\n' "$out" | tail -1)"
eq "configure: creates the user, with a home" "-m -s /bin/bash piagent" "$(cat "$S/useradd-calls" 2>/dev/null)"
CONF="$(cat "$S/etc/wsl.conf" 2>/dev/null)"
has "configure: wsl.conf turns systemd on" "systemd=true" "$CONF"
has "configure: wsl.conf makes the new user the default" "default=piagent" "$CONF"
has "configure: wsl.conf keeps interop on" "enabled=true" "$CONF"
has "configure: wsl.conf keeps the Windows PATH out of Linux" "appendWindowsPath=false" "$CONF"
has "configure: marks the distro as ours" "installer=0.9.9" "$(cat "$S/etc/pi-agent-distro" 2>/dev/null)"
[ ! -f "$S/etc/wsl-distribution.conf" ] && ok "configure: switches off the first-run prompt" || no "configure: switches off the first-run prompt"
[ -f "$S/etc/cloud/cloud-init.disabled" ] && ok "configure: switches off cloud-init" || no "configure: switches off cloud-init"
[ -f "$S/homes/piagent/pi-agent-installer/install.sh" ] && ok "configure: puts the installer in the user's home" || no "configure: puts the installer in the user's home"
has "configure: and gives it to the user" "piagent" "$(cat "$S/chown-calls" 2>/dev/null)"
eq  "configure: records where the Windows system directory is" "PA_WIN_SYSTEM32=/mnt/d/Windows/System32" "$(cat "$S/homes/piagent/.local/share/pi-agent/windows-interop.env" 2>/dev/null)"

# Run again: nothing new to create, nothing to break.
run rsbx "$ROOTSETUP" configure --user piagent --interop on --win-system32 /mnt/d/Windows/System32 --installer-src "$S/src"
eq "configure: runs again without error" "0" "$rc"
eq "configure: and creates the user only once" "1" "$(wc -l < "$S/useradd-calls" | tr -d ' ')"

# Interop off: the Windows side is closed, and nothing that opens it stays behind.
run rsbx "$ROOTSETUP" configure --user piagent --interop off --installer-src "$S/src"
has "configure: --interop off writes enabled=false" "enabled=false" "$(cat "$S/etc/wsl.conf")"
[ ! -e "$S/homes/piagent/.local/share/pi-agent/windows-interop.env" ] && ok "configure: --interop off removes windows-interop.env" || no "configure: --interop off removes windows-interop.env"

# Bad input is refused before anything is touched.
root_world root-bad-input
for bad in 'a b' root Bad 1abc ''; do
  run rsbx "$ROOTSETUP" configure --user "$bad" --interop on --installer-src "$S/src"
  eq "configure: refuses the user name '$bad'" "2" "$rc"
done
run rsbx "$ROOTSETUP" configure --user piagent --interop maybe --installer-src "$S/src"
eq "configure: refuses --interop maybe" "2" "$rc"
run rsbx "$ROOTSETUP" configure --user piagent --interop on --win-system32 relative/path --installer-src "$S/src"
eq "configure: refuses a relative Windows directory" "2" "$rc"
eq "configure: and has touched nothing" "" "$(ls "$S/etc"; cat "$S/useradd-calls" 2>/dev/null)"
if [ "$(id -u)" != 0 ]; then
  run sbx PA_ETC="$S/etc" "$ROOTSETUP" configure --user piagent --interop on --installer-src "$S/src"
  eq  "refuses to run as an ordinary user" "1" "$rc"
  has "and says it needs root" "root" "$out"
fi

# packages: the same prerequisites install.sh looks for, plus what systemd --user needs.
root_world root-packages
run rsbx "$ROOTSETUP" packages
eq  "packages: succeeds" "0" "$rc"
eq  "packages: reports it as its last line" "packages ok" "$(printf '%s\n' "$out" | tail -1)"
APT="$(cat "$S/apt-calls" 2>/dev/null)"
has "packages: refreshes the package index" " update" "$APT"
has "packages: installs tmux, which Omnigent's native harnesses run in" "tmux" "$APT"
has "packages: installs util-linux, which brings flock" "util-linux" "$APT"
has "packages: installs the user bus systemd --user needs" "dbus-user-session" "$APT"
has "packages: never asks a question" "frontend=noninteractive" "$APT"

# linger: keep the user's systemd manager running with nobody logged in, and wait until
# its bus is there -- the installer's `systemctl --user` needs it a moment later.
root_world root-linger
echo 1000 > "$S/users/piagent"
run rsbx "$ROOTSETUP" linger --user piagent --timeout 5
eq  "linger: succeeds once the user bus is up" "0|linger uid=1000" "$rc|$(printf '%s\n' "$out" | tail -1)"
has "linger: asks systemd to keep the user manager" "enable-linger piagent" "$(cat "$S/loginctl-calls" 2>/dev/null)"

root_world root-linger-timeout
echo 1000 > "$S/users/piagent"
run rsbx PA_TEST_NO_BUS=1 "$ROOTSETUP" linger --user piagent --timeout 1
eq  "linger: fails when the user bus never comes up" "1" "$rc"
has "linger: and says what it waited for" "bus" "$out"

root_world root-linger-nouser
run rsbx "$ROOTSETUP" linger --user ghost --timeout 1
eq  "linger: fails for a user that does not exist" "1" "$rc"
