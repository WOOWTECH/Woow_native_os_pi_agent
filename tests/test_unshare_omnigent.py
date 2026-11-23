"""pi-agent-unshare-omnigent.py and `install.sh fetch` (docs/OPERATIONS-GOTCHAS.md section 22).

Plugin <= 0.3.34 left its managed omnigent hard-linked into its uv cache; plugin 0.3.35 starts
no host from multi-linked SDK files. The fixtures here are hard links made with os.link in temp
directories; nothing outside them is touched.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('unshare', ROOT / 'rootfs/bin/pi-agent-unshare-omnigent.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

SITE = 'lib/python3.12/site-packages/'
FILES = {
    SITE + 'omnigent/__init__.py': (b'__version__ = "0.16.0"\n', 0o644),
    SITE + 'omnigent/_speedups.so': (bytes(range(256)) * 64, 0o755),
    SITE + 'omnigent/native/native_bridge_common.py': (b'# common\n' * 900, 0o644),
    SITE + 'omnigent-0.16.0.dist-info/INSTALLER': (b'', 0o644),
}
TIMES = (1_700_000_000_123_456_789, 1_600_000_000_987_654_321)


class Fixture:
    def __init__(self, base):
        self.home = base / 'pa'
        self.tool = self.home / 'data/omnigent-plugin/uv/tools/omnigent'
        self.cache = self.home / 'data/omnigent-plugin/uv-cache/archive-v0/fixture'

    def build(self):
        for relative, (data, mode) in FILES.items():
            cached, path = self.cache / relative, self.tool / relative
            cached.parent.mkdir(parents=True, exist_ok=True)
            path.parent.mkdir(parents=True, exist_ok=True)
            cached.write_bytes(data)
            cached.chmod(mode)
            os.utime(cached, ns=TIMES)
            os.link(cached, path)
        # uv writes the entry script and the interpreter link itself: one link, never followed.
        (self.tool / 'bin').mkdir()
        (self.tool / 'bin/omnigent').write_bytes(b'#!/fixture/python\n')
        (self.tool / 'bin/python').symlink_to('/usr/bin/python3')
        return self

    def snapshot(self, root):
        result = {}
        for path in sorted(root.rglob('*')):
            info = path.lstat()
            key = str(path.relative_to(root))
            if stat.S_ISREG(info.st_mode):
                result[key] = {'sha': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': stat.S_IMODE(info.st_mode),
                               'mtime': info.st_mtime_ns, 'links': info.st_nlink, 'inode': info.st_ino}
            elif stat.S_ISLNK(info.st_mode):
                result[key] = {'link': os.readlink(path)}
        return result


def run_main(home, *extra):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = mod.main(['pi-agent-unshare-omnigent.py', str(home), *extra])
    text = out.getvalue()
    return code, json.loads(text), text


class UnshareTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.fx = Fixture(self.base)

    def test_first_install_and_missing_tool_tree_are_left_alone(self):
        self.assertEqual(run_main(self.fx.home)[:2], (0, {'status': 'absent', 'tool': '/'.join(mod.TOOL)}))
        (self.fx.home / 'data/omnigent-plugin').mkdir(parents=True)
        self.assertEqual(run_main(self.fx.home)[1]['status'], 'absent')

    def test_check_counts_shared_files_and_changes_nothing(self):
        self.fx.build()
        before = self.fx.snapshot(self.fx.home)
        code, report, text = run_main(self.fx.home, '--check')
        self.assertEqual((code, report['status'], report['shared']), (3, 'shared', len(FILES)))
        self.assertEqual(report['sharedBytes'], sum(len(data) for data, _ in FILES.values()))
        self.assertEqual(self.fx.snapshot(self.fx.home), before)
        self.assertNotIn(str(self.base), text)  # counts and a fixed relative label only

    def test_repair_keeps_bytes_mode_and_times_and_leaves_the_cache_copy(self):
        self.fx.build()
        tool, cache = self.fx.snapshot(self.fx.tool), self.fx.snapshot(self.fx.cache)
        code, report, text = run_main(self.fx.home)
        self.assertEqual((code, report['status'], report['repaired'], report['remaining']), (0, 'repaired', len(FILES), 0))
        self.assertNotIn(str(self.base), text)
        after = self.fx.snapshot(self.fx.tool)
        self.assertEqual(set(after), set(tool))
        for key, old in tool.items():
            new = after[key]
            if 'link' in old:
                self.assertEqual(new, old)
                continue
            self.assertEqual((new['sha'], new['mode'], new['mtime'], new['links']), (old['sha'], old['mode'], old['mtime'], 1), key)
            self.assertEqual(new['inode'] != old['inode'], old['links'] > 1, key)  # bin/omnigent keeps its inode
        cached = self.fx.snapshot(self.fx.cache)
        for key, old in cache.items():
            self.assertEqual((cached[key]['sha'], cached[key]['inode'], cached[key]['links']), (old['sha'], old['inode'], 1))
        self.assertFalse([p for p in self.fx.home.rglob(mod.TEMP_PREFIX + '*')])
        self.assertEqual(run_main(self.fx.home)[:2], (0, {**{k: 0 for k in ('blocked', 'shared', 'sharedBytes', 'staleTemps')},
                                                          'files': len(FILES) + 1, 'status': 'clean', 'tool': '/'.join(mod.TOOL)}))

    def test_two_names_inside_the_tool_tree_both_end_with_one_link(self):
        self.fx.build()
        first = self.fx.tool / SITE / 'omnigent/a.py'
        first.write_bytes(b'same\n')
        os.link(first, self.fx.tool / SITE / 'omnigent/b.py')
        self.assertEqual(run_main(self.fx.home)[0], 0)
        a, b = (self.fx.tool / SITE / 'omnigent/a.py').stat(), (self.fx.tool / SITE / 'omnigent/b.py').stat()
        self.assertEqual((a.st_nlink, b.st_nlink), (1, 1))
        self.assertNotEqual(a.st_ino, b.st_ino)

    def test_symlinks_are_never_followed(self):
        self.fx.build()
        outside = self.base / 'outside'
        outside.mkdir()
        (outside / 'a').write_bytes(b'outside\n')
        os.link(outside / 'a', outside / 'b')
        (self.fx.tool / 'lib/linked-dir').symlink_to(outside)
        (self.fx.tool / 'lib/linked-file').symlink_to(outside / 'a')
        before = self.fx.snapshot(outside)
        self.assertEqual(run_main(self.fx.home)[0], 0)
        self.assertEqual(self.fx.snapshot(outside), before)
        self.assertTrue((self.fx.tool / 'lib/linked-dir').is_symlink())

    def test_a_symlinked_tool_path_is_refused(self):
        real = self.base / 'elsewhere'
        real.mkdir()
        (real / 'f').write_bytes(b'x')
        os.link(real / 'f', real / 'g')
        for link_at in ('uv', 'uv/tools/omnigent'):
            with self.subTest(link_at=link_at):
                plugin = self.fx.home / 'data/omnigent-plugin'
                target = plugin / link_at
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(real)
                code, report, _ = run_main(self.fx.home)
                self.assertEqual((code, report['status'], report['reason']), (1, 'refused', 'unsafe-tool-path'))
                self.assertEqual((real / 'f').stat().st_nlink, 2)
                target.unlink()

    def test_short_space_changes_nothing(self):
        self.fx.build()
        before = self.fx.snapshot(self.fx.home)
        tiny = os.statvfs_result((4096, 4096, 10, 1, 1, 10, 1, 1, 0, 255))
        with mock.patch.object(mod.os, 'statvfs', return_value=tiny):
            code, report, _ = run_main(self.fx.home)
        self.assertEqual((code, report['reason']), (1, 'insufficient-space'))
        self.assertEqual(self.fx.snapshot(self.fx.home), before)

    def test_another_users_tree_or_a_read_only_directory_changes_nothing(self):
        self.fx.build()
        before = self.fx.snapshot(self.fx.home)
        with mock.patch.object(mod.os, 'getuid', return_value=os.getuid() + 1):
            self.assertEqual(run_main(self.fx.home)[1]['reason'], 'foreign-owner')
        package = self.fx.tool / SITE / 'omnigent/native'
        package.chmod(0o555)
        self.addCleanup(package.chmod, 0o755)
        code, report, _ = run_main(self.fx.home)
        self.assertEqual((code, report['reason'], report['blocked']), (1, 'foreign-owner-or-read-only', 1))
        self.assertEqual(self.fx.snapshot(self.fx.home), before)

    def test_a_write_during_the_copy_keeps_the_original_and_no_temp(self):
        self.fx.build()
        target = self.fx.tool / SITE / 'omnigent/__init__.py'  # the first shared file in walk order
        real_utime = os.utime
        writes = []

        def utime_then_write(fd, **kwargs):
            real_utime(fd, **kwargs)
            if not writes:
                writes.append(1)
                with open(target, 'ab') as stream:
                    stream.write(b'# late write\n')

        with mock.patch.object(mod.os, 'utime', side_effect=utime_then_write):
            code, report, _ = run_main(self.fx.home)
        self.assertEqual((code, report['reason']), (1, 'changed-during-repair'))
        self.assertEqual(target.stat().st_nlink, 2)
        self.assertEqual(target.read_bytes(), FILES[SITE + 'omnigent/__init__.py'][0] + b'# late write\n')
        self.assertFalse([p for p in self.fx.home.rglob(mod.TEMP_PREFIX + '*')])
        self.assertEqual(run_main(self.fx.home)[1]['status'], 'repaired')  # a rerun finishes the job

    def test_a_temp_left_by_a_killed_repair_is_reported_and_removed(self):
        self.fx.build()
        stale = self.fx.tool / SITE / ('omnigent/' + mod.TEMP_PREFIX + 'deadbeefdeadbeef.4242')
        stale.write_bytes(b'partial')
        code, report, _ = run_main(self.fx.home, '--check')
        self.assertEqual((code, report['staleTemps']), (3, 1))
        code, report, _ = run_main(self.fx.home)
        self.assertEqual((code, report['staleTempsRemoved']), (0, 1))
        self.assertFalse(stale.exists())

    def test_usage(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(mod.main(['pi-agent-unshare-omnigent.py']), 2)
            self.assertEqual(mod.main(['pi-agent-unshare-omnigent.py', '/x', '--repair']), 2)


@unittest.skipUnless(sys.platform.startswith('linux'), 'install.sh runs the repair on Linux and WSL only')
class FetchStageTests(unittest.TestCase):
    """The real `install.sh fetch`: repair first, and stop before the plugin is replaced when it cannot."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.fx = Fixture(Path(temp.name)).build()
        self.marker = self.fx.home / 'plugins/pi-omnigent-plugin/package.json'
        self.marker.parent.mkdir(parents=True)
        self.marker.write_text('{"name": "@woowtech/pi-omnigent-plugin", "version": "0.3.34"}')

    def fetch(self):
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(self.fx.home.parent), 'PI_AGENT_HOME': str(self.fx.home)}
        result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), 'fetch'], env=env, capture_output=True, text=True, timeout=300)
        return result.returncode, result.stdout + result.stderr

    def test_fetch_repairs_before_unpacking(self):
        _, output = self.fetch()  # may stop later for want of the fixture's node; the repair comes first
        self.assertIn('hard-linked files now have their own copies', output)
        for relative in FILES:
            self.assertEqual((self.fx.tool / relative).stat().st_nlink, 1, relative)

    def test_fetch_stops_with_the_old_plugin_in_place_when_refused(self):
        package = self.fx.tool / SITE / 'omnigent'
        package.chmod(0o555)
        self.addCleanup(package.chmod, 0o755)
        code, output = self.fetch()
        self.assertNotEqual(code, 0)
        self.assertIn('foreign-owner-or-read-only', output)
        self.assertIn('section 22', output)
        self.assertIn('0.3.34', self.marker.read_text())
        self.assertEqual((self.fx.tool / SITE / 'omnigent/__init__.py').stat().st_nlink, 2)


if __name__ == '__main__':
    unittest.main()
