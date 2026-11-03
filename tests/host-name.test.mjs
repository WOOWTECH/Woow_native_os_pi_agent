// v0.2.2 host-name tests, the Node half (tests/host-name.sh runs it, then the Python half):
//
//   A  pi-agent-host-name       seed / check / set against temp installs
//   B  the plugin patch         omnigent-plugin-host-name-guard-patch.mjs on the pinned plugin
//   C  install.sh wire          the patch + the seed are wired in, idempotently
//   D  env propagation          PI_AGENT_TAKEOVER_HOST_ID survives the plugin's own Node layer
//
// Hermetic: temp directories only. It never reads or writes ~/.omnigent, a running
// install or a real Omnigent server, and it ignores OMNIGENT_CONFIG_HOME on purpose
// (the tool under test must too -- A15 proves it).
//
// Needs PA_TEST_PRISTINE (the pinned pi-omnigent-plugin, extracted; sha256-verified by
// the driver) for B-D, and PA_TEST_PYTHON for the syntax checks and D.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = path.join(ROOT, 'rootfs', 'bin');
const TOOL = path.join(BIN, 'pi-agent-host-name.mjs');
const LAUNCHER = path.join(BIN, 'pi-agent-host-name');
const GUARD = path.join(BIN, 'omnigent-plugin-host-name-guard-patch.mjs');
const SESSION = path.join(BIN, 'omnigent-plugin-session-home-patch.mjs');
const INSTALL = path.join(ROOT, 'install.sh');
const PRISTINE = process.env.PA_TEST_PRISTINE || '';
const PY = process.env.PA_TEST_PYTHON || '';
const MARKER = 'host-name-guard (Woow native installer)';
const HOST = 'testbox.local';

let passed = 0, failed = 0, skipped = 0;
const made = [];
async function t(name, fn) {
  try { await fn(); passed++; console.log(`  PASS  ${name}`); }
  catch (error) {
    failed++;
    console.log(`  FAIL  ${name}\n        ${String(error.message).split('\n').join('\n        ')}`);
  }
}
const skip = (name, why) => { skipped++; console.log(`  SKIP  ${name} -- ${why}`); };
const tmp = (prefix) => { const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix)); made.push(d); return d; };

// ---------------------------------------------------------------- helpers A ---
const cfgOf = (home) => path.join(home, 'home', '.omnigent', 'config.yaml');
const put = (home, text) => { fs.mkdirSync(path.dirname(cfgOf(home)), { recursive: true }); fs.writeFileSync(cfgOf(home), text, { mode: 0o644 }); };
const get = (home) => fs.readFileSync(cfgOf(home), 'utf8');
const mode = (file) => fs.statSync(file).mode & 0o777;
const newHome = () => tmp('pa-hn-');
// A clean environment: nothing from the machine running the tests leaks into the tool.
const envFor = (home, extra = {}) => ({ PATH: process.env.PATH, PI_AGENT_HOME: home, PI_AGENT_HOSTNAME: HOST, ...extra });
function cli(home, args, extra = {}) {
  const r = spawnSync(process.execPath, [TOOL, ...args], { env: envFor(home, extra), encoding: 'utf8' });
  return { code: r.status, out: r.stdout, err: r.stderr };
}
const OMNI_FULL = [
  'host:',
  '  host_id: 0123456789abcdef0123456789abcdef',
  '  name: my-laptop',
  'server: https://omnigent.example.test',
  '',
].join('\n');

console.log('== A. pi-agent-host-name: seed / check / set ==');

await t('A1 seed: a fresh install gets "<hostname> (pi-agent)", file 0600, directory 0700', () => {
  const h = newHome(); const r = cli(h, ['seed']);
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /^SEEDED host\.name="testbox\.local \(pi-agent\)"/);
  assert.equal(get(h), 'host:\n  name: "testbox.local (pi-agent)"\n');
  assert.equal(mode(cfgOf(h)), 0o600);
  assert.equal(mode(path.dirname(cfgOf(h))), 0o700);
});

await t('A2 seed: idempotent -- the second run changes nothing', () => {
  const h = newHome(); cli(h, ['seed']);
  const before = get(h), mtime = fs.statSync(cfgOf(h)).mtimeMs;
  const r = cli(h, ['seed']);
  assert.equal(r.code, 0); assert.match(r.out, /^KEPT host\.name="testbox\.local \(pi-agent\)"/);
  assert.equal(get(h), before); assert.equal(fs.statSync(cfgOf(h)).mtimeMs, mtime);
});

await t('A3 seed: never overwrites an existing name, and says nothing alarming about it', () => {
  const h = newHome(); put(h, OMNI_FULL);
  const r = cli(h, ['seed']);
  assert.equal(r.code, 0); assert.match(r.out, /^KEPT host\.name="my-laptop"/); assert.doesNotMatch(r.out, /WARN/);
  assert.equal(get(h), OMNI_FULL);
  assert.equal(fs.existsSync(cfgOf(h) + '.pre-host-name.bak'), false);
});

await t('A4 seed: an existing name equal to the plain hostname is NOT renamed -- it gets a warning', () => {
  const h = newHome(); const text = `host:\n  host_id: 0123456789abcdef0123456789abcdef\n  name: ${HOST}\n`; put(h, text);
  const r = cli(h, ['seed']);
  assert.equal(r.code, 0);
  assert.equal(get(h), text);
  assert.match(r.out, /WARN: .*named "testbox\.local", the same as the machine itself/);
  assert.match(r.out, /NOT renamed/);
  assert.match(r.out, /pi-agent-host-name set "testbox\.local \(pi-agent\)"/);
});

await t('A5 seed: the plain-hostname comparison ignores case', () => {
  const h = newHome(); put(h, 'host:\n  name: TESTBOX.LOCAL\n');
  const r = cli(h, ['seed']);
  assert.match(r.out, /WARN/); assert.equal(get(h), 'host:\n  name: TESTBOX.LOCAL\n');
});

