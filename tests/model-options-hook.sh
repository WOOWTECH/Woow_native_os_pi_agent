#!/bin/bash
# The Pi model-options patch must be on disk before the Omnigent host starts -- including on a fresh install.
#
# Why this exists. pi-web-start.sh patches the omnigent the plugin installed, at every service start, and skips
# the step while that omnigent does not exist. On a fresh install it does not exist at the first start: the plugin
# installs it a few seconds later, so the first host loaded an unpatched module and kept it (a pi-web restart does
# not restart the host): Pi showed `ready: false`, no models, in Omnigent, while `pi --list-models` listed them all
# (docs/OPERATIONS-GOTCHAS.md section 21). The fix has two halves, and this suite checks both and then the wiring:
#   A  omnigent-plugin-model-options-hook-patch.mjs: applies, is idempotent, gated, anchored, leaves no half-patch
#   B  it composes with the darwin patch, in either order
#   C  the REAL installDependencies() of the patched plugin, with stand-ins for uv and the tool's python: the
#      patch runs right after the install and before the plugin looks at the result -- on install and on update,
#      not otherwise, never fails the install
#   D  install.sh: `wire` installs the file and patches the plugin tree; `fetch` (from file:// copies of the
#      pinned tarballs) patches a fresh tree again after the tree is replaced
#   E  pi-web-start.sh applies it at every start, so a re-extracted plugin tree is covered at once
#
#   tests/model-options-hook.sh
#
# Hermetic: temp directories, the pinned plugin tarballs (verified against lib/pins.sh) and no network
# beyond fetching those. Nothing outside the temp directories is touched.
#
# Environment (all optional):
#   PA_TEST_NODE          node to use (default: node on PATH, else the install's scoped node)
#   PA_TEST_PLUGIN_TGZ    a local copy of the pinned omnigent plugin tarball, for offline runs (still verified)
#   PA_TEST_PASEO_TGZ     the same for the paseo plugin (needed by section D's fetch)
#   PA_TEST_CACHE         where downloads are kept (default $TMPDIR/pi-agent-test-cache)
#   PA_TEST_KEEP=1        keep the work directory for inspection
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
die()  { printf 'model-options-hook tests: %s\n' "$*" >&2; exit 2; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

INSTALL_HOME="${PA_TEST_INSTALL_HOME:-${PI_AGENT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}}"
unset PI_AGENT_HOME PI_AGENT_DATA_DIR PI_AGENT_SESSION_HOME PI_OMNIGENT_UV_CONSTRAINTS
NODE="${PA_TEST_NODE:-$(command -v node || true)}"
[ -x "$NODE" ] || NODE="$INSTALL_HOME/node/bin/node"
[ -x "$NODE" ] || die "no node found (set PA_TEST_NODE)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pi-agent-hook-test.XXXXXX")" || die "cannot create a work directory"
cleanup() { [ "${PA_TEST_KEEP:-}" = 1 ] && { echo "kept: $WORK"; return; }; rm -rf "${WORK:?}"; }
trap cleanup EXIT
CACHE="${PA_TEST_CACHE:-${TMPDIR:-/tmp}/pi-agent-test-cache}"; mkdir -p "$CACHE"

# fetch_pinned <url> <sha256> <env override> <file name>  -> path of the verified tarball
fetch_pinned() {
  local url="$1" want="$2" override="$3" name="$4" f
  f="${override:-$CACHE/$name}"
  if [ ! -f "$f" ] || [ "$(sha256_file "$f")" != "$want" ]; then
    [ -z "$override" ] || die "$name override does not match the pinned sha256 $want"
    echo "fetching $url" >&2
    curl -fsSL --retry 3 -o "$f.part" "$url" || die "cannot download $url"
    [ "$(sha256_file "$f.part")" = "$want" ] || { rm -f "$f.part"; die "sha256 of $name differs from lib/pins.sh -- refusing to use it"; }
    mv "$f.part" "$f"
  fi
  printf '%s' "$f"
}
OMNI_TGZ="$(fetch_pinned "$PIN_OMNIGENT_PLUGIN_TGZ" "$PIN_OMNIGENT_PLUGIN_SHA256" "${PA_TEST_PLUGIN_TGZ:-}" "woowtech-pi-omnigent-plugin-$PIN_OMNIGENT_PLUGIN_VERSION.tgz")" || exit 2
PRISTINE="$WORK/pristine"; mkdir -p "$PRISTINE"
tar xzf "$OMNI_TGZ" --strip-components=1 -C "$PRISTINE" || die "cannot unpack the plugin"

