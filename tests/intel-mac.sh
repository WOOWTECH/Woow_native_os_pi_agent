#!/bin/bash
# Intel Macs: what lets the Omnigent plugin install its own omnigent there.
#
# Why this exists. On an Intel Mac the plugin's `uv tool install omnigent==<pin>` resolves afresh and picks
# cryptography >= 49 and argon2-cffi-bindings 26, which publish no x86_64 macOS wheel. uv falls back to their
# sdists, the cryptography build fails even with the Command Line Tools (its Rust crate finds no OpenSSL
# headers), and the Omnigent tab stays in DEPENDENCIES_MISSING -- found on the first two Intel Macs installed.
# Once that install works, a second Intel-only failure follows it: the first run of the new omnigent takes
# 4-6 s there, and the plugin probes it with a 5 s limit. This suite checks each piece and then the real thing:
#   A  vendor/omnigent-requirements.lock pins both twice: once for Intel Macs, once for everything else
#   B  the darwin patch makes the plugin pass --constraints "$PI_OMNIGENT_UV_CONSTRAINTS" to that install,
#      and on x64 run the new omnigent once, without the probe's limit, before probing it
#   C  pi-agent-env.sh sets the variable on Intel Macs, and nowhere else
#   D  with the pinned uv: the lock selects the right pins on this machine, and the Intel pins are still
#      uv's own answer to the command the lock's header documents
#   E  on an Intel Mac: the venv, a plain constrained install and the patched plugin's own install all
#      succeed with source builds forbidden
#
#   tests/intel-mac.sh
#
# A-C are hermetic: temp directories and the pinned plugin tarball (verified against lib/pins.sh), nothing
# else. D needs the pinned uv and the network; E needs an Intel Mac as well. Without them they are skipped.
#
# Environment (all optional):
#   PA_TEST_NODE          node to use (default: node on PATH, else the install's scoped node)
#   PA_TEST_UV            the pinned uv (default: the install's)
#   PA_TEST_PLUGIN_TGZ    a local copy of the pinned plugin tarball, for offline runs (still verified)
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
die()  { printf 'intel-mac tests: %s\n' "$*" >&2; exit 2; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# relay: the node checks print "ok <name>" or "no <name>\t<detail>"; count them here.
relay() {
  local line
  while IFS= read -r line; do
    case "$line" in
      ok\ *) ok "${line#ok }" ;;
      no\ *) line="${line#no }"; no "${line%%	*}" "${line#*	}" ;;
      *)     printf '        %s\n' "$line" ;;
    esac
  done
}

# Where to LOOK (read-only) for node and uv when none is given: an existing install's.
INSTALL_HOME="${PA_TEST_INSTALL_HOME:-${PI_AGENT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-agent}}"
unset PI_AGENT_HOME PI_AGENT_DATA_DIR PI_OMNIGENT_UV_CONSTRAINTS UV_CONSTRAINT

NODE="${PA_TEST_NODE:-$(command -v node || true)}"
[ -x "$NODE" ] || NODE="$INSTALL_HOME/node/bin/node"
[ -x "$NODE" ] || die "no node found (set PA_TEST_NODE)"

LOCK="$HERE/vendor/omnigent-requirements.lock"
INTEL="platform_machine == 'x86_64' and sys_platform == 'darwin'"
NOT_INTEL="platform_machine != 'x86_64' or sys_platform != 'darwin'"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pi-agent-intel-test.XXXXXX")" || die "cannot create a work directory"
cleanup() { [ "${PA_TEST_KEEP:-}" = 1 ] && { echo "kept: $WORK"; return; }; rm -rf "${WORK:?}"; }
trap cleanup EXIT
CACHE="${PA_TEST_CACHE:-${TMPDIR:-/tmp}/pi-agent-test-cache}"
mkdir -p "$CACHE"

# --- the pinned plugin, verified before use ---------------------------------------------
TGZ="${PA_TEST_PLUGIN_TGZ:-$CACHE/woowtech-pi-omnigent-plugin-$PIN_OMNIGENT_PLUGIN_VERSION.tgz}"
if [ ! -f "$TGZ" ] || [ "$(sha256_file "$TGZ")" != "$PIN_OMNIGENT_PLUGIN_SHA256" ]; then
  [ -z "${PA_TEST_PLUGIN_TGZ:-}" ] || die "PA_TEST_PLUGIN_TGZ does not match the pinned sha256 $PIN_OMNIGENT_PLUGIN_SHA256"
  echo "fetching $PIN_OMNIGENT_PLUGIN_TGZ"
  curl -fsSL --retry 3 -o "$TGZ.part" "$PIN_OMNIGENT_PLUGIN_TGZ" || die "cannot download the pinned plugin"
  got="$(sha256_file "$TGZ.part")"
  [ "$got" = "$PIN_OMNIGENT_PLUGIN_SHA256" ] || { rm -f "$TGZ.part"; die "sha256 of the downloaded plugin is $got, lib/pins.sh pins $PIN_OMNIGENT_PLUGIN_SHA256 -- refusing to use it"; }
  mv "$TGZ.part" "$TGZ"