await t('A6 seed: a host section with only host_id gets the name added first; every other line and the id stay', () => {
  const h = newHome();
  const text = 'host:\n  host_id: 0123456789abcdef0123456789abcdef\nother:\n  nested: 1\nserver: https://x.example.test\n'; put(h, text);
  const r = cli(h, ['seed']);
  assert.equal(r.code, 0, r.err);
  assert.equal(get(h), 'host:\n  name: "testbox.local (pi-agent)"\n  host_id: 0123456789abcdef0123456789abcdef\nother:\n  nested: 1\nserver: https://x.example.test\n');
  assert.equal(mode(cfgOf(h)), 0o600);
  assert.equal(fs.readFileSync(cfgOf(h) + '.pre-host-name.bak', 'utf8'), text);
  assert.equal(mode(cfgOf(h) + '.pre-host-name.bak'), 0o600);
});

await t('A7 seed: a config without a host section gets one appended (also when the file lacks a final newline)', () => {
  const h = newHome(); put(h, 'server: https://x.example.test\nworkspace: /w');
  const r = cli(h, ['seed']);
  assert.equal(r.code, 0, r.err);
  assert.equal(get(h), 'server: https://x.example.test\nworkspace: /w\nhost:\n  name: "testbox.local (pi-agent)"\n');
});

await t('A8 seed: reads the "\\uXXXX" form omnigent itself writes for non-ASCII names, and keeps it', () => {
  const h = newHome();
  const text = 'host:\n  host_id: 0123456789abcdef0123456789abcdef\n  name: "\\u5C0F\\u660E\\u7684 MacBook (pi-agent)"\n'; put(h, text);
  const r = cli(h, ['seed']);
  assert.match(r.out, /^KEPT host\.name="小明的 MacBook \(pi-agent\)"/); assert.equal(get(h), text);
});

await t('A9 seed: shapes it will not edit are left alone with a warning, and the exit status stays 0', () => {
  const cases = {
    'flow style, no name': 'host: {host_id: 0123456789abcdef0123456789abcdef}\n',
    'block scalar': 'host: |\n  something\n',
    'scalar': 'host: nonsense\n',
    'duplicate host keys': 'host:\n  host_id: a\nhost:\n  host_id: b\n',
    'name with a continuation line': 'host:\n  name: first\n    second\n',
    'tab indentation': 'host:\n\tname: x\n',
  };
  for (const [label, text] of Object.entries(cases)) {
    const h = newHome(); put(h, text);
    const r = cli(h, ['seed']);
    assert.equal(r.code, 0, `${label}: ${r.err}`);
    assert.match(r.out, /WARN: not seeding/, label);
    assert.equal(get(h), text, label);
  }
});

await t('A9b seed: a one-line flow-style host section that already has a name is respected (read, not edited)', () => {
  const h = newHome(); put(h, 'host: {name: my-box}\n');
  const r = cli(h, ['seed']);
  assert.match(r.out, /^KEPT host\.name="my-box"/); assert.equal(get(h), 'host: {name: my-box}\n');
  const h2 = newHome(); put(h2, `host: {host_id: abc, name: "${HOST}"}\n`);
  assert.match(cli(h2, ['seed']).out, /WARN: .*the same as the machine itself/);
});

await t('A10 an unreadable config never fails seed (it runs inside the installer); set and check report it', () => {
  const h = newHome(); fs.mkdirSync(cfgOf(h), { recursive: true });
  const s = cli(h, ['seed']); assert.equal(s.code, 0); assert.match(s.out, /WARN: not seeding a host name: cannot read/);
  assert.equal(cli(h, ['set', 'x']).code, 3);
  assert.equal(cli(h, ['check']).code, 3);
});

await t('A11 set: replaces the name in place; keeps comments, CRLF line ends and every other line; keeps the FIRST backup', () => {
  const h = newHome();
  put(h, 'host:\r\n  host_id: 0123456789abcdef0123456789abcdef\r\n  name: \'old name\'  # was set by hand\r\nserver: s\r\n');
  const r = cli(h, ['set', 'new name (pi-agent)']);
  assert.equal(r.code, 0, r.err);
  assert.equal(get(h), 'host:\r\n  host_id: 0123456789abcdef0123456789abcdef\r\n  name: "new name (pi-agent)"  # was set by hand\r\nserver: s\r\n');
  assert.match(r.out, /^SET host\.name="new name \(pi-agent\)" \(was "old name"\)/);
  assert.match(r.out, /pi-agent restart/);
  const original = fs.readFileSync(cfgOf(h) + '.pre-host-name.bak', 'utf8');
  cli(h, ['set', 'third']);
  assert.equal(fs.readFileSync(cfgOf(h) + '.pre-host-name.bak', 'utf8'), original, 'the first backup must survive later edits');
  assert.equal(mode(cfgOf(h)), 0o600);
});

await t('A12 set: can take the exact name of an old host (replacing it on purpose), whatever characters it has', () => {
  const names = [HOST, 'ElmodeMacBook-Air.local', "Elmo's MacBook Pro", 'Mac 小明 (主機) #1: "x" \\ y', 'café-mini', 'a'.repeat(200)];
  for (const name of names) {
    const h = newHome(); put(h, `host:\n  host_id: 0123456789abcdef0123456789abcdef\n  name: "${HOST} (pi-agent)"\n`);
    const r = cli(h, ['set', name]);
    assert.equal(r.code, 0, `${name}: ${r.err}${r.out}`);
    const j = JSON.parse(cli(h, ['check', '--json']).out);
    assert.equal(j.name, name);
    assert.equal(j.hostId, '0123456789abcdef0123456789abcdef', 'the host_id must be left alone');
    if (name === HOST) { assert.match(r.out, /WARN: .*PI_AGENT_TAKEOVER_HOST_ID/); assert.equal(j.status, 'plain-hostname'); }
    else if (!name.endsWith('(pi-agent)')) assert.match(r.out, /NOTE: .*PI_AGENT_TAKEOVER_HOST_ID/);
  }
});

await t('A12b set: the same name again is reported as UNCHANGED and writes nothing', () => {
  const h = newHome(); cli(h, ['set', 'same']); const before = fs.statSync(cfgOf(h)).mtimeMs;
  const r = cli(h, ['set', 'same']);
  assert.match(r.out, /^UNCHANGED/); assert.equal(fs.statSync(cfgOf(h)).mtimeMs, before);
});

