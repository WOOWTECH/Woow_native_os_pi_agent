"""Owned synthetic incomplete-census and all-child reaping regressions."""
import contextlib
import ctypes
import errno
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock

import owned_native_acceptance as owned
import owned_process_custody as custody
import test_owned_process_custody as fixtures

HERE = Path(__file__).resolve().parent


def setUpModule():
    fixtures.setUpModule()


class IncompleteCensusTests(unittest.TestCase):
    def setUp(self):
        self.fx = fixtures.DetachedCustodyTests()

    @contextlib.contextmanager
    def subreaper(self):
        libc = ctypes.CDLL(None)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        try:yield
        finally:libc.prctl(36, previous.value, 0, 0, 0)

    def test_departed_unbound_einval_reproof_captures_adopted_child(self):
        with self.subreaper():
            child = subprocess.Popen([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_custody_child.py'), 'adoption-barrier'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
            original_open = os.pidfd_open
            hit, adopted, adopted_fd = [], None, None
            def acquire(pid, flags=0):
                nonlocal adopted, adopted_fd
                if pid == child.pid and not hit:
                    self.assertEqual(flags, 0)
                    child.stdin.write(b'fork\n');child.stdin.flush()
                    self.assertTrue(select.select([child.stdout], [], [], 2)[0])
                    text = child.stdout.readline().decode()
                    self.assertTrue(text.startswith('adopted:'))
                    adopted = int(text.split(':')[1]);adopted_fd = original_open(adopted, 0)
                    self.assertEqual(child.wait(timeout=2), 0)
                    hit.append(pid)
                    raise OSError(errno.EINVAL, 'owned candidate fixture')
                return original_open(pid, flags)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 2)[0])
                self.assertEqual(child.stdout.readline(), b'ready\n')
                with mock.patch.object(os, 'pidfd_open', side_effect=acquire):proofs = ledger.refresh()
                self.assertEqual(hit, [child.pid])
                self.assertIn(adopted, [p[0] for p in proofs])
                self.assertNotIn(child.pid, ledger._caps)
                self.assertFalse(ledger.empty)
            finally:
                if child.poll() is None:self.fx.terminate_fixture(child)
                if adopted_fd is not None:
                    signal.pidfd_send_signal(adopted_fd, signal.SIGTERM)
                    self.assertTrue(select.select([adopted_fd], [], [], 2)[0])
                    os.waitpid(adopted, 0);os.close(adopted_fd)
                ledger.refresh();ledger.close()
                for stream in (child.stdin, child.stdout, child.stderr):stream.close()

    def test_persistent_live_candidate_holds_preserving_caps_and_cumulative_bounds(self):
        held = subprocess.Popen(['/bin/sleep', '5'])
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
        ledger.refresh();cap = ledger._caps[held.pid]
        original_cap = cap.pidfd, cap.procfd, cap.proof[:5]
        candidate = subprocess.Popen(['/bin/sleep', '5'])
        original_open = os.pidfd_open
        attempts = []
        def acquire(pid, flags=0):
            if pid == candidate.pid:
                self.assertEqual(flags, 0);attempts.append(pid)
                raise OSError(errno.EINVAL, 'owned persistent fixture')
            return original_open(pid, flags)
        try:
            before_fds = ledger.budget.fds
            with ledger._operation():
                ledger.budget.passes = 7
                with mock.patch.object(os, 'pidfd_open', side_effect=acquire), \
                        mock.patch.object(signal, 'pidfd_send_signal', side_effect=AssertionError('no authority from failure')):
                    with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
                self.assertEqual(error.exception.custody_code, 'CUSTODY_CENSUS_BOUND')
                self.assertEqual(ledger.budget.passes, 128)
                self.assertEqual(len(attempts), 121)
                self.assertGreater(ledger.budget.bytes, 0)
                self.assertIn(('pid', candidate.pid), ledger.budget.seen)
                self.assertEqual(ledger.budget.fds, before_fds)
                self.assertEqual((cap.pidfd, cap.procfd, cap.proof[:5]), original_cap)
                self.assertIn(held.pid, ledger._caps)
                self.assertNotIn(candidate.pid, ledger._caps)
            self.assertIsNone(candidate.poll());self.assertIsNone(held.poll())
        finally:
            self.fx.terminate_fixture(candidate);self.fx.terminate_fixture(held)
            ledger.refresh();ledger.close()

    def test_withdrawn_candidate_edge_allows_fresh_nonempty_proven_peer(self):
        with self.fx.private_run() as run:
            process, port = self.fx.node_server(run)
            ledger = process.ensure_custody()
            self.assertEqual(owned.Endpoint(process, port).get('/'), b'owned-detached-response')
            text = self.fx.command(process, 'spawn-candidate')
            self.assertTrue(text.startswith('candidate:'))
            candidate = int(text.split(':')[1])
            original_open = os.pidfd_open
            fixture_fd = original_open(candidate, 0)
            hit = []
            def acquire(pid, flags=0):
                if pid == candidate and not hit:
                    self.assertEqual(flags, 0)
                    self.assertEqual(self.fx.command(process, 'exit-candidate'), 'candidate-ended')
                    self.assertTrue(select.select([fixture_fd], [], [], 2)[0])
                    hit.append(pid)
                    raise OSError(errno.EINVAL, 'owned withdrawn edge fixture')
                return original_open(pid, flags)
            try:
                with mock.patch.object(os, 'pidfd_open', side_effect=acquire):proofs = ledger.refresh()
                self.assertEqual(hit, [candidate])
                self.assertGreater(len(proofs), 1)
                self.assertNotIn(candidate, [p[0] for p in proofs])
                self.assertIsNone(process.process.poll())
                self.assertEqual(owned.Endpoint(process, port).get('/'), b'owned-detached-response')
                self.assertIsNone(process.uncertainty)
            finally:os.close(fixture_fd)

    def test_anchor_constructor_invalid_pid_flags_and_other_errno_refuse(self):
        proof = owned.identity(os.getpid())
        with mock.patch.object(os, 'pidfd_open', side_effect=OSError(errno.EINVAL, 'owned anchor')) as call:
            with self.assertRaises(custody.CustodyError) as error:
                custody.OwnedDescendants(proof, deadline=time.monotonic() + 3)
            self.assertEqual(error.exception.errno, errno.EINVAL)
            call.assert_called_once_with(proof[0], 0)
        ledger = custody.OwnedDescendants(proof, deadline=time.monotonic() + 3)
        try:
            with ledger._operation():
                for invalid in (0, -1, True, '123'):
                    with mock.patch.object(os, 'pidfd_open', side_effect=AssertionError('invalid must not reach syscall')):
                        with self.assertRaises(custody.CustodyError):ledger._open_cap(invalid)
                with self.assertRaises(TypeError):ledger._open_cap(proof[0], flags=1)
            for number in (errno.EPERM, errno.EACCES, errno.EIO):
                child = subprocess.Popen(['/bin/sleep', '2'])
                original_open = os.pidfd_open
                def acquire(pid, flags=0):
                    if pid == child.pid:raise OSError(number, 'owned other errno')
                    return original_open(pid, flags)
                try:
                    with mock.patch.object(os, 'pidfd_open', side_effect=acquire):
                        with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
                    self.assertEqual(error.exception.errno, number)
                finally:self.fx.terminate_fixture(child)
        finally:ledger.refresh();ledger.close()

    def test_missing_known_live_capability_cannot_be_withdrawn(self):
        child = subprocess.Popen(['/bin/sleep', '3'])
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 2)
        try:
            ledger.refresh();cap = ledger._caps[child.pid]
            original_children = ledger._children
            with mock.patch.object(ledger, '_children', side_effect=lambda parent: set() if parent is ledger.anchor else original_children(parent)):
                with self.assertRaises(custody.CustodyError):ledger.refresh()
            self.assertIs(ledger._caps[child.pid], cap)
            self.assertIsNone(child.poll())
        finally:self.fx.terminate_fixture(child);ledger.refresh();ledger.close()

    def test_all_child_clone_reap_requires_fresh_post_reap_census(self):
        with self.subreaper():
            events = []
            try:
                with self.fx.private_run() as run:
                    with self.fx.signal_guardian('wall-reap'):
                        process = run.spawn(['/bin/true'])
                    try:
                        process.wait(3)
                        events = self.fx.fixture_events(process, [], 'fixture-wall-clone')
                        self.assertEqual(len(events), 1)
                        records = self.fx.fixture_events(process, [], 'fixture-reap-accounted')
                        self.assertTrue(any(row['pid'] == events[0]['pid'] and row['status'] == 0 for row in records))
                        self.assertTrue(self.fx.fixture_events(process, [], 'fixture-post-reap-census'))
                        self.assertTrue(run.finish()['teardownVerified'])
                    finally:
                        events = self.fx.fixture_events(process, [], 'fixture-wall-clone')
            finally:
                # RED may have falsely exited without reaping the exact clone.
                # This runs after the private guardian cleanup/adoption boundary.
                for row in events:
                    try:os.waitpid(row['pid'], os.WNOHANG | 0x40000000)
                    except ChildProcessError:pass


if __name__ == '__main__':
    unittest.main(verbosity=2)
