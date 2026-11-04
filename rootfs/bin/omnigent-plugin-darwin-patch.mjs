#!/usr/bin/env node
/**
 * Let pi-omnigent-plugin run on macOS.
 *
 * The plugin's dependency installer refuses any platform but Linux:
 *
 *     if (platform !== 'linux' || !['x64', 'arm64'].includes(arch)) {
 *       issues.push(`This plugin requires a Linux x64 or arm64 container ...`);
 *       return result();
 *     }
 *
 * That `return` happens before discovery, so on a Mac every dependency is
 * reported missing -- omnigent, uv, python, node and all three engines -- and
 * the Omnigent settings tab can never leave DEPENDENCIES_MISSING. Measured on
 * macOS 26.4 / M2: widening this one allow-list is enough for the plugin to
 * bootstrap its own uv + omnigent and find all three engines (`ok: true`,
 * `issues: []`). Nothing else in the plugin needed changing for that path --
 * the `/proc` code the plugin also carries is not on it.
 *
 * The lock, however, is. `locked()` in src/common.mjs looks for flock(1) at
 * exactly ['/usr/bin/flock', '/bin/flock'] and throws LOCK_UNAVAILABLE when
 * neither exists -- which is every Mac, and it blocks `pi-omnigent connect`
 * outright. macOS cannot be fixed by linking one in: /usr/bin is SIP-protected.
 * So the third edit adds a PATH fallback, which finds Homebrew's flock
 * (discoteq/flock 0.4.0, `brew install flock`). That keeps the KERNEL lock the
 * comment above `locked()` promises -- same binary contract, verified on macOS
 * 26.4/M2 with the plugin's own invocation: the holder prints LOCKED and a
 * second attempt exits 75. The `/proc`-based ownership fields degrade on their
 * own: processIdentity() is already wrapped in try/catch returning {}, and
 * legacyLockAlive() falls back to an mtime window, both upstream behaviour --
 * so no security check is weakened here, and none is skipped.
 *
 * The second edit drops the bubblewrap warning on darwin: bwrap is a Linux
 * namespace tool that cannot exist on macOS, so the advice ("add it to the
 * container image") is noise on a laptop.
 *
 * The fourth edit is for Intel Macs. The plugin installs its own omnigent with
 * `uv tool install omnigent==<pin>`, resolving afresh, and at their newest
 * releases two of omnigent's dependencies publish no x86_64 macOS wheel
 * (cryptography >= 49, argon2-cffi-bindings 26). uv then builds them from
 * sdists, and the cryptography build fails even with the Command Line Tools:
 * there are no OpenSSL headers to find. The edit adds
 * `--constraints $PI_OMNIGENT_UV_CONSTRAINTS` to that command when the variable
 * is set. pi-agent-env.sh sets it on Intel Macs only, to the hash-locked
 * requirements the omnigent stage installed from, which pin wheel-backed
 * releases for that platform. Measured on an Intel Mac (macOS 13.7, uv 0.12.10)
 * with source builds forbidden: the install succeeds with the constraints and
 * resolves cryptography 48.0.1 and argon2-cffi-bindings 25.1.0. Everywhere
 * else the variable is unset and the command is unchanged.
 *
 * The fifth edit is for Intel Macs too. Right after that install, discovery
 * probes the new omnigent with `--version` and a 5 s limit, and on an Intel
 * Mac the first run of a freshly installed omnigent takes 4-6 s (measured
 * twice on each of an i3 and an i5 MacBook: 4.0 to 6.1 s, then about 0.5 s on
 * every later run). Past the limit the install is reported as "uv finished, but the
 * managed Omnigent executable is unavailable" and the tab stays in
 * DEPENDENCIES_MISSING until something retries. The edit runs the new
 * omnigent once with a generous limit before that probe, on x64 only, so the
 * probe measures a warm start.
 *
 * This belongs upstream in WOOWTECH/pi-omnigent-plugin, and is applied here
 * only until a release carries it. Same discipline as the omnigent patch in
 * Woow_k3s_pi_agent_package: version-gated, exact-anchor, idempotent, keeps a
 * .orig, and never fails the install -- a Mac without it is a degraded
 * Omnigent tab, not a broken agent.
 */
import fs from 'node:fs';
import path from 'node:path';

const EXPECTED_VERSIONS = ['0.3.31'];

const GATE_OLD = "if (platform !== 'linux' || !['x64', 'arm64'].includes(arch)) {";
const GATE_NEW = "if (!['linux', 'darwin'].includes(platform) || !['x64', 'arm64'].includes(arch)) {";
const MSG_OLD = 'This plugin requires a Linux x64 or arm64 container';
const MSG_NEW = 'This plugin requires Linux or macOS on x64 or arm64';
const BWRAP_OLD = "if (!discovery.bwrap?.available) warnings.push(";
const BWRAP_NEW = "if (platform !== 'darwin' && !discovery.bwrap?.available) warnings.push(";

// src/installer.mjs: the plugin's own `uv tool install omnigent`.
const UV_MARKER = 'uv-constraints (Woow native installer)';
const UV_OLD = "if (action === 'update') args.push('--force');";
const UV_NEW = `if (action === 'update') args.push('--force');
      // ${UV_MARKER}: pi-agent-env.sh sets this on Intel Macs, where a fresh
      // resolution picks dependency releases with no x86_64 macOS wheel.
      if (env.PI_OMNIGENT_UV_CONSTRAINTS) args.push('--constraints', env.PI_OMNIGENT_UV_CONSTRAINTS);`;