await t('A13 set: refuses an empty name, surrounding whitespace, control characters and over-long names -- and writes nothing', () => {
  // (a NUL cannot be passed in argv at all, so BEL stands in for "a control character")
  const bad = ['', ' lead', 'trail ', 'a\nb', 'a\tb', 'a\u0007b', 'x'.repeat(201), String.fromCharCode(0x2028)];
  for (const name of bad) {
    const h = newHome(); put(h, OMNI_FULL);
    const r = cli(h, ['set', name]);
    assert.equal(r.code, 3, JSON.stringify(name));
    assert.equal(get(h), OMNI_FULL, JSON.stringify(name));
    const fresh = newHome(); assert.equal(cli(fresh, ['set', name]).code, 3);
    assert.equal(fs.existsSync(cfgOf(fresh)), false, 'a refused name must not even create the file');
  }
});

await t('A14 check: exit 0 for a distinct name; 1 for the plain hostname or no name; 3 for an unreadable file; --json is JSON', () => {
  const ok = newHome(); put(ok, OMNI_FULL);
  assert.equal(cli(ok, ['check']).code, 0);
  assert.deepEqual(JSON.parse(cli(ok, ['check', '--json']).out), { config: cfgOf(ok), hostname: HOST, name: 'my-laptop', hostId: '0123456789abcdef0123456789abcdef', status: 'ok', lastRefusal: null });
  const plain = newHome(); put(plain, `host:\n  name: ${HOST}\n`);
  const p = cli(plain, ['check']); assert.equal(p.code, 1); assert.match(p.out, /COLLISION-PRONE/);
  const unset = newHome(); const u = cli(unset, ['check']); assert.equal(u.code, 1); assert.match(u.out, /not set/);
  const bad = newHome(); put(bad, 'host: nonsense\n'); assert.equal(cli(bad, ['check']).code, 3);
});

await t('A15 the file is always this install\'s own: OMNIGENT_CONFIG_HOME and HOME are never followed', () => {
  const h = newHome(), foreign = tmp('pa-hn-foreign-');
  const sentinel = 'host:\n  host_id: ffffffffffffffffffffffffffffffff\n  name: owners-live-host\n';
  fs.mkdirSync(path.join(foreign, '.omnigent'), { recursive: true });
  fs.writeFileSync(path.join(foreign, '.omnigent', 'config.yaml'), sentinel);
  const extra = { OMNIGENT_CONFIG_HOME: path.join(foreign, '.omnigent'), HOME: foreign };
  cli(h, ['seed'], extra); cli(h, ['set', 'mine'], extra);
  assert.equal(fs.readFileSync(path.join(foreign, '.omnigent', 'config.yaml'), 'utf8'), sentinel);
  assert.equal(fs.readdirSync(path.join(foreign, '.omnigent')).join(), 'config.yaml', 'nothing else may appear beside the foreign config');
  assert.match(get(h), /name: "mine"/);
});

await t('A16 the bash launcher works with PI_AGENT_HOME derived from its own location, and falls back to a node on PATH', () => {
  const h = newHome();
  fs.mkdirSync(path.join(h, 'bin')); fs.mkdirSync(path.join(h, 'node', 'bin'), { recursive: true });
  for (const f of ['pi-agent-host-name', 'pi-agent-host-name.mjs']) fs.copyFileSync(path.join(BIN, f), path.join(h, 'bin', f));
  fs.chmodSync(path.join(h, 'bin', 'pi-agent-host-name'), 0o755);
  fs.symlinkSync(process.execPath, path.join(h, 'node', 'bin', 'node'));
  const env = { PATH: process.env.PATH, PI_AGENT_HOSTNAME: HOST };
  const r = spawnSync(path.join(h, 'bin', 'pi-agent-host-name'), ['seed'], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr); assert.match(r.stdout, /^SEEDED/);
  assert.equal(get(h), 'host:\n  name: "testbox.local (pi-agent)"\n');
  const h2 = newHome();
  const r2 = spawnSync('bash', [LAUNCHER, 'check', '--json'], { env: { ...env, PI_AGENT_HOME: h2 }, encoding: 'utf8' });
  assert.equal(r2.status, 1, r2.stderr); assert.equal(JSON.parse(r2.stdout).status, 'unset');
});

await t('A17 without PI_AGENT_HOME the tool refuses to guess a file; usage errors exit 2', () => {
  const r = spawnSync(process.execPath, [TOOL, 'check'], { env: { PATH: process.env.PATH }, encoding: 'utf8' });
  assert.equal(r.status, 3); assert.match(r.stderr, /PI_AGENT_HOME is not set/);
  const h = newHome();
  assert.equal(cli(h, []).code, 2); assert.equal(cli(h, ['frobnicate']).code, 2); assert.equal(cli(h, ['set']).code, 2);
  assert.equal(cli(h, ['seed', 'extra']).code, 2);
});

await t('A18 check shows the plugin\'s last HOST_NAME_* refusal as written (real newlines, exact commands) -- and ignores anything else', () => {
  const message = '這台 host 的名稱「X」已被 server 上另一台 host 使用：host_id 2b8a18bc（目前離線）。\n  PI_AGENT_TAKEOVER_HOST_ID=2b8a18bc /p/bin/pi-omnigent repair --server https://s.example.test';
  const withState = (home, state, rel = ['data', 'omnigent-plugin', 'state.json']) => {
    const f = path.join(home, ...rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, typeof state === 'string' ? state : JSON.stringify(state));
  };
  const h = newHome(); put(h, OMNI_FULL); withState(h, { phase: 'error', issue: { code: 'HOST_NAME_COLLISION', message } });
  const r = cli(h, ['check']);
  assert.equal(r.code, 1, 'a pending refusal is a problem even when the name looks fine');
  assert.ok(r.out.includes(`\n${message}\n`) || r.out.endsWith(message + '\n'), r.out);
  assert.match(r.out, /refused to start this host \(HOST_NAME_COLLISION\)/);
  const j = JSON.parse(cli(h, ['check', '--json']).out);
  assert.deepEqual(j.lastRefusal, { code: 'HOST_NAME_COLLISION', message }); assert.equal(j.status, 'ok');
  // not a HOST_NAME_* code, no issue, an unreadable file: nothing is shown and the status is the name's alone
  for (const state of [{ issue: { code: 'NEEDS_LOGIN', message: 'x' } }, { issue: null }, {}, '{not json', { issue: { code: 'HOST_NAME_COLLISION' } }]) {
    const g = newHome(); put(g, OMNI_FULL); withState(g, state);
    const c = cli(g, ['check']); assert.equal(c.code, 0, JSON.stringify(state)); assert.doesNotMatch(c.out, /refused to start/);
    assert.equal(JSON.parse(cli(g, ['check', '--json']).out).lastRefusal, null);
  }
  // PI_AGENT_DATA_DIR relocates the plugin state, as pi-agent-env.sh lets it
  const d = newHome(), data = tmp('pa-hn-data-'); put(d, OMNI_FULL); withState(data, { issue: { code: 'HOST_NAME_UNVERIFIABLE', message: 'm' } }, ['omnigent-plugin', 'state.json']);
  assert.equal(JSON.parse(cli(d, ['check', '--json'], { PI_AGENT_DATA_DIR: data }).out).lastRefusal.code, 'HOST_NAME_UNVERIFIABLE');
});

