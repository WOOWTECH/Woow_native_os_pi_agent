#!/usr/bin/env python3
"""Hermetic launcher tests: fake macOS commands, real Bash/Perl lock; no user state."""
import os
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mac launch ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.payload = self.root / 'payload'
        self.home = self.root / 'User Home'
        self.install = self.home / '.local/share/pi-agent'
        self.bin = self.root / 'bin'
        for p in (self.payload / 'scripts/macos', self.payload / 'rootfs/bin', self.home, self.bin):
            p.mkdir(parents=True)
        self.runner = self.payload / 'scripts/macos/pi-agent-launch.sh'
        self.runner.write_text((REPO / 'scripts/macos/pi-agent-launch.sh').read_text().replace('/usr/libexec/PlistBuddy', str(self.bin / 'PlistBuddy').replace(' ', '\\ ')))
        shutil.copy(REPO / 'rootfs/bin/flock', self.payload / 'rootfs/bin/flock')
        self.script(self.bin / 'uname', '[ "$1" = -m ] && echo arm64 || echo Darwin')
        self.script(self.bin / 'launchctl', 'exit 0')
        self.script(self.bin / 'id', 'echo 501')
        self.script(self.bin / 'curl', 'exit "${CURL_RC:-0}"')
        self.script(self.bin / 'open', 'printf "%s\\n" "$*" >> "$HOME/opened"')
        self.script(self.bin / 'PlistBuddy', 'case "$2" in *PI_WEB_PORT) cat "$HOME/existing-port" ;; *) cat "$HOME/existing-path" ;; esac')
        self.script(self.payload / 'install.sh', '''echo 'stage preflight'
printf '%s\\n' "$PI_AGENT_PIWEB_ARTIFACT" > "$HOME/artifact-used"
printf '%s|%s|%s\\n' "$PI_AGENT_HOME" "$PI_WEB_PORT" "$PI_AGENT_PIWEB_ARTIFACT_SHA256" >> "$HOME/installs"
[ "${FAIL_SETUP:-0}" = 0 ] || exit 23
mkdir -p "$PI_AGENT_HOME/bin"
printf '#!/bin/bash\\nexit 0\\n' > "$PI_AGENT_HOME/bin/pi-agent"
chmod +x "$PI_AGENT_HOME/bin/pi-agent"
echo 'stage service' ''')
        (self.payload / 'piweb-artifact-url').write_text('https://example.invalid/piweb-test-macos-arm64.tar.gz\n')
        (self.payload / 'piweb-artifact-sha256').write_text('a' * 64 + '\n')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('PI_', 'XDG_'))}
        self.env.update(HOME=str(self.home), PATH=f'{self.bin}:/usr/bin:/bin')

    def script(self, path, body):
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_launcher(self, mode='--open', **env):
        return subprocess.run(['/bin/bash', str(self.runner), mode], env={**self.env, **env}, text=True, capture_output=True, timeout=10)

    def test_fresh_setup_progress_log_and_browser(self):
        r = self.run_launcher()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('stage service', r.stdout)
        self.assertIn('stage preflight', (self.install / 'logs/macos-setup.log').read_text())
        self.assertEqual((self.home / 'opened').read_text().strip(), 'http://127.0.0.1:30141')
        self.assertEqual((self.install / 'logs/macos-setup.log').stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.install / '.macos-pkg-incomplete').exists())

    def test_postinstall_does_not_open_browser(self):
        for fail in ('1', '0'):
            r = subprocess.run(['/bin/bash', str(self.runner), '--install'],
                               env={**self.env, 'FAIL_SETUP': fail}, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 1 if fail == '1' else 0, r.stderr)
        self.assertFalse((self.home / 'opened').exists())

    def test_failure_remains_retryable_and_keeps_data(self):
        self.install.mkdir(parents=True)
        (self.install / 'identity').write_text('keep me')
        r = self.run_launcher(FAIL_SETUP='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue((self.install / '.macos-pkg-incomplete').exists())
        self.assertFalse((self.home / 'opened').exists())
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual((self.install / 'identity').read_text(), 'keep me')
        self.assertEqual(len((self.home / 'installs').read_text().splitlines()), 2)

    def test_reopen_does_not_reinstall_but_repair_does(self):
        for mode in ('--open', '--open', '--repair'):
            self.assertEqual(self.run_launcher(mode).returncode, 0)
        self.assertEqual(len((self.home / 'installs').read_text().splitlines()), 2)

    def test_existing_launchd_location_and_port(self):
        custom = self.home / 'Custom install'
        custom.mkdir()
        (custom / 'pi-web-port').write_text('30222\n')
        plist = self.home / 'Library/LaunchAgents/io.woowtech.pi-agent.plist'
        plist.parent.mkdir(parents=True)
        plist.write_text('existing identity')
        (self.home / 'existing-path').write_text(str(custom))
        r = self.run_launcher('--repair')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'{custom}|30222|', (self.home / 'installs').read_text())
        self.assertEqual(plist.read_text(), 'existing identity')
        self.assertFalse(self.install.exists())
        r = self.run_launcher(PI_AGENT_HOME=str(self.install))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('leaving both untouched', r.stderr)

    def test_invalid_port_and_pin_do_not_install(self):
        self.install.mkdir(parents=True)
        (self.install / 'pi-web-port').write_text('0;touch bad')
        self.assertNotEqual(self.run_launcher().returncode, 0)
        (self.install / 'pi-web-port').unlink()
        (self.payload / 'piweb-artifact-sha256').write_text('bad')
        self.assertNotEqual(self.run_launcher().returncode, 0)
        self.assertFalse((self.home / 'installs').exists())

    def test_parallel_open_installs_once(self):
        args = ['/bin/bash', str(self.runner), '--open']
        a = subprocess.Popen(args, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        b = subprocess.Popen(args, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for proc in (a, b):
            out, err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, (out, err))
        self.assertEqual(len((self.home / 'installs').read_text().splitlines()), 1)

    def local_artifact(self, name='piweb-test-macos-arm64.tar.gz'):
        (self.payload / 'artifacts').mkdir(exist_ok=True)
        artifact = self.payload / 'artifacts' / name
        artifact.write_bytes(b'fixture artifact bytes')
        (self.payload / 'piweb-artifact-url').write_text('')
        (self.payload / 'piweb-artifact-file').write_text(name + '\n')
        (self.payload / 'piweb-artifact-sha256').write_text(hashlib.sha256(artifact.read_bytes()).hexdigest() + '\n')
        return artifact

    def test_local_artifact_passes_verified_path_to_installer(self):
        artifact = self.local_artifact()
        r = self.run_launcher('--install')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.home / 'artifact-used').read_text().strip(), str(artifact))
        self.assertIn('Verifying embedded', r.stdout)

    def test_local_artifact_tamper_rejected_before_installer(self):
        artifact = self.local_artifact()
        artifact.write_bytes(b'tampered')
        r = self.run_launcher('--install')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('sha256 mismatch', r.stderr)
        self.assertFalse((self.home / 'installs').exists())

    def test_local_artifact_wrong_arch_rejected_before_installer(self):
        self.local_artifact('piweb-test-macos-x64.tar.gz')
        r = self.run_launcher('--install')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('architecture does not match', r.stderr)
        self.assertFalse((self.home / 'installs').exists())

    def test_local_artifact_selector_rejects_traversal(self):
        self.local_artifact()
        (self.payload / 'piweb-artifact-file').write_text('../piweb-test-macos-arm64.tar.gz')
        r = self.run_launcher('--install')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Invalid embedded artifact filename', r.stderr)
        self.assertFalse((self.home / 'installs').exists())

    def test_builder_local_sha_and_arch_checks_before_copy(self):
        artifact = self.local_artifact()
        sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
        base = ['/bin/bash', str(REPO / 'scripts/build-macos-pkg.sh'), '--artifact-file', str(artifact),
                '--tools', '/nonexistent/pi-agent-test', '--out', str(self.root / 'out')]
        cases = [(['--artifact-sha256', sha], 'no bundled tmux'),
                 (['--artifact-sha256', '0' * 64], 'local artifact sha256 mismatch'),
                 (['--artifact-sha256', sha, '--arch', 'x64'], 'does not match --arch'),
                 ([], '--artifact-sha256 must be'),
                 (['--artifact-sha256', sha, '--artifact-url', 'https://example.invalid/piweb-macos-arm64.tar.gz'], 'choose exactly one')]
        for args, message in cases:
            with self.subTest(args=args):
                r = subprocess.run(base + args, capture_output=True, text=True)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(message, r.stderr)
                self.assertFalse((self.root / 'out').exists())
        wrong = artifact.with_name('piweb-test-linux-arm64.tar.gz')
        artifact.rename(wrong)
        base[3] = str(wrong)
        r = subprocess.run(base + ['--artifact-sha256', sha], capture_output=True, text=True)
        self.assertIn('--artifact-file filename must be', r.stderr)

    def test_existing_plist_port_without_port_file(self):
        custom = self.home / 'Custom install'
        custom.mkdir()
        plist = self.home / 'Library/LaunchAgents/io.woowtech.pi-agent.plist'
        plist.parent.mkdir(parents=True)
        plist.write_text('existing identity')
        (self.home / 'existing-path').write_text(str(custom))
        (self.home / 'existing-port').write_text('30223')
        r = self.run_launcher('--repair')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'{custom}|30223|', (self.home / 'installs').read_text())
        self.assertEqual((self.home / 'opened').read_text().strip(), 'http://127.0.0.1:30223')

    def test_unready_service_reports_repair_without_opening_browser(self):
        self.assertEqual(self.run_launcher('--install').returncode, 0)
        self.runner.write_text(self.runner.read_text().replace('SECONDS + 120', 'SECONDS + 0'))
        r = self.run_launcher(CURL_RC='7')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Pi Agent Repair.command', r.stderr)
        self.assertFalse((self.home / 'opened').exists())

    def test_missing_launchd_job_reports_repair(self):
        self.assertEqual(self.run_launcher('--install').returncode, 0)
        self.script(self.bin / 'launchctl', 'exit 1')
        r = self.run_launcher()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('launchd job is not loaded', r.stderr)
        self.assertFalse((self.home / 'opened').exists())

    def test_root_is_rejected(self):
        self.script(self.bin / 'id', 'echo 0')
        self.assertNotEqual(self.run_launcher().returncode, 0)
        self.assertFalse(self.install.exists())

    def test_package_version_validation_before_native_tools(self):
        for version, valid in [('0.3.0-rc.8', True), ('v0.3.0-rc.8', True),
                               ('1.2.3', True), ('01.2.3', False),
                               ('1.2.3-rc.08', False), ('1.2', False),
                               ('1.2.3+build', False), ('1.2.3\ninvalid', False), ('../bad', False)]:
            with self.subTest(version=version):
                r = subprocess.run(['/bin/bash', str(REPO / 'scripts/build-macos-pkg.sh'),
                                    '--artifact-url', 'https://example.invalid/piweb-macos-arm64.tar.gz',
                                    '--artifact-sha256', 'a' * 64, '--tools', '/nonexistent/pi-agent-test'],
                                   env={**os.environ, 'PI_AGENT_VERSION': version}, capture_output=True, text=True)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('no bundled tmux' if valid else 'version must be SemVer', r.stderr)

    def test_release_gate_rejects_unsigned_before_tools(self):
        r = subprocess.run(['/bin/bash', str(REPO / 'scripts/build-macos-pkg.sh'), '--release'], text=True, capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('--release needs --sign-app', r.stderr)
        r = subprocess.run(['/bin/bash', str(REPO / 'scripts/build-macos-pkg.sh'), '--release', '--sign-app', 'Developer ID Application: Test', '--sign', 'Developer ID Installer: Test'], text=True, capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('all three notarization parameters', r.stderr)

class GateTests(unittest.TestCase):
    def test_verifier_propagates_trust_failures(self):
        with tempfile.TemporaryDirectory(prefix='mac-gate-') as tmp:
            root = Path(tmp)
            pkg = root / 'test.pkg'
            pkg.touch()
            scripts = {
                'uname': 'echo Darwin',
                'pkgutil': '''if [ "$1" = --check-signature ]; then
  echo 'Developer ID Installer: Test'; exit "${FAIL_SIGNATURE:-0}"
fi
mkdir -p "$3/component/Payload/usr/local/lib/woow-pi-agent/tools/bin"
touch "$3/component/Payload/usr/local/lib/woow-pi-agent/tools/bin/tmux"''',
                'xcrun': 'exit "${FAIL_STAPLE:-0}"',
                'spctl': 'exit "${FAIL_GATEKEEPER:-0}"',
                'codesign': '''[ "${FAIL_CODESIGN:-0}" = 0 ] || exit 1
echo 'Authority=Developer ID Application: Test'
echo 'flags=0x10000(runtime)'
echo 'Timestamp=Nov 14, 2026'
''',
            }
            for name, body in scripts.items():
                p = root / name
                p.write_text('#!/bin/bash\n' + body + '\n')
                p.chmod(0o755)
            env = {**os.environ, 'PATH': f'{root}:/usr/bin:/bin'}
            for fail in (None, 'FAIL_SIGNATURE', 'FAIL_STAPLE', 'FAIL_GATEKEEPER', 'FAIL_CODESIGN'):
                with self.subTest(fail=fail):
                    r = subprocess.run(['/bin/bash', str(REPO / 'scripts/verify-macos-pkg.sh'), str(pkg)],
                                       env={**env, **({fail: '1'} if fail else {})}, capture_output=True, text=True)
                    self.assertEqual(r.returncode == 0, fail is None, r.stderr)

if __name__ == '__main__':
    unittest.main(verbosity=2)
