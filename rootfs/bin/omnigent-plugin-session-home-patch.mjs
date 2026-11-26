#!/usr/bin/env node
/**
 * Let pi-omnigent-plugin start the Omnigent host with the user's own HOME.
 *
 * The plugin spawns `omnigent host` itself (src/omnigent.py), handing it a copy
 * of its own environment -- and pi-web, which hosts the plugin, runs with this
 * install's scoped HOME. So the host, every runner it forks and every harness
 * those start inherit the scoped HOME, and a conversation on this machine looks
 * for its MCP servers, plugins, git identity and SSH keys in an empty directory
 * instead of the user's home.
 *
 * Changing HOME only in the harness wrappers is not enough. omnigent's claude
 * harness resolves Claude's status files, settings.json, .claude.json and
 * projects/ from Path.home() inside the RUNNER -- two of them as import-time
 * constants (harnesses/claude_native/bridge.py, main.py) -- so the runner and the
 * harness must agree on one HOME, and the host is where it has to be set.
 *
 * With this edit, when PI_AGENT_SESSION_HOME is in the plugin's environment the
 * host is started with HOME set to it; unset, nothing changes, so the patch is
 * applied unconditionally. Host identity is unaffected: the plugin pins
 * OMNIGENT_CONFIG_HOME and OMNIGENT_DATA_DIR in that same environment, and
 * omnigent resolves the host config through them (host/identity.py ->
 * config.global_config_path). See docs/SESSION-HOME.md.
 *
 * Same discipline as the other plugin patches: version-gated, exact anchor
 * (counted), idempotent, keeps a .orig, never fails the caller.
 *
 *   omnigent-plugin-session-home-patch.mjs <plugin root>
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
const EXPECTED_VERSIONS = ['0.3.31', '0.3.32', '0.3.33', '0.3.34', '0.3.35', '0.3.36', '0.3.37', '0.3.38', '0.3.39', '0.3.40', '0.3.41', '0.3.42-rc.1'];
const MAINTENANCE_AWARE_VERSIONS = ['0.3.35', '0.3.36', '0.3.37', '0.3.38', '0.3.39', '0.3.40', '0.3.41', '0.3.42-rc.1'];
const MARKER = 'session-home (Woow native installer)';
const ANCHOR = '                environment["OMNIGENT_HOST_NO_OPEN"] = "1"\n';
const ADDITION = [
  `                # ${MARKER}: start the host with the user's own HOME when`,
  '                # PI_AGENT_SESSION_HOME is set; its runners and harnesses inherit it.',
  '                if os.environ.get("PI_AGENT_SESSION_HOME"):',
  '                    environment["HOME"] = os.environ["PI_AGENT_SESSION_HOME"]',
  '',
].join('\n');

const log = (m) => console.log(`[omnigent-plugin-session-home-patch] ${m}`);

function main() {
  const root = process.argv[2];
  if (!root) { console.error('usage: omnigent-plugin-session-home-patch.mjs <plugin root>'); return 2; }

  let version;
  try { version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version; }
  catch (error) { log(`cannot read the plugin's package.json (${error.code ?? error.message}) — skipping`); return 0; }

  const target = path.join(root, 'src', 'omnigent.py');
  let source;
  try { source = fs.readFileSync(target, 'utf8'); }
  catch (error) { log(`cannot read ${target} (${error.code ?? error.message}) — skipping`); return 0; }

  if (source.includes(MARKER)) { log('already patched — no change'); return 0; }
  if (!EXPECTED_VERSIONS.includes(version)) {
    log(`plugin ${version} is installed but this patch was validated against ${EXPECTED_VERSIONS.join(', ')} — SKIPPING. Sessions keep the scoped HOME until it is re-checked.`);
    return 0;
  }

  if (MAINTENANCE_AWARE_VERSIONS.includes(version)
      && (source.split('launch = self.require_maintenance_preservation()').length !== 2
          || source.split('subprocess.Popen([launch["pythonExecutable"], "-I", "-B", launch["consoleScript"], "host"').length !== 2)) {
    log('reviewed maintenance/validated-spawn boundary differs — SKIPPING'); return 0;
  }

  // Counted, exact anchor: a moved or re-indented spawn must be re-inspected
  // rather than half-patched into a Python file that no longer parses.
  const hits = source.split(ANCHOR).length - 1;
  if (hits !== 1) { log(`expected exactly 1 host-spawn anchor, found ${hits} — leaving the plugin alone`); return 0; }

  const backup = `${target}.orig`;
  try {
    if (!fs.existsSync(backup)) { fs.copyFileSync(target, backup); log(`kept the pristine file as ${path.basename(backup)}`); }
    const tmp = `${target}.patch-tmp`;
    fs.writeFileSync(tmp, source.replace(ANCHOR, ANCHOR + ADDITION));
    fs.renameSync(tmp, target);
  } catch (error) {
    log(`cannot write beside ${target} (${error.code ?? error.message}) — read-only install, patch it at build time`);
    return 0;
  }
  log(`patched ${target} (plugin ${version})`);
  return 0;
}

process.exit(main());