fi
PRISTINE="$WORK/pristine"; mkdir -p "$PRISTINE"
tar xzf "$TGZ" --strip-components=1 -C "$PRISTINE" || die "cannot unpack the plugin"

echo "== A. the lock: two complementary pins for each package without an x86_64 macOS wheel, nothing else marked"
# Through a file, not a pipe: the counters must be updated in this shell (bash 3.2 has no lastpipe).
cat > "$WORK/lock-check.cjs" <<'JS'
const fs = require('fs');
const [file, INTEL, NOT_INTEL] = process.argv.slice(2);
const lines = fs.readFileSync(file, 'utf8').split('\n');
const pins = [];
lines.forEach((line, i) => {
  const m = /^([A-Za-z0-9._-]+)==([^\s;\\]+)(?: ; ([^\\]*?))?\s*(?:\\)?$/.exec(line);
  if (m) pins.push({ name: m[1].toLowerCase(), version: m[2], marker: m[3] || '',
    hashed: /^\s+--hash=sha256:[0-9a-f]{64}/.test(lines[i + 1] || '') });
});
const say = (pass, name, detail = '') => console.log(pass ? `ok ${name}` : `no ${name}\t${detail}`);
for (const name of ['cryptography', 'argon2-cffi-bindings']) {
  const mine = pins.filter(p => p.name === name);
  const intel = mine.filter(p => p.marker === INTEL), rest = mine.filter(p => p.marker === NOT_INTEL);
  say(mine.length === 2 && intel.length === 1 && rest.length === 1,
    `${name}: one pin for Intel Macs, one for every other platform`, JSON.stringify(mine));
  if (intel.length === 1 && rest.length === 1)
    say(intel[0].version !== rest[0].version, `${name}: the two pins differ (Intel ${intel[0].version}, elsewhere ${rest[0].version})`);
}
const marked = pins.filter(p => p.marker && !['cryptography', 'argon2-cffi-bindings'].includes(p.name));
say(marked.length === 0, 'no other pin carries a marker', marked.map(p => p.name).join(', '));
const unmarked = pins.filter(p => !p.marker).map(p => p.name);
const twice = unmarked.filter((n, i) => unmarked.indexOf(n) !== i);
say(twice.length === 0, 'every other package is pinned exactly once', twice.join(', '));
const bare = pins.filter(p => !p.hashed);
say(bare.length === 0, `all ${pins.length} pins carry sha256 hashes (the omnigent stage installs with --require-hashes)`, bare.map(p => p.name).join(', '));
JS
"$NODE" "$WORK/lock-check.cjs" "$LOCK" "$INTEL" "$NOT_INTEL" > "$WORK/lock-check.out" 2>&1
relay < "$WORK/lock-check.out"

echo "== B. the darwin patch: --constraints for the plugin's own uv install, and a first run before its probe"
PATCH="$HERE/rootfs/bin/omnigent-plugin-darwin-patch.mjs"
P="$WORK/patched"; cp -R "$PRISTINE" "$P"
"$NODE" "$PATCH" "$P" > "$WORK/patch1.log" 2>&1
if grep -q "uv-constraints (Woow native installer)" "$P/src/installer.mjs" \
   && grep -qF "args.push('--constraints', env.PI_OMNIGENT_UV_CONSTRAINTS)" "$P/src/installer.mjs" \
   && grep -q "first-launch (Woow native installer)" "$P/src/installer.mjs"; then
  ok "both edits are in src/installer.mjs (plugin $PIN_OMNIGENT_PLUGIN_VERSION)"
else
  no "both edits are in src/installer.mjs (plugin $PIN_OMNIGENT_PLUGIN_VERSION)" "$(tr '\n' ' ' < "$WORK/patch1.log" | cut -c1-300)"
