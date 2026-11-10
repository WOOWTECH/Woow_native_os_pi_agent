#!/bin/bash
# The claude and codex wrappers: what they run before the real CLI, and the environment Claude Code starts with.
#
# Why this exists. Measured on Allwinner H618 4 GB boards (v0.3.0-rc.3, Claude Code 2.1.296), 2026-11-09/10:
#   * the Paseo daemon asks `claude --version` and `codex --version` every 17.3 s, and each one first ran the shared
#     MCP/skills sync (a node start): about 6% of the 4-core board, about 60% of what it had idle;
#   * inside long-lived sessions Omnigent had started, Claude Code's auto-updater ran
#     `npm install -g @anthropic-ai/claude-code` about every 30 minutes, ~330 MB written to eMMC each time.
#
#   A  --version, -v, -V, --help or -h alone: no sync, and the real CLI gets the arguments; anything else: the sync first
#   B  DISABLE_AUTOUPDATER=1 reaches Claude Code however it is started here -- through the claude wrapper, with the
#      filtered environment Omnigent gives its sessions, and from pi-web-start.sh, whose environment pi-web, the
#      Omnigent host it launches and the Paseo daemon inherit; a value the caller set wins
#
#   tests/cli-wrappers.sh
#   PI_TEST_CLAUDE=... PI_TEST_CODEX=... PI_TEST_ENV=... tests/cli-wrappers.sh   older copies: expect failures, that is the check
#
# Hermetic: a temp directory, a fake node that only notes what it is asked to run, and fake CLIs that report their
# arguments and environment. Nothing else is started.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_W="${PI_TEST_CLAUDE:-$HERE/rootfs/bin/claude}"
CODEX_W="${PI_TEST_CODEX:-$HERE/rootfs/bin/codex}"
ENV_SH="${PI_TEST_ENV:-$HERE/rootfs/bin/pi-agent-env.sh}"
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-cli-wrappers.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
PA="$W/pa"; REAL_HOME="$W/real-home"; NODE_LOG="$W/node.log"
mkdir -p "$PA/bin" "$PA/node/bin" "$PA/home" "$PA/data" "$REAL_HOME" \
  "$PA/clis/claude/node_modules/.bin" "$PA/clis/codex/node_modules/.bin" "$PA/piweb/lib/node_modules/@agegr/pi-web/bin"
cp "$CLAUDE_W" "$PA/bin/claude"; cp "$CODEX_W" "$PA/bin/codex"
cp "$ENV_SH" "$PA/bin/pi-agent-env.sh"; cp "$HERE/rootfs/bin/pi-web-start.sh" "$PA/bin/pi-web-start.sh"
: > "$PA/bin/pi-agent-share-state.mjs"
: > "$PA/piweb/lib/node_modules/@agegr/pi-web/bin/pi-web.js"
# the fake node: notes the script it runs; as pi-web, reports the environment pi-web would hand on
cat > "$PA/node/bin/node" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$NODE_LOG"
case "\$1" in */pi-web.js) echo "pi-web DISABLE_AUTOUPDATER=\${DISABLE_AUTOUPDATER-unset}" ;; esac
exit 0
EOF
for cli in claude codex; do
  printf '#!/bin/bash\necho "ARGS=$*"\necho "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER-unset}"\n' > "$PA/clis/$cli/node_modules/.bin/$cli"
done
chmod 755 "$PA/bin/claude" "$PA/bin/codex" "$PA/bin/pi-web-start.sh" "$PA/node/bin/node" \
  "$PA/clis/claude/node_modules/.bin/claude" "$PA/clis/codex/node_modules/.bin/codex"

