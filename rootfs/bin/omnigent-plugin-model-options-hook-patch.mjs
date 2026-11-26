#!/usr/bin/env node
/**
 * Apply the Pi model-options patch to the omnigent the plugin installs, at the moment it installs it.
 *
 * What goes wrong without it. omnigent-model-options-patch.py teaches Omnigent's Pi model picker to ask
 * `pi --list-models`, so models a gateway (LiteLLM, Ollama, vLLM) declares in models.json show up. It must be
 * on disk BEFORE the Omnigent host starts, because the host loads the module once and keeps it for its whole
 * life -- a pi-web restart does not restart the host. pi-web-start.sh applies it at every service start, to the
 * omnigent the plugin installed under data/omnigent-plugin/uv/tools/omnigent. On a fresh install that omnigent
 * does not exist yet at the first start: the plugin installs it a few seconds later (from its boot, or from
 * `pi-omnigent connect`), and the start script has already skipped the step ("until the plugin has installed
 * omnigent there is nothing to patch"). The first host is then started from an unpatched module, Pi shows
 * `ready: false` and no models in Omnigent, and a service restart does not change that: only a restart of the
 * host does. The same happens whenever the plugin reinstalls omnigent (`uv tool install --force` builds a new
 * venv, and the patch went with the old one).
 *
 * The fix is one edit to src/installer.mjs: right after a successful `uv tool install`, before the plugin
 * looks at the result and so before anything can start a host from it, run the patch with the tool's own
 * interpreter -- the same command, the same interpreter, as pi-web-start.sh. Whatever process performs the
 * install does it (pi-web's boot, `pi-omnigent connect`, `pi-omnigent install-dependencies`), so no ordering
 * between processes has to be won.
 *
 * What it needs is already in the plugin's environment: PI_AGENT_HOME (pi-agent-env.sh exports it to pi-web
 * and to the pi-omnigent wrapper). It is inert when PI_AGENT_HOME is unset or the patch file is not there --
 * the container images bake an omnigent into the image and never run this install path -- and it never fails
 * the install: the patch is a convenience, and pi-web-start.sh still applies it at the next start.
 *
 * Like the darwin patch beside it, this belongs upstream in WOOWTECH/pi-omnigent-plugin and is applied here
 * only until a release carries it: version-gated, exact-anchor, idempotent, keeps a .orig, never fails the
 * install. It composes with the darwin patch in either order (both insert before the same anchor, each with
 * its own marker).
 */
import fs from 'node:fs';
import path from 'node:path';

// 0.3.35+ maintenance-aware layout (0.3.36 adds only refusal reasons and the
// Agent Connect 0.1.21 adapter pin, 0.3.37 only the Agent Connect 0.1.22 combined
// adapter, 0.3.38 only the Agent Connect 0.1.23 combined adapter, 0.3.39 only the
// Agent Connect 0.1.24 combined adapter, 0.3.40 only the Agent Connect 0.1.25
// combined adapter; 0.3.41 adds the Agent Connect 0.1.26 startup UI fix. The
// 0.3.42-rc.1 candidate changes only package, changelog, README and adapter metadata.
// The exact candidate archive is locked in lib/pins.sh.
const EXPECTED_VERSIONS = ['0.3.31', '0.3.32', '0.3.33', '0.3.34', '0.3.35', '0.3.36', '0.3.37', '0.3.38', '0.3.39', '0.3.40', '0.3.41', '0.3.42-rc.1', '0.3.42-rc.2', '0.3.42-rc.3'];
const MAINTENANCE_AWARE_VERSIONS = ['0.3.35', '0.3.36', '0.3.37', '0.3.38', '0.3.39', '0.3.40', '0.3.41', '0.3.42-rc.1', '0.3.42-rc.2', '0.3.42-rc.3'];

// src/installer.mjs: the re-discovery right after the plugin's own `uv tool install omnigent`.
const HOOK_MARKER = 'model-options-hook (Woow native installer)';
const HOOK_OLD = `        discovery = { ...blankDiscovery(), ...await find(env, { fresh }) };
        if (discovery.omnigent?.available) {`;
const HOOK_NEW = `        // ${HOOK_MARKER}: no host has started from this omnigent yet. Patch it now, so
        // the first one loads the patched module -- pi-web-start.sh does the same at every
        // start, but on a fresh install the first start comes before this install.
        try {
          const patch = env.PI_AGENT_HOME && path.join(env.PI_AGENT_HOME, 'bin', 'omnigent-model-options-patch.py');
          const tool = path.join(stateDir, 'uv', 'tools', 'omnigent');
          if (patch) {
            await access(patch);
            await run(path.join(tool, 'bin', 'python'), [patch, '--tool-dir', tool], { env, cwd: stateDir, timeoutMs: 30_000 });
          }
        } catch {}
${HOOK_OLD}`;

const log = (m) => console.log(`[omnigent-plugin-model-options-hook-patch] ${m}`);

/** Replace anchored text in one plugin file, keeping a .orig. Never throws. */
function edit(root, relative, version, { marker, required }) {
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
  for (const [, anchor, replacement] of required) patched = patched.replace(anchor, () => replacement);

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
  if (!root) { console.error('usage: omnigent-plugin-model-options-hook-patch.mjs <plugin root>'); return 2; }

  let version;
  try { version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version; }
  catch (error) { log(`cannot read the plugin's package.json (${error.code ?? error.message}) — skipping`); return 0; }
  if (!EXPECTED_VERSIONS.includes(version)) {
    log(`plugin ${version} is installed but this patch was validated against ${EXPECTED_VERSIONS.join(', ')} — SKIPPING. Re-check whether the plugin still installs omnigent without patching it, then widen EXPECTED_VERSIONS.`);
    return 0;
  }

  if (MAINTENANCE_AWARE_VERSIONS.includes(version)) {
    let source;
    try { source = fs.readFileSync(path.join(root, 'src/installer.mjs'), 'utf8'); }
    catch { log('reviewed maintenance source unavailable — SKIPPING'); return 0; }
    const anchor = 'maintenancePreservation = await maintenance(discovery.omnigent, { stateDir, env, run })';
    if (source.split(anchor).length !== 2) { log('reviewed maintenance boundary differs — SKIPPING'); return 0; }
  }

  return edit(root, 'installer.mjs', version, {
    marker: HOOK_MARKER,
    required: [['re-discovery after the omnigent install', HOOK_OLD, HOOK_NEW]],
  });
}

process.exit(main());