HOOK="$HERE/rootfs/bin/omnigent-plugin-model-options-hook-patch.mjs"
DARWIN="$HERE/rootfs/bin/omnigent-plugin-darwin-patch.mjs"
MARK="model-options-hook (Woow native installer)"
copy_plugin() { rm -rf "$1"; cp -R "$PRISTINE" "$1"; }
installer_of() { printf '%s/src/installer.mjs' "$1"; }

echo "== A. the patch: applies, once, anchored, version-gated"
P="$WORK/a"; copy_plugin "$P"
"$NODE" "$HOOK" "$P" > "$WORK/a1.log" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$MARK" "$(installer_of "$P")" && [ -f "$(installer_of "$P").orig" ]; then
  ok "applies to the pinned plugin $PIN_OMNIGENT_PLUGIN_VERSION (marker in src/installer.mjs, pristine kept as .orig)"
else no "applies to the pinned plugin $PIN_OMNIGENT_PLUGIN_VERSION" "rc=$rc $(tr '\n' ' ' < "$WORK/a1.log" | cut -c1-260)"; fi
"$NODE" --check "$(installer_of "$P")" 2>"$WORK/a-check.log" && ok "the patched src/installer.mjs is valid JavaScript" || no "the patched src/installer.mjs is valid JavaScript" "$(head -3 "$WORK/a-check.log")"
cmp -s "$(installer_of "$P").orig" "$(installer_of "$PRISTINE")" && ok "...and the .orig is byte for byte the pinned file" || no "the .orig is the pinned file" "differs"
before="$(sha256_file "$(installer_of "$P")")"
"$NODE" "$HOOK" "$P" > "$WORK/a2.log" 2>&1
if [ "$(sha256_file "$(installer_of "$P")")" = "$before" ] && grep -q "already patched — no change" "$WORK/a2.log"; then ok "a second run changes nothing (reports already patched)"
else no "a second run changes nothing" "$(tr '\n' ' ' < "$WORK/a2.log" | cut -c1-200)"; fi
G="$WORK/a-gate"; copy_plugin "$G"
"$NODE" -e 'const f=process.argv[1]; const p=JSON.parse(require("fs").readFileSync(f,"utf8")); p.version="9.9.9"; require("fs").writeFileSync(f, JSON.stringify(p))' "$G/package.json"
"$NODE" "$HOOK" "$G" > "$WORK/a-gate.log" 2>&1
if cmp -s "$(installer_of "$G")" "$(installer_of "$PRISTINE")" && grep -q "SKIPPING" "$WORK/a-gate.log"; then ok "a plugin version it was not validated against is left alone, loudly (SKIPPING)"
else no "a plugin version it was not validated against is left alone" "$(tr '\n' ' ' < "$WORK/a-gate.log" | cut -c1-200)"; fi
M="$WORK/a-moved"; copy_plugin "$M"
"$NODE" -e 'const f=process.argv[1]; let s=require("fs").readFileSync(f,"utf8"); s=s.replace("if (discovery.omnigent?.available) {","if (discovery.omnigent && discovery.omnigent.available) {"); require("fs").writeFileSync(f,s)' "$(installer_of "$M")"
cp "$(installer_of "$M")" "$WORK/a-moved.before"
"$NODE" "$HOOK" "$M" > "$WORK/a-moved.log" 2>&1
if cmp -s "$(installer_of "$M")" "$WORK/a-moved.before" && grep -q "expected exactly 1" "$WORK/a-moved.log"; then ok "an anchor that moved is not half-patched: the file stays as it was, with the reason logged"
else no "an anchor that moved is not half-patched" "$(tr '\n' ' ' < "$WORK/a-moved.log" | cut -c1-200)"; fi

echo "== B. it composes with the darwin patch, in either order"
for order in "hook darwin" "darwin hook"; do
  C="$WORK/b-${order// /-}"; copy_plugin "$C"
  for which in $order; do
    if [ "$which" = hook ]; then "$NODE" "$HOOK" "$C" >/dev/null 2>&1; else "$NODE" "$DARWIN" "$C" >/dev/null 2>&1; fi
  done
  n_hook="$(grep -cF "$MARK" "$(installer_of "$C")")"; n_launch="$(grep -c "first-launch (Woow native installer)" "$(installer_of "$C")")"; n_uv="$(grep -c "uv-constraints (Woow native installer)" "$(installer_of "$C")")"
  if "$NODE" --check "$(installer_of "$C")" 2>/dev/null && [ "$n_hook" = 1 ] && [ "$n_launch" = 1 ] && [ "$n_uv" = 1 ]; then ok "$order: valid JavaScript, every edit exactly once"
  else no "$order: valid JavaScript, every edit exactly once" "hook=$n_hook launch=$n_launch uv=$n_uv"; fi
