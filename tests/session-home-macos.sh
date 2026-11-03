#!/bin/bash
# Sandbox tests for `pi-agent-session-home` on macOS: session home, and the cutover that
# hands an existing launchd-managed Omnigent host over to this install.
#
# Everything runs against a throw-away tree under $PA_SHTEST_TMP (default /private/tmp):
#   * a fake "real home" and a fake PI_AGENT_HOME;
#   * REAL launchd jobs, in the user's GUI domain, with unique io.woowtech.pa-shtest.<pid>.*
#     labels -- the fake old host, its watcher, this install's fake pi-web service and the
#     detached workers the code under test schedules;
#   * a stub of the Omnigent server API on 127.0.0.1 (tests/session-home-macos/fake.py),
#     which also reproduces the server's host-rotation behaviour (same name, new host id).
# It never touches the real ~/.omnigent, ai.omnigent.*, io.woowtech.pi-agent or a real server.
# The code under test is told about all of this through PI_SH_* variables (see the script).
#
#   tests/session-home-macos.sh            run everything (about five minutes)
#   KEEP=1 tests/session-home-macos.sh     keep the sandbox for a post-mortem
#   PI_SH_TEST_PYTHON=...                  a python with PyYAML (default: the omnigent tool's)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FAKE_SRC="$HERE/session-home-macos/fake.py"

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
t()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
tn() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d"; else ok "$d"; fi; }   # must fail
note() { printf '  ... %s\n' "$*"; }
head1() { printf '\n== %s\n' "$*"; }
# Assertions on captured output read the globals lazily, so output with quotes in it is harmless.
has()      { printf '%s\n' "$out" | grep -q -- "$1"; }
has_all()  { local p; for p in "$@"; do has "$p" || return 1; done; }
hasr()     { printf '%s\n' "$RES" | grep -q -- "$1"; }
rc0_has()  { [ "$rc" = 0 ] && has "$1"; }
rcn0_has() { [ "$rc" != 0 ] && has "$1"; }

[ "$(uname -s)" = Darwin ] || { echo "SKIP: macOS only (launchd)"; exit 0; }

find_python() {
  local c
  for c in "${PI_SH_TEST_PYTHON:-}" "${PI_AGENT_HOME:-$HOME/.local/share/pi-agent}/data/omnigent-plugin/uv/tools/omnigent/bin/python" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -n "$c" ] && [ -x "$c" ] && "$c" -I -B -c 'import yaml' 2>/dev/null; then echo "$c"; return 0; fi
  done
  return 1
}
PY="$(find_python)" || { echo "SKIP: needs a python with PyYAML (set PI_SH_TEST_PYTHON)"; exit 0; }
UIDN="$(id -u)"

# `ps eww` must show this python's environment (it does for uv/brew pythons, not for Apple's).
( PI_SHTEST_PROBE="visible-$$" exec "$PY" -I -B -c 'import time; time.sleep(6)' ) & probe=$!
sleep 1
if ! ps eww -p "$probe" -o command= 2>/dev/null | grep -q "PI_SHTEST_PROBE=visible-$$"; then
  kill "$probe" 2>/dev/null; echo "SKIP: ps cannot show the environment of $PY (an Apple system python?)"; exit 0
fi
kill "$probe" 2>/dev/null; wait "$probe" 2>/dev/null

ROOT="${PA_SHTEST_TMP:-/private/tmp}"
SB="$(mktemp -d "$ROOT/pa-shtest.XXXXXX")" || exit 2
SB="$(cd "$SB" && pwd -P)"
TAG="pa-shtest.$$"
L_OLD="io.woowtech.$TAG.oldhost"; L_WATCH="io.woowtech.$TAG.watch"; L_SVC="io.woowtech.$TAG.svc"; WPFX="io.woowtech.$TAG.worker"
L_DEP="io.woowtech.$TAG.health"      # an owner's own job that rests on the old host (a health check)
REAL="$SB/real"; PA="$SB/pa"; LA="$REAL/Library/LaunchAgents"; ST="$SB/state"
OLD_ID=aaaaaaaa11111111aaaaaaaa11111111; NEW_ID=bbbbbbbb22222222bbbbbbbb22222222; OTH_ID=cccccccc33333333cccccccc33333333
OLD_NAME="TestMac.local"; NEW_NAME="TestMac.local (pi-agent)"
STUB_PID=""; API=""; WEBPORT=""

