#!/usr/bin/env bash
# Comprehensive smoke test for a native Pi Agent install (Linux / WSL2).
# Run after ./install.sh. Exercises versions, the service, HTTP routes, the
# Omnigent/Paseo plugin state, and a full skill/MCP sharing round-trip.
# Exits non-zero if any assertion fails. Self-cleans its test artifacts.
set -u
: "${PI_AGENT_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}"
export PI_AGENT_HOME
# shellcheck source=/dev/null
. "$PI_AGENT_HOME/bin/pi-agent-env.sh"
PORT="${PI_WEB_PORT:-30141}"
BASE="http://127.0.0.1:$PORT"

# Same assertions on Linux and macOS: the service manager, the "is this port
# listening" check and `timeout` are all spelled differently (or absent) there.
case "$(uname -s)" in Darwin) PA_PLATFORM=macos ;; *) PA_PLATFORM=linux ;; esac
PLIST_LABEL=io.woowtech.pi-agent

svc_active() {
  if [ "$PA_PLATFORM" = macos ]; then launchctl list "$PLIST_LABEL" >/dev/null 2>&1
  else systemctl --user is-active pi-web 2>/dev/null | grep -q '^active'; fi
}
svc_enabled() {   # survives a reboot / re-login
  if [ "$PA_PLATFORM" = macos ]; then [ -f "$HOME/Library/LaunchAgents/$PLIST_LABEL.plist" ]
  else systemctl --user is-enabled pi-web 2>/dev/null | grep -q '^enabled'; fi
}
svc_restart() {
  if [ "$PA_PLATFORM" = macos ]; then
    launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
  else systemctl --user restart pi-web >/dev/null 2>&1; fi
}
# Wait on the port through curl rather than ss/lsof: portable, and it also
# proves pi-web is answering rather than merely bound.
wait_serving() {
  local i; for i in $(seq 1 "${1:-30}"); do
    [ "$(code /api/home)" = 200 ] && return 0; sleep 1
  done; return 1
}
# macOS has no coreutils `timeout`.
pa_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  "$@" & local p=$!
  ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; return $rc
}
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
code(){ curl -s -o /dev/null -m8 -w '%{http_code}' "$BASE$1"; }
jq_api(){ curl -s -m8 "$BASE$1" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(eval(process.argv[1])+"")}catch(e){process.stdout.write("ERR")}})' "$2"; }

echo "# Pi Agent native smoke test (Linux / WSL2 / macOS) — $(date '+%F %T')"
echo "PI_AGENT_HOME=$PI_AGENT_HOME"

echo "## 1. versions"
chk "pi 1.4.0"       '[ "$('"$PI_AGENT_HOME"'/bin/pi --version 2>/dev/null | tail -1)" = 1.4.0 ]'
chk "claude 2.1.296" "$PI_AGENT_HOME/clis/claude/node_modules/.bin/claude --version 2>/dev/null | grep -q 2.1.296"
chk "codex 0.162.1"  "$PI_AGENT_HOME/clis/codex/node_modules/.bin/codex --version 2>/dev/null | grep -q 0.162.1"

echo "## 2. service"
[ "$PA_PLATFORM" = linux ] && export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
chk "service active"            'svc_active'
chk "service enabled (on boot)" 'svc_enabled'

echo "## 3. http routes"
chk "/ = 200"          '[ "$(code /)" = 200 ]'
chk "/api/home = 200"  '[ "$(code /api/home)" = 200 ]'
chk "/omnigent = 200"  '[ "$(code /omnigent)" = 200 ]'

echo "## 4. plugin state (settings tabs enabled)"
chk "settings.json registers omnigent plugin" 'grep -q pi-omnigent-plugin "$PI_AGENT_DATA_DIR/settings.json"'
chk "settings.json registers paseo plugin"    'grep -q pi-paseo-plugin "$PI_AGENT_DATA_DIR/settings.json"'
chk "omnigent plugin active"       '[ "$(jq_api /api/omnigent "o.active")" = true ]'
chk "omnigent detects 3 engines"   '[ "$(jq_api /api/omnigent "o.engines.length")" = 3 ]'
chk "omnigent version 0.3.31"      '[ "$(jq_api /api/omnigent "o.version")" = 0.3.31 ]'

echo "## 5. skill sharing round-trip"
mkdir -p "$PI_AGENT_DATA_DIR/skills/qa-skill"
printf -- '---\nname: qa-skill\ndescription: smoke\n---\nx\n' > "$PI_AGENT_DATA_DIR/skills/qa-skill/SKILL.md"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1
chk "skill visible via ~/.claude/skills"  '[ -e "$HOME/.claude/skills/qa-skill/SKILL.md" ]'
chk "skill visible via ~/.pi/agent/skills" '[ -e "$HOME/.pi/agent/skills/qa-skill/SKILL.md" ]'
chk "skill visible via ~/.agents/skills"   '[ -e "$HOME/.agents/skills/qa-skill/SKILL.md" ]'

# The fixture URL is deliberately a port that refuses instantly: `claude mcp
# list` health-checks every server before printing it, so a reachable-but-slow
# host (example.com) makes this assertion flaky for a reason that has nothing
# to do with sharing.
echo "## 6. MCP sharing round-trip (add two, then prune one)"
printf '%s' '{"mcpServers":{"qa_http":{"url":"http://127.0.0.1:1/mcp"},"qa_cmd":{"command":"echo","args":["hi"]}}}' > "$PI_AGENT_DATA_DIR/mcp.json"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1
chk "claude.json has qa_http"  'node -e "process.exit(require(process.env.HOME+\"/.claude.json\").mcpServers.qa_http?0:1)"'
chk "claude.json has qa_cmd"   'node -e "process.exit(require(process.env.HOME+\"/.claude.json\").mcpServers.qa_cmd?0:1)"'
chk "codex config has qa_http" 'grep -q "qa_http" "$HOME/.codex/config.toml"'
chk "codex config has qa_cmd"  'grep -q "qa_cmd" "$HOME/.codex/config.toml"'
# `claude mcp get <name>` and not `mcp list`: list health-checks every server the
# account carries (a dozen claude.ai ones here) and took >40s before reaching
# ours, which made this assertion time out for a reason unrelated to sharing.
# get resolves one server in ~1.5s and still proves claude read the shared file
# (it reports "Scope: User config").
chk "claude resolves the shared qa_http" "pa_timeout 25 $PI_AGENT_HOME/bin/claude mcp get qa_http 2>/dev/null | grep -q 'User config'"
# prune: remove qa_cmd
printf '%s' '{"mcpServers":{"qa_http":{"url":"http://127.0.0.1:1/mcp"}}}' > "$PI_AGENT_DATA_DIR/mcp.json"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1
chk "qa_cmd pruned from claude.json" 'node -e "process.exit(require(process.env.HOME+\"/.claude.json\").mcpServers.qa_cmd?1:0)"'
chk "qa_cmd pruned from codex config" 'test "$(grep -c qa_cmd "$HOME/.codex/config.toml")" = 0'

echo "## 7. service restart survival"
svc_restart
wait_serving 30 || true
chk "serves after restart" '[ "$(code /api/home)" = 200 ]'

echo "## cleanup test artifacts"
rm -rf "$PI_AGENT_DATA_DIR/skills/qa-skill"
printf '%s' '{"mcpServers":{}}' > "$PI_AGENT_DATA_DIR/mcp.json"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1

echo
echo "# RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
