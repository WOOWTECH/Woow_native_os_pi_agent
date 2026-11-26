"""Owned procfs race fixtures; no installer, SDK, provider or tenant imports."""
import errno
import io
import json
import os
from pathlib import Path
import sys
import signal
import tempfile
import time
import types
import unittest
from unittest import mock

import owned_acceptance_supervisor as supervisor
import owned_native_acceptance as owned

HERE = Path(__file__).resolve().parent


def proc_stat(pid=42, birth=100, pgid=7, session=7, state='R'):
    # Linux stat fields 3..22: state, ppid, pgrp, session, then starttime.
    fields = [state, '1', str(pgid), str(session)] + ['0'] * 15 + [str(birth)]
    return f'{pid} (owned fixture) ' + ' '.join(fields)


class IdentityRaceTests(unittest.TestCase):
    def test_ghost_root_owner_then_dead_stat_is_gone(self):
        """A vanished task's directory can report root before stat says gone."""
        for error in (FileNotFoundError(errno.ENOENT, 'private'),
                      ProcessLookupError(errno.ESRCH, 'private')):
            with self.subTest(errno=error.errno), \
                 mock.patch.object(Path, 'open', side_effect=[io.StringIO(proc_stat()), error]), \
                 mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=0)):
                self.assertIsNone(supervisor.identity(42))

    def test_disappearance_at_stat_open_read_or_owner_lookup_is_gone(self):
        for error_type, number in [(FileNotFoundError, errno.ENOENT),
                                   (ProcessLookupError, errno.ESRCH)]:
            for site in ('first-open', 'first-read', 'owner', 'last-open', 'last-read'):
                error = error_type(number, 'untrusted path must not escape')
                stream = mock.MagicMock()
                stream.__enter__.return_value.read.side_effect = error
                streams = [io.StringIO(proc_stat()), io.StringIO(proc_stat())]
                owner = types.SimpleNamespace(st_uid=1000)
                if site == 'first-open': streams[0] = error
                if site == 'first-read': streams[0] = stream
                if site == 'last-open': streams[1] = error
                if site == 'last-read': streams[1] = stream
                with self.subTest(errno=number, site=site), \
                     mock.patch.object(Path, 'open', side_effect=streams), \
                     mock.patch.object(Path, 'stat', side_effect=error if site == 'owner' else None,
                                       return_value=owner):
                    self.assertIsNone(supervisor.identity(42))

    def test_permission_io_unknown_errors_are_not_disappearance(self):
        for number in (errno.EACCES, errno.EPERM, errno.EIO, errno.EBADF):
            for site in ('first', 'owner', 'last'):
                error = OSError(number, 'private untrusted diagnostic')
                streams = [io.StringIO(proc_stat()), io.StringIO(proc_stat())]
                if site == 'first': streams[0] = error
                if site == 'last': streams[1] = error
                with self.subTest(errno=number, site=site), \
                     mock.patch.object(Path, 'open', side_effect=streams), \
                     mock.patch.object(Path, 'stat', side_effect=error if site == 'owner' else None,
                                       return_value=types.SimpleNamespace(st_uid=1000)):
                    with self.assertRaises(OSError) as caught:
                        supervisor.identity(42)
                    self.assertEqual(caught.exception.errno, number)
        # Errno, not a misleading exception class, decides whether it is gone.
        with mock.patch.object(Path, 'open', side_effect=ProcessLookupError(errno.EIO, 'private')):
            with self.assertRaises(OSError):
                supervisor.identity(42)

    def test_birth_group_or_session_change_holds(self):
        for change in ({'birth': 101}, {'pgid': 8}, {'session': 8}):
            with self.subTest(change=change), \
                 mock.patch.object(Path, 'open', side_effect=[io.StringIO(proc_stat()),
                                                              io.StringIO(proc_stat(**change))]), \
                 mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=1000)):
                with self.assertRaisesRegex(RuntimeError, '^PROC_IDENTITY_CHANGED$'):
                    supervisor.identity(42)

    def test_state_change_is_allowed_but_stable_foreign_uid_is_not_hidden(self):
        for owner in (0, 1001):
            with self.subTest(owner=owner), \
                 mock.patch.object(Path, 'open', side_effect=[io.StringIO(proc_stat()),
                    io.StringIO(proc_stat(state='S'))]), \
                 mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=owner)):
                self.assertEqual(supervisor.identity(42), (42, 100, owner, 7, 7, 'S'))

    def test_same_birth_terminal_after_is_gone_including_root_owner(self):
        for state in ('Z', 'X', 'x'):
            for before_state in ('R', 'Z'):
                for owner in (0, 1000):
                    with self.subTest(after=state, before=before_state, owner=owner), \
                         mock.patch.object(Path, 'open', side_effect=[
                             io.StringIO(proc_stat(state=before_state)),
                             io.StringIO(proc_stat(pgid=-1, session=-1, state=state))]), \
                         mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=owner)):
                        self.assertIsNone(supervisor.identity(42))

    def test_birth_change_holds_before_terminal_classification(self):
        for before_state in ('R', 'Z'):
            with self.subTest(before=before_state), \
                 mock.patch.object(Path, 'open', side_effect=[
                     io.StringIO(proc_stat(state=before_state)),
                     io.StringIO(proc_stat(birth=101, pgid=-1, session=-1, state='Z'))]), \
                 mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=0)):
                with self.assertRaisesRegex(RuntimeError, '^PROC_IDENTITY_CHANGED$'):
                    supervisor.identity(42)

    def test_terminal_to_live_or_unknown_state_holds(self):
        for before_state, after_state in [('Z', 'R'), ('X', 'S'), ('x', 'D'),
                                          ('?', 'R'), ('R', '?'), ('?', 'Z')]:
            with self.subTest(before=before_state, after=after_state), \
                 mock.patch.object(Path, 'open', side_effect=[
                     io.StringIO(proc_stat(state=before_state)),
                     io.StringIO(proc_stat(state=after_state))]), \
                 mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=1000)):
                with self.assertRaises(RuntimeError):
                    supervisor.identity(42)

    def test_live_nonpositive_group_or_session_is_never_ignored(self):
        for bad in ({'pgid': 0}, {'pgid': -1}, {'session': 0}, {'session': -1}):
            for before, after in [(bad, bad), ({}, bad), (bad, {'state': 'Z'})]:
                with self.subTest(before=before, after=after), \
                     mock.patch.object(Path, 'open', side_effect=[
                         io.StringIO(proc_stat(**before)), io.StringIO(proc_stat(**after))]), \
                     mock.patch.object(Path, 'stat', return_value=types.SimpleNamespace(st_uid=1000)):
                    with self.assertRaises(RuntimeError):
                        supervisor.identity(42)

    def test_terminal_after_cannot_hide_owner_permission_error(self):
        with mock.patch.object(Path, 'open', side_effect=[io.StringIO(proc_stat()),
                 io.StringIO(proc_stat(pgid=-1, session=-1, state='Z'))]), \
             mock.patch.object(Path, 'stat', side_effect=PermissionError(errno.EACCES, 'private')):
            with self.assertRaises(PermissionError):
                supervisor.identity(42)

    def test_malformed_wrong_pid_or_oversized_stat_is_not_gone(self):
        for raw in ('malformed', proc_stat(pid=43), 'x' * 8193,
                    proc_stat().replace(' 100', ' invalid')):
            with self.subTest(raw=raw[:32]), mock.patch.object(Path, 'open', return_value=io.StringIO(raw)):
                with self.assertRaises((RuntimeError, ValueError)):
                    supervisor.identity(42)


