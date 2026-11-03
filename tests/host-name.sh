#!/usr/bin/env bash
# v0.2.2 -- the host-name tests: the unique default name, the plugin guard that refuses a
# taken one, and their wiring in install.sh.
#
#   tests/host-name.sh
#
# Three suites, one verdict:
#   tests/host-name.test.mjs        pi-agent-host-name (seed/check/set), the plugin patch,
#                                   `install.sh wire`, env propagation through the plugin
#   tests/host_name_guard_test.py   the REAL patched src/omnigent.py through ensure_host(),
#                                   with the plugin's own httpx client, against a stub
#                                   Omnigent server on 127.0.0.1 (/v1/me, /v1/hosts)
#   (here) K                        real omnigent completes the partial host section the
#                                   seed writes -- only when an omnigent python is at hand
#
# Hermetic. Temp directories and a stub server only: it never reads or writes ~/.omnigent,
# a running install or a real Omnigent server, and it does not start or restart anything.
# The one thing it fetches is the pinned pi-omnigent-plugin tarball -- from the release
# URL in lib/pins.sh, cached, and refused unless its sha256 equals the pin.
#
# Environment (all optional):
#   PA_TEST_NODE          node to use (default: node on PATH, else the install's scoped node)
#   PA_TEST_PYTHON        a python that can import httpx and yaml (default: the install's
#                         omnigent tool python, python3, else a throwaway venv + pip)
#   PA_TEST_PLUGIN_TGZ    a local copy of the pinned tarball, for offline runs (still verified)
#   PA_TEST_CACHE         where the downloaded tarball is kept (default $TMPDIR/pi-agent-test-cache)
#   PA_TEST_OMNIGENT_PYTHON   python with the omnigent package, for suite K
#   PA_TEST_KEEP=1        keep the work directory for inspection
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"

die() { printf 'host-name tests: %s\n' "$*" >&2; exit 2; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Where to LOOK (read-only) for a node/python when none is given: an existing install's.
INSTALL_HOME="${PA_TEST_INSTALL_HOME:-${PI_AGENT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}}"
# From here on nothing of a surrounding install or Omnigent session may leak into the suites:
# each test passes exactly the environment it means to.
unset PI_AGENT_HOME PI_AGENT_DATA_DIR PI_AGENT_SESSION_HOME PI_AGENT_TAKEOVER_HOST_ID PI_AGENT_HOSTNAME OMNIGENT_CONFIG_HOME OMNIGENT_DATA_DIR

NODE="${PA_TEST_NODE:-$(command -v node || true)}"
[ -x "$NODE" ] || NODE="$INSTALL_HOME/node/bin/node"
[ -x "$NODE" ] || die "no node found (set PA_TEST_NODE)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pi-agent-host-name-test.XXXXXX")" || die "cannot create a work directory"
cleanup() { [ "${PA_TEST_KEEP:-}" = 1 ] && { echo "kept: $WORK"; return; }; rm -rf "${WORK:?}"; }
trap cleanup EXIT

# --- the pinned plugin, verified before use ---------------------------------------------
CACHE="${PA_TEST_CACHE:-${TMPDIR:-/tmp}/pi-agent-test-cache}"
mkdir -p "$CACHE"
TGZ="${PA_TEST_PLUGIN_TGZ:-$CACHE/woowtech-pi-omnigent-plugin-$PIN_OMNIGENT_PLUGIN_VERSION.tgz}"
if [ ! -f "$TGZ" ] || [ "$(sha256_file "$TGZ")" != "$PIN_OMNIGENT_PLUGIN_SHA256" ]; then
  [ -z "${PA_TEST_PLUGIN_TGZ:-}" ] || die "PA_TEST_PLUGIN_TGZ does not match the pinned sha256 $PIN_OMNIGENT_PLUGIN_SHA256"
  echo "fetching $PIN_OMNIGENT_PLUGIN_TGZ"
  curl -fsSL --retry 3 -o "$TGZ.part" "$PIN_OMNIGENT_PLUGIN_TGZ" || die "cannot download the pinned plugin"
  got="$(sha256_file "$TGZ.part")"
  [ "$got" = "$PIN_OMNIGENT_PLUGIN_SHA256" ] || { rm -f "$TGZ.part"; die "sha256 of the downloaded plugin is $got, lib/pins.sh pins $PIN_OMNIGENT_PLUGIN_SHA256 -- refusing to use it"; }
  mv "$TGZ.part" "$TGZ"