fi
before="$(sha256_file "$P/src/installer.mjs")"
"$NODE" "$PATCH" "$P" > "$WORK/patch2.log" 2>&1
if [ "$(sha256_file "$P/src/installer.mjs")" = "$before" ] && ! grep -q '\] patched ' "$WORK/patch2.log"; then
  ok "a second run changes nothing (every edit reports already patched)"
else
  no "a second run changes nothing (every edit reports already patched)" "$(tr '\n' ' ' < "$WORK/patch2.log" | cut -c1-300)"
fi

# Drive the real installDependencies() with a stand-in uv: record every command it would run.
cat > "$WORK/drive.mjs" <<'JS'
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [installer, platform, arch, constraints, mode] = process.argv.slice(2);
const { installDependencies } = await import(pathToFileURL(installer).href);
const stateDir = process.env.PA_TEST_STATE;
const managed = path.join(stateDir, 'bin', 'omnigent');
let installed = mode === 'update';
const discover = async () => ({
  uv: { available: true, path: '/stand-in/uv', version: '0.12.10' },
  python: { available: true, path: '/stand-in/python3', version: '3.12.12' },
  omnigent: installed ? { available: true, path: managed, version: '0.16.0' } : { available: false, path: null },
});
const calls = [];
const run = async (command, args, options = {}) => {
  calls.push({ command, args, timeoutMs: options.timeoutMs });
  if (args[0] === 'tool') installed = true;
  return { code: 0, stdout: '', stderr: '' };
};
const env = { PATH: '/usr/bin:/bin', HOME: stateDir, ...(constraints ? { PI_OMNIGENT_UV_CONSTRAINTS: constraints } : {}) };
const result = await installDependencies({ env, home: stateDir, stateDir, run, discover, platform, arch, update: mode === 'update' });
const at = calls.findIndex(c => c.args[0] === 'tool' && c.args[1] === 'install');
console.log(JSON.stringify({ argv: at >= 0 ? calls[at].args : null,
  firstRun: calls.slice(at + 1).filter(c => c.command === managed && c.args[0] === '--version'), ok: result.ok, issues: result.issues }));
JS
drive() {  # drive <installer.mjs> <platform> <arch> <constraints or ""> <install|update>
  local state; state="$(mktemp -d "$WORK/state.XXXXXX")"
  PA_TEST_STATE="$state" "$NODE" "$WORK/drive.mjs" "$@" 2>&1
}
expect() {  # expect <name> <json> <node condition on o.argv / o.firstRun>
  if printf '%s' "$2" | "$NODE" -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(o.argv && ($3) ? 0 : 1)" 2>/dev/null; then ok "$1"
  else no "$1" "$2"; fi
}
C="$WORK/omnigent/requirements.lock"
out="$(drive "$P/src/installer.mjs" darwin x64 "$C" install)"
expect "Intel Mac, variable set: uv tool install gets --constraints <the lock>, ahead of the omnigent requirement" "$out" \
  "o.argv.indexOf('--constraints') >= 0 && o.argv[o.argv.indexOf('--constraints') + 1] === '$C' && o.argv.indexOf('--constraints') < o.argv.findIndex(a => a.startsWith('omnigent=='))"
expect "...then runs the new omnigent once with a limit well above the probe's 5 s, before probing it" "$out" \
  "o.firstRun.length === 1 && o.firstRun[0].timeoutMs >= 60000 && o.ok === true"
out="$(drive "$P/src/installer.mjs" darwin x64 "$C" update)"
expect "...and on the update path too (--force and --constraints, then the first run)" "$out" \
  "o.argv.includes('--force') && o.argv.includes('--constraints') && o.firstRun.length === 1"
out="$(drive "$P/src/installer.mjs" darwin x64 "" install)"
expect "variable unset: the command is unchanged (no --constraints)" "$out" "!o.argv.includes('--constraints')"
out="$(drive "$P/src/installer.mjs" darwin arm64 "" install)"
expect "Apple silicon: no first run before the probe (the install is unchanged there)" "$out" "o.firstRun.length === 0 && !o.argv.includes('--constraints')"
out="$(drive "$PRISTINE/src/installer.mjs" linux x64 "$C" install)"
expect "the unpatched plugin ignores the variable and does no first run (the edits are what do both)" "$out" \
  "!o.argv.includes('--constraints') && o.firstRun.length === 0"