// src/installer.mjs: the re-discovery right after that install.
const LAUNCH_MARKER = 'first-launch (Woow native installer)';
const LAUNCH_OLD = `        discovery = { ...blankDiscovery(), ...await find(env, { fresh }) };
        if (discovery.omnigent?.available) {`;
const LAUNCH_NEW = `        // ${LAUNCH_MARKER}: on an Intel Mac the first run of a freshly
        // installed omnigent takes 4-6 s, and discovery probes it with a 5 s
        // limit. Run it once without that limit, so the probe sees a warm start.
        if (arch === 'x64') {
          try { await run(path.join(stateDir, 'bin', 'omnigent'), ['--version'], { env: installEnv, cwd: stateDir, timeoutMs: 120_000 }); } catch {}
        }
        discovery = { ...blankDiscovery(), ...await find(env, { fresh }) };
        if (discovery.omnigent?.available) {`;

// src/common.mjs: flock(1) lookup inside locked().
const LOCK_MARKER = 'flock-path-fallback (Woow native installer)';
const LOCK_OLD = `  const executable = ['/usr/bin/flock', '/bin/flock'].find(candidate => fs.existsSync(candidate));
  if (!executable) throw Object.assign(new Error('Linux util-linux flock is required.'), { code: 'LOCK_UNAVAILABLE' });`;
const LOCK_NEW = `  // ${LOCK_MARKER}: macOS ships no flock(1), and /usr/bin is SIP-protected so
  // Homebrew's cannot be linked into the two paths below. PATH finds it there
  // instead -- same program, same -n -E contract, so this stays a kernel lock.
  const executable = ['/usr/bin/flock', '/bin/flock'].find(candidate => fs.existsSync(candidate))
    ?? (process.env.PATH || '').split(path.delimiter).filter(Boolean)
      .map(directory => path.join(directory, 'flock'))
      .find(candidate => { try { fs.accessSync(candidate, fs.constants.X_OK); return true; } catch { return false; } });
  if (!executable) throw Object.assign(new Error('flock(1) is required: util-linux on Linux, or \`brew install flock\` on macOS.'), { code: 'LOCK_UNAVAILABLE' });`;

const log = (m) => console.log(`[omnigent-plugin-darwin-patch] ${m}`);

/** Replace anchored text in one plugin file, keeping a .orig. Never throws. */
function edit(root, relative, version, { marker, required, optional = [] }) {
  const target = path.join(root, 'src', relative);
  let source;
  try { source = fs.readFileSync(target, 'utf8'); }
  catch (error) { log(`cannot read ${target} (${error.code ?? error.message}) — skipping`); return 0; }

  if (source.includes(marker)) { log(`${relative}: already patched — no change`); return 0; }

  // Exact anchors, counted: a moved or re-spelled anchor must be re-inspected
  // rather than silently half-patched.
  for (const [name, anchor] of required) {
    const hits = source.split(anchor).length - 1;
    if (hits !== 1) { log(`${relative}: expected exactly 1 ${name}, found ${hits} — leaving this file alone`); return 0; }
  }

  let patched = source;
  for (const [, anchor, replacement] of required) patched = patched.replace(anchor, replacement);
  for (const [name, anchor, replacement] of optional) {
    if (patched.split(anchor).length - 1 === 1) patched = patched.replace(anchor, replacement);
    else log(`${relative}: ${name} not found in the expected shape; leaving it (cosmetic only)`);
  }

  const backup = `${target}.orig`;
  try {
    if (!fs.existsSync(backup)) { fs.copyFileSync(target, backup); log(`${relative}: kept the pristine file as ${path.basename(backup)}`); }
    const tmp = `${target}.patch-tmp`;
    fs.writeFileSync(tmp, patched);
    fs.renameSync(tmp, target);
  } catch (error) {
    log(`cannot write beside ${target} (${error.code ?? error.message}) — read-only install, patch it at build time`);
    return 0;
  }
  log(`patched ${target} (plugin ${version})`);
  return 0;
}

function main() {
  const root = process.argv[2];
  if (!root) { console.error('usage: omnigent-plugin-darwin-patch.mjs <plugin root>'); return 2; }

  let version;
  try { version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version; }
  catch (error) { log(`cannot read the plugin's package.json (${error.code ?? error.message}) — skipping`); return 0; }
  if (!EXPECTED_VERSIONS.includes(version)) {
    log(`plugin ${version} is installed but this patch was validated against ${EXPECTED_VERSIONS.join(', ')} — SKIPPING. Re-check whether macOS still needs it, then widen EXPECTED_VERSIONS.`);
    return 0;
  }

  // The lock blocks `connect` on macOS; the installer gate blocks dependency
  // discovery. Independent files, so one failing never blocks the other.
  edit(root, 'common.mjs', version, {
    marker: LOCK_MARKER,
    required: [['flock lookup', LOCK_OLD, LOCK_NEW]],
  });

  edit(root, 'installer.mjs', version, {
    marker: GATE_NEW,
    required: [['platform gate', GATE_OLD, GATE_NEW], ['refusal message', MSG_OLD, MSG_NEW]],
    optional: [['bubblewrap warning', BWRAP_OLD, BWRAP_NEW]],
  });

  // Their own markers: each idempotent by itself, whether or not the others ran.
  edit(root, 'installer.mjs', version, {
    marker: UV_MARKER,
    required: [['uv tool install arguments', UV_OLD, UV_NEW]],
  });
  return edit(root, 'installer.mjs', version, {
    marker: LAUNCH_MARKER,
    required: [['re-discovery after the omnigent install', LAUNCH_OLD, LAUNCH_NEW]],
  });
}

process.exit(main());
