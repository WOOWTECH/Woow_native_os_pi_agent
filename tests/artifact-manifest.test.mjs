import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { expectedManifest, receiptName, verifyManifest, writeManifest } from '../lib/artifact-manifest.mjs';

const repo = path.resolve(import.meta.dirname, '..');
const pins = Object.fromEntries(execFileSync('bash', ['-c',
  '. "$1/lib/pins.sh"; printf "%s\\n" "$PIN_PI_WEB_VERSION" "$PIN_PI_WEB_REF" "$PIN_OMNIGENT_UI_SHA256"', '_', repo],
{ encoding: 'utf8' }).trim().split('\n').map((value, i) => [['version', 'ref', 'adapter'][i], value]));
const expected = () => expectedManifest(repo, 'linux', 'x64', pins.version, pins.ref, pins.adapter);
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'native-artifact-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const tree = path.join(dir, 'tree'), pkg = path.join(tree, 'lib/node_modules/@agegr/pi-web');
  fs.mkdirSync(pkg, { recursive: true });
  fs.writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({ version: pins.version }));
  for (const name of ['.next/BUILD_ID', '.next/server/app/omnigent/page.js', '.next/server/app/paseo/setup/page.js']) {
    fs.mkdirSync(path.dirname(path.join(pkg, name)), { recursive: true });
    fs.writeFileSync(path.join(pkg, name), 'fixture');
  }
  const manifest = expected();
  const save = () => fs.writeFileSync(path.join(tree, receiptName), JSON.stringify(manifest));
  save(); return { dir, tree, pkg, manifest, save };
}
test('matching release, platform and exact frozen archives are accepted', t => {
  const f = fixture(t); verifyManifest(f.tree, expected());
});
for (const [name, mutate] of [
  ['old native version', m => { m.version = '0.2.7'; }],
  ['wrong architecture', m => { m.arch = 'arm64'; }],
  ['wrong platform', m => { m.os = 'macos'; }],
  ['stale combined adapter', m => { m.adapterSha256 = '0'.repeat(64); }],
  ['stale Pi Web source', m => { m.piWebRef = '0'.repeat(40); }],
  ['changed packaged bytes', m => { m.packages[0].sha256 = '0'.repeat(64); }],
  ['missing shared package', m => { m.packages.pop(); }],
]) test(`rejects ${name}`, t => {
  const f = fixture(t); mutate(f.manifest); f.save();
  assert.throws(() => verifyManifest(f.tree, expected()), /does not match/);
});
test('legacy artifact without provenance cannot satisfy the current release', t => {
  const f = fixture(t); fs.unlinkSync(path.join(f.tree, receiptName));
  assert.throws(() => verifyManifest(f.tree, expected()), /ENOENT/);
});
test('a receipt cannot hide missing compiled Agent Connect routes', t => {
  const f = fixture(t); fs.unlinkSync(path.join(f.pkg, '.next/server/app/paseo/setup/page.js'));
  assert.throws(() => verifyManifest(f.tree, expected()), /ENOENT/);
});
test('source writer binds the actual checked-out source commit', t => {
  const f = fixture(t);
  const git = args => execFileSync('git', ['-C', f.pkg, ...args], { encoding: 'utf8' }).trim();
  git(['init', '-q']); git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']);
  assert.throws(() => writeManifest(f.tree, expected()), /source build ref/);
  f.manifest.piWebRef = git(['rev-parse', 'HEAD']);
  writeManifest(f.tree, f.manifest); verifyManifest(f.tree, f.manifest);
});
test('real installer rejects an old tree without deleting the existing installation', t => {
  const f = fixture(t), install = path.join(f.dir, 'install');
  fs.mkdirSync(path.join(install, 'node/bin'), { recursive: true });
  fs.symlinkSync(process.execPath, path.join(install, 'node/bin/node'));
  fs.mkdirSync(path.join(install, 'piweb'), { recursive: true });
  const retained = path.join(install, 'piweb/existing.txt'); fs.writeFileSync(retained, 'retain');
  f.manifest.version = '0.2.7'; f.save();
  const archive = path.join(f.dir, 'piweb-stale-linux-x64.tar.gz');
  execFileSync('tar', ['czf', archive, '-C', f.tree, '.']);
  const result = spawnSync('bash', [path.join(repo, 'install.sh'), 'piweb'], {
    cwd: repo, encoding: 'utf8', env: { HOME: f.dir, PATH: process.env.PATH,
      PI_AGENT_HOME: install, PI_AGENT_PIWEB_ARTIFACT: archive },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /release binding failed/);
  assert.equal(fs.readFileSync(retained, 'utf8'), 'retain');
});

test('every frozen candidate binds the source commit it was packed from', () => {
  for (const row of expected().packages) {
    assert.match(row.sourceCommit, /^[a-f0-9]{40}$/, row.file);
    assert.equal(row.sourceFreezeSha256, undefined, row.file);
    assert.equal(row.releaseHandoffSha256, undefined, row.file);
  }
  // pi-omnigent-plugin #33, squash-merged; git archive + npm pack reproduces the archive.
  assert.equal(expected().packages.find(x => x.file.includes('omnigent-plugin-0.3.36')).sourceCommit,
    'b21f2e6e31c283059bc31e3076da01d1d7411cc0');
});
// A reviewed candidate frozen before it had a commit (as 0.3.35 was) keeps its
// freeze and handoff identity instead; never both kinds of provenance.
const freezeOnly = row => { delete row.sourceCommit; row.sourceFreezeSha256 = 'b'.repeat(64); row.releaseHandoffSha256 = 'c'.repeat(64); };
function withPluginRow(t, mutate) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'candidate-provenance-'));
  t.after(() => fs.rmSync(dir, { recursive:true, force:true }));
  fs.copyFileSync(path.join(repo,'VERSION'),path.join(dir,'VERSION'));
  fs.cpSync(path.join(repo,'candidate-packages'),path.join(dir,'candidate-packages'),{recursive:true});
  const file=path.join(dir,'candidate-packages/manifest.json');
  const value=JSON.parse(fs.readFileSync(file));
  mutate(value.artifacts.find(x => x.file.includes('omnigent-plugin-0.3.36')));
  fs.writeFileSync(file,JSON.stringify(value));
  return dir;
}
test('a pre-commit candidate retains exact freeze and handoff provenance', t => {
  const dir = withPluginRow(t, freezeOnly);
  const row = expectedManifest(dir,'linux','x64',pins.version,pins.ref,pins.adapter).packages.find(x => x.file.includes('omnigent-plugin-0.3.36'));
  assert.equal(row.sourceCommit, undefined);
  assert.equal(row.sourceFreezeSha256, 'b'.repeat(64));
  assert.equal(row.releaseHandoffSha256, 'c'.repeat(64));
});
for (const [label, mutate] of [
  ['missing freeze', row => { freezeOnly(row); delete row.sourceFreezeSha256; }],
  ['malformed freeze', row => { freezeOnly(row); row.sourceFreezeSha256 = 'not-a-pin'; }],
  ['missing handoff', row => { freezeOnly(row); delete row.releaseHandoffSha256; }],
  ['ambiguous commit and freeze', row => { row.sourceFreezeSha256 = 'b'.repeat(64); }],
  ['malformed commit', row => { row.sourceCommit = 'not-a-commit'; }],
]) test(`source candidate rejects ${label}`, t => {
  const dir = withPluginRow(t, mutate);
  assert.throws(() => expectedManifest(dir,'linux','x64',pins.version,pins.ref,pins.adapter));
});