done

echo "== C. the real installDependencies(): the patch runs right after the install, before the plugin looks at the result"
cat > "$WORK/drive.mjs" <<'JS'
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [installer, platform, arch, mode, scenario] = process.argv.slice(2);
const { installDependencies } = await import(pathToFileURL(installer).href);
const stateDir = process.env.PA_TEST_STATE, paHome = process.env.PA_TEST_HOME || '';
const tool = path.join(stateDir, 'uv', 'tools', 'omnigent'), managed = path.join(stateDir, 'bin', 'omnigent');
let installed = mode === 'update' || mode === 'present', discovers = 0;
const events = [], patchCalls = [];
const discover = async () => {
  events.push(discovers++ === 0 ? 'discover' : 'rediscover');
  return {
    uv: { available: true, path: '/stand-in/uv', version: '0.12.10' },
    python: { available: true, path: '/stand-in/python3', version: '3.12.12' },
    omnigent: installed ? { available: true, path: managed, version: '0.16.0' } : { available: false, path: null },
  };
};
const run = async (command, args, options = {}) => {
  if (args[0] === 'tool' && args[1] === 'install') {
    events.push('uv-install');
    if (scenario === 'uv-fails') return { code: 1, stdout: '', stderr: 'boom' };
    installed = true;
  } else if (args[0] === '--version' && command === managed) {
    events.push('first-run');
  } else if (command === path.join(tool, 'bin', 'python')) {
    events.push('patch'); patchCalls.push({ command, args, timeoutMs: options.timeoutMs });
    if (scenario === 'patch-throws') throw new Error('spawn failed');
    if (scenario === 'patch-exit1') return { code: 1, stdout: '', stderr: 'nope' };
  }
  return { code: 0, stdout: '', stderr: '' };
};
const env = { PATH: '/usr/bin:/bin', HOME: stateDir, ...(paHome ? { PI_AGENT_HOME: paHome } : {}) };
const result = await installDependencies({ env, home: stateDir, stateDir, run, discover, platform, arch, update: mode === 'update' });
console.log(JSON.stringify({ events, patchCalls, ok: result.ok, issues: result.issues, installed: result.installed, tool, paHome }));
JS
PAH="$WORK/pa-home"; mkdir -p "$PAH/bin"; printf '#!/usr/bin/env python3\n' > "$PAH/bin/omnigent-model-options-patch.py"
PAH_NOFILE="$WORK/pa-home-nofile"; mkdir -p "$PAH_NOFILE/bin"
LINUXP="$WORK/c-linux"; copy_plugin "$LINUXP"; "$NODE" "$HOOK" "$LINUXP" >/dev/null 2>&1
DARWINP="$WORK/c-darwin"; copy_plugin "$DARWINP"; "$NODE" "$DARWIN" "$DARWINP" >/dev/null 2>&1; "$NODE" "$HOOK" "$DARWINP" >/dev/null 2>&1
drive() {  # drive <plugin dir> <platform> <arch> <install|update|present> <scenario> <PI_AGENT_HOME or "">
  local state; state="$(mktemp -d "$WORK/state.XXXXXX")"
  PA_TEST_STATE="$state" PA_TEST_HOME="$6" "$NODE" "$WORK/drive.mjs" "$(installer_of "$1")" "$2" "$3" "$4" "$5" 2>&1
}
expect() {  # expect <name> <json> <js condition on o>
  if printf '%s' "$2" | "$NODE" -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(($3) ? 0 : 1)" 2>/dev/null; then ok "$1"
  else no "$1" "$2"; fi
}
WANT_ARGS="o.patchCalls.length === 1 && o.patchCalls[0].command === o.tool + '/bin/python' && o.patchCalls[0].args.join(' ') === '$PAH/bin/omnigent-model-options-patch.py --tool-dir ' + o.tool && o.patchCalls[0].timeoutMs <= 60000"
out="$(drive "$LINUXP" linux x64 install ok "$PAH")"
expect "install: the tool's own python runs the patch with --tool-dir <the tool>, once, with a limit" "$out" "$WANT_ARGS"
expect "...after the uv install and before the plugin looks at the result" "$out" "o.events.join(',') === 'discover,uv-install,patch,rediscover' && o.ok === true && o.installed.includes('omnigent')"
out="$(drive "$LINUXP" linux arm64 update ok "$PAH")"
expect "update (--force builds a new venv, so the patch went with the old one): patched again, in the same place" "$out" "o.events.join(',') === 'discover,uv-install,patch,rediscover' && $WANT_ARGS"
out="$(drive "$DARWINP" darwin x64 install ok "$PAH")"
expect "Intel Mac with the darwin patch: install, the first run, then the patch, then the result" "$out" "o.events.join(',') === 'discover,uv-install,first-run,patch,rediscover' && o.ok === true"
out="$(drive "$LINUXP" linux x64 install ok "")"
expect "PI_AGENT_HOME unset (the container images): nothing runs, the install is unchanged" "$out" "o.patchCalls.length === 0 && o.events.join(',') === 'discover,uv-install,rediscover' && o.ok === true"
out="$(drive "$LINUXP" linux x64 install ok "$PAH_NOFILE")"
expect "the patch file is not there: nothing runs, the install is unchanged" "$out" "o.patchCalls.length === 0 && o.ok === true"
out="$(drive "$LINUXP" linux x64 install patch-exit1 "$PAH")"
expect "the patch exits non-zero: the install still succeeds" "$out" "o.patchCalls.length === 1 && o.ok === true && o.issues.length === 0"
out="$(drive "$LINUXP" linux x64 install patch-throws "$PAH")"
expect "the patch cannot even start: the install still succeeds" "$out" "o.patchCalls.length === 1 && o.ok === true && o.issues.length === 0"
out="$(drive "$LINUXP" linux x64 present ok "$PAH")"
expect "omnigent already installed (nothing to install): the hook does not run -- pi-web-start.sh covers restarts" "$out" "o.patchCalls.length === 0 && o.events.join(',') === 'discover'"
out="$(drive "$LINUXP" linux x64 install uv-fails "$PAH")"
expect "the uv install fails: nothing is patched, and the failure is reported as before" "$out" "o.patchCalls.length === 0 && o.ok === false && o.issues.length >= 1"
out="$(drive "$PRISTINE" linux x64 install ok "$PAH")"
expect "the unpatched plugin never runs it (the edit is what does)" "$out" "o.patchCalls.length === 0"