echo "== C. pi-agent-env.sh sets PI_OMNIGENT_UV_CONSTRAINTS on Intel Macs, and nowhere else"
env_case() {  # env_case <uname -s> <uname -m> <lock present: 1|0>  -> the variable, empty when unset
  local h="$WORK/home-$1-$2-$3" fake="$WORK/uname-$1-$2"
  mkdir -p "$h/bin" "$h/omnigent" "$fake"
  [ "$3" = 1 ] && cp "$LOCK" "$h/omnigent/requirements.lock"
  printf '#!/bin/sh\ncase "$1" in -m) echo %s ;; *) echo %s ;; esac\n' "$2" "$1" > "$fake/uname"; chmod 755 "$fake/uname"
  env -i PATH="$fake:/usr/bin:/bin" PI_AGENT_HOME="$h" /bin/bash -c '. "$1" && printf "%s" "${PI_OMNIGENT_UV_CONSTRAINTS:-}"' _ "$HERE/rootfs/bin/pi-agent-env.sh"
}
v="$(env_case Darwin x86_64 1)"
[ "$v" = "$WORK/home-Darwin-x86_64-1/omnigent/requirements.lock" ] && ok "Intel Mac: set, to the lock the omnigent stage kept" || no "Intel Mac: set, to the lock the omnigent stage kept" "got '$v'"
v="$(env_case Darwin x86_64 0)"
[ -z "$v" ] && ok "Intel Mac before the omnigent stage ran (no lock yet): unset" || no "Intel Mac before the omnigent stage ran (no lock yet): unset" "got '$v'"
v="$(env_case Darwin arm64 1)"
[ -z "$v" ] && ok "Apple silicon Mac: unset" || no "Apple silicon Mac: unset" "got '$v'"
v="$(env_case Linux x86_64 1)"
[ -z "$v" ] && ok "Linux x86_64: unset" || no "Linux x86_64: unset" "got '$v'"

UV=""
for c in "${PA_TEST_UV:-}" "$INSTALL_HOME/bin/uv"; do
  [ -n "$c" ] && [ -x "$c" ] && [ "$("$c" --version 2>/dev/null | awk '{print $2}')" = "$PIN_UV_VERSION" ] && { UV="$c"; break; }
done
NET=0; curl -fsS -o /dev/null --max-time 15 https://pypi.org/simple/cryptography/ 2>/dev/null && NET=1
IS_INTEL=0; [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ] && IS_INTEL=1
pin_of() {  # pin_of <package> <marker or ""> -> its version in the lock
  "$NODE" -e '
    const [file, name, marker] = process.argv.slice(1);
    for (const l of require("fs").readFileSync(file, "utf8").split("\n")) {
      const m = /^([A-Za-z0-9._-]+)==([^\s;\\]+)(?: ; ([^\\]*?))?\s*(?:\\)?$/.exec(l);
      if (m && m[1].toLowerCase() === name && (m[3] || "") === marker) { console.log(m[2]); break; }
    }' "$LOCK" "$1" "$2"
}

echo "== D. with the pinned uv: what the lock installs here, and where the Intel pins come from"
if [ -z "$UV" ] || [ "$NET" = 0 ]; then
  skip "needs uv $PIN_UV_VERSION (set PA_TEST_UV) and access to pypi.org"
