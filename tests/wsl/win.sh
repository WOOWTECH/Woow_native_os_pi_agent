# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 1: rootfs/bin/pi-agent-win -- how an agent reaches Windows programs.
WIN="$REPO/rootfs/bin/pi-agent-win"

# A service started by systemd has no WSL_INTEROP in its environment (microsoft/WSL
# #8056, #8846, #10812), so Windows programs fail to start there. The tool has to
# find a live channel by itself: /run/WSL holds one socket per session, the stale
# ones included, and only the live one lets a Windows program start.
sandbox win-find-channel
GOOD="$S/run/WSL/2000_interop"
: > "$S/run/WSL/100_interop"; : > "$GOOD"
interop_env
CHECK="[ \"\${WSL_INTEROP:-}\" = \"$GOOD\" ] || { echo 'interop: connect failed' >&2; exit 1; }"
winexe cmd.exe   "$CHECK"
winexe hello.exe "$CHECK; echo \"hello \$*\""
run sbx "$WIN" run hello.exe a b
eq "run: finds the live channel when WSL_INTEROP is unset" "0|hello a b" "$rc|$out"

# An interactive shell already has a working channel: use it as it is, do not hunt.
sandbox win-session-channel
MINE="$S/my_interop"; : > "$MINE"; : > "$S/run/WSL/100_interop"
interop_env
CHECK="[ \"\${WSL_INTEROP:-}\" = \"$MINE\" ] || { echo 'interop: connect failed' >&2; exit 1; }"
winexe cmd.exe   "$CHECK"
winexe hello.exe "$CHECK; echo \"hello \$*\""
run sbx WSL_INTEROP="$MINE" "$WIN" run hello.exe x
eq "run: uses the channel the session already has" "0|hello x" "$rc|$out"

# Nothing live: say so, and never start the program half-connected.
sandbox win-no-channel
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe   "echo 'interop: connect failed' >&2; exit 1"
winexe hello.exe "echo SHOULD-NOT-RUN"
run sbx "$WIN" run hello.exe
eq    "run: exit 3 when no channel is live" "3" "$rc"
has   "run: says what is wrong" "interop" "$out"
lacks "run: does not start the program without a channel" "SHOULD-NOT-RUN" "$out"

# Codex runs its commands in a sandbox that refuses the socket a Windows program needs
# (seen on a real PC: "UtilBindVsockAnyPort:317: socket failed 1"). Interop is fine then,
# so the message must not send anyone off to /etc/wsl.conf.
sandbox win-codex-blocked
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe   "echo '<3>WSL (2 - ) ERROR: UtilBindVsockAnyPort:317: socket failed 1' >&2; exit 1"
winexe hello.exe "echo SHOULD-NOT-RUN"
run sbx "$WIN" run hello.exe
eq    "run: exit 3 inside a sandbox that blocks the channel" "3" "$rc"
has   "run: names the sandbox as the cause" "sandbox" "$out"
has   "run: says what to do about it" "outside the sandbox" "$out"
has   "run: says Windows itself is fine" "Windows itself is fine" "$out"
has   "run: names the setting that turns it off" "Full access" "$out"
lacks "run: does not blame the interop setting" "wsl.conf" "$out"
lacks "run: does not start the program" "SHOULD-NOT-RUN" "$out"

# A busy PC can miss one probe. Look again rather than report a channel that is there
# as missing -- but a command the agent asked for is never run twice by this.
sandbox win-busy
: > "$S/run/WSL/100_interop"
interop_env
printf '%s\n' '#!/bin/bash' \
  "n=\$(cat \"$S/probes\" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > \"$S/probes\"" \
  '[ "$n" -ge 2 ] && exit 0' \
  "echo '<3>WSL (2 - ) ERROR: UtilAcceptVsock:271: accept4 failed 110' >&2; exit 1" > "$S/sys32/cmd.exe"
chmod +x "$S/sys32/cmd.exe"
winexe hello.exe "echo \"ran\" >> \"$S/ran\"; echo hello"
run sbx "$WIN" run hello.exe
eq "run: a missed probe is tried again" "0|hello" "$rc|$out"
eq "run: the program itself runs once" "1" "$(wc -l < "$S/ran" | tr -d ' ')"