fi
echo "plugin tarball verified: sha256 $PIN_OMNIGENT_PLUGIN_SHA256"
# `install.sh fetch` downloads the paseo plugin too; test C5 runs the real fetch stage from
# file:// URLs so that nothing but this driver touches the network. Same rule: verified first.
PASEO_TGZ="$CACHE/woowtech-pi-paseo-$PIN_PASEO_PLUGIN_VERSION.tgz"
if [ ! -f "$PASEO_TGZ" ] || [ "$(sha256_file "$PASEO_TGZ")" != "$PIN_PASEO_PLUGIN_SHA256" ]; then
  echo "fetching $PIN_PASEO_PLUGIN_TGZ"
  curl -fsSL --retry 3 -o "$PASEO_TGZ.part" "$PIN_PASEO_PLUGIN_TGZ" || die "cannot download the pinned paseo plugin"
  got="$(sha256_file "$PASEO_TGZ.part")"
  [ "$got" = "$PIN_PASEO_PLUGIN_SHA256" ] || { rm -f "$PASEO_TGZ.part"; die "sha256 of the downloaded paseo plugin is $got, lib/pins.sh pins $PIN_PASEO_PLUGIN_SHA256 -- refusing to use it"; }
  mv "$PASEO_TGZ.part" "$PASEO_TGZ"
fi
PRISTINE="$WORK/pristine"; mkdir -p "$PRISTINE"
tar xzf "$TGZ" --strip-components=1 -C "$PRISTINE" || die "cannot unpack the plugin"
"$NODE" -e 'const p=require(process.argv[1]); if(p.version!==process.argv[2]) throw Error("plugin is "+p.version+", pinned "+process.argv[2])' \
  "$PRISTINE/package.json" "$PIN_OMNIGENT_PLUGIN_VERSION" || die "unexpected plugin version"

# --- a python that can run the plugin's adapter -----------------------------------------
py_ok() { "$1" -I -B -c 'import httpx, yaml' >/dev/null 2>&1; }
PY=""
for c in "${PA_TEST_PYTHON:-}" "$INSTALL_HOME/data/omnigent-plugin/uv/tools/omnigent/bin/python" "$(command -v python3 || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && py_ok "$c" && { PY="$c"; break; }
done
if [ -z "$PY" ]; then
  base="$(command -v python3 || true)"; [ -n "$base" ] || die "no python3 to build a test environment from (set PA_TEST_PYTHON)"
  echo "no python with httpx+yaml found; building a throwaway venv"
  "$base" -m venv "$WORK/venv" && "$WORK/venv/bin/pip" install -q httpx pyyaml || die "cannot build a venv with httpx and pyyaml (set PA_TEST_PYTHON)"
  PY="$WORK/venv/bin/python"
fi
echo "node:   $NODE ($("$NODE" --version))"
echo "python: $PY ($("$PY" -c 'import sys; print(sys.version.split()[0])'))"

export PA_TEST_PRISTINE="$PRISTINE" PA_TEST_PYTHON="$PY" PA_TEST_OMNIGENT_TGZ="$TGZ" PA_TEST_PASEO_TGZ="$PASEO_TGZ"
total_pass=0; total_fail=0; total_skip=0; rc=0
tally() {   # tally <output file>
  local line; line="$(grep '^SUMMARY ' "$1" | tail -1)"
  if [ -z "$line" ]; then echo "(no SUMMARY line in $1)"; rc=1; return; fi
  total_pass=$((total_pass + $(sed -n 's/.*passed=\([0-9]*\).*/\1/p' <<<"$line")))
  total_fail=$((total_fail + $(sed -n 's/.*failed=\([0-9]*\).*/\1/p' <<<"$line")))
  total_skip=$((total_skip + $(sed -n 's/.*skipped=\([0-9]*\).*/\1/p' <<<"$line")))
}