else
  export UV_CACHE_DIR="$CACHE/uv-cache" UV_PYTHON_INSTALL_DIR="$CACHE/python"
  "$UV" venv -q --python "$PIN_PYTHON_VERSION" "$WORK/venv" > "$WORK/venv.log" 2>&1 || no "a $PIN_PYTHON_VERSION venv to install into" "$(tail -2 "$WORK/venv.log")"
  if [ "$IS_INTEL" = 1 ]; then want_c="$(pin_of cryptography "$INTEL")"; want_a="$(pin_of argon2-cffi-bindings "$INTEL")"; where="this Intel Mac"
  else want_c="$(pin_of cryptography "$NOT_INTEL")"; want_a="$(pin_of argon2-cffi-bindings "$NOT_INTEL")"; where="this $(uname -s) $(uname -m) machine"; fi
  "$UV" pip sync --dry-run --python "$WORK/venv/bin/python" --require-hashes "$LOCK" > "$WORK/dry.log" 2>&1
  if grep -qx " + cryptography==$want_c" "$WORK/dry.log" && grep -qx " + argon2-cffi-bindings==$want_a" "$WORK/dry.log"; then
    ok "on $where the lock installs cryptography $want_c and argon2-cffi-bindings $want_a"
  else
    no "on $where the lock installs cryptography $want_c and argon2-cffi-bindings $want_a" "$(grep -E 'cryptography|argon2|error' "$WORK/dry.log" | tr '\n' ' ')"
  fi
  n="$("$NODE" -e 'const s=new Set(); for (const l of require("fs").readFileSync(process.argv[1],"utf8").split("\n")) { const m=/^([A-Za-z0-9._-]+)==/.exec(l); if (m) s.add(m[1].toLowerCase()); } console.log(s.size)' "$LOCK")"
  grep -q "Would install $n packages" "$WORK/dry.log" && ok "...$n packages, one pin of each" || no "...$n packages, one pin of each" "$(grep 'Would install' "$WORK/dry.log")"

  # The header's derivation, rerun: the other pins as constraints, wheels only, for an Intel Mac.
  echo "omnigent==$PIN_OMNIGENT_VERSION" > "$WORK/requirements.in"
  "$NODE" -e '
    for (const l of require("fs").readFileSync(process.argv[1], "utf8").split("\n")) {
      const m = /^([A-Za-z0-9._-]+)==([^\s;\\]+)/.exec(l);
      if (m && !["cryptography", "argon2-cffi-bindings"].includes(m[1].toLowerCase())) console.log(`${m[1]}==${m[2]}`);
    }' "$LOCK" > "$WORK/others.txt"
  MACOSX_DEPLOYMENT_TARGET=13.0 "$UV" pip compile -q "$WORK/requirements.in" -c "$WORK/others.txt" \
    --python-version 3.12 --python-platform x86_64-apple-darwin --only-binary :all: --generate-hashes \
    --no-header -o "$WORK/intel.lock" > "$WORK/compile.log" 2>&1
  hashes_of() {  # hashes_of <file> <package> <marker or ""> -> its sorted sha256 list
    "$NODE" -e '
      const [file, name, marker] = process.argv.slice(1); const lines = require("fs").readFileSync(file, "utf8").split("\n");
      const at = lines.findIndex(l => { const m = /^([A-Za-z0-9._-]+)==[^\s;\\]+(?: ; ([^\\]*?))?\s*(?:\\)?$/.exec(l); return m && m[1].toLowerCase() === name && (m[2] || "") === marker; });
      const out = []; for (let i = at + 1; at >= 0 && i < lines.length && /^\s+--hash=/.test(lines[i]); i++) out.push(lines[i].trim().replace(/ \\$/, ""));
      console.log(out.sort().join(" "));' "$1" "$2" "$3"
  }
  for p in cryptography argon2-cffi-bindings; do
    mine="$(pin_of "$p" "$INTEL")"; theirs="$("$NODE" -e '
      for (const l of require("fs").readFileSync(process.argv[1], "utf8").split("\n")) { const m = /^([A-Za-z0-9._-]+)==([^\s;\\]+)/.exec(l); if (m && m[1].toLowerCase() === process.argv[2]) { console.log(m[2]); break; } }' "$WORK/intel.lock" "$p" 2>/dev/null)"
    if [ -n "$mine" ] && [ "$mine" = "$theirs" ] && [ "$(hashes_of "$LOCK" "$p" "$INTEL")" = "$(hashes_of "$WORK/intel.lock" "$p" "")" ]; then
      ok "$p: the Intel pin ($mine) and its hashes are exactly uv's answer to the lock header's command"
    else
      no "$p: the Intel pin ($mine) and its hashes are exactly uv's answer to the lock header's command" "uv resolves ${theirs:-nothing}: $(tail -2 "$WORK/compile.log" | tr '\n' ' ')"
    fi
  done
  # And the premise: resolved afresh, as the unpatched plugin does, an Intel Mac gets other releases.
  MACOSX_DEPLOYMENT_TARGET=13.0 "$UV" pip compile -q "$WORK/requirements.in" --python-version 3.12 \
    --python-platform x86_64-apple-darwin --no-header -o "$WORK/fresh.txt" > "$WORK/fresh.log" 2>&1
  fresh_c="$(sed -n 's/^cryptography==\([^ ]*\).*/\1/p' "$WORK/fresh.txt")"; fresh_a="$(sed -n 's/^argon2-cffi-bindings==\([^ ]*\).*/\1/p' "$WORK/fresh.txt")"
  if [ -n "$fresh_c$fresh_a" ] && { [ "$fresh_c" != "$(pin_of cryptography "$INTEL")" ] || [ "$fresh_a" != "$(pin_of argon2-cffi-bindings "$INTEL")" ]; }; then
    ok "still needed: a fresh resolution for an Intel Mac picks cryptography $fresh_c, argon2-cffi-bindings $fresh_a (sdists there)"
  else
    no "still needed: a fresh resolution for an Intel Mac picks releases without an x86_64 wheel" "it picks cryptography ${fresh_c:-?}, argon2-cffi-bindings ${fresh_a:-?} -- if those now ship Intel wheels, the Intel pins and the patch edit can go"
  fi