sandbox win-no-such-exe
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe "exit 0"
run sbx "$WIN" run nosuch.exe
eq  "run: exit 127 when the Windows program does not exist" "127" "$rc"
has "run: names the missing program" "nosuch.exe" "$out"

# ps: the thing agents use most. It must not read the user's profile, must not wait
# for input, must let script files run (a stock Windows client blocks them), and must
# hand back UTF-8 -- Windows PowerShell answers in the console code page, which is 950
# on a Traditional Chinese Windows and reaches Linux as mojibake.
sandbox win-ps
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe "exit 0"
printf '%s\n' '#!/bin/bash' \
  "printf '%s\n' \"\$@\" > \"$S/ps-args\"" \
  'echo PS-OUT' \
  'case "$*" in *FAILME*) exit 7 ;; esac' > "$S/sys32/WindowsPowerShell/v1.0/powershell.exe"
chmod +x "$S/sys32/WindowsPowerShell/v1.0/powershell.exe"
run sbx "$WIN" ps 'Get-Date'
eq "ps: passes the output through" "0|PS-OUT" "$rc|$out"
args="$(cat "$S/ps-args" 2>/dev/null)"
has "ps: never loads the user's profile" "-NoProfile" "$args"
has "ps: never waits for input" "-NonInteractive" "$args"
has "ps: lets script files run" "Bypass" "$args"
has "ps: the script reaches PowerShell" "Get-Date" "$args"
has "ps: output is forced to UTF-8" "UTF8" "$args"
run sbx "$WIN" ps 'FAILME'
eq "ps: PowerShell's exit status is the tool's" "7" "$rc"
run sbx "$WIN" ps
eq "ps: asks for a command when given none" "64" "$rc"

# open: the Windows default program for a URL or a file. wslview (wslu) when it is
# installed, PowerShell's Start-Process when not; a Linux path has to become a Windows
# path first; and it needs a live channel like everything else.
sandbox win-open
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe "exit 0"
stub wslview "printf '%s\n' \"\$@\" > \"$S/wslview-args\""
run sbx "$WIN" open http://localhost:30141
eq "open: hands the URL to wslview when it is installed" "0|http://localhost:30141" "$rc|$(cat "$S/wslview-args" 2>/dev/null)"

sandbox win-open-ps
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe "exit 0"
printf '%s\n' '#!/bin/bash' "printf '%s\n' \"\$@\" > \"$S/ps-args\"" > "$S/sys32/WindowsPowerShell/v1.0/powershell.exe"
chmod +x "$S/sys32/WindowsPowerShell/v1.0/powershell.exe"
printf '%s\n' '#!/bin/bash' "printf '%s\\n' 'C:\\Users\\a b\\report.html'" > "$S/bin/wslpath"; chmod +x "$S/bin/wslpath"
run sbx "$WIN" open "http://x/?a=1&b=2"
has "open: without wslview, Start-Process opens the URL" "Start-Process -FilePath 'http://x/?a=1&b=2'" "$(cat "$S/ps-args" 2>/dev/null)"
run sbx "$WIN" open "http://x/it's"
has "open: a quote in the URL cannot break out of the PowerShell string" "'http://x/it''s'" "$(cat "$S/ps-args" 2>/dev/null)"
run sbx "$WIN" open /home/u/report.html
has "open: a Linux path is converted to a Windows path first" 'C:\Users\a b\report.html' "$(cat "$S/ps-args" 2>/dev/null)"
run sbx "$WIN" open
eq "open: asks for a target when given none" "64" "$rc"

sandbox win-open-nochannel
: > "$S/run/WSL/100_interop"
interop_env
winexe cmd.exe "exit 1"
stub wslview "echo SHOULD-NOT-RUN"
run sbx "$WIN" open http://localhost:30141
eq    "open: exit 3 when no channel is live, even with wslview" "3" "$rc"
lacks "open: wslview is not started without a channel" "SHOULD-NOT-RUN" "$out"