class DescendantRaceTests(unittest.TestCase):
    def test_disappeared_task_preserves_found_pids_and_next_adoption_scan(self):
        for number in (errno.ENOENT, errno.ESRCH):
            phase = [0]
            def scan(path):
                current = path.parts[-2]
                context = mock.MagicMock()
                context.__enter__.return_value = iter([types.SimpleNamespace(name=current)])
                return context
            def read(path, *args, **kwargs):
                current = path.parts[-4]
                if current == '42':
                    return io.StringIO('43 44' if phase[0] == 0 else '44 45')
                if current == '43':
                    raise OSError(number, 'vanished intermediate')
                return io.StringIO('')
            with self.subTest(errno=number), mock.patch.object(os, 'scandir', side_effect=scan), \
                 mock.patch.object(Path, 'open', read):
                self.assertEqual(supervisor.descendants(42), [43, 44])
                phase[0] = 1
                self.assertEqual(supervisor.descendants(42), [44, 45])

    def test_required_anchor_disappearance_and_other_errors_hold(self):
        for number in (errno.ENOENT, errno.ESRCH, errno.EACCES, errno.EPERM, errno.EIO, errno.EBADF):
            with self.subTest(errno=number), \
                 mock.patch.object(os, 'scandir', side_effect=OSError(number, 'private')):
                with self.assertRaises(OSError) as caught:
                    supervisor.descendants(42)
                self.assertEqual(caught.exception.errno, number)

    def test_task_and_child_count_bounds_remain_errors(self):
        context = mock.MagicMock()
        context.__enter__.return_value = iter(types.SimpleNamespace(name=str(i)) for i in range(3))
        with mock.patch.object(os, 'scandir', return_value=context):
            with self.assertRaisesRegex(RuntimeError, '^TASK_BOUND$'):
                supervisor.descendants(42, maximum=2)
        context.__enter__.return_value = iter([types.SimpleNamespace(name='42')])
        with mock.patch.object(os, 'scandir', return_value=context), \
             mock.patch.object(Path, 'open', return_value=io.StringIO('43 44 45')):
            with self.assertRaisesRegex(RuntimeError, '^CHILD_BOUND$'):
                supervisor.descendants(42, maximum=2)

    def test_vanished_descendant_task_directory_keeps_other_members(self):
        for number in (errno.ENOENT, errno.ESRCH):
            def scan(path):
                current = path.parts[-2]
                if current == '43':
                    raise OSError(number, 'dead descendant task directory')
                context = mock.MagicMock()
                context.__enter__.return_value = iter([types.SimpleNamespace(name=current)])
                return context
            def read(path, *args, **kwargs):
                return io.StringIO('43 44' if path.parts[-4] == '42' else '')
            with self.subTest(errno=number), mock.patch.object(os, 'scandir', side_effect=scan), \
                 mock.patch.object(Path, 'open', read):
                self.assertEqual(supervisor.descendants(42), [43, 44])
