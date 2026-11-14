#!/bin/bash
# Finder opens .command in Terminal: real progress and errors stay visible.
MODE=--open
case "$(basename "$0")" in *Repair*) MODE=--repair ;; esac
/bin/bash /usr/local/lib/woow-pi-agent/scripts/macos/pi-agent-launch.sh "$MODE"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "Pi Agent stopped (exit $rc). Review the message above; press Return to close."
  read -r _
fi
exit "$rc"
