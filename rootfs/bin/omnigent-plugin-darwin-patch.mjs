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
 * the flock/`/proc` code the plugin also carries is not on it.
 *
 * The second edit drops the bubblewrap warning on darwin: bwrap is a Linux
 * namespace tool that cannot exist on macOS, so the advice ("add it to the
 * container image") is noise on a laptop.
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

const log = (m) => console.log(`[omnigent-plugin-darwin-patch] ${m}`);

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

  const target = path.join(root, 'src', 'installer.mjs');
  let source;
  try { source = fs.readFileSync(target, 'utf8'); }
  catch (error) { log(`cannot read ${target} (${error.code ?? error.message}) — skipping`); return 0; }

  if (source.includes(GATE_NEW)) { log('already patched — no change'); return 0; }

  // Exact anchors, counted: a moved or re-spelled gate must be re-inspected
  // rather than silently half-patched.
  for (const [name, anchor] of [['platform gate', GATE_OLD], ['refusal message', MSG_OLD]]) {
    const hits = source.split(anchor).length - 1;
    if (hits !== 1) { log(`expected exactly 1 ${name}, found ${hits} — leaving the plugin alone`); return 0; }
  }

  let patched = source.replace(GATE_OLD, GATE_NEW).replace(MSG_OLD, MSG_NEW);
  if (patched.split(BWRAP_OLD).length - 1 === 1) patched = patched.replace(BWRAP_OLD, BWRAP_NEW);
  else log('bwrap warning not found in the expected shape; leaving it (cosmetic only)');

  const backup = `${target}.orig`;
  try {
    if (!fs.existsSync(backup)) { fs.copyFileSync(target, backup); log(`kept the pristine file as ${path.basename(backup)}`); }
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

process.exit(main());
