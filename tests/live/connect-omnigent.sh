#!/usr/bin/env bash
# Live-test helper (runs inside the PiAgent distro, as its user; see docs/WSL2-LIVE-TEST.md): name this install's
# Omnigent host and connect the plugin to a REAL server.
#
# The password comes in the environment of the job (a GitHub secret handed over with WSLENV) and goes to the plugin
# on stdin -- the one way it accepts a password. Nothing here prints it.
#
# The plugin takes a kernel lock (flock -n) for every operation and answers OPERATION_BUSY, at once, when another
# one is running -- the second live run hit that seconds after the install, the first did not. "Retry shortly" is
# what the plugin itself says to do, so: try again, a few times, and show who is running when it is busy.
set -euo pipefail
: "${OMNIGENT_SERVER:?not set}" "${OMNIGENT_USERNAME:?not set}" "${OMNIGENT_PASSWORD:?not set}" "${LIVE_HOST_NAME:?not set}"
PA="${PI_AGENT_HOME:-$HOME/.local/share/pi-agent}"
MAX_ATTEMPTS="${PA_LIVE_CONNECT_ATTEMPTS:-9}"
RETRY_SECONDS="${PA_LIVE_RETRY_SECONDS:-20}"
OUT="$(mktemp "${TMPDIR:-/tmp}/pa-connect-out.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

# A name of its own: two hosts of one account must not share one (docs/OPERATIONS-GOTCHAS.md section 13).
"$PA/bin/pi-agent-host-name" set "$LIVE_HOST_NAME"

attempt=0
while :; do
  attempt=$((attempt + 1))
  rc=0
  printf '%s\n' "$OMNIGENT_PASSWORD" \
    | "$PA/bin/pi-omnigent" connect --server "$OMNIGENT_SERVER" --username "$OMNIGENT_USERNAME" --password-stdin >"$OUT" 2>&1 || rc=$?
  cat "$OUT"
  if [ "$rc" -eq 0 ] || ! grep -q 'OPERATION_BUSY' "$OUT" || [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then break; fi
  echo "connect: the plugin is busy (attempt $attempt of $MAX_ATTEMPTS); running now:"
  # Command lines only (the password is on stdin, never in an argument); the first 150 characters of each.
  pids="$(pgrep -d, -f 'omnigent|flock|pi-web|paseo|uv |pip ' || true)"
  if [ -n "$pids" ]; then { ps -o pid,etimes,args -p "$pids" | cut -c1-150; } || true; fi
  sleep "$RETRY_SECONDS"
done
exit "$rc"