# doctor: one line per check, never stopping at the first problem, exit 1 if any check
# failed. A check whose prerequisite failed is skipped, not failed a second time.
doctor_world() {   # doctor_world NAME -- a healthy WSL2 machine
  sandbox "$1"
  : > "$S/run/WSL/100_interop"; interop_env
  mkdir -p "$S/systemd"
  winexe cmd.exe "exit 0"
  printf '%s\n' '#!/bin/bash' \
    'case "$*" in *Invoke-WebRequest*) echo "${PA_TEST_HTTP:-200}" ;; *) echo 2 ;; esac' \
    > "$S/sys32/WindowsPowerShell/v1.0/powershell.exe"
  chmod +x "$S/sys32/WindowsPowerShell/v1.0/powershell.exe"
  stub systemctl 'echo "${PA_TEST_UNIT:-active}"'
}
dsbx() { sbx PA_WSL_SYSTEMD_DIR="$S/systemd" PA_RUN_USER_DIR="$S/runuser" "$@"; }

doctor_world win-doctor-ok
run dsbx "$WIN" doctor
eq    "doctor: exit 0 on a healthy machine" "0" "$rc"
has   "doctor: interop works"                "[PASS] interop" "$out"
has   "doctor: PowerShell answers"           "[PASS] powershell" "$out"
has   "doctor: Windows reaches pi-web"       "[PASS] localhost" "$out"
has   "doctor: the service is active"        "[PASS] service" "$out"
lacks "doctor: nothing failed"               "[FAIL]" "$out"

doctor_world win-doctor-nochannel
winexe cmd.exe "exit 1"
run dsbx "$WIN" doctor
eq  "doctor: exit 1 when the channel is dead" "1" "$rc"
has "doctor: reports the dead channel"        "[FAIL] interop" "$out"
has "doctor: skips PowerShell, which needs it" "[SKIP] powershell" "$out"
has "doctor: skips the localhost check"        "[SKIP] localhost" "$out"
has "doctor: still reports the checks that do not need it" "[PASS] systemd" "$out"

doctor_world win-doctor-codex-blocked
winexe cmd.exe "echo '<3>WSL (2 - ) ERROR: UtilBindVsockAnyPort:317: socket failed 1' >&2; exit 1"
run dsbx "$WIN" doctor
eq    "doctor: exit 1 inside a sandbox" "1" "$rc"
has   "doctor: says a sandbox is in the way" "[FAIL] interop" "$out"
has   "doctor: names the sandbox" "sandbox" "$out"
lacks "doctor: does not blame the interop setting" "wsl.conf" "$out"
has   "doctor: does not call the service down" "[SKIP] service" "$out"
lacks "doctor: says nothing false about the service" "[FAIL] service" "$out"

doctor_world win-doctor-localhost
run dsbx PA_TEST_HTTP=0 PI_WEB_PORT=30199 "$WIN" doctor
eq  "doctor: exit 1 when Windows cannot reach pi-web" "1" "$rc"
has "doctor: says which port" "[FAIL] localhost" "$out"
has "doctor: names the port"  "30199" "$out"

doctor_world win-doctor-systemd
rmdir "$S/systemd"
run dsbx "$WIN" doctor
has "doctor: reports systemd that is not running" "[FAIL] systemd" "$out"
has "doctor: says how to enable it"               "systemd=true" "$out"

doctor_world win-doctor-service
run dsbx PA_TEST_UNIT=inactive "$WIN" doctor
has "doctor: reports a service that is not active" "[FAIL] service" "$out"

doctor_world win-doctor-mnt
run dsbx PI_AGENT_HOME="/mnt/c/pi-agent" PA_WSL_MNT_ROOT=/mnt "$WIN" doctor
has "doctor: reports an install on a Windows drive" "[FAIL] home" "$out"

doctor_world win-doctor-notwsl
printf 'Linux version 6.8.0-45-generic (buildd@lcy02) #45-Ubuntu SMP\n' > "$S/proc-version"
run dsbx "$WIN" doctor
eq    "doctor: exit 1 outside WSL" "1" "$rc"
has   "doctor: says this is not WSL" "[FAIL] wsl" "$out"
lacks "doctor: runs no other check outside WSL" "[PASS]" "$out"

doctor_world win-doctor-port-file
printf '30177\n' > "$S/pa/pi-web-port"
run dsbx PA_TEST_HTTP=0 "$WIN" doctor
has "doctor: checks the port the install recorded" "30177" "$out"
