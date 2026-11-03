#!/bin/bash
# The `pi` wrapper under session home: which HOME and which Pi data directory it hands to pi.
#
# Why this exists. Pi keeps its models, login and settings in one directory, and
# pi-agent-env.sh points that at THIS install's data dir. Session home keeps the caller's
# HOME for the engines the Omnigent host runs -- but a Pi that still read the install's own
# (empty) data dir found no models at all (Omnigent: MODELS_UNAVAILABLE) although the user's
# own ~/.pi/agent had them. Found on the first Mac cut over; claude and codex were fine
# because their data lives under HOME.
#
# The rule under test: while session home is on, a caller running with a HOME that is not the
# install's own gets <HOME>/.pi/agent -- but ONLY when that directory holds a Pi configuration
# (models.json or auth.json). A user with no Pi of their own keeps the install's data dir,
# where pi-agent-litellm put the gateway; redirecting them would leave Pi without models.
#
#   tests/pi-wrapper-session-home.sh
#   PI_TEST_WRAPPER=/path/to/an/older/pi tests/pi-wrapper-session-home.sh     (expect failures: that is the check)
#
# Hermetic: a temp directory, a fake node that only reports its environment. Touches nothing else.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="${PI_TEST_WRAPPER:-$HERE/rootfs/bin/pi}"
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-piwrap.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
PA="$W/pa"; REAL="$W/real"; REAL_AUTH="$W/real-auth-only"; REAL_EMPTY="$W/real-empty-pi-dir"; REAL_NOPI="$W/real-without-pi"
mkdir -p "$PA/bin" "$PA/node/bin" "$PA/home" "$PA/data" "$REAL/.pi/agent" "$REAL_AUTH/.pi/agent" "$REAL_EMPTY/.pi/agent" "$REAL_NOPI"
echo '{"providers": {}}' > "$REAL/.pi/agent/models.json"      # the user's own Pi: models
echo '{}' > "$REAL_AUTH/.pi/agent/auth.json"                    # ...only a login
# $REAL_EMPTY/.pi/agent exists but holds nothing; $REAL_NOPI has no .pi at all
CLI_DIR="$PA/piweb/lib/node_modules/@agegr/pi-web/node_modules/@earendil-works/pi-coding-agent/dist"
mkdir -p "$CLI_DIR"; : > "$CLI_DIR/cli.js"
cp "$WRAPPER" "$PA/bin/pi"
cp "$HERE/rootfs/bin/pi-agent-env.sh" "$PA/bin/pi-agent-env.sh"
cat > "$PA/node/bin/node" <<'EOF'
#!/bin/bash
echo "HOME=$HOME"
echo "PI_CODING_AGENT_DIR=${PI_CODING_AGENT_DIR:-}"
EOF
chmod 755 "$PA/node/bin/node" "$PA/bin/pi"

# run_pi CALLER_HOME|- [CALLER_PI_DIR]   ('-' = no HOME at all)
run_pi() {
  local -a e=(env -i PATH=/usr/bin:/bin PI_AGENT_HOME="$PA")
  [ "$1" = - ] || e+=(HOME="$1")
  [ -z "${2:-}" ] || e+=(PI_CODING_AGENT_DIR="$2")
  "${e[@]}" "$PA/bin/pi" 2>&1
}
# expect LABEL CALLER_HOME CALLER_PI_DIR WANT_HOME WANT_PI_DIR
expect() {
  local out want
  out="$(run_pi "$2" "$3")"
  want="HOME=$4
PI_CODING_AGENT_DIR=$5"
  if [ "$out" = "$want" ]; then ok "$1"; else no "$1" "got  $(printf '%s' "$out" | tr '\n' ' ')| wanted $(printf '%s' "$want" | tr '\n' ' ')"; fi
}
session_home_on()  { printf 'REAL_HOME=%s\nPARKED=\nBACKUP=\nENABLED_AT=test\n' "$REAL" > "$PA/session-home.state"; }
session_home_off() { rm -f "$PA/session-home.state"; }

echo "== session home OFF: this install is scoped, as before"
session_home_off
expect "a caller with the user's own HOME still gets the install's HOME and data dir" "$REAL" "" "$PA/home" "$PA/data"
expect "...and so does a caller that passes no Pi dir and no HOME" - "" "$PA/home" "$PA/data"

echo "== session home ON, the user has a Pi of their own"
session_home_on
expect "the Omnigent host's session (the user's own HOME) uses the user's own ~/.pi/agent (it has models.json)" "$REAL" "" "$REAL" "$REAL/.pi/agent"
expect "...also when only a login (auth.json) is there" "$REAL_AUTH" "" "$REAL_AUTH" "$REAL_AUTH/.pi/agent"
expect "...and when the scoped default is merely inherited from the host's environment" "$REAL" "$PA/data" "$REAL" "$REAL/.pi/agent"
expect "a Pi directory the caller chose itself is honoured" "$REAL" "$W/elsewhere/pi" "$REAL" "$W/elsewhere/pi"
echo "== session home ON, the user has no Pi configuration of their own: nothing changes for them"
expect "~/.pi/agent exists but holds no models.json or auth.json -> the install's data dir" "$REAL_EMPTY" "" "$REAL_EMPTY" "$PA/data"
expect "no ~/.pi at all -> the install's data dir" "$REAL_NOPI" "" "$REAL_NOPI" "$PA/data"
expect "...also when the scoped default is inherited" "$REAL_NOPI" "$PA/data" "$REAL_NOPI" "$PA/data"
echo "== session home ON, other callers"
expect "pi-web's own terminal (this install's HOME) keeps this install's data dir" "$PA/home" "" "$PA/home" "$PA/data"
expect "...and ignores an inherited scoped default the same way" "$PA/home" "$PA/data" "$PA/home" "$PA/data"
expect "a caller with no HOME stays scoped (nothing to keep)" - "" "$PA/home" "$PA/data"

echo
printf 'pi wrapper under session home: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