echo "== D. install.sh: wire and fetch"
mkhome() {  # mkhome <dir>: a PI_AGENT_HOME with a node and the pristine plugin
  rm -rf "$1"; mkdir -p "$1/node/bin" "$1/plugins"; ln -s "$NODE" "$1/node/bin/node"; cp -R "$PRISTINE" "$1/plugins/pi-omnigent-plugin"
}
H="$WORK/d-wire"; mkhome "$H"
env -i PATH="$PATH" HOME="$HOME" PI_AGENT_HOME="$H" PI_AGENT_HOSTNAME=testbox.local bash "$HERE/install.sh" wire > "$WORK/d-wire.log" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -x "$H/bin/omnigent-plugin-model-options-hook-patch.mjs" ] && grep -qF "$MARK" "$(installer_of "$H/plugins/pi-omnigent-plugin")"; then ok "wire installs the patch script (executable) and patches the plugin tree"
else no "wire installs the patch script and patches the plugin tree" "rc=$rc $(tail -4 "$WORK/d-wire.log" | tr '\n' ' ' | cut -c1-260)"; fi
before="$(sha256_file "$(installer_of "$H/plugins/pi-omnigent-plugin")")"
env -i PATH="$PATH" HOME="$HOME" PI_AGENT_HOME="$H" PI_AGENT_HOSTNAME=testbox.local bash "$HERE/install.sh" wire > "$WORK/d-wire2.log" 2>&1
if [ "$(sha256_file "$(installer_of "$H/plugins/pi-omnigent-plugin")")" = "$before" ] && grep -q "model-options-hook-patch\] installer.mjs: already patched" "$WORK/d-wire2.log"; then ok "wire twice: the second run changes nothing"
else no "wire twice: the second run changes nothing" "$(grep -i "model-options-hook" "$WORK/d-wire2.log" | head -2 | tr '\n' ' ')"; fi
PASEO_TGZ="$(fetch_pinned "$PIN_PASEO_PLUGIN_TGZ" "$PIN_PASEO_PLUGIN_SHA256" "${PA_TEST_PASEO_TGZ:-}" "woowtech-pi-paseo-$PIN_PASEO_PLUGIN_VERSION.tgz" 2>/dev/null)" || PASEO_TGZ=""
if [ -z "$PASEO_TGZ" ]; then skip "fetch from file:// copies of the pinned tarballs: the paseo plugin could not be fetched (set PA_TEST_PASEO_TGZ)"
else
  COPY="$WORK/d-copy"; mkdir -p "$COPY"; cp -R "$HERE/lib" "$HERE/rootfs" "$COPY/"; cp "$HERE/install.sh" "$COPY/"
  sed -i.bak -e "s#^PIN_OMNIGENT_PLUGIN_TGZ=.*#PIN_OMNIGENT_PLUGIN_TGZ=\"file://$OMNI_TGZ\"#" -e "s#^PIN_PASEO_PLUGIN_TGZ=.*#PIN_PASEO_PLUGIN_TGZ=\"file://$PASEO_TGZ\"#" "$COPY/lib/pins.sh"; rm -f "$COPY/lib/pins.sh.bak"
  F="$WORK/d-fetch"; rm -rf "$F"; mkdir -p "$F/node/bin"; ln -s "$NODE" "$F/node/bin/node"
  env -i PATH="$PATH" HOME="$HOME" PI_AGENT_HOME="$F" bash "$COPY/install.sh" fetch > "$WORK/d-fetch.log" 2>&1; rc=$?
  PI="$F/plugins/pi-omnigent-plugin"
  if [ "$rc" = 0 ] && grep -qF "$MARK" "$(installer_of "$PI")"; then ok "fetch (the real stage) patches the fresh plugin tree"
  else no "fetch (the real stage) patches the fresh plugin tree" "rc=$rc $(tail -3 "$WORK/d-fetch.log" | tr '\n' ' ' | cut -c1-240)"; fi
  printf '\n// local edit that a re-fetch must discard\n' >> "$(installer_of "$PI")"
  env -i PATH="$PATH" HOME="$HOME" PI_AGENT_HOME="$F" bash "$COPY/install.sh" fetch > "$WORK/d-fetch2.log" 2>&1
  if grep -qF "$MARK" "$(installer_of "$PI")" && ! grep -q "local edit that a re-fetch" "$(installer_of "$PI")"; then ok "...and again after the tree is replaced"
  else no "...and again after the tree is replaced" "$(tail -3 "$WORK/d-fetch2.log" | tr '\n' ' ' | cut -c1-240)"; fi