# run CLI ARGS...: the wrapper with only what Omnigent hands a session (HOME, PATH); prints the fake CLI's report
run() { local cli="$1"; shift; : > "$NODE_LOG"; env -i HOME="$REAL_HOME" PATH=/usr/bin:/bin PI_AGENT_HOME="$PA" /bin/bash "$PA/bin/$cli" "$@" 2>&1; }
synced() { grep -q 'pi-agent-share-state.mjs$' "$NODE_LOG" && echo yes || echo no; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
# case LABEL WANT_SYNC CLI ARGS...
case_() {
  local label="$1" want="$2" cli="$3"; shift 3
  local out got_args want_args="$*"; out="$(run "$cli" "$@")"; got_args="$(field "$out" ARGS)"
  if [ "$(synced)" = "$want" ] && [ "$got_args" = "$want_args" ]; then ok "$label"
  else no "$label" "sync ran: $(synced) (wanted $want); the CLI got '$got_args' (wanted '$want_args')"; fi
}

echo "== A. what runs before the real CLI"
case_ "claude --version: no sync"                  no  claude --version
case_ "claude -v: no sync"                         no  claude -v
case_ "claude --help: no sync"                     no  claude --help
case_ "claude -h: no sync"                         no  claude -h
case_ "codex --version: no sync"                   no  codex --version
case_ "codex -V: no sync"                          no  codex -V
case_ "codex --help: no sync"                      no  codex --help
case_ "claude --version --help: still only those"  no  claude --version --help
case_ "claude with no arguments (a session): the sync runs"  yes claude
case_ "claude -p 'hi': the sync runs, arguments intact"      yes claude -p hi
case_ "claude mcp --help: a subcommand, the sync runs"        yes claude mcp --help
case_ "claude -p -v (a prompt that is '-v'): the sync runs"   yes claude -p -v
case_ "claude --version-x: not the flag, the sync runs"       yes claude --version-x
case_ "codex exec 'x': the sync runs"                         yes codex exec x

echo "== B. DISABLE_AUTOUPDATER reaches Claude Code"
out="$(run claude -p hi)"
[ "$(field "$out" DISABLE_AUTOUPDATER)" = 1 ] && ok "through the claude wrapper, with only HOME and PATH (what Omnigent passes): 1" \
  || no "through the claude wrapper, with only HOME and PATH (what Omnigent passes): 1" "$(field "$out" DISABLE_AUTOUPDATER)"
out="$(run claude --version)"
[ "$(field "$out" DISABLE_AUTOUPDATER)" = 1 ] && ok "...also for --version, which skips the sync: 1" \
  || no "...also for --version, which skips the sync: 1" "$(field "$out" DISABLE_AUTOUPDATER)"
out="$(: > "$NODE_LOG"; env -i HOME="$REAL_HOME" PATH=/usr/bin:/bin PI_AGENT_HOME="$PA" DISABLE_AUTOUPDATER=0 /bin/bash "$PA/bin/claude" -p hi 2>&1)"
[ "$(field "$out" DISABLE_AUTOUPDATER)" = 0 ] && ok "a value the caller set wins (DISABLE_AUTOUPDATER=0 lets it update)" \
  || no "a value the caller set wins (DISABLE_AUTOUPDATER=0 lets it update)" "$(field "$out" DISABLE_AUTOUPDATER)"
out="$(: > "$NODE_LOG"; env -i HOME="$REAL_HOME" PATH=/usr/bin:/bin PI_AGENT_HOME="$PA" /bin/bash "$PA/bin/pi-web-start.sh" 2>&1)"
case "$out" in
  *"pi-web DISABLE_AUTOUPDATER=1"*) ok "pi-web-start.sh starts pi-web with it, so the Omnigent host and the Paseo daemon inherit it" ;;
  *) no "pi-web-start.sh starts pi-web with it, so the Omnigent host and the Paseo daemon inherit it" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
esac
grep -q '^export DISABLE_AUTOUPDATER=' "$PA/bin/pi-agent-env.sh" && ok "it is set in pi-agent-env.sh, the one file every launcher sources" \
  || no "it is set in pi-agent-env.sh, the one file every launcher sources"

echo
printf 'claude/codex wrappers: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