// A cutover (docs/MACOS-CUTOVER.md) makes this install's host take over the REPLACED host's identity,
// name included -- and on a Mac that name is usually the plain hostname. That is the point of it, not a
// collision: the replaced host is gone and its server row is this host's. The tool must say so, instead of
// warning on every `install.sh wire` that the name "may collide" and telling the owner to rename it
// (which, on an adopted identity, would rename the owner's own host on the server).
const putState = (home, lines) => fs.writeFileSync(path.join(home, 'session-home.state'), lines.join('\n') + '\n');
const ADOPTED = (name = HOST) => ['REAL_HOME=/Users/someone', 'PARKED=/Users/someone/.omnigent.pre-pi-agent', 'CUTOVER=yes', `OLD_HOST_ID=0123456789abcdef0123456789abcdef`, `OLD_HOST_NAME=${name}`];
const PLAIN_CFG = `host:\n  host_id: 0123456789abcdef0123456789abcdef\n  name: ${HOST}\n`;

await t('A19 seed: a name a cutover adopted from the replaced host is kept WITHOUT the collision warning', () => {
  const h = newHome(); put(h, PLAIN_CFG); putState(h, ADOPTED());
  const r = cli(h, ['seed']);
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /^KEPT host\.name="testbox\.local"/);
  assert.match(r.out, /cutover/i);
  assert.doesNotMatch(r.out, /WARN|NOT renamed|pi-agent-host-name set/);
  assert.equal(get(h), PLAIN_CFG);
});

await t('A20 seed: the exception is exact -- another name in the state, a plain session home, or a missing CUTOVER=yes still warn', () => {
  const other = newHome(); put(other, PLAIN_CFG); putState(other, ADOPTED('some-other-host'));
  assert.match(cli(other, ['seed']).out, /WARN: .*the same as the machine itself/);
  const plainSessionHome = newHome(); put(plainSessionHome, PLAIN_CFG); putState(plainSessionHome, ['REAL_HOME=/Users/someone', 'PARKED=', 'BACKUP=', 'ENABLED_AT=x']);
  assert.match(cli(plainSessionHome, ['seed']).out, /WARN: .*the same as the machine itself/);
  const notYes = newHome(); put(notYes, PLAIN_CFG); putState(notYes, ADOPTED().map((l) => l.replace('CUTOVER=yes', 'CUTOVER=no')));
  assert.match(cli(notYes, ['seed']).out, /WARN: .*the same as the machine itself/);
  const noState = newHome(); put(noState, PLAIN_CFG);
  assert.match(cli(noState, ['seed']).out, /WARN: .*the same as the machine itself/);
});

await t('A21 seed: the adopted-name comparison ignores case and surrounding blanks, like the hostname one', () => {
  const h = newHome(); put(h, PLAIN_CFG); putState(h, ADOPTED('  TestBox.LOCAL '));
  const r = cli(h, ['seed']);
  assert.match(r.out, /^KEPT/); assert.doesNotMatch(r.out, /WARN/);
});

await t('A22 check: an adopted name is status "adopted", exit 0, and says why; --json carries it', () => {
  const h = newHome(); put(h, PLAIN_CFG); putState(h, ADOPTED());
  const c = cli(h, ['check']);
  assert.equal(c.code, 0, c.out);
  assert.match(c.out, /adopted/i); assert.doesNotMatch(c.out, /COLLISION-PRONE|pi-agent-host-name set/);
  const j = JSON.parse(cli(h, ['check', '--json']).out);
  assert.equal(j.status, 'adopted'); assert.equal(j.name, HOST);
  // and without the cutover record the very same file is still collision-prone
  const plain = newHome(); put(plain, PLAIN_CFG);
  assert.equal(cli(plain, ['check']).code, 1); assert.equal(JSON.parse(cli(plain, ['check', '--json']).out).status, 'plain-hostname');
});