fi

echo "== E. pi-web-start.sh applies it at every start"
S="$WORK/e-start"; rm -rf "$S"; mkdir -p "$S/bin" "$S/node/bin" "$S/plugins" "$S/piweb/lib/node_modules/@agegr/pi-web/bin"
ln -s "$NODE" "$S/node/bin/node"; cp -R "$PRISTINE" "$S/plugins/pi-omnigent-plugin"
for f in pi-agent-env.sh pi-web-start.sh pi-agent-share-state.mjs omnigent-plugin-model-options-hook-patch.mjs; do cp "$HERE/rootfs/bin/$f" "$S/bin/$f"; done
chmod +x "$S/bin/pi-web-start.sh"; echo 'process.exit(0)' > "$S/piweb/lib/node_modules/@agegr/pi-web/bin/pi-web.js"
start() { env -i PATH="$PATH" PI_AGENT_HOME="$S" HOME="$WORK" bash "$S/bin/pi-web-start.sh" > "$1" 2>&1; }
start "$WORK/e1.log"; rc=$?
if [ "$rc" = 0 ] && grep -qF "$MARK" "$(installer_of "$S/plugins/pi-omnigent-plugin")" && grep -q "model-options-hook-patch\] .*patched" "$WORK/e1.log"; then ok "a start patches the plugin tree (and logs it with the [pi-web] prefix)"
else no "a start patches the plugin tree" "rc=$rc $(tail -3 "$WORK/e1.log" | tr '\n' ' ' | cut -c1-240)"; fi
rm -rf "$S/plugins/pi-omnigent-plugin"; cp -R "$PRISTINE" "$S/plugins/pi-omnigent-plugin"
start "$WORK/e2.log"
grep -qF "$MARK" "$(installer_of "$S/plugins/pi-omnigent-plugin")" && ok "a plugin tree re-extracted outside install.sh is covered again at the next start" || no "a plugin tree re-extracted outside install.sh is covered again at the next start" "$(tail -3 "$WORK/e2.log" | tr '\n' ' ' | cut -c1-240)"
before="$(sha256_file "$(installer_of "$S/plugins/pi-omnigent-plugin")")"; start "$WORK/e3.log"
[ "$(sha256_file "$(installer_of "$S/plugins/pi-omnigent-plugin")")" = "$before" ] && ok "...and a start over a patched tree changes nothing" || no "a start over a patched tree changes nothing" "differs"

echo
printf 'model-options hook: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