echo; echo "######## host-name.test.mjs"
"$NODE" "$HERE/tests/host-name.test.mjs" 2>&1 | tee "$WORK/node.out"
[ "${PIPESTATUS[0]}" = 0 ] || rc=1
tally "$WORK/node.out"

echo; echo "######## host_name_guard_test.py"
"$PY" -I -B "$HERE/tests/host_name_guard_test.py" "$PRISTINE" "$NODE" "$HERE/rootfs/bin/omnigent-plugin-host-name-guard-patch.mjs" 2>&1 | tee "$WORK/py.out"
[ "${PIPESTATUS[0]}" = 0 ] || rc=1
tally "$WORK/py.out"

# --- K: real omnigent completes the partial section the seed writes ---------------------
echo; echo "######## K. real omnigent keeps the seeded name and generates only the host_id"
: > "$WORK/k.out"
kcheck() {   # kcheck <label> <command...>
  local label="$1"; shift
  if "$@" >>"$WORK/k.detail" 2>&1; then echo "  PASS  $label" | tee -a "$WORK/k.out"; else echo "  FAIL  $label (see below)" | tee -a "$WORK/k.out"; sed 's/^/        /' "$WORK/k.detail"; fi
}
OPY=""
for c in "${PA_TEST_OMNIGENT_PYTHON:-}" "$INSTALL_HOME/data/omnigent-plugin/uv/tools/omnigent/bin/python"; do
  [ -n "$c" ] && [ -x "$c" ] && "$c" -I -B -c 'import omnigent.host.identity' >/dev/null 2>&1 && { OPY="$c"; break; }
done
if [ -z "$OPY" ]; then
  echo "  SKIP  K* -- no python with the omnigent package (set PA_TEST_OMNIGENT_PYTHON)" | tee -a "$WORK/k.out"
  printf 'SUMMARY passed=0 failed=0 skipped=1\n' >> "$WORK/k.out"
else
  k=0
  for NAME in "box.local (pi-agent)" "小明的 MacBook (pi-agent)" 'quote"and\back (pi-agent)'; do
    k=$((k + 1)); KH="$WORK/k$k"; mkdir -p "$KH"
    : > "$WORK/k.detail"
    PI_AGENT_HOME="$KH" PI_AGENT_HOSTNAME=box.local "$NODE" "$HERE/rootfs/bin/pi-agent-host-name.mjs" set "$NAME" >/dev/null
    kcheck "K$k omnigent keeps the name written by pi-agent-host-name ($NAME) and adds a 32-hex host_id" \
      env -i HOME="$KH/hh" OMNIGENT_CONFIG_HOME="$KH/home/.omnigent" OMNIGENT_DATA_DIR="$KH/home/.omnigent" \
      "$OPY" -I -B -c '
import sys
from omnigent.host.identity import load_or_create_host_identity
i = load_or_create_host_identity()
assert i.name == sys.argv[1], (i.name, sys.argv[1])
assert len(i.host_id) == 32 and all(c in "0123456789abcdef" for c in i.host_id), i.host_id
' "$NAME"
    : > "$WORK/k.detail"
    out="$(PI_AGENT_HOME="$KH" PI_AGENT_HOSTNAME=box.local "$NODE" "$HERE/rootfs/bin/pi-agent-host-name.mjs" check --json)"
    kcheck "K$k ...and pi-agent-host-name reads the file omnigent rewrote (name intact, host_id seen, status ok)" \
      "$PY" -I -B -c '
import json, sys
j = json.loads(sys.argv[1])
assert j["name"] == sys.argv[2] and len(j["hostId"] or "") == 32 and j["status"] == "ok", j
' "$out" "$NAME"
  done
  kp=$(grep -c '^  PASS' "$WORK/k.out"); kf=$(grep -c '^  FAIL' "$WORK/k.out")
  printf 'SUMMARY passed=%s failed=%s skipped=0\n' "$kp" "$kf" >> "$WORK/k.out"
fi
tally "$WORK/k.out"

echo
echo "TOTAL passed=$total_pass failed=$total_fail skipped=$total_skip"
[ "$total_fail" = 0 ] && [ "$rc" = 0 ] || { echo "host-name tests: FAILED"; exit 1; }
echo "host-name tests: OK"
