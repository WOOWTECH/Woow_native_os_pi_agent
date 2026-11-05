#!/bin/bash
# After a pi-web restart on a Mac the plugin must not report its connected host as gone.
#
# Why this exists. resume() in the plugin checks that its host stayed up by reading /proc/<pid>. macOS has no /proc, so
# every pi-web restart put a Mac in phase `error`, HOST_PROCESS_MISSING, while the host stayed connected under the
# same pid (measured on two Intel Macs) until `pi-omnigent repair` was run by hand. The darwin patch makes the check
# apply only where /proc exists (docs/OPERATIONS-GOTCHAS.md section 6).
#   A  the patch: applies to the pinned plugin, idempotent, valid Python, composes with the other plugin patches
#   B  tests/resume_no_proc_test.py: the REAL src/omnigent.py through resume(), against a stub server
#
#   tests/resume-no-proc.sh
#
# Hermetic: temp directories, a stub server on 127.0.0.1, and the pinned plugin tarball (verified against lib/pins.sh).
#
# Environment (all optional):
#   PA_TEST_NODE          node to use (default: node on PATH, else the install's scoped node)
#   PA_TEST_PYTHON        a python that can import httpx and yaml (default: the install's omnigent tool python, python3)
#   PA_TEST_PLUGIN_TGZ    a local copy of the pinned plugin tarball, for offline runs (still verified)
#   PA_TEST_CACHE         where the download is kept (default $TMPDIR/pi-agent-test-cache)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
die() { printf 'resume-no-proc tests: %s\n' "$*" >&2; exit 2; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
INSTALL_HOME="${PA_TEST_INSTALL_HOME:-${PI_AGENT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}}"
unset PI_AGENT_HOME PI_AGENT_DATA_DIR
NODE="${PA_TEST_NODE:-$(command -v node || true)}"
[ -x "$NODE" ] || NODE="$INSTALL_HOME/node/bin/node"
[ -x "$NODE" ] || die "no node found (set PA_TEST_NODE)"
PY=""
for c in "${PA_TEST_PYTHON:-}" "$INSTALL_HOME/data/omnigent-plugin/uv/tools/omnigent/bin/python" "$(command -v python3 || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && "$c" -I -B -c 'import httpx, yaml' >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || die "no python that can import httpx and yaml (set PA_TEST_PYTHON)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pi-agent-resume-test.XXXXXX")" || die "cannot create a work directory"
trap 'rm -rf "${WORK:?}"' EXIT
CACHE="${PA_TEST_CACHE:-${TMPDIR:-/tmp}/pi-agent-test-cache}"; mkdir -p "$CACHE"
TGZ="${PA_TEST_PLUGIN_TGZ:-$CACHE/woowtech-pi-omnigent-plugin-$PIN_OMNIGENT_PLUGIN_VERSION.tgz}"
if [ ! -f "$TGZ" ] || [ "$(sha256_file "$TGZ")" != "$PIN_OMNIGENT_PLUGIN_SHA256" ]; then
  [ -z "${PA_TEST_PLUGIN_TGZ:-}" ] || die "PA_TEST_PLUGIN_TGZ does not match the pinned sha256"
  curl -fsSL --retry 3 -o "$TGZ.part" "$PIN_OMNIGENT_PLUGIN_TGZ" || die "cannot download the pinned plugin"
  [ "$(sha256_file "$TGZ.part")" = "$PIN_OMNIGENT_PLUGIN_SHA256" ] || { rm -f "$TGZ.part"; die "sha256 differs from lib/pins.sh -- refusing to use it"; }
  mv "$TGZ.part" "$TGZ"
fi
PRISTINE="$WORK/pristine"; mkdir -p "$PRISTINE"
tar xzf "$TGZ" --strip-components=1 -C "$PRISTINE" || die "cannot unpack the plugin"

DARWIN="$HERE/rootfs/bin/omnigent-plugin-darwin-patch.mjs"
GUARD="$HERE/rootfs/bin/omnigent-plugin-host-name-guard-patch.mjs"
SESSION="$HERE/rootfs/bin/omnigent-plugin-session-home-patch.mjs"
MARK="no-proc-no-verdict (Woow native installer)"
syntax() { "$PY" -I -B -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$1" 2>&1; }

echo "== A. the patch: applies, once, and composes with the other patches to src/omnigent.py"
P="$WORK/a"; cp -R "$PRISTINE" "$P"
"$NODE" "$DARWIN" "$P" > "$WORK/a1.log" 2>&1
if [ "$(grep -cF "$MARK" "$P/src/omnigent.py")" = 1 ] && grep -qF "Path('/proc/self').exists() and self.managed_host_pid(server) is None" "$P/src/omnigent.py"; then ok "the edit is in src/omnigent.py, once (plugin $PIN_OMNIGENT_PLUGIN_VERSION)"
else no "the edit is in src/omnigent.py, once" "$(tr '\n' ' ' < "$WORK/a1.log" | cut -c1-260)"; fi
s="$(syntax "$P/src/omnigent.py")" && ok "...and the file is valid Python" || no "the file is valid Python" "$s"
cmp -s "$P/src/omnigent.py.orig" "$PRISTINE/src/omnigent.py" && ok "...with the pristine file kept as .orig" || no "the pristine file is kept as .orig" "differs"
before="$(sha256_file "$P/src/omnigent.py")"; "$NODE" "$DARWIN" "$P" > "$WORK/a2.log" 2>&1
[ "$(sha256_file "$P/src/omnigent.py")" = "$before" ] && ok "a second run changes nothing" || no "a second run changes nothing" "$(tr '\n' ' ' < "$WORK/a2.log" | cut -c1-200)"
for order in "$DARWIN $GUARD $SESSION" "$GUARD $SESSION $DARWIN"; do
  C="$WORK/compose"; rm -rf "$C"; cp -R "$PRISTINE" "$C"
  for patch in $order; do "$NODE" "$patch" "$C" >/dev/null 2>&1; done
  names="$(for patch in $order; do basename "$patch" | sed -E 's/omnigent-plugin-|-patch.mjs//g'; done | tr '\n' ' ')"
  n="$(grep -cF "$MARK" "$C/src/omnigent.py")"; s="$(syntax "$C/src/omnigent.py")"; rc=$?
  if [ "$n" = 1 ] && [ "$rc" = 0 ]; then ok "applied in the order $names: the edit once, valid Python"
  else no "applied in the order $names: the edit once, valid Python" "edits=$n $s"; fi
done

echo "== B. the real src/omnigent.py through resume(), against a stub server"
"$PY" -I -B "$HERE/tests/resume_no_proc_test.py" "$PRISTINE" "$NODE" "$DARWIN" > "$WORK/py.out" 2>&1; rc=$?
grep -vE '^SUMMARY|^$' "$WORK/py.out"
py_pass="$(sed -n 's/^SUMMARY passed=\([0-9]*\).*/\1/p' "$WORK/py.out")"; py_fail="$(sed -n 's/^SUMMARY.*failed=\([0-9]*\).*/\1/p' "$WORK/py.out")"
[ -n "$py_pass" ] || { no "the python suite ran to the end" "rc=$rc"; py_pass=0; py_fail=0; }

echo
printf 'resume without /proc: %s passed, %s failed\n' "$((pass + py_pass))" "$((fail + py_fail))"
[ "$((fail + py_fail))" = 0 ]
