# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 3: rootfs/bin/pi-agent-env.sh -- what the agents' environment gets on WSL.
ENV_SH="$REPO/rootfs/bin/pi-agent-env.sh"

# penv NAME... -- source the env file in a clean shell and print VAR=value lines.
penv() { sbx bash -c '. "$1"; printf "PATH=%s\nBROWSER=%s\n" "$PATH" "${BROWSER:-}"' _ "$ENV_SH"; }
pathof()    { printf '%s\n' "$1" | sed -n 's/^PATH=//p'; }
browserof() { printf '%s\n' "$1" | sed -n 's/^BROWSER=//p'; }

# Nothing recorded by the Windows-side installer = interop is off = nothing changes.
sandbox env-baseline
BASE="$(penv)"
eq "env: without windows-interop.env the PATH has no Windows directory" "0" "$(pathof "$BASE" | grep -c "$S/sys32")"
eq "env: and BROWSER is left alone" "" "$(browserof "$BASE")"

# With it, the two Windows directories come LAST: the scoped Node and our wrappers keep
# winning, so a Windows node/npm/git on the path cannot shadow them.
sandbox env-interop
interop_env
GOT="$(penv)"; GOT_PATH="$(pathof "$GOT")"
case "$GOT_PATH" in
  *":$S/sys32:$S/sys32/WindowsPowerShell/v1.0") ok "env: System32 and PowerShell are appended at the very end" ;;
  *) no "env: System32 and PowerShell are appended at the very end" "$GOT_PATH" ;;
esac
case "$GOT_PATH" in
  "$S/pa/bin:$S/pa/node/bin:"*) ok "env: the scoped bin and Node still come first" ;;
  *) no "env: the scoped bin and Node still come first" "$GOT_PATH" ;;
esac
eq  "env: BROWSER opens links on the Windows side" "$S/pa/bin/pi-agent-win open" "$(browserof "$GOT")"

# Sourced twice (a wrapper that sources it, run from a shell that already did): no duplicates.
TWICE="$(sbx bash -c '. "$1"; . "$1"; printf "%s" "$PATH"' _ "$ENV_SH")"
eq "env: sourcing it twice adds the directories once" "1" "$(printf '%s' "$TWICE" | tr ':' '\n' | grep -c "^$S/sys32$")"

# A BROWSER the user chose is theirs.
CHOSEN="$(sbx BROWSER=/usr/bin/mybrowser bash -c '. "$1"; printf "%s" "$BROWSER"' _ "$ENV_SH")"
eq "env: an existing BROWSER is kept" "/usr/bin/mybrowser" "$CHOSEN"

# The file is there but the drive is not (interop was turned off, or the drive changed).
sandbox env-gone
printf 'PA_WIN_SYSTEM32=%s\n' "$S/no-such-drive/Windows/System32" > "$S/pa/windows-interop.env"
GONE="$(penv)"
eq "env: a recorded directory that does not exist is ignored" "0" "$(pathof "$GONE" | grep -c no-such-drive)"
eq "env: and BROWSER is left alone then" "" "$(browserof "$GONE")"

# The port the install recorded reaches everything that sources this file (tests/smoke.sh does).
sandbox env-port
printf '30142\n' > "$S/pa/pi-web-port"
eq "env: PI_WEB_PORT comes from the install's record" "30142" "$(sbx bash -c '. "$1"; printf "%s" "${PI_WEB_PORT:-unset}"' _ "$ENV_SH")"
eq "env: an explicit PI_WEB_PORT wins over the record" "30199" "$(sbx PI_WEB_PORT=30199 bash -c '. "$1"; printf "%s" "${PI_WEB_PORT:-unset}"' _ "$ENV_SH")"
sandbox env-port-none
eq "env: no record, nothing is set" "unset" "$(sbx bash -c '. "$1"; printf "%s" "${PI_WEB_PORT:-unset}"' _ "$ENV_SH")"
