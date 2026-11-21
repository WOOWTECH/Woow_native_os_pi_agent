// Run only on a real Mac. The installer and installed wrappers are the test
// subject: no substituted CLI/provider binaries, launchctl or uname fixtures.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
assert.equal(process.platform, 'darwin', 'actual macOS required');
assert.equal(process.arch, process.env.NATIVE_MAC_ARCH);
const evidence = path.resolve(process.env.NATIVE_MAC_EVIDENCE);
fs.mkdirSync(evidence, { recursive: true });
// Darwin's per-user TMPDIR is too long for tmux/daemon Unix-domain sockets.
// mkdtemp still owns a private, unpredictable root; never use the user's HOME.
const scratch = fs.realpathSync(fs.mkdtempSync('/private/tmp/native-ci-'));
const account = path.join(scratch, 'account'), install = path.join(scratch, 'install');
for (const dir of [account, install, path.join(scratch, 'tmp')]) fs.mkdirSync(dir, { mode: 0o700 });
const label = `io.woowtech.pi-agent.ci-${process.pid}-${Date.now()}`;
const receipt = { platform: process.platform, arch: process.arch, source: '', stages: [], checks: {},
  providerTurns: 0, modelCredentials: false, signedPackage: false, userMacAcceptance: false,
  launchd: { label, ephemeral: true, domain: `gui/${process.getuid()}` }, success: false };