fi

echo "== E. on an Intel Mac: the venv and the plugin's own install, with source builds forbidden"
if [ "$IS_INTEL" = 0 ] || [ -z "$UV" ] || [ "$NET" = 0 ]; then
  skip "needs an Intel Mac, uv $PIN_UV_VERSION and access to pypi.org"
else
  V='import importlib.metadata as m, sys; print(" ".join(m.version(p) for p in sys.argv[1:]))'
  want="$(pin_of cryptography "$INTEL") $(pin_of argon2-cffi-bindings "$INTEL") $PIN_OMNIGENT_VERSION"
  if "$UV" pip sync -q --python "$WORK/venv/bin/python" --require-hashes --no-build "$LOCK" > "$WORK/sync.log" 2>&1 \
     && [ "$("$WORK/venv/bin/python" -c "$V" cryptography argon2-cffi-bindings omnigent)" = "$want" ]; then
    ok "the omnigent stage's venv installs from wheels alone (cryptography, argon2-cffi-bindings, omnigent: $want)"
  else
    no "the omnigent stage's venv installs from wheels alone" "$(tail -3 "$WORK/sync.log" | tr '\n' ' ')"
  fi
  if UV_TOOL_DIR="$WORK/tools" UV_TOOL_BIN_DIR="$WORK/toolbin" "$UV" tool install -q --python "$PIN_PYTHON_VERSION" --no-build \
       --constraints "$LOCK" "omnigent==$PIN_OMNIGENT_VERSION" > "$WORK/tool.log" 2>&1 \
     && [ "$("$WORK/tools/omnigent/bin/python" -c "$V" cryptography argon2-cffi-bindings omnigent)" = "$want" ]; then
    ok "the plugin's own install, with the patch's --constraints, installs from wheels alone ($want)"
  else
    no "the plugin's own install, with the patch's --constraints, installs from wheels alone" "$(tail -3 "$WORK/tool.log" | tr '\n' ' ')"
  fi
  "$WORK/toolbin/omnigent" --version 2>/dev/null | grep -q "omnigent $PIN_OMNIGENT_VERSION" \
    && ok "...and the omnigent it installed runs" || no "...and the omnigent it installed runs" "$("$WORK/toolbin/omnigent" --version 2>&1 | head -1)"

  # The patched plugin itself: its installDependencies(), its own uv call and its own 5 s probe of the result.
  # Its state directory is fresh; its uv cache and Python directories are links to this suite's cache, which
  # only saves the downloads. PATH holds nothing but the pinned uv, so no installed omnigent can be found
  # instead of the one this installs.
  ST="$WORK/plugin-state"; mkdir -p "$ST" "$WORK/plugin-path" "$WORK/plugin-home"
  ln -s "$UV_CACHE_DIR" "$ST/uv-cache"; ln -s "$UV_PYTHON_INSTALL_DIR" "$ST/python"; ln -s "$UV" "$WORK/plugin-path/uv"
  cat > "$WORK/real.mjs" <<'JS'
import { pathToFileURL } from 'node:url';
const [installer, stateDir] = process.argv.slice(2);
const { installDependencies } = await import(pathToFileURL(installer).href);
const r = await installDependencies({ stateDir, home: process.env.HOME });
console.log(JSON.stringify({ ok: r.ok, issues: r.issues, installed: r.installed, version: r.omnigent && r.omnigent.version }));
JS
  out="$(env -i HOME="$WORK/plugin-home" PATH="$WORK/plugin-path:/usr/bin:/bin" PI_OMNIGENT_UV_CONSTRAINTS="$LOCK" UV_NO_BUILD=1 \
           "$NODE" "$WORK/real.mjs" "$P/src/installer.mjs" "$ST" 2>&1 | tail -1)"
  if printf '%s' "$out" | "$NODE" -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(o.ok === true && o.installed.includes('omnigent') && o.version === '$PIN_OMNIGENT_VERSION' ? 0 : 1)" 2>/dev/null; then
    ok "the patched plugin installs its omnigent and its own probe finds it: ok, omnigent $PIN_OMNIGENT_VERSION"
  else
    no "the patched plugin installs its omnigent and its own probe finds it" "$out"
  fi
fi

echo
printf 'intel mac: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
