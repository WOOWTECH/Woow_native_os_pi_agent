#!/usr/bin/env bash
# Live-test helper (runs inside the PiAgent distro, as its user; see docs/WSL2-LIVE-TEST.md): name this install's
# Omnigent host and connect the plugin to a REAL server.
#
# The password comes in the environment of the job (a GitHub secret handed over with WSLENV) and goes to the plugin
# on stdin -- the one way it accepts a password. Nothing here prints it.
set -euo pipefail
: "${OMNIGENT_SERVER:?not set}" "${OMNIGENT_USERNAME:?not set}" "${OMNIGENT_PASSWORD:?not set}" "${LIVE_HOST_NAME:?not set}"
PA="${PI_AGENT_HOME:-$HOME/.local/share/pi-agent}"

# A name of its own: two hosts of one account must not share one (docs/OPERATIONS-GOTCHAS.md section 13).
"$PA/bin/pi-agent-host-name" set "$LIVE_HOST_NAME"
printf '%s\n' "$OMNIGENT_PASSWORD" \
  | "$PA/bin/pi-omnigent" connect --server "$OMNIGENT_SERVER" --username "$OMNIGENT_USERNAME" --password-stdin