const save = () => fs.writeFileSync(path.join(evidence, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
const sha = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const read = file => JSON.parse(fs.readFileSync(file));
// Deliberate allowlist: never forward CI tokens, login homes or model credentials.
const env = { HOME: account, PATH: '/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR: path.join(scratch, 'tmp'),
  LANG: 'en_US.UTF-8', CI: '1', NEXT_TELEMETRY_DISABLED: '1', PI_AGENT_HOME: install,
  PI_AGENT_LINK_KEYCHAIN: '0', PI_AGENT_LAUNCHD_LABEL: label, PI_AGENT_LAUNCHD_EPHEMERAL: '1',
  npm_config_cache: path.join(scratch, 'npm-cache'), UV_CACHE_DIR: path.join(scratch, 'uv-cache'),
  DISABLE_AUTOUPDATER: '1', PI_TELEMETRY: '0', PI_SKIP_VERSION_CHECK: '1' };
function run(command, args = [], { output = false, timeout = 600000 } = {}) {
  const began = Date.now();
  const result = spawnSync(command, args, { cwd: repo, env, encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024 });
  if (output) fs.appendFileSync(path.join(evidence, 'installer.log'), (result.stdout || '') + (result.stderr || ''));
  if (result.status !== 0) {
    // Installed daemons/status may contain pairing data: keep their output private.
    let code = result.error?.code || 'COMMAND_FAILED';
    if (path.basename(command) === 'pi-paseo') {
      // Node's SQLite warning can precede the CLI's already-redacted JSON.
      for (const line of (result.stderr || '').split('\n')) {
        try { const reported = JSON.parse(line).code; if (/^[A-Z_]{1,64}$/.test(reported)) code = reported; } catch {}
      }
      receipt.commandFailure = { action: args[0], status: result.status, signal: result.signal, code, elapsedMs: Date.now() - began };
      receipt.failureState = lifecycleSnapshot();
    }
    throw new Error(`${path.basename(command)} ${args[0] || ''}: exit ${result.status}, ${code}`);
  }
  return (result.stdout || '').trim();
}
async function until(check, description, ms = 90000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await check()) return; await delay(1000); }
  throw new Error(`timeout: ${description}`);
}
async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve)); return port;
}
const webPort = await freePort(); env.PI_WEB_PORT = String(webPort);
const url = `http://127.0.0.1:${webPort}`;
async function webUp() {
  try { return (await fetch(url, { signal: AbortSignal.timeout(3000) })).ok; } catch { return false; }
}
const bin = name => path.join(install, 'bin', name);
function launchdGone() {
  const result = spawnSync('/bin/launchctl', ['print', `${receipt.launchd.domain}/${label}`],
    { env, encoding: 'utf8', timeout: 5000 });
  receipt.launchd.lastPrintExit = result.status;
  // A timed-out or unlaunchable inspection is not evidence of removal.
  return !result.error && Number.isInteger(result.status) && result.status !== 0;
}
let api, runtime, launchdAttempted = false;
function lifecycleSnapshot() {
  // Only enum values, process states and booleans; never copy config, identity,
  // args, environment or daemon logs into public CI artifacts.
  if (!runtime) return null;
  const loc = runtime.locations();
  const record = name => { try { return read(path.join(loc.stateDir, name)); } catch { return {}; } };
  const state = record('state.json'), supervisor = record('supervisor.json');
  const processState = pid => {
    if (!Number.isInteger(pid) || pid <= 1) return 'absent';
    const r = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { env, encoding: 'utf8' });
    const value = (r.stdout || '').trim();
    return r.status !== 0 ? 'absent' : /^[A-Za-z+<>-]{1,12}$/.test(value) ? value : 'unknown';
  };
  const runtimeLock = record('runtime.lock');
  return { phase: /^[a-z_]{1,40}$/.test(state.phase) ? state.phase : null,
    desiredEnabled: state.desiredEnabled === true,
    registrationEnabled: record('host-registration.json').enabled === true,
    supervisorProcess: processState(supervisor.pid), daemonProcess: processState(state.daemonPid),
    runtimeLockPresent: fs.existsSync(path.join(loc.stateDir, 'runtime.lock')),
    runtimeLockOwnerProcess: processState(runtimeLock.pid) };
}
function safeError(error) {
  return { name: ['Error', 'RuntimeError', 'AssertionError'].includes(error?.name) ? error.name : 'Error',
    code: /^[A-Z_]{1,64}$/.test(error?.code) ? error.code : 'UNKNOWN',
    supervisorStillStopping: error?.message === 'Plugin supervisor is still stopping' };
}
async function started(description) {
  // Reachable can precede completion of activate(). Wait for its final health
  // receipt AND released runtime lock before testing normal stop/restart.
  // This is not an interrupted-start/cancellation acceptance test.
  await until(async () => {
    const s = await api.status();
    return s.phase === 'running' && s.daemon.running && s.daemon.reachable &&
      s.state.lastDiagnostic?.daemonReachable === true &&
      !fs.existsSync(path.join(runtime.locations().stateDir, 'runtime.lock'));
  }, description, 180000);
}
try {
  receipt.source = run('/usr/bin/git', ['rev-parse', 'HEAD']); save();
  const pins = Object.fromEntries(run('/bin/bash', ['-c', '. lib/pins.sh; set | /usr/bin/grep ^PIN_']).split('\n').map(line => {
    const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1).replace(/^'|'$/g, '')];
  }));
  receipt.candidates = read(path.join(repo, 'candidate-packages/manifest.json')).artifacts;
  for (const row of receipt.candidates) assert.equal(sha(path.join(repo, 'candidate-packages', row.file)), row.sha256);
  for (const [prefix, filename] of [['SHARED_RUNTIME', 'woowtech-pi-agent-shared-runtime'], ['PASEO_PLUGIN', 'woowtech-pi-paseo'], ['OMNIGENT_PLUGIN', 'woowtech-pi-omnigent-plugin']]) {
    const row = receipt.candidates.find(row => row.file === `${filename}-${pins[`PIN_${prefix}_VERSION`]}.tgz`);
    assert.equal(row?.sha256, pins[`PIN_${prefix}_SHA256`]);
  }
  receipt.checks.archiveHashes = true;
  // Build the same bundled tmux used by the pkg. No brew/sudo/global installation.
  run('/bin/bash', ['scripts/build-macos-tmux.sh', path.join(repo, 'tools')], { output: true, timeout: 1200000 });
  for (const stage of ['preflight', 'node', 'fetch', 'piweb', 'clis', 'shared', 'paseo', 'omnigent', 'wire']) {
    console.log(`installer stage: ${stage}`);
    receipt.stages.push({ stage, status: 'running' }); save();
    run('/bin/bash', ['install.sh', stage], { output: true, timeout: 1800000 });
    receipt.stages.at(-1).status = 'passed'; save();
  }
  const node = path.join(install, 'node/bin/node');
  // Exercise the normal release-artifact path using this exact built graph.
  const artifacts = path.join(scratch, 'release-artifacts');
  run('/bin/bash', ['scripts/build-piweb-artifact.sh', artifacts], { output: true });
  const artifact = path.join(artifacts, `piweb-${pins.PIN_PI_WEB_VERSION}-macos-${process.arch}.tar.gz`);
  env.PI_AGENT_PIWEB_ARTIFACT = artifact;
  run('/bin/bash', ['install.sh', 'piweb'], { output: true });
  delete env.PI_AGENT_PIWEB_ARTIFACT;
  receipt.releaseArtifact = { sha256: sha(artifact),
    manifest: read(path.join(install, 'piweb/pi-agent-artifact.json')), installed: true };
  assert.equal(run(node, ['--version']), `v${pins.PIN_NODE_VERSION}`);
  const sdk = path.join(install, 'piweb/lib/node_modules/@agegr/pi-web');
  assert.equal(read(path.join(sdk, 'package.json')).version, pins.PIN_PI_WEB_VERSION);
  assert.equal(run('/usr/bin/git', ['-C', sdk, 'rev-parse', 'HEAD']), pins.PIN_PI_WEB_REF);
  run(node, ['-e', 'const p=require(process.argv[1]);const t=p.spawn("/bin/echo",["pty-ok"],{env:process.env});let out="";t.onData(s=>out+=s);t.onExit(()=>{if(!out.includes("pty-ok"))process.exitCode=1});', path.join(sdk, 'node_modules/node-pty')]);
  receipt.checks.nativePty = true;
  receipt.versions = { node: pins.PIN_NODE_VERSION, piweb: pins.PIN_PI_WEB_VERSION };
  const expectedPi = read(path.join(sdk, 'package.json')).dependencies['@earendil-works/pi-coding-agent'];
  assert.match(expectedPi, /^\d+\.\d+\.\d+$/);
  assert.equal(read(path.join(sdk, 'node_modules/@earendil-works/pi-coding-agent/package.json')).version, expectedPi);
  receipt.sdkGraph = { expectedPi, lockSha256: sha(path.join(sdk, 'package-lock.json')), combinedAdapterSha256: pins.PIN_OMNIGENT_UI_SHA256 };
  for (const [name, expected] of [['claude', pins.PIN_CLAUDE_VERSION], ['codex', pins.PIN_CODEX_VERSION], ['pi', expectedPi]]) {
    const actual = run(bin(name), ['--version']).match(/\d+\.\d+\.\d+/)?.[0];
    assert.equal(actual, expected, `${name} installed wrapper`); receipt.versions[name] = actual;
  }
  assert.equal(run(bin('tmux'), ['-V']), `tmux ${pins.PIN_TMUX_VERSION}`);
  assert.equal(run(path.join(install, 'omnigent/venv/bin/python'), ['-c', 'import importlib.metadata;print(importlib.metadata.version("omnigent"))']), pins.PIN_OMNIGENT_VERSION);
  run(path.join(install, 'omnigent/venv/bin/omnigent'), ['--help']);
  receipt.versions.omnigent = pins.PIN_OMNIGENT_VERSION;
  for (const [plugin, expected] of [['pi-omnigent-plugin', pins.PIN_OMNIGENT_PLUGIN_VERSION], ['pi-paseo-plugin', pins.PIN_PASEO_PLUGIN_VERSION]]) {
    assert.equal(read(path.join(install, 'plugins', plugin, 'package.json')).version, expected);
  }
  for (const [file, marker] of [['common.mjs', 'flock-path-fallback'], ['installer.mjs', "['linux', 'darwin'].includes(platform)"], ['installer.mjs', 'uv-constraints'], ['omnigent.py', 'no-proc-no-verdict']]) {
    assert.ok(fs.readFileSync(path.join(install, 'plugins/pi-omnigent-plugin/src', file), 'utf8').includes(marker), marker);
  }
  run(bin('flock'), ['-n', '-E', '75', path.join(scratch, 'flock-check'), '/bin/sh', '-c', 'exit 0']);
  receipt.checks.darwinWiring = true;
  assert.equal(fs.existsSync(path.join(install, 'home/Library/Keychains')), false);
  const settings = read(path.join(install, 'data/settings.json'));
  for (const plugin of ['pi-paseo-plugin', 'pi-omnigent-plugin']) assert.ok(settings.packages.includes(path.join(install, 'plugins', plugin)));
  assert.equal(sha(path.join(install, 'plugins/pi-omnigent-plugin/integrations/pi-web/combined.adapter.patch')), pins.PIN_OMNIGENT_UI_SHA256);
  const combined = read(path.join(install, 'plugins/pi-omnigent-plugin/integrations/pi-web/combined.adapter-meta.json'));
  assert.equal(combined.baseCommit, pins.PIN_PI_WEB_REF);
  assert.equal(combined.piWebVersion, pins.PIN_PI_WEB_VERSION);
  assert.equal(combined.patchSha256, pins.PIN_OMNIGENT_UI_SHA256);
  assert.equal(combined.paseo.packageVersion, pins.PIN_PASEO_PLUGIN_VERSION);
  assert.equal(combined.omnigent.packageVersion, pins.PIN_OMNIGENT_PLUGIN_VERSION);
  assert.equal(combined.paseo.adapterPatchSha256, sha(path.join(install, 'plugins/pi-paseo-plugin/host/adapter.patch')));
  receipt.checks.combinedCandidateMetadata = true;
  // Source only the installed native environment before importing the installed API.
  const scopedEnv = JSON.parse(run('/bin/bash', ['-c', '. "$PI_AGENT_HOME/bin/pi-agent-env.sh"; "$PI_AGENT_HOME/node/bin/node" -e "console.log(JSON.stringify(process.env))"']));
  for (const key of Object.keys(process.env)) delete process.env[key];
  Object.assign(process.env, scopedEnv);
  const root = path.join(install, 'plugins/pi-paseo-plugin');
  api = await import(pathToFileURL(path.join(root, 'src/host-api.mjs')));
  runtime = await import(pathToFileURL(path.join(root, 'src/runtime.mjs')));
  const layout = await import(pathToFileURL(path.join(root, 'src/runtime-layout.mjs')));
  assert.ok(layout.runtimeReady(runtime.locations()));
  const rt = layout.runtimeDirectory(runtime.locations());
  assert.equal(run(node, [path.join(rt, 'node_modules/@getpaseo/cli/bin/paseo'), '--version']), pins.PIN_GETPASEO_CLI_VERSION);
  receipt.versions.paseoCore = pins.PIN_GETPASEO_CLI_VERSION;
  receipt.runtime = read(path.join(rt, '.pi-paseo-runtime.json'));
  assert.equal(receipt.runtime.revision, receipt.candidates.find(row => row.file.startsWith('woowtech-pi-paseo-')).runtimeRevision);
  assert.equal(receipt.runtime.revision, layout.RUNTIME_REVISION);
  await api.saveConfig({ name: 'Native installer CI', target: 'woowtech' });
  // A real launchd job and installed PiWeb launcher, with no persistent DB update.
  launchdAttempted = true;
  receipt.stages.push({ stage: 'service', status: 'running' }); save();
  run('/bin/bash', ['install.sh', 'service'], { output: true });
  await until(webUp, 'PiWeb HTTP via launchd', 180000);
  assert.match(run('/bin/launchctl', ['print', `${receipt.launchd.domain}/${label}`]), /state = running/);
  assert.ok(fs.existsSync(path.join(install, 'home/.local/bin/pi-web')), 'real Omnigent launcher installed');
  receipt.stages.at(-1).status = 'passed'; receipt.checks.piWebFirstStart = true; save();
  for (const route of ['/omnigent', '/paseo/setup', '/api/plugin-paseo']) {
    const res = await fetch(url + route, { signal: AbortSignal.timeout(30000) });
    assert.equal(res.status, 200, route);
  }
  run(bin('pi-paseo'), ['start']);
  await started('Agent Connect activation completed');
  const loc = runtime.locations();
  const identity = () => ({ serverId: sha(path.join(loc.paseoHome, 'server-id')), keypair: sha(path.join(loc.paseoHome, 'daemon-keypair.json')) });
  const firstIdentity = identity();
  receipt.checks.agentConnectFirstStart = true;
  const status = JSON.parse(run(bin('pi-paseo'), ['status']));
  for (const name of ['claude', 'codex', 'pi']) {
    const launcher = status.state.providerLaunchers[name];
    assert.equal(launcher.startup, 'ready'); assert.equal(launcher.command, bin(name));
  }
  receipt.checks.realProviderWrapperDiscovery = true;
  receipt.preStop = { ...lifecycleSnapshot(), diagnosticCode: status.diagnosticCode };
  save();
  run(bin('pi-paseo'), ['stop']);
  await until(async () => !(await runtime.status()).daemon.running, 'Agent Connect stop');
  run(bin('pi-agent'), ['stop']);
  await until(async () => launchdGone() && !(await webUp()), 'PiWeb stop and launchd removal');
  receipt.checks.firstStop = true;
  run(bin('pi-agent'), ['start']); await until(webUp, 'PiWeb restart', 180000);
  run(bin('pi-paseo'), ['start']);
  await started('Agent Connect restart completed');
  assert.deepEqual(identity(), firstIdentity);
  receipt.checks.restartIdentity = true;
  // Run the frozen extension-free boundary and real cold/warm MCP processes
  // against the SDK and shared bundle actually installed on this Mac.
  const shared = path.join(install, 'shared-runtime');
  assert.equal(read(path.join(shared, 'package.json')).version, pins.PIN_SHARED_RUNTIME_VERSION);
  receipt.sharedRuntime = { version: pins.PIN_SHARED_RUNTIME_VERSION,
    mcpAdapterTestSha256: sha(path.join(shared, 'tests/mcp-adapter.test.mjs')) };
  env.PI_SHARED_SDK_ROOT = sdk;
  run(node, ['--test', ...['resource-authority', 'resource-boundary', 'extension-scan', 'bridge', 'mcp-adapter'].map(test => path.join(shared, `tests/${test}.test.mjs`))], { output: true });
  receipt.checks.sharedSdkBoundary = true;
  receipt.checks.sharedColdWarmMcp = true;
  for (const file of ['data/auth.json', 'home/.codex/auth.json', 'home/.claude/.credentials.json']) {
    const full = path.join(install, file);
    if (fs.existsSync(full)) assert.equal(Object.keys(read(full)).length, 0, `no provider credentials: ${file}`);
  }
  receipt.checks.credentialFree = true;
  receipt.success = true;
} catch (error) {
  receipt.error = { name: error.name, message: error.message }; process.exitCode = 1;
} finally {
  let stopped = true;
  if (api) {
    const began = Date.now();
    try { await api.lifecycle({ action: 'stop' }); assert.equal((await runtime.status()).daemon.running, false); }
    catch (error) { stopped = false; receipt.cleanupError = safeError(error); }
    receipt.cleanupElapsedMs = Date.now() - began;
    receipt.cleanupState = lifecycleSnapshot();
  }
  if (launchdAttempted) {
    const bootout = spawnSync('/bin/launchctl', ['bootout', `${receipt.launchd.domain}/${label}`],
      { env, encoding: 'utf8', timeout: 30000 });
    receipt.launchd.bootoutExit = bootout.status;
    if (bootout.error) receipt.launchd.bootoutError = safeError(bootout.error);
    try {
      // HTTP may close before launchd has removed its service record. Require
      // both within the same bounded wait before declaring cleanup complete.
      await until(async () => launchdGone() && !(await webUp()), 'final PiWeb stop and launchd removal', 30000);
    } catch (error) { stopped = false; receipt.launchdCleanupError = safeError(error); }
  }
  receipt.checks.finalStop = stopped;
  if (!stopped) { receipt.success = false; process.exitCode = 1; }
  save();
  if (stopped) fs.rmSync(scratch, { recursive: true, force: true });
  console.log(JSON.stringify(receipt, null, 2));
}