cleanup() {
  local l
  for l in $(launchctl list 2>/dev/null | awk '{print $3}' | grep -F "$TAG"); do launchctl bootout "gui/$UIDN/$l" >/dev/null 2>&1; done
  for l in "$L_OLD" "$L_WATCH" "$L_SVC"; do launchctl enable "gui/$UIDN/$l" >/dev/null 2>&1; done
  [ -z "$API" ] || pkill -f -- "--server $API" 2>/dev/null
  pkill -f -- "$SB/" 2>/dev/null
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null
  if [ "${KEEP:-0}" = 1 ]; then echo "sandbox kept: $SB"; else rm -rf "$SB"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --------------------------------------------------------------------- helpers ---
waitfor() { local n="$1" i; shift; for i in $(seq 1 "$n"); do if eval "$*" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }
free_port() { "$PY" -I -B -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
stj() { curl -s -m 5 "$API/_test/state" | "$PY" -I -B -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
hstatus() { stj "d['hosts'].get('$1',{}).get('status')"; }
hname() { stj "d['hosts'].get('$1',{}).get('name')"; }
hcreated() { stj "d['hosts'].get('$1',{}).get('created_at')"; }
post() { curl -s -m 5 -X POST -H 'Content-Type: application/json' -d "$2" "$API$1" >/dev/null; }
bound_to() { stj "len([s for s in d['sessions'] if s['host_id']=='$1'])"; }
lc_loaded() { launchctl print "gui/$UIDN/$1" >/dev/null 2>&1; }
lc_pid() { launchctl print "gui/$UIDN/$1" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1; }
lc_disabled() { launchctl print-disabled "gui/$UIDN" 2>/dev/null | grep -F "\"$1\"" | grep -q 'disabled'; }
result_line() { grep 'RESULT:' "$PA/session-home.result" 2>/dev/null | tail -1; }
wait_result() { waitfor "$1" '[ -n "$(result_line)" ]'; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
yget() { "$PY" -I -B -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2"; }
jget() { "$PY" -I -B -c 'import sys,json; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2"; }
hostinfo() {   # hostinfo HOSTID FIELD -> FIELD of the newest live fake host with that id
  "$PY" -I -B - "$ST" "$1" "$2" <<'EOF'
import glob, json, os, sys
d, hid, field = sys.argv[1:4]
best = None
for p in glob.glob(os.path.join(d, "host-*.json")):
    try:
        j = json.load(open(p))
        if j.get("host_id") != hid:
            continue
        os.kill(j["pid"], 0)
    except Exception:
        continue
    if best is None or os.path.getmtime(p) > best[0]:
        best = (os.path.getmtime(p), j)
if best:
    print(best[1].get(field) or "")
EOF
}
# A deterministic listing of a tree: path, type, mode, content hash / link target.
snap() {
  ( cd "$1" 2>/dev/null && find . -print | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf '%s|L|%s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then printf '%s|D|%s\n' "$p" "$(stat -f %Lp "$p")"
      else printf '%s|F|%s|%s\n' "$p" "$(stat -f %Lp "$p")" "$(shasum -a 256 "$p" | cut -c1-16)"; fi
    done )
}
snap_old() { snap "$1" | grep -v -E '^\./(daemons|logs|locks)(/|\|)'; }       # a host's own bookkeeping moves
snap_all() { snap "$REAL"; echo ---; snap "$PA"; }

stub_up() {
  rm -f "$SB/api.port"
  "$PY" -I -B "$SB/fake.py" api "$SB/seed.json" "$SB/api.port" >"$SB/api.log" 2>&1 &
  STUB_PID=$!
  waitfor 10 '[ -s "$SB/api.port" ]' || { echo "stub did not start"; exit 2; }
  API="http://127.0.0.1:$(cat "$SB/api.port")"
}

# ---------------------------------------------------------------------- sandbox ---
mkdir -p "$REAL/Library/LaunchAgents" "$REAL/.omnigent/"{bin,health,logs/host,daemons,locks,codex-native/rollout-a,pi-native/s1,attachments} \
         "$REAL/.claude/skills/demo" "$REAL/.local/bin" "$REAL/.codex" "$SB/tools/bin" "$SB/fakepkg/omnigent/host" "$ST" \
         "$PA/bin" "$PA/logs" "$PA/data/omnigent-plugin" "$PA/home/.omnigent" "$PA/home/.local/bin"
# the fakes, under the names the real programs have, run by the test python
fakeify() { { echo "#!$PY"; sed 1d "$FAKE_SRC"; } > "$1"; chmod 755 "$1"; }
cp "$FAKE_SRC" "$SB/fake.py"
fakeify "$PA/bin/omnigent"
fakeify "$PA/bin/pi-omnigent"            # the plugin CLI wrapper; its `repair` is emulated
fakeify "$PA/home/.local/bin/pi-web"
# the cutover looks for these two marks of an install that is new enough for session home
mkdir -p "$PA/plugins/pi-omnigent-plugin/src"
echo '# session-home (Woow native installer): the mark the cutover preflight looks for' > "$PA/plugins/pi-omnigent-plugin/src/omnigent.py"
: > "$SB/fakepkg/omnigent/__init__.py"; : > "$SB/fakepkg/omnigent/host/__init__.py"
cat > "$SB/fakepkg/omnigent/host/service_entry.py" <<'EOF'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("fakehost", os.environ["FAKE_PY"])
spec = importlib.util.spec_from_loader("fakehost", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.run_host(sys.argv[1:])
EOF
# the real scripts under test, laid out as an install lays them out
for f in pi-agent-session-home pi-agent-session-home-macos pi-web-start.sh pi-agent-env.sh; do
  install -m 755 "$REPO/rootfs/bin/$f" "$PA/bin/$f"
done

"$PY" -I -B - "$SB/seed.json" "$OLD_ID" "$NEW_ID" "$OTH_ID" "$OLD_NAME" "$NEW_NAME" <<'EOF'
import json, sys
out, OLD, NEW, OTH, ON, NN = sys.argv[1:7]
hosts = [{"host_id": OLD, "name": ON, "owner": "woow", "status": "offline", "created_at": 1788643254, "last_seen": 1},
         {"host_id": NEW, "name": NN, "owner": "woow", "status": "offline", "created_at": 1793662352, "last_seen": 1},
         {"host_id": OTH, "name": "Some other machine", "owner": "woow", "status": "online", "created_at": 1788668198, "last_seen": 1}]
mine = {1, 2, 4, 5, 7, 8, 10, 11, 13, 14, 16, 17, 19, 20}
new = {3, 9, 15}
sessions = []
for i in range(1, 22):
    sessions.append({"id": "%032x" % (0xabc000 + i), "status": "idle",
                     "host_id": OLD if i in mine else NEW if i in new else OTH,
                     "title": "conversation %d" % i, "created_at": 1793000000 - i})
json.dump({"hosts": hosts, "sessions": sessions, "max_page": 5, "token": "test-token", "user": "woow"}, open(out, "w"))
EOF
stub_up
WEBPORT="$(free_port)"
# the fake pi-omnigent runs under `env -i`, so it cannot be told where things are by variables
printf '{"state": "%s", "svc_label": "%s"}\n' "$ST" "$L_SVC" > "$PA/.fake.json"

write_old_install() {
  cat > "$REAL/.omnigent/config.yaml" <<EOF
host:
  host_id: $OLD_ID
  name: $OLD_NAME
providers:
  claude:
    cli: claude
    default: true
    kind: subscription
  pi-original:
    cli: pi
    kind: subscription
  pi-subscription:
    cli: pi
    default: pi
    kind: subscription
runner:
  idle_timeout_s: 43200
server: $API
telemetry:
  enabled: true
EOF
  printf '{"%s": {"token": "test-token"}}\n' "$API" > "$REAL/.omnigent/auth_tokens.json"
  cat > "$REAL/.omnigent/bin/host-service.sh" <<'EOF'
#!/bin/bash
# stand-in for ~/.omnigent/bin/host-service.sh: clear stale registry records, then become the daemon
for f in "$HOME/.omnigent/daemons"/*.json; do
  [ -f "$f" ] || continue
  pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$f")
  kill -0 "$pid" 2>/dev/null || rm -f "$f"
done
exec "$PYBIN" -m omnigent.host.service_entry --server "$FAKE_SERVER"
EOF
  chmod 755 "$REAL/.omnigent/bin/host-service.sh"
  echo '{"thread":"a"}' > "$REAL/.omnigent/codex-native/rollout-a/state.json"
  echo 'line one' > "$REAL/.omnigent/codex-native/rollout-a/rollout.jsonl"
  echo 'pi session' > "$REAL/.omnigent/pi-native/s1/session.jsonl"
  echo 'blob' > "$REAL/.omnigent/attachments/a.bin"
  : > "$REAL/.omnigent/logs/host/service.log"
  echo '{"ok": true}' > "$REAL/.omnigent/health/state.json"
  echo '{"mcpServers": {}}' > "$REAL/.claude.json"
  echo 'model = "x"' > "$REAL/.codex/config.toml"
  echo '# demo skill' > "$REAL/.claude/skills/demo/SKILL.md"
}
write_new_install() {
  cat > "$PA/home/.omnigent/config.yaml" <<EOF
host:
  host_id: $NEW_ID
  name: $NEW_NAME
providers:
  claude-subscription:
    cli: claude
    default: anthropic
    kind: subscription
  codex-subscription:
    cli: codex
    default: openai
    kind: subscription
  pi-subscription:
    cli: pi
    default: pi
    kind: subscription
server: $API
telemetry:
  enabled: false
EOF
  printf '{"%s": {"token": "test-token"}}\n' "$API" > "$PA/home/.omnigent/auth_tokens.json"
  chmod 600 "$PA/home/.omnigent/auth_tokens.json" "$PA/home/.omnigent/config.yaml"
  cat > "$PA/data/omnigent-plugin/connection.json" <<EOF
{
  "server": "$API",
  "workspace": "$PA/home",
  "host": {"id": "$NEW_ID", "name": "$NEW_NAME", "manager": "plugin", "managerRunning": false, "managed": false, "state": "unknown", "connected": true},
  "engines": {"claude": {"agentId": "58a1bc5b", "models": [{"id": "sonnet", "isDefault": true}]}},
  "installation": {"schema": 2, "id": "0123456789abcdef0123456789abcdef", "package": "pi-omnigent-plugin"}
}
EOF
  printf '{"phase": "needs-verification", "enabled": true, "server": "%s", "loginConfirmed": true, "installationId": "0123456789abcdef0123456789abcdef"}\n' "$API" > "$PA/data/omnigent-plugin/state.json"
  chmod 600 "$PA/data/omnigent-plugin/connection.json" "$PA/data/omnigent-plugin/state.json"
}
write_plists() {
  cat > "$LA/$L_OLD.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$L_OLD</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$REAL/.omnigent/bin/host-service.sh</string></array>
<key>EnvironmentVariables</key><dict>
<key>HOME</key><string>$REAL</string>
<key>PATH</key><string>$SB/tools/bin:$SB/nonexistent/bin:/usr/bin:/bin</string>
<key>PYTHONPATH</key><string>$SB/fakepkg</string>
<key>FAKE_STATE</key><string>$ST</string>
<key>FAKE_PY</key><string>$PA/bin/omnigent</string>
<key>FAKE_SERVER</key><string>$API</string>
<key>PYBIN</key><string>$PY</string>
</dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>StandardOutPath</key><string>$REAL/.omnigent/logs/host/service.log</string>
<key>StandardErrorPath</key><string>$REAL/.omnigent/logs/host/service.log</string>
</dict></plist>
EOF
  cat > "$LA/$L_WATCH.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$L_WATCH</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string><string>exit 0</string></array>
<key>RunAtLoad</key><true/></dict></plist>
EOF
  cat > "$LA/$L_SVC.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$L_SVC</string>
<key>ProgramArguments</key><array><string>$PA/bin/pi-web-start.sh</string></array>
<key>EnvironmentVariables</key><dict>
<key>PI_AGENT_HOME</key><string>$PA</string>
<key>PI_WEB_PORT</key><string>$WEBPORT</string>
<key>FAKE_STATE</key><string>$ST</string>
</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$PA/logs/pi-web.log</string>
<key>StandardErrorPath</key><string>$PA/logs/pi-web.log</string>
</dict></plist>
EOF
  chmod 600 "$LA/$L_OLD.plist"
  # an owner's own job that rests on the old host, as the health check on the real MacBook does:
  # it asks launchd whether the old job runs, and logs under ~/.omnigent. Never loaded here.
  cat > "$REAL/.local/bin/fake-health" <<EOS
#!/bin/bash
launchctl print "gui/\$(id -u)/$L_OLD" 2>/dev/null | grep -q 'state = running'
EOS
  chmod 755 "$REAL/.local/bin/fake-health"
  cat > "$LA/$L_DEP.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$L_DEP</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$REAL/.local/bin/fake-health</string></array>
<key>StartInterval</key><integer>3600</integer>
<key>StandardOutPath</key><string>$REAL/.omnigent/health/fake-health.log</string>
<key>StandardErrorPath</key><string>$REAL/.omnigent/health/fake-health.log</string>
</dict></plist>
EOF
}

# What the code under test is told. In production none of these is set.
export PI_AGENT_HOME="$PA"
export PI_SH_REAL_HOME="$REAL" PI_SH_PYTHON="$PY" PI_SH_OMNIGENT="$PA/bin/omnigent"
export PI_SH_SERVICE_LABEL="$L_SVC" PI_SH_OLD_HOST_LABEL="$L_OLD" PI_SH_OLD_AUX_LABELS="$L_WATCH" PI_SH_WORKER_PREFIX="$WPFX"
export PI_SH_HOST_FILTER="--server $API"
export PI_SH_POLL=1 PI_SH_HEALTH_TRIES=40 PI_SH_OFFLINE_TRIES=15 PI_SH_ONLINE_TRIES=20 PI_SH_EXIT_TRIES=20 PI_SH_MIN_FREE_MB=50
SH="$PA/bin/pi-agent-session-home"          # the Linux entry point, which hands over on Darwin
MAC="$PA/bin/pi-agent-session-home-macos"

# ----------------------------------------------------------------------------------
head1 "0. the config merge (no launchd, no server)"
write_old_install; write_new_install
M="$SB/merged.yaml"
out="$("$MAC" _pyh cfg-merge "$REAL/.omnigent/config.yaml" "$PA/home/.omnigent/config.yaml" "$M" 2>&1)"; rc=$?
t "merge succeeds" test "$rc" = 0
t "adopts the old host_id" test "$(yget "$M" host.host_id)" = "$OLD_ID"
t "adopts the old host name" test "$(yget "$M" host.name)" = "$OLD_NAME"
t "adds the old provider the new config lacks" test "$(yget "$M" providers.claude.kind)" = subscription
t "adds the old pi-original too" test "$(yget "$M" providers.pi-original.cli)" = pi
t "the added provider loses its default marker (no second default for the family)" test -z "$(yget "$M" providers.claude.default)"
t "the new config's own default survives" test "$(yget "$M" providers.claude-subscription.default)" = anthropic
t "adds the runner block the new config lacks" test "$(yget "$M" runner.idle_timeout_s)" = 43200
t "never overwrites: telemetry.enabled stays as the new config has it (False)" test "$(yget "$M" telemetry.enabled)" = False
t "the server line is untouched" test "$(yget "$M" server)" = "$API"
t "the report lists what was kept" has "telemetry"
h0="$(sha "$PA/home/.omnigent/config.yaml")"
"$MAC" _pyh cfg-merge "$REAL/.omnigent/config.yaml" "$PA/home/.omnigent/config.yaml" - >/dev/null 2>&1
t "report-only mode (-) writes nothing" test "$(sha "$PA/home/.omnigent/config.yaml")" = "$h0"
# a different server is not a hand-over
sed "s|^server: .*|server: https://elsewhere.example|" "$REAL/.omnigent/config.yaml" > "$SB/other-server.yaml"
tn "refuses two configs that name different servers" "$MAC" _pyh cfg-merge "$SB/other-server.yaml" "$PA/home/.omnigent/config.yaml" -
# the real loader accepts the merged file
if "$PY" -I -B -c 'import omnigent.onboarding.provider_config' 2>/dev/null; then
  t "omnigent's own load_providers parses the merged config" "$PY" -I -B -c "
import yaml
from omnigent.onboarding.provider_config import load_providers
p = load_providers(yaml.safe_load(open('$M')))
assert {'claude','claude-subscription','codex-subscription','pi-subscription','pi-original'} <= set(p), sorted(p)"
else note "omnigent not importable here: skipped the real-loader check"; fi
# the PATH rule shared by pi-web-start.sh and the repair environment
mkdir -p "$SB/ep/a" "$SB/ep/b"
t "extend_path appends the extra directories that exist, once, in order, and skips the others" test "$("$MAC" _extend_path /usr/bin:/bin "$SB/ep/a:$SB/nope:/usr/bin:$SB/ep/b:$SB/ep/a")" = "/usr/bin:/bin:$SB/ep/a:$SB/ep/b"

# ----------------------------------------------------------------------------------
head1 "1. baseline: a fake old launchd host, and this install's fake service, both connected"
write_old_install; write_new_install; write_plists
launchctl bootstrap "gui/$UIDN" "$LA/$L_OLD.plist"
launchctl bootstrap "gui/$UIDN" "$LA/$L_WATCH.plist"
launchctl bootstrap "gui/$UIDN" "$LA/$L_SVC.plist"
t "the old host connects to the (stub) server" waitfor 25 '[ "$(hstatus $OLD_ID)" = online ]'
t "this install's host connects too" waitfor 40 '[ "$(hstatus $NEW_ID)" = online ]'
t "pi-web (fake) answers" waitfor 20 'curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:$WEBPORT/api/home | grep -q 200'
t "pi-web reports its host connected" eval "curl -s http://127.0.0.1:$WEBPORT/api/omnigent | grep -q '\"connected\": true'"
t "this install's host runs with the scoped HOME" test "$(hostinfo $NEW_ID home)" = "$PA/home"
t "the old host runs with the real HOME" test "$(hostinfo $OLD_ID home)" = "$REAL"
t "the 14/3/4 conversations are bound as seeded" test "$(bound_to $OLD_ID)/$(bound_to $NEW_ID)/$(bound_to $OTH_ID)" = "14/3/4"
OLD_CREATED="$(hcreated $OLD_ID)"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"
t "launchd knows the old host's pid" test -n "$OLD_PID_BEFORE"
# originals, for the byte-for-byte comparisons later
SHA_PLIST_OLD="$(sha "$LA/$L_OLD.plist")"; SHA_PLIST_WATCH="$(sha "$LA/$L_WATCH.plist")"; SHA_PLIST_SVC="$(sha "$LA/$L_SVC.plist")"; SHA_PLIST_DEP="$(sha "$LA/$L_DEP.plist")"
SHA_CFG_NEW="$(sha "$PA/home/.omnigent/config.yaml")"; SHA_RECEIPT="$(sha "$PA/data/omnigent-plugin/connection.json")"
SHA_PSTATE="$(sha "$PA/data/omnigent-plugin/state.json")"
SNAP_OLD="$SB/snap-old.before"; snap_old "$REAL/.omnigent" > "$SNAP_OLD"

if [ "${STOP_AFTER:-}" = baseline ]; then   # for debugging by hand: leave the baseline running
  { for v in SB PA REAL API WEBPORT OLD_ID NEW_ID OTH_ID OLD_NAME NEW_NAME L_OLD L_WATCH L_SVC WPFX PY PI_AGENT_HOME PI_SH_REAL_HOME PI_SH_PYTHON PI_SH_OMNIGENT PI_SH_SERVICE_LABEL PI_SH_OLD_HOST_LABEL PI_SH_OLD_AUX_LABELS PI_SH_WORKER_PREFIX PI_SH_HOST_FILTER PI_SH_POLL PI_SH_HEALTH_TRIES PI_SH_OFFLINE_TRIES PI_SH_ONLINE_TRIES PI_SH_EXIT_TRIES PI_SH_MIN_FREE_MB; do eval "printf 'export %s=%q\n' $v \"\$$v\""; done; } > "$SB/env.sh"
  cat > "$SB/cleanup.sh" <<EOF
#!/bin/bash
kill $STUB_PID 2>/dev/null
for l in \$(launchctl list | awk '{print \$3}' | grep -F $TAG); do launchctl bootout gui/$UIDN/\$l; done
pkill -f -- "--server $API"
pkill -f -- "$SB/"
rm -rf "$SB"
EOF
  chmod 755 "$SB/cleanup.sh"
  trap - EXIT INT TERM HUP
  echo "baseline is up; source $SB/env.sh to work in it; $SB/cleanup.sh removes it"
  exit 0
fi

# ----------------------------------------------------------------------------------
head1 "2. refusals and the dry run change nothing"
before="$(snap_all)"
out="$("$SH" enable 2>&1)"; rc=$?
t "enable refuses while the old launchd host serves ~/.omnigent" test "$rc" -ne 0
t "...and points at the cutover" has "cutover --dry-run"
tn "...without having linked ~/.omnigent" test -L "$REAL/.omnigent"
t "...and nothing in the tree changed" test "$before" = "$(snap_all)"

out="$("$SH" status 2>&1)"
t "status names the old job and its pid" has "old job:.*$L_OLD.*loaded=yes.*pid="
t "status classifies the two hosts" has_all "host pid .*old" "host pid .*ours"

before="$(snap_all)"
out="$("$SH" cutover 2>&1)"; rc=$?
t "cutover with no flag is a dry run that succeeds" test "$rc" = 0
t "...prints the plan" has "PLAN"
t "...counts the 14 conversations bound to the old host" has "bound to the old host: 14"
t "...names what the merge would add" has "providers.claude"
t "...changed nothing at all in the fake real home or the install (whole-tree checksum)" test "$before" = "$(snap_all)"
t "...and the old host still runs, same pid" test "$(lc_pid "$L_OLD")" = "$OLD_PID_BEFORE"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "--dry-run is the same" test "$rc" = 0
t "...and still changed nothing" test "$before" = "$(snap_all)"
tn "...and no dry run ever ran the plugin CLI (a dry run runs nothing but reads)" eval "ls $ST/pi-omnigent-*.json"

SESS_BUSY="$(printf '%032x' $((0xabc000 + 4)))"
post /_test/session "{\"id\":\"$SESS_BUSY\",\"status\":\"running\"}"
before="$(snap_all)"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "a running conversation blocks the cutover" test "$rc" -ne 0
t "...and names it" has "BLOCKED.*$SESS_BUSY"
t "...without changing anything" test "$before" = "$(snap_all)"
out="$("$SH" cutover --dry-run --allow-running "$SESS_BUSY" 2>&1)"; rc=$?
t "--allow-running lets that one through, with a note" rc0_has "will be cut off (allowed)"
out="$("$SH" cutover --dry-run --force 2>&1)"; rc=$?
t "--force lets it through, with a note" rc0_has "will be cut off (--force)"
post /_test/session "{\"id\":\"$SESS_BUSY\",\"status\":\"idle\"}"

# a host of someone else's: not the old launchd job, not ours
mkdir -p "$SB/elsewhere/.omnigent"
sed "s/host_id: .*/host_id: $OTH_ID/; s/  name: .*/  name: Some other machine/" "$PA/home/.omnigent/config.yaml" > "$SB/elsewhere/.omnigent/config.yaml"
( HOME="$SB/elsewhere" OMNIGENT_CONFIG_HOME="$SB/elsewhere/.omnigent" OMNIGENT_DATA_DIR="$SB/elsewhere/.omnigent" FAKE_STATE="$ST" \
  exec "$PA/bin/omnigent" host --server "$API" ) >/dev/null 2>&1 &
FOREIGN=$!
waitfor 10 'ps -p $FOREIGN >/dev/null 2>&1 && [ -n "$(ps eww -p $FOREIGN -o command= | grep -o OMNIGENT_CONFIG_HOME=[^ ]*)" ]'
before="$(snap_all)"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "a host that is neither the old job nor ours blocks the cutover" test "$rc" -ne 0
t "...and says where it lives" has "cannot place.*serves-$SB/elsewhere"
out="$("$SH" enable 2>&1)"; rc=$?
t "enable refuses that one too" test "$rc" -ne 0
t "...changing nothing" test "$before" = "$(snap_all)"
kill "$FOREIGN" 2>/dev/null; wait "$FOREIGN" 2>/dev/null
waitfor 10 '! ps -p $FOREIGN >/dev/null 2>&1'

post /_test/offline "{\"host_id\":\"$OLD_ID\"}"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "an old host the server shows offline blocks the cutover" rcn0_has "not online"
post /_test/connect "{\"host_id\":\"$OLD_ID\",\"name\":\"$OLD_NAME\"}"

# the preconditions that come from the install, not from the machine
cp "$PA/data/omnigent-plugin/state.json" "$SB/state.json.keep"
sed 's/"loginConfirmed": true/"loginConfirmed": false/' "$SB/state.json.keep" > "$PA/data/omnigent-plugin/state.json"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "a plugin login that is not confirmed blocks the cutover (its repair would ask for a password)" rcn0_has "login is not confirmed"
cp -p "$SB/state.json.keep" "$PA/data/omnigent-plugin/state.json"
cp "$PA/bin/pi-web-start.sh" "$SB/pwstart.keep"; grep -v "session-home.state" "$SB/pwstart.keep" > "$PA/bin/pi-web-start.sh"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "an install whose pi-web-start.sh predates macOS session home blocks it, and says to update" rcn0_has "predates macOS session home"
cp -p "$SB/pwstart.keep" "$PA/bin/pi-web-start.sh"
mv "$PA/plugins/pi-omnigent-plugin/src/omnigent.py" "$SB/omnigent.py.keep"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "a plugin that is not patched to hand the real HOME to its host blocks it" rcn0_has "not patched"
mv "$SB/omnigent.py.keep" "$PA/plugins/pi-omnigent-plugin/src/omnigent.py"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "all three put back: ready again" test "$rc" = 0
t "...and the owner's own job that rests on the old host (a health check) is named as a note, not a blocker" has "note:.*launchd job $L_DEP"
tn "(precondition) this install's directory has no health/ yet" test -d "$PA/home/.omnigent/health"

# ----------------------------------------------------------------------------------
head1 "3. the cutover"
rm -f "$PA/session-home.result"
out="$(PI_SH_DECOY=leak-check "$SH" cutover --apply --in 0 2>&1)"; rc=$?
t "cutover --apply schedules a detached job" rc0_has "scheduled cutover as $WPFX"
t "the job finishes (up to 3 minutes)" wait_result 180
RES="$(result_line)"; note "$RES"
t "RESULT: OK" hasr "RESULT: OK"

t "old host plist moved out of LaunchAgents" test ! -e "$LA/$L_OLD.plist"
t "...into .pre-pi-agent/, byte for byte" test "$(sha "$LA/.pre-pi-agent/$L_OLD.plist")" = "$SHA_PLIST_OLD"
t "watcher plist moved too, byte for byte" test "$(sha "$LA/.pre-pi-agent/$L_WATCH.plist")" = "$SHA_PLIST_WATCH"
tn "old host job is no longer loaded" lc_loaded "$L_OLD"
t "old host job is disabled in launchd" lc_disabled "$L_OLD"
t "watcher is disabled in launchd" lc_disabled "$L_WATCH"
tn "the old host process is gone" kill -0 "$OLD_PID_BEFORE"
t "~/.omnigent is a link to this install's directory" test "$(readlink "$REAL/.omnigent")" = "$PA/home/.omnigent"
PARKED="$(sed -n 's/^PARKED=//p' "$PA/session-home.state")"
t "the old directory is parked, not deleted" test -d "$PARKED"
t "...and is whole (everything but its own bookkeeping unchanged)" test "$(snap_old "$PARKED")" = "$(cat "$SNAP_OLD")"
t "codex-native is hard-linked into this install" test "$(stat -f %i "$PARKED/codex-native/rollout-a/rollout.jsonl")" = "$(stat -f %i "$PA/home/.omnigent/codex-native/rollout-a/rollout.jsonl")"
t "pi-native and attachments carried over" eval "test -f '$PA/home/.omnigent/pi-native/s1/session.jsonl' && test -f '$PA/home/.omnigent/attachments/a.bin'"
t "the owner's own job that logs under the old directory can still start: its log directory exists" test -d "$PA/home/.omnigent/health"
t "...and that job's plist was left alone, byte for byte" test "$(sha "$LA/$L_DEP.plist")" = "$SHA_PLIST_DEP"

C="$PA/home/.omnigent/config.yaml"
t "config: host_id adopted" test "$(yget "$C" host.host_id)" = "$OLD_ID"
t "config: name adopted" test "$(yget "$C" host.name)" = "$OLD_NAME"
t "config: this install's own providers kept, defaults intact" test "$(yget "$C" providers.codex-subscription.default)" = openai
t "config: the old provider 'claude' is there, without a second default" eval "test \"\$(cat <<<\"$(yget "$C" providers.claude.cli)\")\" = claude && test -z \"$(yget "$C" providers.claude.default)\""
t "config: runner block carried over" test "$(yget "$C" runner.idle_timeout_s)" = 43200
t "config: this install's own telemetry value wins" test "$(yget "$C" telemetry.enabled)" = False
t "config: server untouched" test "$(yget "$C" server)" = "$API"
R="$PA/data/omnigent-plugin/connection.json"
t "plugin receipt names the adopted host" test "$(jget "$R" host.id)" = "$OLD_ID"
t "...and keeps its mode 0600 (the plugin refuses anything else)" test "$(stat -f %Lp "$R")" = 600
S="$PA/session-home.state"
t "state file: real home" test "$(sed -n 's/^REAL_HOME=//p' "$S")" = "$REAL"
t "state file: cutover marker and ids" eval "grep -q '^CUTOVER=yes' '$S' && grep -q '^OLD_HOST_ID=$OLD_ID' '$S'"
t "state file: the old job's PATH is recorded" eval "grep -q '^HOST_PATH=.*$SB/tools/bin' '$S'"

NEWPID="$(hostinfo $OLD_ID pid)"
t "the host now running is this install's (adopted id), a new process" eval "test -n '$NEWPID' && test '$NEWPID' != '$OLD_PID_BEFORE'"
t "it runs with HOME = the real home" test "$(hostinfo $OLD_ID home)" = "$REAL"
t "...and PI_AGENT_SESSION_HOME = the real home" test "$(hostinfo $OLD_ID session_home)" = "$REAL"
t "...and its config stays this install's directory" test "$(hostinfo $OLD_ID cfg_home)" = "$PA/home/.omnigent"
t "the old job's PATH entries that exist were appended" eval "hostinfo $OLD_ID path | tr ':' '\n' | grep -qx '$SB/tools/bin'"
tn "...and the ones that do not exist were not" eval "hostinfo $OLD_ID path | tr ':' '\n' | grep -qx '$SB/nonexistent/bin'"
t "...after this install's own bin, which keeps winning" eval "p=\$(hostinfo $OLD_ID path); a=\${p%%$PA/bin*}; b=\${p%%$SB/tools/bin*}; [ \${#a} -lt \${#b} ]"
t "pi-web (fake) is healthy again" eval "curl -s http://127.0.0.1:$WEBPORT/api/omnigent | grep -q '\"connected\": true'"

echo "  -- the plugin's own repair refreshed the receipt, with the service still down:"
RDUMP="$(ls -t "$ST"/pi-omnigent-*.json 2>/dev/null | head -1)"
t "the plugin CLI ran exactly once" test "$(ls "$ST"/pi-omnigent-*.json 2>/dev/null | wc -l | tr -d ' ')" = 1
t "...as: repair --server <the plugin's server>" test "$(jget "$RDUMP" argv)" = "['repair', '--server', '$API']"
t "...under env -i: nothing but what the wrapper needs (the worker's PI_SH_* / a decoy / runner variables did not leak)" "$PY" -I -B -c "
import json
e = json.load(open('$RDUMP'))['env']
assert set(e) <= {'PATH','PI_AGENT_HOME','PI_AGENT_SESSION_HOME','USER','LOGNAME','LANG','TMPDIR','__CF_USER_TEXT_ENCODING','LC_CTYPE'}, sorted(e)   # the last two are added by macOS and python
assert not [k for k in e if k.startswith(('PI_SH_', 'OMNIGENT', 'FAKE'))], sorted(e)"
t "...handing over the real HOME for the host it starts" test "$(jget "$RDUMP" env.PI_AGENT_SESSION_HOME)" = "$REAL"
t "...and PATH = the base plus the old job's directories that exist" test "$(jget "$RDUMP" env.PATH)" = "/usr/bin:/bin:/usr/sbin:/sbin:$SB/tools/bin"
t "...while this install's service was still down (it runs BEFORE the restart)" test "$(jget "$RDUMP" svc_loaded)" = False
t "...and the journal agrees on the order: repair done, then verified, only then the service started" eval "awk '/^DONE_repair=/{r=NR} /^DONE_verify_repair=/{v=NR} /^SVC_STARTED=/{s=NR} END{exit !(r && v && s && r<v && v<s)}' '$PA/cutover.journal'"
t "the plugin's state.json still says the login is confirmed" test "$(jget "$PA/data/omnigent-plugin/state.json" loginConfirmed)" = True
t "the plugin's second start of a host (it cannot see the first, macOS has no /proc) did not disturb it: one host process" test "$($MAC _classify | grep -c '^ours:')" = 1

echo "  -- the evidence is on the SERVER:"
t "server: the OLD host id is online" test "$(hstatus $OLD_ID)" = online
t "server: ...under its old name" test "$(hname $OLD_ID)" = "$OLD_NAME"
t "server: ...and it is the same row (created_at unchanged)" test "$(hcreated $OLD_ID)" = "$OLD_CREATED"
t "server: all 14 conversations are still bound to it" test "$(bound_to $OLD_ID)" = 14
t "server: the other hosts' conversations did not move" test "$(bound_to $NEW_ID)/$(bound_to $OTH_ID)" = "3/4"
t "server: NO row was rotated (the thing a new id under the old name would have caused)" test "$(stj "d['rotations']")" = 0
t "server: this install's old row is left behind, offline, untouched" eval "test \"$(hstatus $NEW_ID)\" = offline && test \"$(hname $NEW_ID)\" = '$NEW_NAME'"
t "server: exactly one row holds the name, and it is the id in the config (the same-name guard's pass condition)" \
  test "$(stj "[h['host_id'] for h in d['hosts'].values() if h['name']=='$OLD_NAME']")" = "['$OLD_ID']"
t "a backup with a manifest was written" eval "ls $PA/backups/cutover-*/MANIFEST.sha256 >/dev/null"
t "...holding the old config, tokens and plists" eval "cd $PA/backups/cutover-*/ && test -f old-config.yaml && test -f old-auth_tokens.json && test -f $L_OLD.plist && test -f scoped-config.yaml && test -f connection.json"
t "the journal says done" eval "grep -q '^STATUS=done' '$PA/cutover.journal'"

echo "  -- a host that merely reaches this install's directory through the ~/.omnigent link is not 'ours':"
mkdir -p "$SB/decoyhome" "$SB/decoydata"; ln -sfn "$PA/home/.omnigent" "$SB/decoyhome/.omnigent"
( HOME="$SB/decoyhome" OMNIGENT_DATA_DIR="$SB/decoydata" FAKE_STATE="$ST" exec "$PA/bin/omnigent" host --server "$API" ) >/dev/null 2>&1 &
DECOY=$!
waitfor 10 'ps eww -p $DECOY -o command= 2>/dev/null | grep -q decoyhome'
cls="$("$MAC" _classify 2>&1)"
t "classification: the pinned adopted host is ours" eval "printf '%s\\n' \"\$cls\" | grep -q '^ours:$NEWPID\$'"
t "...the unpinned host that reaches the directory only through the link is not (Omnigent.app would look like this)" eval "printf '%s\\n' \"\$cls\" | grep -q '^unknown:$DECOY:unpinned'"
kill $DECOY 2>/dev/null; wait $DECOY 2>/dev/null
post /_test/connect "{\"host_id\":\"$OLD_ID\",\"name\":\"$OLD_NAME\"}"       # the decoy's exit marked the shared id offline; the real host is up
t "the server shows the adopted host online again" waitfor 10 '[ "$(hstatus $OLD_ID)" = online ]'

out="$("$SH" status 2>&1)"
t "status reports the cutover" has_all "CUTOVER=yes" "journal:.*status=done"
out="$("$SH" disable 2>&1)"; rc=$?
t "disable refuses after a cutover, and says to use uncutover" rcn0_has "uncutover"
before="$(snap_all)"
out="$("$SH" cutover --dry-run 2>&1)"; rc=$?
t "a second cutover is refused" test "$rc" -ne 0

# ----------------------------------------------------------------------------------
head1 "4. restart, and the detached job outlives whoever scheduled it"
rm -f "$PA/session-home.result"
HP_BEFORE="$(hostinfo $OLD_ID pid)"
( exec perl -e 'use POSIX; setsid(); exec @ARGV' -- /bin/bash -c "'$SH' restart --in 3; sleep 120" ) >"$SB/sched.out" 2>&1 &
SCHED=$!
waitfor 15 'grep -q "scheduled restart" "$SB/sched.out"'
t "restart scheduled a job" grep -q "scheduled restart as $WPFX" "$SB/sched.out"
kill -9 -- "-$SCHED" 2>/dev/null; kill -9 "$SCHED" 2>/dev/null
sleep 1
tn "the scheduling process group is dead" kill -0 "$SCHED"
t "...yet the launchd job is still loaded and waiting" eval "launchctl list | grep -q '$WPFX'"
t "the job finishes by itself (up to 2 minutes)" wait_result 120
RES="$(result_line)"; note "$RES"
t "restart: RESULT: OK, host with the real HOME" hasr "RESULT: OK.*HOME=$REAL"
t "...the host process really was replaced" eval "test \"\$(hostinfo $OLD_ID pid)\" != '$HP_BEFORE'"
t "...and is still the adopted identity with the real HOME" eval "test \"\$(hostinfo $OLD_ID home)\" = '$REAL' && test \"\$(hstatus $OLD_ID)\" = online"
tn "the worker's plist removed itself" eval "ls $LA/$WPFX.* 2>/dev/null | grep -q ."
tn "...and the worker job is gone" eval "launchctl list | grep -q '$WPFX'"

# ----------------------------------------------------------------------------------
head1 "5. uncutover puts everything back"
rm -f "$PA/session-home.result"
out="$("$SH" uncutover --in 0 2>&1)"; rc=$?
t "uncutover schedules a job" rc0_has "scheduled uncutover"
t "it finishes" wait_result 180
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, everything as before" hasr "RESULT: ROLLED BACK"
t "old plists are back where they were, byte for byte" eval "test \"$(sha "$LA/$L_OLD.plist")\" = '$SHA_PLIST_OLD' && test \"$(sha "$LA/$L_WATCH.plist")\" = '$SHA_PLIST_WATCH'"
tn "...and .pre-pi-agent/ holds none of them" eval "ls $LA/.pre-pi-agent/*.plist 2>/dev/null | grep -q ."
t "the old host job runs again" waitfor 20 'test -n "$(lc_pid "$L_OLD")"'
tn "the old job is no longer disabled" lc_disabled "$L_OLD"
t "~/.omnigent is a real directory again" eval "test -d '$REAL/.omnigent' && ! test -L '$REAL/.omnigent'"
t "...with the original content (checksum of the tree)" test "$(snap_old "$REAL/.omnigent")" = "$(cat "$SNAP_OLD")"
t "this install's config is the original, byte for byte" test "$(sha "$PA/home/.omnigent/config.yaml")" = "$SHA_CFG_NEW"
t "the plugin receipt is the original, byte for byte" test "$(sha "$PA/data/omnigent-plugin/connection.json")" = "$SHA_RECEIPT"
t "the plugin state is the original, byte for byte" test "$(sha "$PA/data/omnigent-plugin/state.json")" = "$SHA_PSTATE"
tn "no state file" test -e "$PA/session-home.state"
tn "no journal left in the way" test -e "$PA/cutover.journal"
t "...it was archived" eval "ls $PA/backups/cutover-*.journal >/dev/null"
t "server: the old host is online again, same name, same 14 conversations" eval "test \"$(hstatus $OLD_ID)\" = online && test \"$(hname $OLD_ID)\" = '$OLD_NAME' && test \"$(bound_to $OLD_ID)\" = 14"
t "this install's host is back on its own id with the scoped HOME" waitfor 40 '[ "$(hstatus $NEW_ID)" = online ] && [ "$(hostinfo $NEW_ID home)" = "$PA/home" ]'
t "the old host runs with the real HOME" test "$(hostinfo $OLD_ID home)" = "$REAL"
t "still no rotation anywhere" test "$(stj "d['rotations']")" = 0
t "a fresh dry run works again" eval "'$SH' cutover --dry-run >/dev/null 2>&1"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

# ----------------------------------------------------------------------------------
head1 "6. a failure part-way rolls the whole thing back"
check_restored() {   # check_restored LABEL : the state is the original one
  local what="$1"
  t "$what: old plists restored byte for byte" eval "test \"$(sha "$LA/$L_OLD.plist")\" = '$SHA_PLIST_OLD' && test \"$(sha "$LA/$L_WATCH.plist")\" = '$SHA_PLIST_WATCH'"
  t "$what: old host job running" waitfor 20 'test -n "$(lc_pid "$L_OLD")"'
  t "$what: ~/.omnigent is the original directory" test "$(snap_old "$REAL/.omnigent")" = "$(cat "$SNAP_OLD")"
  t "$what: this install's config, plugin receipt and plugin state are the originals, byte for byte" eval "test \"$(sha "$PA/home/.omnigent/config.yaml")\" = '$SHA_CFG_NEW' && test \"$(sha "$PA/data/omnigent-plugin/connection.json")\" = '$SHA_RECEIPT' && test \"$(sha "$PA/data/omnigent-plugin/state.json")\" = '$SHA_PSTATE'"
  tn "$what: no state file" test -e "$PA/session-home.state"
  t "$what: server shows the old host online with its 14 conversations" eval "test \"$(hstatus $OLD_ID)\" = online && test \"$(bound_to $OLD_ID)\" = 14"
  t "$what: this install is healthy on its own identity again" waitfor 40 '[ "$(hstatus $NEW_ID)" = online ] && curl -s http://127.0.0.1:$WEBPORT/api/omnigent | grep -q "\"connected\": true"'
  t "$what: the old host's pid is different from before (it really was stopped and restarted)" eval "test \"$(lc_pid "$L_OLD")\" != '$OLD_PID_BEFORE'"
}

echo "  -- 6a. the server renames the host when the adopted identity reconnects"
post /_test/chaos "{\"on_connect\":{\"host_id\":\"$OLD_ID\",\"rename\":\"Renamed By Server\"}}"
# the chaos fires on the NEXT connect of that id; make it the adopted host's, not a re-check
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, with the reason" hasr "RESULT: ROLLED BACK.*Renamed By Server"
check_restored "6a"
t "6a: the row has its real name back" test "$(hname $OLD_ID)" = "$OLD_NAME"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6b. the server drops the conversations' binding on reconnect"
post /_test/chaos "{\"on_connect\":{\"host_id\":\"$OLD_ID\",\"unbind\":true}}"
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, naming the unbound conversations" hasr "RESULT: ROLLED BACK.*no longer bound"
# the chaos unbound them on the server for real; put them back as the real server would still have them
for i in 1 2 4 5 7 8 10 11 13 14 16 17 19 20; do post /_test/session "{\"id\":\"$(printf '%032x' $((0xabc000 + i)))\",\"host_id\":\"$OLD_ID\"}"; done
check_restored "6b"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6c. the host cannot start with session home (the repair step fails)"
touch "$ST/fail-session-home"
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes" wait_result 300
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, with the reason (the repair could not start its host)" hasr "RESULT: ROLLED BACK.*pi-omnigent repair failed"
rm -f "$ST/fail-session-home"
check_restored "6c"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6e. the plugin's repair fails"
touch "$ST/fail-repair"
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, with the reason" hasr "RESULT: ROLLED BACK.*pi-omnigent repair failed"
rm -f "$ST/fail-repair"
check_restored "6e"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6f. the repair exits 0 but has not saved the receipt (it started the adopted host, though)"
touch "$ST/repair-noop"
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, because the receipt still names the old identity" hasr "RESULT: ROLLED BACK.*receipt still names host"
rm -f "$ST/repair-noop"
check_restored "6f"
t "6f: the host the repair had started is gone: one host of this install is running, the restored one" test "$($MAC _classify | grep -c '^ours:')" = 1
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6g. the repair is fine but the service does not come up (the local check fails)"
touch "$ST/fail-piweb"
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes (it waits out the health check)" wait_result 300
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK, with the local health reason" hasr "RESULT: ROLLED BACK.*local check failed"
rm -f "$ST/fail-piweb"
check_restored "6g"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6h. a rollback that cannot confirm everything says so, and uncutover finishes the job"
touch "$ST/fail-piweb-always"
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
t "the job finishes (two health waits)" wait_result 360
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLBACK INCOMPLETE, honest about what is not confirmed" hasr "RESULT: ROLLBACK INCOMPLETE.*this install healthy: NO"
t "...with the old host back and online all the same" hasr "old host online: yes"
t "...and the journal kept, so that the cutover cannot be started again over it" eval "grep -q '^STATUS=rollback-incomplete' '$PA/cutover.journal'"
rm -f "$ST/fail-piweb-always"
rm -f "$PA/session-home.result"
"$SH" uncutover --in 0 >/dev/null 2>&1
t "uncutover finishes it" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK" hasr "RESULT: ROLLED BACK"
check_restored "6h"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

echo "  -- 6d. the worker is killed half way; the next login finds the leftovers and rolls back"
export PI_SH_STEP_PAUSE=2
rm -f "$PA/session-home.result"
"$SH" cutover --apply --in 0 >/dev/null 2>&1
unset PI_SH_STEP_PAUSE
t "the cutover gets as far as parking the old directory" waitfor 120 'grep -q "^DONE_park_link=yes" "$PA/cutover.journal"'
WPID="$(cat "$PA/session-home.lock/pid" 2>/dev/null)"
kill -9 "$WPID" 2>/dev/null
sleep 1
tn "the worker is dead" kill -0 "$WPID"
t "the world is half-changed: ~/.omnigent is a link" test -L "$REAL/.omnigent"
WLABEL="$(sed -n 's/^LABEL=//p' "$PA/session-home.run" | tail -1)"
t "the worker's plist is still there (that is what a login would load)" test -f "$LA/$WLABEL.plist"
rm -f "$PA/session-home.result"
launchctl bootout "gui/$UIDN/$WLABEL" >/dev/null 2>&1
launchctl bootstrap "gui/$UIDN" "$LA/$WLABEL.plist"
t "the rerun finishes" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: ROLLED BACK ('an earlier run was interrupted')" hasr "RESULT: ROLLED BACK.*interrupted"
check_restored "6d"
OLD_PID_BEFORE="$(lc_pid "$L_OLD")"

# ----------------------------------------------------------------------------------
head1 "7. enable / disable, without a cutover, restore the tree byte for byte"
# the host stops but its launchd job stays loaded (a clean exit does not restart it): enable must still refuse
launchctl kill SIGTERM "gui/$UIDN/$L_OLD" >/dev/null 2>&1
t "the old host process is gone, its job still loaded" waitfor 20 '[ "$(hstatus $OLD_ID)" != online ] && [ -z "$(lc_pid $L_OLD)" ] && launchctl print gui/$UIDN/$L_OLD >/dev/null 2>&1'
snap "$REAL" > "$SB/real.before"
out="$("$SH" enable 2>&1)"; rc=$?
t "enable refuses while that job is loaded, and names it" rcn0_has "$L_OLD is loaded"
t "...changing nothing" test "$(cat "$SB/real.before")" = "$(snap "$REAL")"
# now the way its owner would stop it for good
launchctl bootout "gui/$UIDN/$L_OLD" >/dev/null 2>&1; launchctl bootout "gui/$UIDN/$L_WATCH" >/dev/null 2>&1
out="$("$SH" enable 2>&1)"; rc=$?
t "enable works when nothing else serves ~/.omnigent" test "$rc" = 0
t "~/.omnigent is a link, the old directory parked" eval "test -L '$REAL/.omnigent' && test -d '$REAL/.omnigent.pre-pi-agent'"
t "codex-native hard-linked" test "$(stat -f %i "$REAL/.omnigent.pre-pi-agent/codex-native/rollout-a/rollout.jsonl")" = "$(stat -f %i "$PA/home/.omnigent/codex-native/rollout-a/rollout.jsonl")"
t "a backup of ~/.claude.json, ~/.codex/config.toml and the skills was made" eval "cd $PA/backups/session-home-*/ && test -f claude.json && test -f codex-config.toml && test -f skill-dirs.tgz"
t "the state file is what the wrappers and pi-web-start.sh read" eval "grep -q '^REAL_HOME=$REAL' '$PA/session-home.state'"
out="$("$SH" disable 2>&1)"; rc=$?
t "disable works" test "$rc" = 0
snap "$REAL" > "$SB/real.after"
t "the fake real home is byte for byte what it was (every file, mode and link)" test "$(cat "$SB/real.before")" = "$(cat "$SB/real.after")"
tn "no state file" test -e "$PA/session-home.state"

head1 "7b. session home alone (no cutover): restart moves the host to the real HOME, and back"
"$SH" enable >/dev/null 2>&1
rm -f "$PA/session-home.result"
"$SH" restart --in 0 >/dev/null 2>&1
t "the restart finishes" wait_result 120
RES="$(result_line)"; note "$RES"
t "RESULT: OK, the host runs with the real HOME" hasr "RESULT: OK.*HOME=$REAL"
t "...and has PI_AGENT_SESSION_HOME from the state file (pi-web-start.sh read it; no systemd drop-in here)" test "$(hostinfo $NEW_ID home)/$(hostinfo $NEW_ID session_home)" = "$REAL/$REAL"
tn "a plain enable records no HOST_PATH, so no PATH additions" eval "hostinfo $NEW_ID path | tr ':' '\n' | grep -qx '$SB/tools/bin'"
"$SH" disable >/dev/null 2>&1
rm -f "$PA/session-home.result"
"$SH" restart --in 0 >/dev/null 2>&1
t "the second restart finishes" wait_result 120
RES="$(result_line)"; note "$RES"
t "back on the scoped HOME" hasr "RESULT: OK.*HOME=$PA/home"
t "...and the host no longer has PI_AGENT_SESSION_HOME" test -z "$(hostinfo $NEW_ID session_home)"

head1 "7c. a session home that cannot work is reverted by the restart itself"
touch "$ST/fail-session-home"
"$SH" enable >/dev/null 2>&1
rm -f "$PA/session-home.result"
"$SH" restart --in 0 >/dev/null 2>&1
t "the restart finishes (it waits out the health check, then reverts)" wait_result 240
RES="$(result_line)"; note "$RES"
t "RESULT: REVERTED, with the reason" hasr "RESULT: REVERTED"
tn "the state file is gone" test -e "$PA/session-home.state"
tn "~/.omnigent is not a link" test -L "$REAL/.omnigent"
t "the host is back on the scoped HOME" waitfor 30 '[ "$(hostinfo $NEW_ID home)" = "$PA/home" ]'
rm -f "$ST/fail-session-home"

# ----------------------------------------------------------------------------------
head1 "8. the negative control: what a new id under the old name does to the server (the stub reproduces it)"
r0="$(stj "d['rotations']")"
post /_test/connect "{\"host_id\":\"dddddddd44444444dddddddd44444444\",\"name\":\"$OLD_NAME\"}"
t "a new host id under the old name rotates the old row..." test "$(stj "d['rotations']")" = "$((r0 + 1))"
t "...deletes the old id and repoints the 14 conversations at the newcomer" eval "test \"$(hstatus $OLD_ID)\" = None && test \"$(bound_to dddddddd44444444dddddddd44444444)\" = 14"

echo
printf 'session-home macOS sandbox tests: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  echo "--- tail of $PA/logs/session-home.log"; tail -40 "$PA/logs/session-home.log" 2>/dev/null
  KEEP=1
  exit 1
fi
exit 0
