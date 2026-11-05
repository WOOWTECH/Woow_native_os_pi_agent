#!/bin/bash
# The `claude` wrapper on a Mac without the Command Line Tools: which git Claude Code finds.
#
# Why this exists. There /usr/bin/git is a stub that opens the "install the command line developer tools?" dialog.
# Claude Code runs git whenever it starts to work, and a connected Omnigent host starts it every 3 minutes, so on such
# a Mac the dialog came back within 3 minutes of each Cancel -- measured on an Intel Mac with the tools moved away. The
# wrapper puts bin/no-dev-tools/git ahead of the stub, and only there.
#
#   tests/claude-no-tools.sh
#   PI_TEST_WRAPPER=/path/to/an/older/claude tests/claude-no-tools.sh     (expect failures: that is the check)
#
# Hermetic: a temp directory, a simulated Mac (uname and xcode-select stand-ins) and a fake Claude Code that reports the
# git it finds. /usr/bin/git itself is only ever looked up, never run, so this opens no dialog on any Mac.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="${PI_TEST_WRAPPER:-$HERE/rootfs/bin/claude}"
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

if [ ! -e /usr/bin/git ]; then echo "  SKIP  no /usr/bin/git here, which is what the wrapper looks for"; exit 0; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-claude-tools.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
PA="$W/pa"; SIM="$W/sim"; DEV="$W/developer"; BREW="$W/brew"
mkdir -p "$PA/bin/no-dev-tools" "$PA/node/bin" "$PA/home" "$PA/clis/claude/node_modules/.bin" "$SIM" "$DEV/usr/bin" "$BREW" "$W/empty"
cp "$WRAPPER" "$PA/bin/claude"
cp "$HERE/rootfs/bin/pi-agent-env.sh" "$PA/bin/pi-agent-env.sh"
cp "$HERE/rootfs/bin/no-dev-tools/git" "$PA/bin/no-dev-tools/git"
: > "$PA/bin/pi-agent-share-state.mjs"
printf '#!/bin/bash\nexit 0\n' > "$PA/node/bin/node"
# the fake Claude Code: the git it would run, and PATH
cat > "$PA/clis/claude/node_modules/.bin/claude" <<'EOS'
#!/bin/bash
echo "GIT=$(command -v git)"
echo "PATH=$PATH"
EOS
printf '#!/bin/bash\necho "real git: $*"\n' > "$DEV/usr/bin/git"
printf '#!/bin/bash\n[ "${1:-}" = -s ] && { cat "%s/os"; exit 0; }\nexec %s "$@"\n' "$W" "$(command -v uname)" > "$SIM/uname"
# xcode-select -p: the directory in $W/dev-dir, or the failure of a Mac without the tools
printf '#!/bin/bash\n[ "${1:-}" = -p ] && [ -s "%s/dev-dir" ] && { cat "%s/dev-dir"; exit 0; }\necho "xcode-select: error: unable to get active developer directory" >&2\nexit 2\n' "$W" "$W" > "$SIM/xcode-select"
printf '#!/bin/bash\necho "brew git: $*"\n' > "$BREW/git"
chmod 755 "$PA/bin/claude" "$PA/bin/no-dev-tools/git" "$PA/node/bin/node" "$PA/clis/claude/node_modules/.bin/claude" "$DEV/usr/bin/git" "$SIM/uname" "$SIM/xcode-select" "$BREW/git"
STAND_IN="$PA/bin/no-dev-tools/git"

# run_wrapper OS DEV_DIR PATH: the wrapper on a simulated machine; prints the fake Claude Code's report
run_wrapper() {
  echo "$1" > "$W/os"; printf '%s' "$2" > "$W/dev-dir"
  env -i HOME="$W/home" PATH="$3" PI_AGENT_HOME="$PA" /bin/bash "$PA/bin/claude" 2>&1
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "== a Mac without the tools"
out="$(run_wrapper Darwin "" "$SIM:/usr/bin:/bin:/usr/sbin:/sbin")"
[ "$(field "$out" GIT)" = "$STAND_IN" ] && ok "Claude Code finds the stand-in, not the stub" || no "Claude Code finds the stand-in, not the stub" "$(field "$out" GIT)"
printf '' > "$W/dev-dir"
msg="$(env -i PATH="$SIM:/usr/bin:/bin" "$STAND_IN" --version 2>&1)"; rc=$?
[ "$rc" = 127 ] && ok "the stand-in answers like a missing git: exit 127" || no "the stand-in answers like a missing git: exit 127" "exit $rc"
case "$msg" in *"xcode-select --install"*) ok "...and says how to get the tools" ;; *) no "...and says how to get the tools" "$msg" ;; esac
out2="$(env -i HOME="$W/home" PATH="$PA/bin/no-dev-tools:$SIM:/usr/bin:/bin:/usr/sbin:/sbin" PI_AGENT_HOME="$PA" /bin/bash "$PA/bin/claude" 2>&1)"
[ "$(field "$out2" PATH | tr ':' '\n' | grep -c no-dev-tools)" = 1 ] && ok "a claude started from a claude does not add it twice" || no "a claude started from a claude does not add it twice" "$(field "$out2" PATH)"

echo "== the tools installed while a claude keeps running"
printf '%s' "$DEV" > "$W/dev-dir"
msg="$(env -i PATH="$SIM:/usr/bin:/bin" "$STAND_IN" log --format='%h %s' 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$msg" = "real git: log --format=%h %s" ] && ok "the stand-in runs the real git, with its arguments intact" || no "the stand-in runs the real git, with its arguments intact" "exit $rc: $msg"

echo "== nothing changes anywhere else"
out="$(run_wrapper Darwin "$DEV" "$SIM:/usr/bin:/bin:/usr/sbin:/sbin")"
[ "$(field "$out" GIT)" = /usr/bin/git ] && ok "a Mac with the tools: /usr/bin/git" || no "a Mac with the tools: /usr/bin/git" "$(field "$out" GIT)"
out="$(run_wrapper Darwin "" "$SIM:$BREW:/usr/bin:/bin:/usr/sbin:/sbin")"
[ "$(field "$out" GIT)" = "$BREW/git" ] && ok "no tools, but a git from elsewhere first on PATH: that one" || no "no tools, but a git from elsewhere first on PATH: that one" "$(field "$out" GIT)"
out="$(run_wrapper Linux "" "$SIM:/usr/bin:/bin:/usr/sbin:/sbin")"
[ "$(field "$out" GIT)" = /usr/bin/git ] && ok "Linux: /usr/bin/git, xcode-select not asked" || no "Linux: /usr/bin/git, xcode-select not asked" "$(field "$out" GIT)"
[ "$(field "$out" PATH | tr ':' '\n' | grep -c no-dev-tools)" = 0 ] && ok "...and PATH does not name the stand-in" || no "...and PATH does not name the stand-in" "$(field "$out" PATH)"

echo
printf 'claude without the tools: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
