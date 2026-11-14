#!/bin/bash
# Shared per-user PKG install/retry and Finder entry. Bash 3.2 compatible.
set -euo pipefail
PAYLOAD="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:---open}"
case "$MODE" in --open|--install|--repair) ;; *) echo 'usage: pi-agent-launch.sh [--open|--install|--repair]' >&2; exit 64 ;; esac
[ "$(uname -s)" = Darwin ] || { echo 'macOS only' >&2; exit 1; }
[ "$(id -u)" != 0 ] || { echo 'Run as the logged-in user, without sudo.' >&2; exit 1; }
umask 077
# Respect the existing launchd install location rather than creating a second identity.
PLIST_PORT=""
PLIST="$HOME/Library/LaunchAgents/io.woowtech.pi-agent.plist"
if [ -f "$PLIST" ]; then
  EXISTING="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_AGENT_HOME' "$PLIST")" || {
    echo "Cannot determine existing install from $PLIST; leaving it untouched." >&2; exit 1;
  }
  [ -z "${PI_AGENT_HOME:-}" ] || [ "$PI_AGENT_HOME" = "$EXISTING" ] || {
    echo "PI_AGENT_HOME differs from $PLIST; leaving both untouched." >&2; exit 1;
  }
  PI_AGENT_HOME="$EXISTING"
  PLIST_PORT="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_WEB_PORT' "$PLIST" 2>/dev/null || true)"
fi
export PI_AGENT_HOME="${PI_AGENT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}"
case "$PI_AGENT_HOME" in /*) ;; *) echo 'PI_AGENT_HOME must be absolute' >&2; exit 1 ;; esac
mkdir -p "$PI_AGENT_HOME/logs"
LOG="$PI_AGENT_HOME/logs/macos-setup.log"
# Kernel lock: serializes double clicks and postinstall; no stale PID files.
if [ "${2:-}" != --locked ]; then
  echo "Pi Agent: waiting for any setup already running. Log: $LOG"
  exec "$PAYLOAD/rootfs/bin/flock" "$PI_AGENT_HOME/.macos-setup.lock" /bin/bash "$0" "$MODE" --locked
fi
PORT=30141
if [ -f "$PI_AGENT_HOME/pi-web-port" ]; then PORT="$(cat "$PI_AGENT_HOME/pi-web-port")"; fi
[ -z "$PLIST_PORT" ] || PORT="$PLIST_PORT"
case "$PORT" in ''|*[!0-9]*) echo 'Invalid saved pi-web-port; leaving configuration untouched.' >&2; exit 1 ;; esac
[ "${#PORT}" -le 5 ] && [ "$PORT" -gt 0 ] && [ "$PORT" -le 65535 ] || exit 1
export PI_WEB_PORT="$PORT"
CTL="$PI_AGENT_HOME/bin/pi-agent"
STAMP="$PI_AGENT_HOME/.macos-pkg-complete"
# A failed upgrade must remain retryable even if an older control script exists.
if [ "$MODE" != --open ] || [ ! -x "$CTL" ] || [ -f "$PI_AGENT_HOME/.macos-pkg-incomplete" ]; then
  touch "$PI_AGENT_HOME/.macos-pkg-incomplete"
  ART_URL="$(head -n1 "$PAYLOAD/piweb-artifact-url")"
  ART_NAME="$(head -n1 "$PAYLOAD/piweb-artifact-file" 2>/dev/null || true)"
  export PI_AGENT_PIWEB_ARTIFACT_SHA256="$(head -n1 "$PAYLOAD/piweb-artifact-sha256")"
  [ "${#PI_AGENT_PIWEB_ARTIFACT_SHA256}" = 64 ] || { echo 'Invalid artifact SHA256' >&2; exit 1; }
  printf '%s' "$PI_AGENT_PIWEB_ARTIFACT_SHA256" | grep -Eq '^[0-9a-f]{64}$' || { echo 'Invalid artifact SHA256' >&2; exit 1; }
  if [ -n "$ART_NAME" ]; then
    case "$ART_NAME" in *[!A-Za-z0-9._+-]*) echo 'Invalid embedded artifact filename' >&2; exit 1 ;; esac
    [ -z "$ART_URL" ] || { echo 'Ambiguous artifact manifests' >&2; exit 1; }
    printf '%s' "$ART_NAME" | grep -Eq '^piweb-[A-Za-z0-9._+-]+-macos-(arm64|x64)\.tar\.gz$' || { echo 'Invalid embedded artifact filename' >&2; exit 1; }
    case "$(uname -m)" in arm64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) echo 'Unsupported Mac architecture' >&2; exit 1 ;; esac
    case "$ART_NAME" in *-macos-"$ARCH".tar.gz) ;; *) echo 'Embedded artifact architecture does not match this Mac' >&2; exit 1 ;; esac
    export PI_AGENT_PIWEB_ARTIFACT="$PAYLOAD/artifacts/$ART_NAME"
    [ -f "$PI_AGENT_PIWEB_ARTIFACT" ] && [ ! -L "$PI_AGENT_PIWEB_ARTIFACT" ] || { echo 'Embedded artifact missing or symlinked' >&2; exit 1; }
    # install.sh's local-file branch does NOT verify SHA: never enter it until
    # this root-owned package payload matches the explicitly pinned digest.
    echo 'Verifying embedded pi-web artifact ...'
    [ "$(shasum -a 256 "$PI_AGENT_PIWEB_ARTIFACT" | awk '{print $1}')" = "$PI_AGENT_PIWEB_ARTIFACT_SHA256" ] || {
      echo 'Embedded artifact sha256 mismatch; reinstall a verified package.' >&2; exit 1;
    }
  else
    printf '%s' "$ART_URL" | grep -Eq '^https://[A-Za-z0-9._~/%+-]+-macos-(arm64|x64)\.tar\.gz$' || { echo 'Invalid artifact URL' >&2; exit 1; }
    export PI_AGENT_PIWEB_ARTIFACT="$ART_URL"
  fi
  echo "Pi Agent setup: downloads require internet. Stage output follows; log: $LOG"
  # pipefail preserves install failure, including tee/disk failures.
  if (cd "$HOME" && /bin/bash "$PAYLOAD/install.sh") 2>&1 | tee -a "$LOG"; then
    date -u > "$STAMP"
    rm -f "$PI_AGENT_HOME/.macos-pkg-incomplete"
  else
    echo "Setup failed. Your data was kept. Reopen /Applications/Pi Agent.command to retry. Log: $LOG" >&2
    exit 1
  fi
fi
[ "$MODE" != --install ] || exit 0
"$CTL" start
if ! launchctl print "gui/$(id -u)/io.woowtech.pi-agent" >/dev/null 2>&1; then
  echo 'Pi Agent launchd job is not loaded. Open /Applications/Pi Agent Repair.command.' >&2
  exit 1
fi
URL="http://127.0.0.1:$PORT"
echo "Waiting up to 120 seconds for $URL ..."
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl --noproxy '*' --fail --silent --output /dev/null --connect-timeout 1 --max-time 2 "$URL/"; then
    open "$URL"
    echo "Pi Agent is ready: $URL"
    exit 0
  fi
  sleep 2
done
echo "Service did not become ready. Inspect $PI_AGENT_HOME/logs/pi-web.log and $LOG." >&2
echo 'Use /Applications/Pi Agent Repair.command to rerun setup without deleting your data.' >&2
exit 1
