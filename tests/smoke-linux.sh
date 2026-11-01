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
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
code(){ curl -s -o /dev/null -m8 -w '%{http_code}' "$BASE$1"; }
jq_api(){ curl -s -m8 "$BASE$1" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(eval(process.argv[1])+"")}catch(e){process.stdout.write("ERR")}})' "$2"; }

echo "# Pi Agent native smoke test — $(date '+%F %T')"
echo "PI_AGENT_HOME=$PI_AGENT_HOME"

echo "## 1. versions"
chk "pi 1.4.0"       '[ "$('"$PI_AGENT_HOME"'/bin/pi --version 2>/dev/null | tail -1)" = 1.4.0 ]'
chk "claude 2.1.296" "$PI_AGENT_HOME/clis/claude/node_modules/.bin/claude --version 2>/dev/null | grep -q 2.1.296"
chk "codex 0.162.1"  "$PI_AGENT_HOME/clis/codex/node_modules/.bin/codex --version 2>/dev/null | grep -q 0.162.1"

echo "## 2. service"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
chk "service active"            'systemctl --user is-active pi-web | grep -q "^active"'
chk "service enabled (on boot)" 'systemctl --user is-enabled pi-web | grep -q "^enabled"'

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

echo "## 6. MCP sharing round-trip (add two, then prune one)"
printf '%s' '{"mcpServers":{"qa_http":{"url":"https://example.com/mcp"},"qa_cmd":{"command":"echo","args":["hi"]}}}' > "$PI_AGENT_DATA_DIR/mcp.json"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1
chk "claude.json has qa_http"  'node -e "process.exit(require(process.env.HOME+\"/.claude.json\").mcpServers.qa_http?0:1)"'
chk "claude.json has qa_cmd"   'node -e "process.exit(require(process.env.HOME+\"/.claude.json\").mcpServers.qa_cmd?0:1)"'
chk "codex config has qa_http" 'grep -q "qa_http" "$HOME/.codex/config.toml"'
chk "codex config has qa_cmd"  'grep -q "qa_cmd" "$HOME/.codex/config.toml"'
chk "claude mcp list shows qa_http" "timeout 25 $PI_AGENT_HOME/bin/claude mcp list 2>/dev/null | grep -q qa_http"
# prune: remove qa_cmd
printf '%s' '{"mcpServers":{"qa_http":{"url":"https://example.com/mcp"}}}' > "$PI_AGENT_DATA_DIR/mcp.json"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1
chk "qa_cmd pruned from claude.json" 'node -e "process.exit(require(process.env.HOME+\"/.claude.json\").mcpServers.qa_cmd?1:0)"'
chk "qa_cmd pruned from codex config" 'test "$(grep -c qa_cmd "$HOME/.codex/config.toml")" = 0'

echo "## 7. service restart survival"
systemctl --user restart pi-web >/dev/null 2>&1
for i in $(seq 1 20); do ss -tlnp 2>/dev/null | grep -q ":$PORT " && break; sleep 1; done
chk "serves after restart" '[ "$(code /api/home)" = 200 ]'

echo "## cleanup test artifacts"
rm -rf "$PI_AGENT_DATA_DIR/skills/qa-skill"
printf '%s' '{"mcpServers":{}}' > "$PI_AGENT_DATA_DIR/mcp.json"
node "$PI_AGENT_HOME/bin/pi-agent-share-state.mjs" >/dev/null 2>&1

echo
echo "# RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
