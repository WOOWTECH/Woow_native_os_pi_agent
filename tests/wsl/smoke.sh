# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 7: tests/smoke.sh -- run from a real terminal, which is how the Windows installer runs it on a user's PC.
#
# Found on the first real Windows PC: with a terminal on stdin, `claude mcp get` under `timeout` is stopped by the kernel for
# touching the terminal from a background process group (state T), so the check fails after its 25 s limit and the install
# ends with exit 70. CI never saw it: a hosted runner has no terminal. The self-check asks nobody anything, so it runs with
# stdin from /dev/null.
SMOKE="$REPO/tests/smoke.sh"

smoke_world() {
  sandbox "$1"
  mkdir -p "$S/data" "$S/pa/clis" "$S/home"
  # Everything the self-check would touch is a stand-in: the service manager above all, on this machine it is a real one.
  printf 'export PI_AGENT_DATA_DIR=%s\n' "$S/data" > "$S/pa/bin/pi-agent-env.sh"
  stub uname 'echo Linux'
  stub systemctl 'exit 0'
  stub launchctl 'echo "launchctl must not run in this test" >&2; exit 99'
  stub node 'exit 0'
  stub curl 'printf 200'
  printf '#!/bin/bash\nif [ -t 0 ]; then echo terminal; else echo no-terminal; fi >> "%s"\n' "$S/stdin-seen" > "$S/pa/bin/pi"
  chmod +x "$S/pa/bin/pi"
}
# pty.spawn is no use here: on the Python 3.9 that macOS ships it keeps waiting for input after the child has gone.
PTY_PY='
import os, pty, signal, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
def give_up(*_):
    os.killpg(pid, signal.SIGKILL)
    sys.exit("gave up after 120 s")
signal.signal(signal.SIGALRM, give_up)
signal.alarm(120)
while True:
    try:
        data = os.read(fd, 65536)
    except OSError:
        break
    if not data:
        break
    sys.stdout.write(data.decode("utf-8", "replace"))
os.waitpid(pid, 0)
'
ptyrun() { sbx python3 -c "$PTY_PY" "$@"; }

# A harness that does not really give a terminal would make the check below pass for nothing.
smoke_world smoke-harness
run ptyrun /bin/bash -c 'if [ -t 0 ]; then echo terminal; else echo no-terminal; fi'
has "the test harness really gives a terminal" "terminal" "$(printf '%s' "$out" | tr -d '\r' | grep -v '^no-terminal')"

smoke_world smoke-tty
run ptyrun "$SMOKE"
eq "the self-check takes the terminal away from what it runs" "no-terminal" "$(head -1 "$S/stdin-seen" 2>/dev/null)"
lacks "the self-check stays inside this test's stand-ins" "launchctl must not run" "$out"
