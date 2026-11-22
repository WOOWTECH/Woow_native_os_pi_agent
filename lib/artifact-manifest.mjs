// Bind a prebuilt Pi Web tree to this native release and the frozen adapters.
// This receipt is written only after a source build; packaging verifies it.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

export const receiptName = 'pi-agent-artifact.json';
const sha = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));

export function expectedManifest(root, os, arch, piWebVersion, piWebRef, adapterSha256) {
  const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
  assert.match(version, /^\d+\.\d+\.\d+(?:-[\w.-]+)?$/);
  assert.ok(['linux', 'macos'].includes(os));
  assert.ok(['x64', 'arm64'].includes(arch));
  assert.match(piWebRef, /^[a-f0-9]{40}$/);
  assert.match(adapterSha256, /^[a-f0-9]{64}$/);
  const rows = json(path.join(root, 'candidate-packages/manifest.json')).artifacts;
  assert.equal(rows.length, 3, 'three frozen packages are required');
  assert.equal(new Set(rows.map(row => row.file)).size, 3);
  const packages = rows.map(({ file, sha256, sourceCommit, sourceFreezeSha256, releaseHandoffSha256 }) => {
    assert.match(file, /^woowtech-pi-(?:paseo|omnigent-plugin|agent-shared-runtime)-\d+\.\d+\.\d+\.tgz$/);
    // A local reviewed candidate may have a frozen source set before a commit.
    // Keep that identity explicit; never label its bytes with the base commit.
    let provenance;
    if (sourceCommit !== undefined) {
      assert.match(sourceCommit, /^[a-f0-9]{40}$/);
      assert.equal(sourceFreezeSha256, undefined, 'ambiguous candidate provenance');
      assert.equal(releaseHandoffSha256, undefined, 'ambiguous candidate provenance');
      provenance = { sourceCommit };
    } else {
      assert.match(sourceFreezeSha256, /^[a-f0-9]{64}$/);
      assert.match(releaseHandoffSha256, /^[a-f0-9]{64}$/);
      provenance = { sourceFreezeSha256, releaseHandoffSha256 };
    }
    assert.equal(sha(path.join(root, 'candidate-packages', file)), sha256, `frozen archive changed: ${file}`);
    return { file, sha256, ...provenance };
  }).sort((a, b) => a.file.localeCompare(b.file));
  return { schema: 1, version, os, arch, piWebVersion, piWebRef, adapterSha256, packages };
}

function packageRoot(tree) { return path.join(tree, 'lib/node_modules/@agegr/pi-web'); }
function verifyTree(tree, expected) {
  assert.equal(json(path.join(packageRoot(tree), 'package.json')).version, expected.piWebVersion);
  for (const file of ['.next/BUILD_ID', '.next/server/app/omnigent/page.js', '.next/server/app/paseo/setup/page.js']) {
    assert.ok(fs.statSync(path.join(packageRoot(tree), file)).isFile(), `missing compiled route: ${file}`);
  }
}
export function writeManifest(tree, expected) {
  verifyTree(tree, expected);
  const ref = execFileSync('git', ['-C', packageRoot(tree), 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  assert.equal(ref, expected.piWebRef, 'source build ref differs from pins');
  fs.writeFileSync(path.join(tree, receiptName), JSON.stringify(expected, null, 2) + '\n');
}
export function verifyManifest(tree, expected) {
  assert.deepEqual(json(path.join(tree, receiptName)), expected,
    'prebuilt Pi Web does not match this native release, platform or frozen payloads; use its matching release asset');
  verifyTree(tree, expected);
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const [mode, tree, root, os, arch, version, ref, adapter] = process.argv.slice(2);
  assert.ok(['write', 'verify'].includes(mode), 'expected write or verify');
  const expected = expectedManifest(root, os, arch, version, ref, adapter);
  (mode === 'write' ? writeManifest : verifyManifest)(tree, expected);
}
