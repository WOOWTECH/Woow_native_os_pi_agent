#!/usr/bin/env python3
"""Linux-safe real tar fixtures + fake Apple commands. No keys, network, or signing."""
import ast
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / 'scripts/sign-macos-piweb-artifact.sh'
IDENTITY = 'Developer ID Application: Fixture (TEST123)'
MAGIC = bytes.fromhex('cffaedfe')


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='artifact signing ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        self.source = self.root / 'piweb-test-macos-arm64.tar.gz'
        self.out = self.root / 'piweb-test-signed-macos-arm64.tar.gz'
        self.files = {
            'lib/.git/HEAD': b'6fcd7d44981ab51a21d6cd6eb06d361d0e3d3068\n',
            'lib/package.json': b'{"version":"0.10.0"}',
            'lib/package-lock.json': b'{"lockfileVersion":3}',
            'lib/libvips.dylib': MAGIC + b'libvips',
            'lib/sharp.node': MAGIC + b'sharp',
            'lib/next-swc.node': MAGIC + b'swc',
            'lib/esbuild': MAGIC + b'executable',
            'lib/unexpected name': MAGIC + b'no extension or execute bit',
            'lib/fat': bytes.fromhex('cafebabf') + b'fat',
            'lib/linux.node': b'\x7fELFnot mac',
            'lib/Example.class': bytes.fromhex('cafebabe') + b'Java',
            'lib/._sharp.node': b'AppleDouble bookkeeping',
        }
        self.archive(self.files)
        self.stub('uname', "print('Darwin')")
        self.stub('file', "print('Java class' if sys.argv[-1].endswith('.class') else 'Mach-O 64-bit executable arm64')")
        self.stub('lipo', "print('arm64 x86_64' if sys.argv[-1].endswith('/fat') else 'arm64')")
        self.stub('security', '''
if '-s' not in sys.argv:
    print('"/tmp/Original Keychain" "/tmp/login.keychain-db"')
''')
        self.stub('codesign', '''
p = Path(sys.argv[-1])
if '--force' in sys.argv:
    if os.environ.get('FAIL_SIGN') and p.name == 'sharp.node':
        print('fixture signing failure'); sys.exit(17)
    assert '--timestamp' in sys.argv and sys.argv[sys.argv.index('--options')+1] == 'runtime'
    assert sys.argv[sys.argv.index('--sign')+1] == 'Developer ID Application: Fixture (TEST123)'
    p.write_bytes(p.read_bytes() + b'\\nFIXTURE-SIGNED')
    if os.environ.get('MUTATE_SOURCE'):
        (p.parent / 'package.json').write_text('modified')
elif '--verify' in sys.argv:
    assert '--strict' in sys.argv and '--all-architectures' in sys.argv
    if b'FIXTURE-SIGNED' not in p.read_bytes():
        print('code object is not signed at all'); sys.exit(4)
else:
    assert '--architecture' in sys.argv
    if os.environ.get('BAD_AUTHORITY'):
        print('Authority=Apple Development: Wrong')
    else:
        print('Authority=Developer ID Application: Fixture (TEST123)')
    if not os.environ.get('MISSING_RUNTIME'):
        print('CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+2')
    if not os.environ.get('MISSING_TIMESTAMP'):
        print('Timestamp=Nov 14, 2026 at 12:00:00')
''')
        self.env = {**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}',
                    'PI_AGENT_BUILD_PYTHON': sys.executable, 'CALL_LOG': str(self.log),
                    'PYTHONDONTWRITEBYTECODE': '1'}

    def stub(self, name, body):
        p = self.bin / name
        p.write_text(f'#!{sys.executable}\nimport os,sys,json\nfrom pathlib import Path\n'
                     'with open(os.environ["CALL_LOG"], "a") as log: log.write(json.dumps([Path(sys.argv[0]).name]+sys.argv[1:])+"\\n")\n'
                     + body)
        p.chmod(0o755)

    def archive(self, files=None, entries=None):
        with tarfile.open(self.source, 'w:gz') as t:
            for name, data in (files or {}).items():
                m = tarfile.TarInfo(name)
                m.size = len(data)
                m.mode = 0o755 if name.endswith('esbuild') else 0o644
                t.addfile(m, io.BytesIO(data))
            if files:
                m = tarfile.TarInfo('bin/esbuild')
                m.type = tarfile.SYMTYPE
                m.linkname = '../lib/esbuild'
                t.addfile(m)
            for m, data in entries or []:
                t.addfile(m, io.BytesIO(data) if data is not None else None)

    def sha(self, path=None):
        return hashlib.sha256((path or self.source).read_bytes()).hexdigest()

    def invoke(self, verify=False, env=None, extra=None, source=None):
        source = source or self.source
        args = ['/bin/bash', str(HELPER), '--artifact-file', str(source),
                '--artifact-sha256', self.sha(source), '--sign-app', IDENTITY]
        args += ['--verify-only'] if verify else ['--out', str(self.out)]
        return subprocess.run(args + (extra or []), env={**self.env, **(env or {})},
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_signs_every_native_preserves_source_and_verifies_repacked_output(self):
        old_sha = self.sha()
        r = self.invoke()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.sha(), old_sha)
        self.assertNotEqual(self.sha(self.out), old_sha)
        report = json.loads(Path(str(self.out) + '.signing.json').read_text())
        expected = {'lib/libvips.dylib', 'lib/sharp.node', 'lib/next-swc.node',
                    'lib/esbuild', 'lib/unexpected name', 'lib/fat'}
        self.assertEqual({x['path'] for x in report['native_files']}, expected)
        self.assertEqual(Path(str(self.out) + '.sha256').read_text(), f'{self.sha(self.out)}  {self.out.name}\n')
        with tarfile.open(self.out) as t:
            for name in ('lib/.git/HEAD', 'lib/package.json', 'lib/package-lock.json', 'lib/linux.node'):
                self.assertEqual(t.extractfile('./' + name).read(), self.files[name])
            self.assertEqual(t.getmember('./bin/esbuild').linkname, '../lib/esbuild')
            self.assertNotIn('./lib/._sharp.node', t.getnames())
        r = self.invoke(verify=True, source=self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any('--architecture' in c and 'x86_64' in c for c in self.calls()))

    def test_python39_syntax_and_isolated_wrapper(self):
        ast.parse((REPO / 'scripts/macos/piweb-artifact-signing.py').read_text(), feature_version=(3, 9))
        self.assertIn('"${PI_AGENT_BUILD_PYTHON:-/usr/bin/python3}" -I', HELPER.read_text())

    def test_bad_input_sha_stops_before_signing(self):
        r = self.invoke(extra=['--artifact-sha256', '0' * 64])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('SHA256 mismatch', r.stderr)
        self.assertFalse(any(c[0] == 'codesign' for c in self.calls()))
        self.assertFalse(self.out.exists())

    def test_unsigned_verification_fails_without_mutation(self):
        old = self.sha()
        r = self.invoke(verify=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not signed at all', r.stderr)
        self.assertEqual(old, self.sha())
        self.assertFalse(any('--force' in c for c in self.calls()))

    def test_missing_trust_properties_fail(self):
        for fault in ('MISSING_TIMESTAMP', 'MISSING_RUNTIME', 'BAD_AUTHORITY'):
            with self.subTest(fault=fault):
                r = self.invoke(env={fault: '1'})
                self.assertNotEqual(r.returncode, 0)
                self.assertFalse(self.out.exists())

    def test_keychain_search_list_restored_on_signing_failure(self):
        keychain = self.root / 'Existing Signing.keychain-db'
        keychain.touch()
        r = self.invoke(env={'FAIL_SIGN': '1'}, extra=['--keychain', str(keychain)])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('fixture signing failure', r.stderr)
        calls = [c for c in self.calls() if c[0] == 'security']
        self.assertEqual(calls[-1], ['security', 'list-keychains', '-d', 'user', '-s',
                                    '/tmp/Original Keychain', '/tmp/login.keychain-db'])
        self.assertIn(str(keychain.resolve()), calls[1])
        self.assertFalse(self.out.exists())

    def test_non_native_mutation_is_rejected(self):
        r = self.invoke(env={'MUTATE_SOURCE': '1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('changed non-native', r.stderr)
        self.assertFalse(self.out.exists())

    def test_output_relabel_or_overwrite_rejected(self):
        for out in (self.source, self.root / 'piweb-signed-macos-x64.tar.gz'):
            with self.subTest(out=out):
                r = self.invoke(extra=['--out', str(out)])
                self.assertNotEqual(r.returncode, 0)
        self.out.write_bytes(b'existing')
        r = self.invoke()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.out.read_bytes(), b'existing')

    def test_unsafe_archive_graphs_rejected_before_codesign(self):
        def member(name, kind=tarfile.REGTYPE, target=''):
            m = tarfile.TarInfo(name); m.type = kind; m.linkname = target
            return (m, b'' if kind == tarfile.REGTYPE else None)
        cases = [
            [member('../escaped')], [member('/tmp/escaped')],
            [member('pivot', tarfile.SYMTYPE, '/tmp'), member('pivot/escaped')],
            [member('escape', tarfile.SYMTYPE, '../../escaped')],
            [member('hard', tarfile.LNKTYPE, '../escaped')],
            [member('fifo', tarfile.FIFOTYPE)],
            [member('dup'), member('dup')],
        ]
        for entries in cases:
            with self.subTest(entries=entries):
                self.archive(entries=entries)
                r = self.invoke()
                self.assertNotEqual(r.returncode, 0)
                self.assertFalse(any(c[0] == 'codesign' for c in self.calls()))
                self.assertFalse(self.out.exists())

    def test_release_builder_rejects_unsigned_archive_before_package_tools(self):
        self.stub('pkgbuild', "print('unexpected pkgbuild'); sys.exit(99)")
        r = subprocess.run(['/bin/bash', str(REPO / 'scripts/build-macos-pkg.sh'), '--release',
                            '--artifact-file', str(self.source), '--artifact-sha256', self.sha(),
                            '--sign-app', IDENTITY, '--sign', 'Developer ID Installer: Fixture (TEST123)',
                            '--notary-key', '/not/accessed', '--notary-key-id', 'test', '--notary-issuer', 'test'],
                           env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not signed at all', r.stderr)
        self.assertFalse(any(c[0] == 'pkgbuild' or c[0] == 'security' for c in self.calls()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
