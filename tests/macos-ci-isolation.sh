#!/bin/bash
# Portable contract fixtures; these do not constitute a real Mac/launchd pass.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/account" "$W/install/logs"
cat > "$W/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) echo Darwin;; -m) echo arm64;; esac
SH
cat > "$W/bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
exit "${TEST_LAUNCHCTL_STATUS:-0}"
SH
cat > "$W/bin/id" <<'SH'
#!/bin/bash
if [ "$1" = -un ]; then touch "$TEST_KEYCHAIN_LOOKUP"; fi
exec /usr/bin/id "$@"
SH
chmod +x "$W/bin/"*
fixture() {
  env -i HOME="$W/account" PATH="$W/bin:/usr/bin:/bin" PI_AGENT_HOME="$W/install" \
    TEST_CALLS="$W/calls" TEST_KEYCHAIN_LOOKUP="$W/keychain-lookup" "$@"
}
fixture PI_AGENT_LINK_KEYCHAIN=0 /bin/bash "$REPO/install.sh" wire > "$W/wire.log" 2>&1
[ ! -e "$W/keychain-lookup" ]
[ ! -e "$W/install/home/Library/Keychains" ]
fixture PI_AGENT_LAUNCHD_LABEL=io.woowtech.test-owned PI_AGENT_LAUNCHD_EPHEMERAL=1 /bin/bash "$REPO/install.sh" service > "$W/service.log" 2>&1
uid="$(id -u)"
grep -Fx "bootstrap gui/$uid $W/account/Library/LaunchAgents/io.woowtech.test-owned.plist" "$W/calls"
! grep -q -- ' -w\|unload' "$W/calls"
fixture PI_AGENT_LAUNCHD_LABEL=io.woowtech.test-owned PI_AGENT_LAUNCHD_EPHEMERAL=1 /bin/bash "$W/install/bin/pi-agent" stop
grep -Fx "bootout gui/$uid/io.woowtech.test-owned" "$W/calls"
if fixture TEST_LAUNCHCTL_STATUS=63 PI_AGENT_LAUNCHD_LABEL=io.woowtech.test-owned PI_AGENT_LAUNCHD_EPHEMERAL=1 /bin/bash "$W/install/bin/pi-agent" start > /dev/null 2>&1; then
  echo 'FAIL: control wrapper hid launchd failure'; exit 1
fi
if fixture TEST_LAUNCHCTL_STATUS=63 PI_AGENT_LAUNCHD_LABEL=io.woowtech.test-owned PI_AGENT_LAUNCHD_EPHEMERAL=1 /bin/bash "$REPO/install.sh" service > /dev/null 2>&1; then
  echo 'FAIL: installer hid launchd failure'; exit 1
fi
if fixture PI_AGENT_LAUNCHD_LABEL='../escape' /bin/bash "$REPO/install.sh" service > /dev/null 2>&1; then
  echo 'FAIL: invalid label accepted'; exit 1
fi
: > "$W/calls"
fixture /bin/bash "$REPO/install.sh" service > /dev/null 2>&1
grep -Fx "load -w $W/account/Library/LaunchAgents/io.woowtech.pi-agent.plist" "$W/calls"
echo 'Mac isolation contracts: PASS (portable fixture only)'