class GuardianControlTests(unittest.TestCase):
    def test_control_parser_bounds_partial_records_and_retains_first_reason(self):
        process = object.__new__(owned.OwnedProcess)
        process.uncertainty = None
        process.buffers = {'control': bytearray(b'{"uncertain":')}
        process.check_control()  # A fragmented record is not yet an event.
        process.buffers['control'] = bytearray(
            b'{"uncertain":"PROC_DISCOVERY_ERROR","errno":13}\n'
            b'{"uncertain":"PROC_DISCOVERY_ERROR","errno":5}\n')
        with self.assertRaisesRegex(owned.Hold, '^CHILD_TREE_UNCERTAIN$'):
            process.check_control()
        self.assertEqual(process.uncertainty, {'uncertain': 'PROC_DISCOVERY_ERROR', 'errno': 13})
        for payload, expected in [(b'x' * 8193, 'CONTROL_BOUND'),
                                  (b'[]\n', 'CONTROL_INVALID'),
                                  (b'bad json\n', 'CONTROL_INVALID'),
                                  (b'{"uncertain":"PRIVATE path"}\n', 'CONTROL_INVALID'),
                                  (b'{"uncertain":"PROC_DISCOVERY_ERROR","errno":true}\n', 'CONTROL_INVALID'),
                                  (b'{"uncertain":"PROC_DISCOVERY_ERROR","args":[]}\n', 'CONTROL_INVALID')]:
            process.uncertainty = None
            process.buffers['control'] = bytearray(payload)
            with self.subTest(expected=expected), self.assertRaisesRegex(owned.Hold, '^' + expected + '$'):
                process.check_control()

    def cleanup_fixture(self, process):
        """Fixture-only reaping after short helper exit, never production success."""
        cutoff = time.monotonic() + 3
        while supervisor.descendants(process.process.pid):
            self.assertLess(time.monotonic(), cutoff, 'fixture child did not exit')
            time.sleep(0.01)
        proof = process.proof
        fd = os.pidfd_open(proof[0])
        try:
            self.assertEqual(supervisor.identity(proof[0])[:5], proof[:5])
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        finally:
            os.close(fd)
        process.process.wait(timeout=3)
        process.close_pipes()

    def fault(self, mode):
        """Replace only the exec'd test guardian at the subprocess OS boundary."""
        popen = owned.subprocess.Popen
        def launch(argv, **kwargs):
            self.assertEqual(Path(argv[4]).name, 'owned_acceptance_supervisor.py')
            argv = list(argv)
            argv[4:5] = [str(HERE / 'fixtures/owned_proc_fault_guardian.py'), mode]
            return popen(argv, **kwargs)
        return mock.patch.object(owned.subprocess, 'Popen', side_effect=launch)

    def test_permission_uncertainty_is_reported_before_command_deadline(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)
            parent.chmod(0o700)
            run = owned.OwnedRun(parent, scope='safety-fixture')
            with self.fault('permission'):
                process = run.spawn(['/bin/sleep', '0.15'])
            try:
                started = time.monotonic()
                with self.assertRaisesRegex(owned.Hold, '^CHILD_TREE_UNCERTAIN$'):
                    process.wait(1)
                self.assertLess(time.monotonic() - started, 0.8)
            finally:
                receipt = run.finish(owned.Hold('fixture-failure'))
                self.assertFalse(receipt['teardownVerified'])
                self.cleanup_fixture(process)

    def test_bounded_first_reason_errno_and_foreign_uid_remain_hold(self):
        for mode, expected in [
                ('permission-then-io', {'uncertain': 'PROC_DISCOVERY_ERROR', 'errno': errno.EACCES}),
                ('io', {'uncertain': 'PROC_DISCOVERY_ERROR', 'errno': errno.EIO}),
                ('unknown', {'uncertain': 'PROC_DISCOVERY_INVALID'}),
                ('foreign-uid', {'uncertain': 'DESCENDANT_IDENTITY_MISMATCH'})]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as raw:
                parent = Path(raw)
                parent.chmod(0o700)
                run = owned.OwnedRun(parent, scope='safety-fixture')
                with self.fault(mode):
                    process = run.spawn(['/bin/sleep', '0.15'])
                try:
                    with self.assertRaisesRegex(owned.Hold, '^CHILD_TREE_UNCERTAIN$'):
                        process.wait(1)
                    self.assertEqual(process.uncertainty, expected)
                    receipt = run.finish(owned.Hold('fixture-failure'))
                    self.assertEqual(receipt['status'], 'HOLD')
                    self.assertTrue(receipt['privateRootRetained'])
                    self.assertFalse(receipt['teardownVerified'])
                    self.assertEqual(receipt['uncertainProcesses'][0]['firstUncertainty'], expected)
                    self.assertNotIn('PRIVATE-FIXTURE', json.dumps(receipt))
                    self.assertEqual(bytes(process.buffers['control']).count(b'"uncertain"'), 1)
                finally:
                    self.cleanup_fixture(process)
                    run.ws.close()

    def test_transient_proc_esrch_under_actual_guardian_can_complete(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)
            parent.chmod(0o700)
            run = owned.OwnedRun(parent, scope='safety-fixture')
            failure = None
            try:
                with self.fault('gone'):
                    process = run.spawn(['/bin/sleep', '0.15'])
                process.wait(2)
                self.assertIsNone(process.uncertainty)
            except BaseException as error:
                failure = error
                raise
            finally:
                receipt = run.finish(failure)
            self.assertTrue(receipt['teardownVerified'])
            self.assertEqual(receipt['status'], 'SAFETY_FIXTURE_COMPLETED')

    def test_actual_short_shell_fork_churn_completes_with_verified_teardown(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)
            parent.chmod(0o700)
            run = owned.OwnedRun(parent, scope='safety-fixture')
            failure = None
            try:
                process = run.spawn(['/bin/bash', '-c',
                    'for ((i=0;i<400;i++)); do /bin/true | /bin/true; done'])
                process.wait(5)
                self.assertEqual(process.process.returncode, 0)
                self.assertIsNone(process.uncertainty)
            except BaseException as error:
                failure = error
                raise
            finally:
                receipt = run.finish(failure)
                if process.process.poll() is None:
                    self.cleanup_fixture(process)
                    run.ws.close()
            self.assertTrue(receipt['teardownVerified'])
            self.assertFalse(receipt['privateRootRetained'])
            self.assertIs(receipt['realUbuntuAcceptance'], False)

    def test_real_group_and_session_escape_still_hold(self):
        for action in ('os.setpgid(0, 0)', 'os.setsid()'):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as raw:
                parent = Path(raw)
                parent.chmod(0o700)
                run = owned.OwnedRun(parent, scope='safety-fixture')
                process = run.spawn([sys.executable, '-I', '-S', '-B', '-c',
                    'import os,time; ' + action + '; time.sleep(0.15)'])
                try:
                    with self.assertRaisesRegex(owned.Hold, '^CHILD_TREE_UNCERTAIN$'):
                        process.wait(1)
                    self.assertEqual(process.uncertainty, {'uncertain': 'DESCENDANT_IDENTITY_MISMATCH'})
                finally:
                    receipt = run.finish(owned.Hold('fixture-escape'))
                    self.assertFalse(receipt['teardownVerified'])
                    self.cleanup_fixture(process)
                    run.ws.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
