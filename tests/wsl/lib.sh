# Helpers for tests/wsl.sh. Sourced, never executed.
#
# The point of this suite is that it can run anywhere -- the dev Mac, a Linux box, CI
# -- and still say something true about the WSL2 support. Everything the code under
# test reads from the machine (/proc/version, /run/WSL, /run/user, /etc, /home, the
# Windows drive) is redirected into a throw-away directory, and every external
# program is a stub, so it never touches a real WSL, a real install or the real /etc.
# bash 3.2 compatible (macOS): no arrays-as-flags, no mapfile, no ${var,,}.

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pa-wsl-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

eq()    { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected: [$2]  got: [$3]"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "expected to contain: [$2]  got: [$3]" ;; esac; }
lacks() { case "$3" in *"$2"*) no "$1" "must not contain: [$2]  got: [$3]" ;; *) ok "$1" ;; esac; }

# sandbox NAME -- a fresh layout; sets $S. The proc-version file says "microsoft", so
# the sandbox is a WSL2 machine unless a test overwrites it.
sandbox() {
  S="$TMP/$1"; rm -rf "$S"
  mkdir -p "$S/bin" "$S/run/WSL" "$S/sys32/WindowsPowerShell/v1.0" "$S/pa/bin" "$S/home"
  printf 'Linux version 5.15.167.4-microsoft-standard-WSL2 (root@x) (gcc) #1 SMP\n' > "$S/proc-version"
}

# stub NAME BODY -- a program on PATH.
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$S/bin/$1"; chmod +x "$S/bin/$1"; }

# winexe NAME BODY -- a "Windows program" under the fake System32.
winexe() { printf '#!/bin/bash\n%s\n' "$2" > "$S/sys32/$1"; chmod +x "$S/sys32/$1"; }

# interop_env -- what the Windows-side installer writes when interop is on.
interop_env() { printf 'PA_WIN_SYSTEM32=%s\n' "$S/sys32" > "$S/pa/windows-interop.env"; }

# sbx [VAR=val ...] COMMAND... -- run in a clean environment (nothing from the
# developer's shell leaks in: no WSL_INTEROP, no XDG_RUNTIME_DIR, no real PATH).
sbx() {
  env -i PATH="$S/bin:$SYS_PATH" HOME="$S/home" TMPDIR="$TMP" \
    PI_AGENT_HOME="$S/pa" PA_WSL_PROC_VERSION="$S/proc-version" \
    PA_WSL_RUN_DIR="$S/run/WSL" "$@"
}

# run CMD... -- stdout+stderr into $out, exit status into $rc.
out=""; rc=0
run() { out="$("$@" 2>&1)"; rc=$?; }

# stubf NAME -- like stub, but the body comes on stdin and @S@ is replaced by the sandbox.
stubf() { sed "s#@S@#$S#g" > "$S/bin/$1"; chmod +x "$S/bin/$1"; }