// ---------------------------------------------------------------- helpers B ---
const havePristine = PRISTINE && fs.existsSync(path.join(PRISTINE, 'src', 'omnigent.py'));
function newPlugin(version) {
  const d = tmp('pa-hn-plugin-');
  fs.mkdirSync(path.join(d, 'src'));
  fs.copyFileSync(path.join(PRISTINE, 'package.json'), path.join(d, 'package.json'));
  fs.copyFileSync(path.join(PRISTINE, 'src', 'omnigent.py'), path.join(d, 'src', 'omnigent.py'));
  fs.copyFileSync(path.join(PRISTINE, 'src', 'issues.mjs'), path.join(d, 'src', 'issues.mjs'));
  if (version) {
    const p = JSON.parse(fs.readFileSync(path.join(d, 'package.json'), 'utf8')); p.version = version;
    fs.writeFileSync(path.join(d, 'package.json'), JSON.stringify(p));
  }
  return d;
}
const pyOf = (plugin) => path.join(plugin, 'src', 'omnigent.py');
const issuesOf = (plugin) => path.join(plugin, 'src', 'issues.mjs');
const run = (script, plugin) => { const r = spawnSync(process.execPath, [script, plugin].filter(Boolean), { encoding: 'utf8' }); return { code: r.status, out: r.stdout + r.stderr }; };
const count = (text, needle) => text.split(needle).length - 1;
const pristineText = havePristine ? fs.readFileSync(path.join(PRISTINE, 'src', 'omnigent.py'), 'utf8') : '';
const pristineIssues = havePristine ? fs.readFileSync(path.join(PRISTINE, 'src', 'issues.mjs'), 'utf8') : '';
const NEW_CODES = ['HOST_NAME_COLLISION', 'HOST_NAME_UNVERIFIABLE', 'HOST_NAME_TAKEOVER_ONLINE'];
function syntaxOk(python, file) {
  const r = spawnSync(python, ['-I', '-B', '-c', 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())', file], { encoding: 'utf8' });
  return { ok: r.status === 0, err: r.stderr };
}

console.log('== B. the plugin patch ==');
if (!havePristine) skip('B*', 'PA_TEST_PRISTINE (the extracted pinned plugin) is not set');
else {
  await t('B1 applies once: method above ensure_host, call right before the host.log open, .orig is the pristine file', () => {
    const p = newPlugin(); const r = run(GUARD, p);
    assert.equal(r.code, 0); assert.match(r.out, /patched .*omnigent\.py \(plugin 0\.3\.31\)/);
    const text = fs.readFileSync(pyOf(p), 'utf8');
    assert.equal(count(text, 'def guard_host_name(self, server: str) -> None:'), 1);
    assert.equal(count(text, 'self.guard_host_name(server)'), 1);
    assert.equal(count(text, MARKER), 2, 'one marker on the method comment, one on the call');
    const def = text.indexOf('def guard_host_name'), ensure = text.indexOf('    def ensure_host(self, server: str) -> str:');
    const call = text.indexOf('self.guard_host_name(server)'), open = text.indexOf('descriptor = os.open(self.state_dir / "host.log"');
    const popen = text.indexOf('subprocess.Popen([binary, "host"');
    assert.ok(def < ensure && ensure < call && call < open && open < popen, `order def=${def} ensure=${ensure} call=${call} open=${open} popen=${popen}`);
    assert.equal(fs.readFileSync(pyOf(p) + '.orig', 'utf8'), pristineText);
    // and the hints, in the plugin's own table
    const issues = fs.readFileSync(issuesOf(p), 'utf8');
    for (const code of NEW_CODES) assert.equal(count(issues, `  ${code}: hint(null,`), 1, code);
    assert.equal(count(issues, MARKER), 1);
    assert.equal(fs.readFileSync(issuesOf(p) + '.orig', 'utf8'), pristineIssues);
    assert.match(r.out, /patched .*issues\.mjs \(plugin 0\.3\.31\)/);
  });

  await t('B2 second run is a no-op (byte-identical files, "already patched")', () => {
    const p = newPlugin(); run(GUARD, p); const once = fs.readFileSync(pyOf(p), 'utf8'), onceIssues = fs.readFileSync(issuesOf(p), 'utf8');
    const r = run(GUARD, p);
    assert.equal(r.code, 0); assert.match(r.out, /omnigent\.py: already patched — no change/); assert.match(r.out, /issues\.mjs: hints already patched — no change/);
    assert.equal(fs.readFileSync(pyOf(p), 'utf8'), once); assert.equal(fs.readFileSync(issuesOf(p), 'utf8'), onceIssues);
  });

  await t('B2b a tree patched by an older run that lacked the hints gets the hints and nothing else changes', () => {
    const p = newPlugin(); run(GUARD, p);
    fs.copyFileSync(path.join(PRISTINE, 'src', 'issues.mjs'), issuesOf(p)); fs.rmSync(issuesOf(p) + '.orig');
    const guarded = fs.readFileSync(pyOf(p), 'utf8');
    const r = run(GUARD, p);
    assert.match(r.out, /omnigent\.py: already patched/); assert.match(r.out, /patched .*issues\.mjs/);
    assert.equal(fs.readFileSync(pyOf(p), 'utf8'), guarded);
    assert.ok(fs.readFileSync(issuesOf(p), 'utf8').includes(MARKER));
  });

  await t('B3 a plugin version it was not validated against is skipped LOUDLY and left untouched', () => {
    const p = newPlugin('0.3.99'); const r = run(GUARD, p);
    assert.equal(r.code, 0); assert.match(r.out, /WARN: plugin 0\.3\.99 .* SKIPPING/);
    assert.equal(fs.readFileSync(pyOf(p), 'utf8'), pristineText); assert.equal(fs.readFileSync(issuesOf(p), 'utf8'), pristineIssues);
    assert.equal(fs.existsSync(pyOf(p) + '.orig'), false); assert.equal(fs.existsSync(issuesOf(p) + '.orig'), false);
  });

  await t('B4 a moved or duplicated anchor leaves the file alone (counted anchors, never half-patched)', () => {
    const missing = newPlugin(); const noDef = pristineText.replace('    def ensure_host(self, server: str) -> str:\n', '    def ensure_host2(self, server: str) -> str:\n');
    fs.writeFileSync(pyOf(missing), noDef);
    let r = run(GUARD, missing); assert.match(r.out, /WARN: expected exactly 1 ensure_host definition and 1 host\.log open, found 0 and 1/);
    assert.equal(fs.readFileSync(pyOf(missing), 'utf8'), noDef);
    const doubled = newPlugin(); const twice = pristineText + '\n' + '            descriptor = os.open(self.state_dir / "host.log", os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)\n';
    fs.writeFileSync(pyOf(doubled), twice);
    r = run(GUARD, doubled); assert.match(r.out, /found 1 and 2/);
    assert.equal(fs.readFileSync(pyOf(doubled), 'utf8'), twice);
    assert.equal(fs.existsSync(pyOf(doubled) + '.orig'), false);
  });

  await t('B4b the hints are best effort: a moved ISSUES table costs only the hints; a refused guard adds no hints', () => {
    const p = newPlugin(); const moved = pristineIssues.replace('const ISSUES = Object.freeze({', 'const ISSUES2 = Object.freeze({');
    fs.writeFileSync(issuesOf(p), moved);
    let r = run(GUARD, p);
    assert.equal(r.code, 0); assert.match(r.out, /patched .*omnigent\.py/); assert.match(r.out, /WARN: expected exactly 1 ISSUES table in issues\.mjs, found 0/);
    assert.ok(fs.readFileSync(pyOf(p), 'utf8').includes(MARKER)); assert.equal(fs.readFileSync(issuesOf(p), 'utf8'), moved);
    const q = newPlugin(); fs.rmSync(issuesOf(q));
    r = run(GUARD, q); assert.equal(r.code, 0); assert.match(r.out, /WARN: cannot read .*issues\.mjs/); assert.ok(fs.readFileSync(pyOf(q), 'utf8').includes(MARKER));
    const refused = newPlugin(); fs.writeFileSync(pyOf(refused), pristineText.replace('    def ensure_host(self, server: str) -> str:\n', '    def ensure_host2(self, server: str) -> str:\n'));
    r = run(GUARD, refused); assert.match(r.out, /WARN: expected exactly 1 ensure_host/);
    assert.equal(fs.readFileSync(issuesOf(refused), 'utf8'), pristineIssues, 'no guard, no hints');
  });

  await t('B9 the patched issues.mjs still loads, describes the three codes in all three languages, and leaves every other code alone', async () => {
    const p = newPlugin(); run(GUARD, p);
    const mod = await import(pathToFileURL(issuesOf(p)).href + '?patched');
    const before = await import(pathToFileURL(path.join(PRISTINE, 'src', 'issues.mjs')).href + '?pristine');
    for (const code of NEW_CODES) {
      const d = mod.describeIssue({ code, message: 'the adapter message' });
      assert.equal(d.code, code); assert.equal(d.message, 'the adapter message'); assert.equal(d.action, null);
      for (const lang of ['en', 'zh-TW', 'zh-CN']) assert.ok(typeof d.hints[lang] === 'string' && d.hints[lang].length > 20, `${code} ${lang}`);
      assert.notDeepEqual(d.hints, mod.describeIssue({ code: 'NOT_A_CODE' }).hints, `${code} must not fall back to the generic hint`);
      assert.ok(mod.ISSUE_CODES.includes(code));
      assert.equal(before.describeIssue({ code }).code, code, 'the pristine table knows nothing of it (the reason for the patch)');
      assert.deepEqual(before.describeIssue({ code }).hints, before.describeIssue({ code: 'NOT_A_CODE' }).hints);
    }
    assert.match(mod.describeIssue({ code: 'HOST_NAME_COLLISION' }).hints['zh-TW'], /pi-agent-host-name check/);
    assert.match(mod.describeIssue({ code: 'HOST_NAME_UNVERIFIABLE' }).hints.en, /pi-omnigent repair/);
    for (const code of before.ISSUE_CODES) assert.deepEqual(mod.describeIssue({ code }), before.describeIssue({ code }), `${code} must be unchanged`);
    assert.equal(mod.ISSUE_CODES.length, before.ISSUE_CODES.length + NEW_CODES.length);
  });

  await t('B5 never fails the caller: missing files, bad package.json, read-only tree -> exit 0; no argument -> usage, exit 2', () => {
    const empty = tmp('pa-hn-empty-'); let r = run(GUARD, empty); assert.equal(r.code, 0); assert.match(r.out, /cannot read the plugin's package\.json/);
    const noSrc = tmp('pa-hn-nosrc-'); fs.copyFileSync(path.join(PRISTINE, 'package.json'), path.join(noSrc, 'package.json'));
    r = run(GUARD, noSrc); assert.equal(r.code, 0); assert.match(r.out, /cannot read .*omnigent\.py/);
    const bad = newPlugin(); fs.writeFileSync(path.join(bad, 'package.json'), '{not json'); assert.equal(run(GUARD, bad).code, 0);
    assert.equal(run(GUARD, '').code, 2);
    if (process.getuid && process.getuid() !== 0) {
      const ro = newPlugin(); fs.chmodSync(path.join(ro, 'src'), 0o555);
      try { r = run(GUARD, ro); assert.equal(r.code, 0); assert.match(r.out, /WARN: cannot write/); assert.equal(fs.readFileSync(pyOf(ro), 'utf8'), pristineText); }
      finally { fs.chmodSync(path.join(ro, 'src'), 0o755); }
    }
  });

  await t('B6 composes with the session-home patch in either order -- same bytes, both markers, still valid Python', () => {
    const a = newPlugin(); run(SESSION, a); run(GUARD, a);
    const b = newPlugin(); run(GUARD, b); run(SESSION, b);
    const ta = fs.readFileSync(pyOf(a), 'utf8'), tb = fs.readFileSync(pyOf(b), 'utf8');
    assert.equal(ta, tb);
    assert.ok(ta.includes('session-home (Woow native installer)') && ta.includes(MARKER));
    assert.equal(fs.readFileSync(pyOf(a) + '.orig', 'utf8'), pristineText, '.orig stays pristine whichever patch ran first');
    assert.equal(fs.readFileSync(pyOf(b) + '.orig', 'utf8'), pristineText);
    if (PY) { const s = syntaxOk(PY, pyOf(a)); assert.ok(s.ok, s.err); }
  });

  await t('B7 an existing .orig is never overwritten', () => {
    const p = newPlugin(); fs.writeFileSync(pyOf(p) + '.orig', 'KEEP ME\n');
    run(GUARD, p); assert.equal(fs.readFileSync(pyOf(p) + '.orig', 'utf8'), 'KEEP ME\n');
  });

  await t('B8 the patched file is valid Python for every interpreter available here', () => {
    const p = newPlugin(); run(GUARD, p);
    const seen = new Set(); let checked = 0;
    for (const py of [PY, '/usr/bin/python3', 'python3', 'python3.9', 'python3.12']) {
      if (!py || seen.has(py)) continue; seen.add(py);
      const v = spawnSync(py, ['-c', 'import sys; print(sys.version.split()[0])'], { encoding: 'utf8' });
      if (v.status !== 0) continue;
      const s = syntaxOk(py, pyOf(p)); assert.ok(s.ok, `${py} ${v.stdout.trim()}: ${s.err}`); checked++;
    }
    assert.ok(checked >= 1, 'no python interpreter found to check the syntax with');
  });
}

// ---------------------------------------------------------------- helpers C ---
console.log('== C. install.sh wire ==');
if (!havePristine) skip('C*', 'PA_TEST_PRISTINE is not set');
else {
  const wireHome = () => {
    const h = tmp('pa-hn-wire-');
    fs.mkdirSync(path.join(h, 'node', 'bin'), { recursive: true });
    fs.symlinkSync(process.execPath, path.join(h, 'node', 'bin', 'node'));
    fs.mkdirSync(path.join(h, 'plugins'));
    fs.cpSync(PRISTINE, path.join(h, 'plugins', 'pi-omnigent-plugin'), { recursive: true });
    return h;
  };
  const wire = (h, extra = {}) => {
    const r = spawnSync('bash', [INSTALL, 'wire'], { env: { PATH: process.env.PATH, HOME: process.env.HOME, PI_AGENT_HOME: h, PI_AGENT_HOSTNAME: HOST, ...extra }, encoding: 'utf8' });
    return { code: r.status, out: r.stdout + r.stderr };
  };

  await t('C1 wire installs the three new files, patches the plugin and seeds a unique name', () => {
    const h = wireHome(); const r = wire(h);
    assert.equal(r.code, 0, r.out);
    for (const f of ['pi-agent-host-name', 'pi-agent-host-name.mjs', 'omnigent-plugin-host-name-guard-patch.mjs']) {
      const file = path.join(h, 'bin', f); assert.ok(fs.existsSync(file), f); assert.ok((mode(file) & 0o111) !== 0, `${f} must be executable`);
    }
    assert.ok(fs.readFileSync(pyOf(path.join(h, 'plugins', 'pi-omnigent-plugin')), 'utf8').includes(MARKER));
    assert.ok(fs.readFileSync(issuesOf(path.join(h, 'plugins', 'pi-omnigent-plugin')), 'utf8').includes(MARKER), 'the hints too');
    assert.equal(get(h), 'host:\n  name: "testbox.local (pi-agent)"\n'); assert.equal(mode(cfgOf(h)), 0o600);
    assert.match(r.out, /SEEDED host\.name/); assert.match(r.out, /patched .*omnigent\.py/);
    const after = spawnSync(path.join(h, 'bin', 'pi-agent-host-name'), ['check'], { env: { PATH: process.env.PATH, PI_AGENT_HOSTNAME: HOST }, encoding: 'utf8' });
    assert.equal(after.status, 0, after.stdout + after.stderr);
  });

  await t('C2 wire twice: the second run changes neither the plugin nor the config', () => {
    const h = wireHome(); wire(h);
    const py = fs.readFileSync(pyOf(path.join(h, 'plugins', 'pi-omnigent-plugin')), 'utf8'), cfg = get(h), m = fs.statSync(cfgOf(h)).mtimeMs;
    const r = wire(h); assert.equal(r.code, 0, r.out);
    assert.match(r.out, /already patched — no change/); assert.match(r.out, /KEPT host\.name/);
    assert.equal(fs.readFileSync(pyOf(path.join(h, 'plugins', 'pi-omnigent-plugin')), 'utf8'), py); assert.equal(get(h), cfg); assert.equal(fs.statSync(cfgOf(h)).mtimeMs, m);
  });

  await t('C3 an existing install named exactly like the machine is not renamed -- wire prints a warning and carries on', () => {
    const h = wireHome(); const text = `host:\n  host_id: 0123456789abcdef0123456789abcdef\n  name: ${HOST}\n`; put(h, text);
    const r = wire(h); assert.equal(r.code, 0, r.out);
    assert.equal(get(h), text);
    assert.match(r.out, /\[pi-agent\] WARN:.*named "testbox\.local", the same as the machine itself/); assert.match(r.out, /NOT renamed/);
    assert.ok(fs.readFileSync(pyOf(path.join(h, 'plugins', 'pi-omnigent-plugin')), 'utf8').includes(MARKER), 'the patch still applies');
  });

  await t('C4 a plugin the patch was not validated against does not fail wire, and the skip is a warning', () => {
    const h = wireHome(); const pj = path.join(h, 'plugins', 'pi-omnigent-plugin', 'package.json');
    const p = JSON.parse(fs.readFileSync(pj, 'utf8')); p.version = '9.9.9'; fs.writeFileSync(pj, JSON.stringify(p));
    const r = wire(h); assert.equal(r.code, 0, r.out);
    assert.match(r.out, /\[pi-agent\] WARN:.*SKIPPING/); assert.match(r.out, /wire OK/);
    assert.equal(get(h), 'host:\n  name: "testbox.local (pi-agent)"\n', 'the name is still seeded');
  });
}

const OMNI_TGZ = process.env.PA_TEST_OMNIGENT_TGZ || '', PASEO_TGZ = process.env.PA_TEST_PASEO_TGZ || '';
if (!havePristine || !OMNI_TGZ || !PASEO_TGZ) skip('C5', 'needs PA_TEST_PRISTINE, PA_TEST_OMNIGENT_TGZ and PA_TEST_PASEO_TGZ');
else {
  await t('C5 install.sh fetch (the real stage, from file:// copies of the pinned tarballs) patches the fresh plugin tree -- and again after the tree is replaced', () => {
    const copy = tmp('pa-hn-fetch-'), h = tmp('pa-hn-fetchhome-');
    fs.cpSync(path.join(ROOT, 'lib'), path.join(copy, 'lib'), { recursive: true });
    fs.cpSync(path.join(ROOT, 'rootfs'), path.join(copy, 'rootfs'), { recursive: true });
    fs.copyFileSync(INSTALL, path.join(copy, 'install.sh'));
    let pins = fs.readFileSync(path.join(copy, 'lib', 'pins.sh'), 'utf8');
    const before = pins;
    pins = pins.replace(/^PIN_OMNIGENT_PLUGIN_TGZ=.*$/m, `PIN_OMNIGENT_PLUGIN_TGZ="file://${OMNI_TGZ}"`)
      .replace(/^PIN_PASEO_PLUGIN_TGZ=.*$/m, `PIN_PASEO_PLUGIN_TGZ="file://${PASEO_TGZ}"`);
    assert.notEqual(pins, before, 'the pins were not rewritten');
    fs.writeFileSync(path.join(copy, 'lib', 'pins.sh'), pins);
    fs.mkdirSync(path.join(h, 'node', 'bin'), { recursive: true });
    fs.symlinkSync(process.execPath, path.join(h, 'node', 'bin', 'node'));
    const fetch = () => {
      const r = spawnSync('bash', [path.join(copy, 'install.sh'), 'fetch'], { env: { PATH: process.env.PATH, HOME: process.env.HOME, PI_AGENT_HOME: h }, encoding: 'utf8' });
      return { code: r.status, out: r.stdout + r.stderr };
    };
    const plugin = path.join(h, 'plugins', 'pi-omnigent-plugin');
    let r = fetch(); assert.equal(r.code, 0, r.out);
    assert.match(r.out, /\[omnigent-plugin-host-name-guard-patch\] patched /);
    assert.ok(fs.readFileSync(pyOf(plugin), 'utf8').includes(MARKER), 'the guard must be in the plugin right after fetch');
    assert.ok(fs.readFileSync(issuesOf(plugin), 'utf8').includes(MARKER), 'and its hints');
    assert.ok(fs.existsSync(path.join(h, 'plugins', 'pi-paseo-plugin', 'package.json')));
    fs.appendFileSync(pyOf(plugin), '\n# local edit that a re-fetch must discard\n');
    r = fetch(); assert.equal(r.code, 0, r.out);
    const again = fs.readFileSync(pyOf(plugin), 'utf8');
    assert.ok(again.includes(MARKER) && !again.includes('local edit that a re-fetch'), 'a re-fetch replaces the tree and patches the new one');
    assert.match(r.out, /\[omnigent-plugin-host-name-guard-patch\] patched /);
  });
}

// ---------------------------------------------------------------- helpers D ---
console.log('== D. PI_AGENT_TAKEOVER_HOST_ID reaches the guard through the plugin\'s own Node layer ==');
if (!havePristine || !PY) skip('D1', 'needs PA_TEST_PRISTINE and PA_TEST_PYTHON');
else {
  await t('D1 runtimeEnv + runJSON hand the variable to the Python adapter unchanged (and drop nothing else)', async () => {
    const { runtimeEnv } = await import(pathToFileURL(path.join(PRISTINE, 'src', 'installer.mjs')).href);
    const { runJSON } = await import(pathToFileURL(path.join(PRISTINE, 'src', 'common.mjs')).href);
    const dir = tmp('pa-hn-env-'); const script = path.join(dir, 'adapter.py');
    fs.writeFileSync(script, 'import json, os, sys\njson.dump({"ok": True, "data": {"t": os.environ.get("PI_AGENT_TAKEOVER_HOST_ID"), "h": os.environ.get("PI_AGENT_HOME")}}, sys.stdout)\n');
    const env = { ...process.env, PI_AGENT_TAKEOVER_HOST_ID: '2b8a18bc', PI_AGENT_HOME: '/some where/pa' };
    const out = await runJSON(PY, ['-I', '-B', script], {}, { env: runtimeEnv({}, env), timeout: 20_000 });
    assert.deepEqual(out, { ok: true, data: { t: '2b8a18bc', h: '/some where/pa' } });
  });
}

if (!havePristine) skip('D2', 'needs PA_TEST_PRISTINE');
else {
  await t('D2 a refusal through the plugin\'s real Node layer: initialize() returns and stores {code, message}; status() adds the new hints; `connect` shows only the code; check prints the message', async () => {
    const plugin = tmp('pa-hn-node-'); fs.cpSync(PRISTINE, plugin, { recursive: true });
    const patchOut = run(GUARD, plugin); assert.match(patchOut.out, /patched .*issues\.mjs/);
    // The plugin's lock helper needs flock(1): present on Linux, a perl stand-in plus the darwin patch on a Mac.
    const savedPath = process.env.PATH;
    if (process.platform === 'darwin') {
      assert.match(run(path.join(BIN, 'omnigent-plugin-darwin-patch.mjs'), plugin).out, /patched|already/);
      const shimDir = tmp('pa-hn-flock-'); fs.copyFileSync(path.join(BIN, 'flock'), path.join(shimDir, 'flock')); fs.chmodSync(path.join(shimDir, 'flock'), 0o755);
      process.env.PATH = `${shimDir}${path.delimiter}${savedPath}`;
    }
    try {
      const rt = await import(pathToFileURL(path.join(plugin, 'src', 'runtime.mjs')).href);
      const cn = await import(pathToFileURL(path.join(plugin, 'src', 'connect.mjs')).href);
      const home = tmp('pa-hn-nodehome-'), agentDir = path.join(home, 'data');
      const loc = { root: plugin, home: path.join(home, 'home'), agentDir, stateDir: path.join(agentDir, 'omnigent-plugin'),
        omniDir: path.join(home, 'home', '.omnigent'), omniDataDir: path.join(home, 'home', '.omnigent') };
      fs.mkdirSync(loc.stateDir, { recursive: true });
      const message = 'collision text\n  PI_AGENT_TAKEOVER_HOST_ID=2b8a18bc /p/bin/pi-omnigent repair --server https://s.example.test';
      const options = { loc, lifecycle: { active: true, registered: true },
        dependencies: { ok: true, omnigent: { available: true, python: '/nonexistent', path: '/nonexistent' } },
        callAdapter: async (input) => {
          if (input.action === 'status') return { ok: true, data: { server: 'https://s.example.test', host: { id: null, connected: false }, engines: {} } };
          if (input.action === 'connect') return { ok: false, error: { code: 'HOST_NAME_COLLISION', message } };
          throw new Error(`unexpected adapter action ${input.action}`);
        } };
      const server = 'https://s.example.test';
      // what `pi-omnigent repair` / `initialize` print
      const init = await rt.initialize({ ...options, server, username: 'woow', password: 'x' });
      assert.equal(init.ok, false); assert.equal(init.phase, 'error');
      assert.deepEqual(init.error, { code: 'HOST_NAME_COLLISION', message });
      // what the plugin keeps
      const stored = JSON.parse(fs.readFileSync(path.join(loc.stateDir, 'state.json'), 'utf8'));
      assert.deepEqual(stored.issue, { code: 'HOST_NAME_COLLISION', message });
      // what `pi-omnigent status` prints and Settings reads: the message AND the localized hints
      const st = await rt.status({ ...options, prefetchCatalog: false });
      assert.equal(st.issue.code, 'HOST_NAME_COLLISION'); assert.equal(st.issue.message, message); assert.equal(st.issue.action, null);
      assert.match(st.issue.hints['zh-TW'], /pi-agent-host-name check/); assert.match(st.issue.hints.en, /pi-agent-host-name check/);
      // what `pi-omnigent connect` prints: the code alone (the plugin's design) -- hence the hints and `check`
      const out = await cn.connectWithPassword({ ...options, server, username: 'woow', password: 'x' });
      assert.equal(out.ok, false); assert.deepEqual(out.error, { code: 'HOST_NAME_COLLISION' });
      // and what pi-agent-host-name check prints from the same state
      const chk = cli(home, ['check']);
      assert.equal(chk.code, 1); assert.ok(chk.out.includes(message), chk.out);
    } finally { process.env.PATH = savedPath; }
  });
}

for (const d of made) fs.rmSync(d, { recursive: true, force: true });
console.log(`SUMMARY passed=${passed} failed=${failed} skipped=${skipped}`);
process.exit(failed ? 1 : 0);
