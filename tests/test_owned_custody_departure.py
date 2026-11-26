"""Owned synthetic departure, lifetime, close-accounting and cutoff-phase regressions.

Runtime V6: the kernel namespace exit window (R1), nonmutating borrowed validation
(V5-S1/P2-1), exact retirement/close accounting (P2-2), cutoff sampling phase
(P2-3), construction-time known work expiry (V5-S2) and the FD-directory
departure shape. Runtime V6 r2: a cutoff-truncated exit-window wait is the
cutoff's own expiry (M1), the FD directory's real exiting errno EACCES (M2), an
exited or exiting anchor refuses as gone (M3), a zombie kept by a live owned
parent is an inert terminal leaf (M4) and a released task's empty listing is a
census change (M5). Runtime V6 r3: every owned safety suite is self-executing
under its `python3 -B <suite>` CI wiring (V6R2-S1). No installer, SDK, provider
or external network.
"""
import ast
import contextlib
import errno
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import time
import unittest
from unittest import mock

import owned_acceptance_supervisor as owned_supervisor
import owned_native_acceptance as owned
import owned_process_custody as custody
import test_owned_process_custody as fixtures

HERE = Path(__file__).resolve().parent
CHILD = str(HERE / 'fixtures/owned_custody_child.py')
PF_EXITING = 0x4


def setUpModule():
    fixtures.setUpModule()


def departed_marker():
    return getattr(custody, 'DEPARTED', None)


class _Children:
    """Exact private direct children of this test process; never a scan."""
    def __init__(self, case):
        self.case, self.items = case, []

    def spawn(self, mode, *args):
        child = subprocess.Popen([sys.executable, '-I', '-S', '-B', CHILD, mode, *map(str, args)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.items.append(child)
        return child

    def line(self, child, seconds=5):
        self.case.assertTrue(select.select([child.stdout], [], [], seconds)[0], 'fixture line timeout')
        return child.stdout.readline().decode().strip()

    def release(self, child, payload=b'x'):
        if child.poll() is None:
            child.stdin.write(payload);child.stdin.flush()
            self.case.assertEqual(child.wait(timeout=3), 0)

    def close(self):
        for child in self.items:
            if child.poll() is None:
                fixtures.DetachedCustodyTests().terminate_fixture(child)
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()


def dispose(ledger):
    """Test-only disposal of a ledger whose custody state is deliberately sticky."""
    caps = list(ledger._caps.values()) + list(ledger._provisional.values())
    for cap in caps:
        for field in ('procfd', 'pidfd'):
            fd = getattr(cap, field)
            if fd is not None:
                with contextlib.suppress(OSError):os.close(fd)
                setattr(cap, field, None)
    for field in ('selffd', 'rootfd'):
        fd = getattr(ledger, field)
        if fd is not None:
            with contextlib.suppress(OSError):os.close(fd)
            setattr(ledger, field, None)
    ledger._caps.clear();ledger._provisional.clear()
    ledger.closed = True


def finish(ledger):
    if not ledger.closed:
        ledger.refresh();ledger.close()


def ordered(ledger, pids):
    """Deterministic scan order anchor, A, B, C over the same held objects."""
    keys = [ledger.anchor.pid, *pids]
    assert set(keys) == set(ledger._caps), (keys, list(ledger._caps))
    ledger._caps = {pid: ledger._caps[pid] for pid in keys}


class NamespaceExitWindowTests(unittest.TestCase):
    """F1: readlink ns/net ENOENT while the same held PIDfd is still nonready."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    def test_real_kernel_exit_window_waits_for_same_pidfd_then_retires(self):
        reaped = []
        def reap(budget):
            for child in self.children.items:
                if child.returncode is None:
                    pid, status = os.waitpid(child.pid, os.WNOHANG)
                    if pid:
                        budget.record_reap(pid, status)
                        child.returncode = os.waitstatus_to_exitcode(status)
                        reaped.append((pid, child.returncode))
        child = self.children.spawn('memfd-exit', 256)
        self.assertEqual(self.children.line(child), 'ready')
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8, reap=reap)
        own = os.pidfd_open(child.pid)
        procfd = os.open('/proc/' + str(child.pid), os.O_RDONLY | os.O_DIRECTORY)
        poller = select.poll()
        poller.register(own, select.POLLIN)
        try:
            self.assertIn(child.pid, [p[0] for p in ledger.refresh()])
            held = ledger._caps[child.pid]
            fds, pins = ledger.budget.fds, dict(ledger.budget.pins)
            work, cutoff = ledger.lifetime.work_deadline, ledger.budget.deadline
            real_close = ledger._close_cap
            retired = []
            def close_cap(cap):
                if cap.pid == child.pid:
                    retired.append(bool(poller.poll(0)))
                return real_close(cap)
            states = []
            real_state = getattr(ledger, '_exit_state', None)
            def exit_state(cap):
                value = real_state(cap)
                states.append((cap.pid, value[1] & PF_EXITING, bool(poller.poll(0))))
                return value
            child.stdin.write(b'exit\n');child.stdin.flush()
            observed, limit = False, time.monotonic() + 3
            while time.monotonic() < limit:
                try:
                    os.readlink('ns/net', dir_fd=procfd);enoent = False
                except FileNotFoundError:
                    enoent = True
                if poller.poll(0):
                    break
                if enoent:
                    observed = True
                    break
            self.assertTrue(observed, 'kernel namespace exit window was not observed before readiness')
            with mock.patch.object(ledger, '_close_cap', side_effect=close_cap), \
                    mock.patch.object(ledger, '_exit_state', side_effect=exit_state, create=True):
                try:
                    proofs = ledger.refresh()  # Immediately, inside the observed window.
                except custody.CustodyError as error:
                    self.fail('exit window held: %s errno %s' % (error.custody_code, error.errno))
            self.assertEqual([p[0] for p in proofs], [os.getpid()])
            self.assertEqual(retired, [True], 'retire only after same-PIDfd readiness')
            self.assertTrue(states and states[0][0] == child.pid and states[0][1] and not states[0][2],
                            'the PF_EXITING bounded wait must be the exercised path')
            self.assertEqual(reaped, [(child.pid, 0)])
            self.assertNotIn(child.pid, ledger._caps)
            self.assertNotIn(child.pid, ledger._provisional)
            self.assertIsNone(held.pidfd)
            self.assertEqual(ledger.budget.fds, fds - 2)
            self.assertNotIn(('pid', child.pid), ledger.budget.pins)
            self.assertEqual({k: v for k, v in pins.items()
                              if k not in {('pid', child.pid), ('task', child.pid)}}, ledger.budget.pins)
            self.assertEqual((ledger.lifetime.work_deadline, ledger.budget.deadline), (work, cutoff))
            self.assertIsNone(ledger.lifetime.teardown_deadline)
            self.assertLessEqual(ledger.budget.passes, 128)
            ledger.close()
        finally:
            os.close(procfd);os.close(own)
            if not ledger.closed:
                if child.poll() is None:self.children.release(child, b'exit\n')
                finish(ledger)

    def test_release_inside_exit_window_is_readiness_not_identity_change(self):
        # A grandchild can be reaped by its own parent at any moment. After
        # release, pid_getattr reports root ownership for the held procfd; the
        # same-PIDfd readiness that release implies must win over that UID.
        child = self.children.spawn('memfd-exit', 256)
        self.assertEqual(self.children.line(child), 'ready')
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        own = os.pidfd_open(child.pid)
        procfd = os.open('/proc/' + str(child.pid), os.O_RDONLY | os.O_DIRECTORY)
        poller = select.poll()
        poller.register(own, select.POLLIN)
        released = []
        try:
            self.assertIn(child.pid, [p[0] for p in ledger.refresh()])
            real_state = getattr(ledger, '_exit_state', None)
            def exit_state(cap):
                value = real_state(cap)
                if cap.pid == child.pid and not released:
                    self.assertTrue(value[1] & PF_EXITING)
                    self.assertTrue(select.select([own], [], [], 3)[0])
                    pid, status = os.waitpid(child.pid, 0)
                    child.returncode = os.waitstatus_to_exitcode(status)
                    released.append(os.fstat(cap.procfd).st_uid)
                return value
            child.stdin.write(b'exit\n');child.stdin.flush()
            observed, limit = False, time.monotonic() + 3
            while time.monotonic() < limit:
                try:
                    os.readlink('ns/net', dir_fd=procfd);enoent = False
                except FileNotFoundError:
                    enoent = True
                if poller.poll(0):
                    break
                if enoent:
                    observed = True
                    break
            self.assertTrue(observed, 'kernel namespace exit window was not observed before readiness')
            with mock.patch.object(ledger, '_exit_state', side_effect=exit_state, create=True):
                try:
                    proofs = ledger.refresh()
                except custody.CustodyError as error:
                    self.fail('release inside window held: %s errno %s' % (error.custody_code, error.errno))
            self.assertEqual(len(released), 1)
            self.assertNotEqual(released[0], os.getuid(), 'kernel reports released-task ownership')
            self.assertEqual([p[0] for p in proofs], [os.getpid()])
            self.assertNotIn(child.pid, ledger._caps)
            ledger.close()
        finally:
            os.close(procfd);os.close(own)
            if not ledger.closed:
                if child.poll() is None:self.children.release(child, b'exit\n')
                finish(ledger)

    def test_injected_enoent_without_pf_exiting_holds_promptly(self):
        child = self.children.spawn('idle')
        self.assertEqual(self.children.line(child), 'ready')
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        real_link = os.readlink
        hit = []
        def missing(path, *args, **kwargs):
            cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
            if path == 'ns/net' and cap is not None and kwargs.get('dir_fd') == cap.procfd:
                hit.append(cap.pid)
                raise FileNotFoundError(errno.ENOENT, 'owned namespace fixture')
            return real_link(path, *args, **kwargs)
        try:
            started = time.monotonic()
            with mock.patch.object(os, 'readlink', side_effect=missing):
                with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_IO_ERROR', errno.ENOENT))
            self.assertLess(time.monotonic() - started, 0.5, 'no wait without PF_EXITING')
            self.assertTrue(hit)
            cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
            self.assertIsNotNone(cap)
            self.assertIsNotNone(cap.pidfd)
            self.assertFalse(select.select([cap.pidfd], [], [], 0)[0])
            self.assertIsNone(child.poll())
        finally:
            self.children.release(child)
            finish(ledger)

    def test_persistent_exiting_leader_with_nonready_pidfd_is_exit_unconfirmed(self):
        child = self.children.spawn('terminal-leader-held')
        pid = int(self.children.line(child))
        self.assertEqual(pid, child.pid)
        procfd = os.open('/proc/' + str(pid), os.O_RDONLY | os.O_DIRECTORY)
        own = os.pidfd_open(pid)
        ledgers = []
        try:
            limit = time.monotonic() + 3
            while True:
                try:os.readlink('ns/net', dir_fd=procfd)
                except FileNotFoundError:break
                self.assertLess(time.monotonic(), limit)
                time.sleep(0.005)
            self.assertFalse(select.select([own], [], [], 0)[0])
            # M1: only the full 2 s bound is EXIT_UNCONFIRMED. A wait truncated by
            # the operation cutoff raises that cutoff's own phase-tagged expiry.
            cases = (('full', 'CUSTODY_EXIT_UNCONFIRMED', None, 2.0),
                     ('work', 'CUSTODY_DEADLINE', 'work', 0.6),
                     ('teardown', 'CUSTODY_TEARDOWN_DEADLINE', 'teardown', 0.6),
                     ('explicit', 'CUSTODY_DEADLINE', 'explicit', 0.6))
            for label, code, phase, bound in cases:
                with self.subTest(cutoff=label):
                    ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic()
                                                     + (0.6 if label == 'work' else 8))
                    ledgers.append(ledger)
                    if label == 'teardown':
                        ledger.begin_teardown(0.6)
                    work, teardown = ledger.lifetime.work_deadline, ledger.lifetime.teardown_deadline
                    started = time.monotonic()
                    with self.assertRaises(custody.CustodyError) as error:
                        if label == 'explicit':
                            with ledger._operation(time.monotonic() + 0.6):ledger.refresh()
                        else:
                            ledger.refresh()
                    elapsed = time.monotonic() - started
                    self.assertEqual((error.exception.custody_code, error.exception.phase), (code, phase))
                    self.assertLess(elapsed, bound + 0.4, 'bounded by min(2s, operation cutoff)')
                    self.assertGreater(elapsed, bound - 0.2, 'the bounded event wait was used')
                    self.assertEqual((ledger.lifetime.work_deadline, ledger.lifetime.teardown_deadline),
                                     (work, teardown), 'nothing is renewed')
                    cap = ledger._caps.get(pid) or ledger._provisional.get(pid)
                    self.assertIsNotNone(cap, 'an unproved exit never retires the capability')
                    self.assertIsNotNone(cap.pidfd)
                    self.assertFalse(select.select([cap.pidfd], [], [], 0)[0])
                    self.assertFalse(select.select([own], [], [], 0)[0])
                    if label == 'work':
                        self.assertTrue(owned_supervisor.known_work_expiry(error.exception))
                    else:
                        self.assertFalse(owned_supervisor.known_work_expiry(error.exception))
        finally:
            self.children.release(child)
            os.close(procfd);os.close(own)
            for ledger in ledgers:
                if not ledger.closed:
                    try:finish(ledger)
                    except custody.CustodyError:dispose(ledger)

    def test_anchor_namespace_enoent_is_never_departure_and_never_waits(self):
        # M3: a live anchor's ENOENT stays CUSTODY_IO_ERROR; an anchor whose stat
        # shows the same birth, the anchor UID and PF_EXITING refuses as gone.
        # Neither ever waits or departs.
        for label, flags in (('live', None), ('exiting', PF_EXITING)):
            with self.subTest(anchor=label):
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
                real_link, real_state = os.readlink, ledger._exit_state
                states, waits = [], []
                def missing(path, *args, **kwargs):
                    if path == 'ns/net' and kwargs.get('dir_fd') == ledger.anchor.procfd:
                        raise FileNotFoundError(errno.ENOENT, 'owned anchor namespace fixture')
                    return real_link(path, *args, **kwargs)
                def exit_state(cap):
                    value = real_state(cap)
                    states.append(value[1] & PF_EXITING)
                    return value if flags is None else (value[0], value[1] | flags, value[2])
                try:
                    started = time.monotonic()
                    with mock.patch.object(os, 'readlink', side_effect=missing), \
                            mock.patch.object(ledger, '_exit_state', side_effect=exit_state), \
                            mock.patch.object(ledger, '_exit_window', side_effect=lambda *a: waits.append(a)):
                        with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
                    if flags is None:
                        self.assertEqual((error.exception.custody_code, error.exception.errno),
                                         ('CUSTODY_IO_ERROR', errno.ENOENT))
                    else:
                        self.assertEqual((error.exception.custody_code, error.exception.errno),
                                         ('CUSTODY_ANCHOR_GONE', None))
                    self.assertLess(time.monotonic() - started, 0.5)
                    self.assertEqual(waits, [], 'anchor never enters the exit-window wait')
                    self.assertEqual(states, [0], 'the real live anchor has no PF_EXITING')
                finally:
                    finish(ledger)

    def test_other_namespace_errnos_gain_no_tolerance_even_when_exiting(self):
        for number in (errno.EACCES, errno.EPERM, errno.EIO, errno.ELOOP, errno.ESRCH):
            with self.subTest(errno=errno.errorcode[number]):
                child = self.children.spawn('idle')
                self.assertEqual(self.children.line(child), 'ready')
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
                real_link = os.readlink
                hit, waited = [], []
                def failing(path, *args, **kwargs):
                    cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
                    if path == 'ns/net' and cap is not None and kwargs.get('dir_fd') == cap.procfd:
                        hit.append(cap.pid)
                        raise OSError(number, 'owned namespace errno fixture')
                    return real_link(path, *args, **kwargs)
                def exit_state(cap):
                    waited.append(cap.pid)
                    return (ledger._stat(cap)[0], PF_EXITING, 'R')
                try:
                    started = time.monotonic()
                    with mock.patch.object(os, 'readlink', side_effect=failing), \
                            mock.patch.object(ledger, '_exit_state', side_effect=exit_state, create=True):
                        with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
                    self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_IO_ERROR', number))
                    self.assertLess(time.monotonic() - started, 0.5)
                    self.assertEqual(waited, [])
                    self.assertTrue(hit)
                finally:
                    self.children.release(child)
                    finish(ledger)


class BorrowedCapabilityTests(unittest.TestCase):
    """F2/F6: borrowed validation never mutates; outer transactions restart."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    def three(self):
        a, b = self.children.spawn('idle'), self.children.spawn('idle')
        server = self.children.spawn('serve')
        self.assertEqual(self.children.line(a), 'ready')
        self.assertEqual(self.children.line(b), 'ready')
        port = int(self.children.line(server))
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        ledger.refresh()
        ordered(ledger, [a.pid, b.pid, server.pid])
        return a, b, server, port, ledger

    def scanning(self, ledger, arm):
        real_scan = ledger._socket_fd
        calls = []
        def scan(inode):
            calls.append(inode)
            arm[0] = arm[1](len(calls))
            try:return real_scan(inode)
            finally:arm[0] = False
        return mock.patch.object(ledger, '_socket_fd', side_effect=scan), calls

    def depart_at_namespace(self, ledger, a, b, arm, hit):
        real_link = os.readlink
        def departed(path, *args, **kwargs):
            cap = ledger._caps.get(a.pid)
            if arm[0] and not hit and path == 'ns/net' and cap is not None and kwargs.get('dir_fd') == cap.procfd:
                caps = [ledger._caps[a.pid], ledger._caps[b.pid]]
                self.children.release(a);self.children.release(b)
                self.assertTrue(all(select.select([c.pidfd], [], [], 0)[0] for c in caps))
                hit.append(a.pid)
                raise PermissionError(errno.EACCES, 'owned namespace departure fixture')
            return real_link(path, *args, **kwargs)
        return mock.patch.object(os, 'readlink', side_effect=departed)

    def test_listener_scan_survives_two_departures_and_proves_serving_peer(self):
        a, b, server, port, ledger = self.three()
        arm, hit = [False, lambda count: count == 1], []
        scan, calls = self.scanning(ledger, arm)
        try:
            with scan, self.depart_at_namespace(ledger, a, b, arm, hit):
                try:
                    row, (cap, name) = ledger.verify_listener(port)
                except custody.CustodyError as error:
                    self.fail('borrowed-capability HOLD: %s errno %s' % (error.custody_code, error.errno))
            self.assertEqual(hit, [a.pid])
            self.assertEqual(len(calls), 2, 'one departure, one fresh restarted scan')
            self.assertEqual(cap.pid, server.pid)
            self.assertIs(ledger._caps[server.pid], cap)
            self.assertTrue(name.isdecimal())
            self.assertEqual(row[0], ('127.0.0.1', port))
            self.assertNotIn(a.pid, ledger._caps)
            self.assertNotIn(b.pid, ledger._caps)
        finally:
            self.children.release(server, b'exit\n')
            finish(ledger)

    def test_connected_peer_scan_restarts_and_keeps_one_connection(self):
        a, b, server, port, ledger = self.three()
        arm, hit = [False, lambda count: count == 2], []
        scan, calls = self.scanning(ledger, arm)
        real_connect = socket.socket.connect
        connects = []
        def connect(sock, address):
            connects.append(address)
            return real_connect(sock, address)
        try:
            with scan, self.depart_at_namespace(ledger, a, b, arm, hit), \
                    mock.patch.object(socket.socket, 'connect', connect):
                try:
                    with ledger.connect_owned(port, time.monotonic() + 3) as conn:
                        self.assertEqual(hit, [a.pid], 'peer proof precedes any request byte')
                        conn.sendall(b'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')
                        wire = b''
                        while True:
                            block = conn.recv(8192)
                            if not block:break
                            wire += block
                except custody.CustodyError as error:
                    self.fail('borrowed-capability HOLD: %s errno %s' % (error.custody_code, error.errno))
            self.assertTrue(wire.endswith(b'owned-serving-peer'))
            self.assertEqual(connects, [('127.0.0.1', port)])
            self.assertGreaterEqual(len(calls), 3)
            server.stdin.write(b'count\n');server.stdin.flush()
            self.assertEqual(self.children.line(server), 'count:1')
            self.assertNotIn(a.pid, ledger._caps)
            self.assertNotIn(b.pid, ledger._caps)
        finally:
            self.children.release(server, b'exit\n')
            finish(ledger)

    def test_nonready_namespace_eacces_in_scan_is_refused_without_restart(self):
        a, b, server, port, ledger = self.three()
        arm, hit = [False, lambda count: count == 1], []
        scan, calls = self.scanning(ledger, arm)
        real_link = os.readlink
        def denied(path, *args, **kwargs):
            cap = ledger._caps.get(a.pid)
            if arm[0] and not hit and path == 'ns/net' and cap is not None and kwargs.get('dir_fd') == cap.procfd:
                hit.append(a.pid)
                raise PermissionError(errno.EACCES, 'owned live namespace fixture')
            return real_link(path, *args, **kwargs)
        try:
            with scan, mock.patch.object(os, 'readlink', side_effect=denied):
                with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_IO_ERROR', errno.EACCES))
            self.assertEqual(len(calls), 1, 'genuine unknown never restarts')
            self.assertIn(a.pid, ledger._caps)
            self.assertIsNotNone(ledger._caps[a.pid].pidfd)
            self.assertFalse(select.select([ledger._caps[a.pid].pidfd], [], [], 0)[0])
        finally:
            for child in (a, b):self.children.release(child)
            self.children.release(server, b'exit\n')
            finish(ledger)

    def test_recurring_departure_restart_is_bounded_by_pass_budget(self):
        server = self.children.spawn('serve')
        port = int(self.children.line(server))
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        marker = departed_marker() or object()
        refreshes = []
        real_refresh = ledger.refresh
        def refresh():
            refreshes.append(True)
            return real_refresh()
        try:
            started = time.monotonic()
            with mock.patch.object(ledger, '_socket_fd', return_value=marker), \
                    mock.patch.object(ledger, 'refresh', side_effect=refresh):
                with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
            # Whichever shared, never-reset operation bound is reached first.
            self.assertIn(error.exception.custody_code, ('CUSTODY_CENSUS_BOUND', 'CUSTODY_ANCESTRY_UNKNOWN',
                                                         'CUSTODY_READ_BOUND', 'CUSTODY_IDENTITY_BOUND'))
            self.assertLessEqual(len(refreshes), 128)
            self.assertLessEqual(ledger.budget.passes, 128)
            self.assertLess(time.monotonic() - started, 6)
        finally:
            self.children.release(server, b'exit\n')
            finish(ledger)

    def fd_dir_departure(self, how):
        a = self.children.spawn('idle')
        server = self.children.spawn('serve')
        self.assertEqual(self.children.line(a), 'ready')
        port = int(self.children.line(server))
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        ledger.refresh()
        ordered(ledger, [a.pid, server.pid])
        arm, hit, opened = [False, lambda count: count == 1], [], {}
        scan, calls = self.scanning(ledger, arm)
        real_open, real_entries = ledger._open, ledger._entries
        def target(dir_fd):
            cap = ledger._caps.get(a.pid) if how != 'anchor' else ledger.anchor
            return arm[0] and not hit and cap is not None and dir_fd == cap.procfd
        def fail(number):
            if how in ('enoent-ready', 'esrch-ready', 'eacces-ready'):
                self.children.release(a)
                self.assertTrue(select.select([ledger._caps[a.pid].pidfd], [], [], 0)[0])
            hit.append(number)
            raise OSError(number, 'owned fd directory fixture')
        def open_(path, flags, **kwargs):
            if path == 'fd' and target(kwargs.get('dir_fd')):
                if how == 'esrch-ready':
                    fd = real_open(path, flags, **kwargs)
                    opened[fd] = True
                    return fd
                fail(errno.EACCES if how in ('eacces-ready', 'eacces-live') else errno.ENOENT)
            return real_open(path, flags, **kwargs)
        def entries(fd):
            if opened.pop(fd, False):
                def read():
                    # Like the real generator: the directory read fails in next().
                    fail(errno.ESRCH)
                    yield
                return read()
            return real_entries(fd)
        return a, server, port, ledger, scan, calls, hit, open_, entries

    def test_fd_directory_departure_restarts_and_proves_serving_peer(self):
        # M2: EACCES is the kernel's exiting/zombie errno at the FD directory.
        for how in ('enoent-ready', 'esrch-ready', 'eacces-ready'):
            with self.subTest(how=how):
                a, server, port, ledger, scan, calls, hit, open_, entries = self.fd_dir_departure(how)
                try:
                    with scan, mock.patch.object(ledger, '_open', side_effect=open_), \
                            mock.patch.object(ledger, '_entries', side_effect=entries):
                        try:
                            row, (cap, name) = ledger.verify_listener(port)
                        except custody.CustodyError as error:
                            self.fail('fd-directory departure HOLD: %s errno %s' % (error.custody_code, error.errno))
                    self.assertEqual(len(hit), 1)
                    self.assertEqual(len(calls), 2)
                    self.assertEqual(cap.pid, server.pid)
                    self.assertNotIn(a.pid, ledger._caps)
                finally:
                    self.children.release(server, b'exit\n')
                    finish(ledger)

    def test_fd_directory_nonready_anchor_and_permission_stay_fatal(self):
        # A live, non-exiting owner's EACCES (no PF_EXITING) stays a permission HOLD.
        expected = {'enoent-live': errno.ENOENT, 'anchor': errno.ENOENT, 'eacces-live': errno.EACCES}
        for how, number in expected.items():
            with self.subTest(how=how):
                a, server, port, ledger, scan, calls, hit, open_, entries = self.fd_dir_departure(how)
                try:
                    with scan, mock.patch.object(ledger, '_open', side_effect=open_), \
                            mock.patch.object(ledger, '_entries', side_effect=entries):
                        with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
                    self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_IO_ERROR', number))
                    self.assertEqual(len(hit), 1)
                    self.assertEqual(len(calls), 1, 'never an empty owner set or restart')
                finally:
                    self.children.release(a)
                    self.children.release(server, b'exit\n')
                    finish(ledger)

    def test_one_site_aware_departure_decision_table(self):
        child = self.children.spawn('idle')
        self.assertEqual(self.children.line(child), 'ready')
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        gone = custody.CustodyError('CUSTODY_ANCHOR_GONE')
        try:
            ledger.refresh()
            target = ledger._caps[child.pid]
            self.assertTrue(callable(getattr(ledger, '_departed', None)), 'one shared departure helper')
            for site in ('stat', 'children', 'procdir', 'empty-tasks', 'fd-dir', 'namespace'):
                # The kernel's exiting errno at each held-capability site.
                exiting = {'namespace': errno.ENOENT, 'fd-dir': errno.EACCES}.get(site)
                for anchor in (False, True):
                    cap = ledger.anchor if anchor else target
                    numbers = (None,) if site == 'empty-tasks' else (errno.ENOENT, errno.ESRCH, errno.EACCES, errno.EIO)
                    for number in numbers:
                        for ready in (False, True):
                            for flags in ((0, PF_EXITING) if anchor else (0,)):
                                if site == 'empty-tasks':
                                    wanted = not anchor and ready
                                elif site in ('namespace', 'fd-dir'):
                                    tolerated = number in (errno.ENOENT, errno.ESRCH, errno.EACCES)
                                    if anchor:
                                        # Never a departure, never a wait: refuses as gone.
                                        wanted = gone if tolerated and (ready or flags and number == exiting) else False
                                    else:
                                        wanted = ready and tolerated
                                else:
                                    wanted = ready and number in (errno.ENOENT, errno.ESRCH)
                                error = None if number is None else OSError(number, 'decision fixture')
                                with self.subTest(site=site, anchor=anchor, errno=number, ready=ready, flags=flags), \
                                        mock.patch.object(ledger, '_fdinfo', return_value=ready), \
                                        mock.patch.object(ledger, '_exit_state',
                                                          return_value=(cap.proof[1], flags, 'R')), \
                                        ledger._operation():
                                    if wanted is gone:
                                        with self.assertRaises(custody.CustodyError) as refused:
                                            ledger._departed(cap, error, site, cap.proof[1])
                                        self.assertEqual(refused.exception.custody_code, 'CUSTODY_ANCHOR_GONE')
                                    else:
                                        self.assertIs(ledger._departed(cap, error, site, cap.proof[1]), wanted)
        finally:
            self.children.release(child)
            finish(ledger)


class CloseAccountingTests(unittest.TestCase):
    """F3: exact-object retirement; independent closes; first error sticky."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    @contextlib.contextmanager
    def failing_close(self, fail):
        real_close = os.close
        closed, failed = [], []
        def close(fd):
            real_close(fd)  # Linux releases the number even when close reports an error.
            closed.append(fd)
            if fail(fd) and not failed:
                failed.append(fd)
                raise OSError(errno.EIO, 'owned close fixture')
        with mock.patch.object(os, 'close', side_effect=close):
            yield closed, failed

    def test_retirement_close_failure_keeps_independent_accounting_and_is_sticky(self):
        child = self.children.spawn('idle')
        self.assertEqual(self.children.line(child), 'ready')
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        try:
            ledger.refresh()
            cap = ledger._caps[child.pid]
            procfd, pidfd, fds = cap.procfd, cap.pidfd, ledger.budget.fds
            self.children.release(child)
            with self.failing_close(lambda fd: fd == procfd) as (closed, failed):
                with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_CLOSE_FAILED', errno.EIO))
            self.assertEqual(failed, [procfd])
            self.assertIn(pidfd, closed, 'independent PIDfd close still attempted')
            self.assertEqual((cap.procfd, cap.pidfd), (None, None))
            self.assertNotIn(child.pid, ledger._caps)
            self.assertNotIn(child.pid, ledger._provisional)
            self.assertEqual(ledger.budget.fds, fds - 1, 'only the successful close is released')
            self.assertIn((child.pid, 'procfd', procfd), ledger._retained)
            self.assertIn(('pid', child.pid), ledger.budget.pins)
            for operation in (ledger.refresh, ledger.close):
                with self.assertRaises(custody.CustodyError) as again:operation()
                self.assertEqual((again.exception.custody_code, again.exception.errno),
                                 ('CUSTODY_CLOSE_FAILED', errno.EIO), 'first error stays sticky')
        finally:
            dispose(ledger)

    def test_constructor_cleanup_attempts_every_handle_after_failure(self):
        real_open, real_pidfd = os.open, os.pidfd_open
        opened = {}
        def open_(path, flags, *args, **kwargs):
            fd = real_open(path, flags, *args, **kwargs)
            opened.setdefault(path, fd)
            return fd
        def pidfd_open(pid, flags=0):
            if pid == os.getpid():
                raise OSError(errno.EIO, 'owned constructor fixture')
            return real_pidfd(pid, flags)
        budget = custody.Budget(time.monotonic() + 8)
        with mock.patch.object(os, 'open', side_effect=open_), \
                mock.patch.object(os, 'pidfd_open', side_effect=pidfd_open), \
                self.failing_close(lambda fd: fd == opened.get(str(os.getpid()))) as (closed, failed):
            with self.assertRaises(custody.CustodyError) as error:
                custody.OwnedDescendants(owned.identity(os.getpid()), budget=budget)
        self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_CLOSE_FAILED', errno.EIO))
        self.assertEqual(failed, [opened[str(os.getpid())]])
        self.assertIn(opened['/proc'], closed, 'root descriptor still closed after the self close failed')
        self.assertEqual(budget.fds, 1, 'failed close remains charged, never released twice')

    def test_close_attempts_every_handle_and_keeps_first_error(self):
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        try:
            ledger.refresh()
            anchor = ledger.anchor
            procfd, pidfd, selffd, rootfd = anchor.procfd, anchor.pidfd, ledger.selffd, ledger.rootfd
            with self.failing_close(lambda fd: fd == procfd) as (closed, failed):
                with self.assertRaises(custody.CustodyError) as error:ledger.close()
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_CLOSE_FAILED', errno.EIO))
            for fd in (pidfd, selffd, rootfd):
                self.assertIn(fd, closed)
            self.assertEqual((anchor.procfd, anchor.pidfd, ledger.selffd, ledger.rootfd), (None,) * 4)
            self.assertEqual(ledger.budget.fds, 1)
            with self.assertRaises(custody.CustodyError) as again:ledger.close()
            self.assertEqual(again.exception.custody_code, 'CUSTODY_CLOSE_FAILED')
        finally:
            dispose(ledger)

    def test_stale_object_retirement_never_closes_or_pops_newer_capability(self):
        child = self.children.spawn('idle')
        self.assertEqual(self.children.line(child), 'ready')
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8)
        try:
            ledger.refresh()
            stale = ledger._caps[child.pid]
            with ledger._operation():
                ledger._close_cap(stale)
                newer = ledger._open_cap(child.pid)
            self.assertIsNot(newer, stale)
            ledger._caps[child.pid] = newer
            ledger._provisional.pop(child.pid, None)
            fds, pins = ledger.budget.fds, dict(ledger.budget.pins)
            real_close = os.close
            closes = []
            with mock.patch.object(os, 'close', side_effect=lambda fd: (closes.append(fd), real_close(fd))):
                with ledger._operation():
                    ledger._close_cap(stale)
            self.assertEqual(closes, [], 'a retired object is never closed twice')
            self.assertIs(ledger._caps[child.pid], newer)
            self.assertEqual((ledger.budget.fds, ledger.budget.pins), (fds, pins))
            os.fstat(newer.procfd);os.fstat(newer.pidfd)
            self.assertIn(child.pid, [p[0] for p in ledger.refresh()])
        finally:
            self.children.release(child)
            try:finish(ledger)
            except custody.CustodyError:dispose(ledger)


class CutoffPhaseTests(unittest.TestCase):
    """F4: sample the clock first; classify expiry by the error's own phase."""

    def test_stop_after_clock_sample_is_not_a_stale_work_expiry(self):
        budget = custody.Budget(10)
        lifetime = custody.TreeLifetime(10)
        with mock.patch.object(custody.time, 'monotonic', return_value=9):
            with budget.operation(lifetime=lifetime):
                fired = []
                def racing():
                    if not fired:
                        fired.append(True)
                        # A stop handler runs between this sample and the comparison.
                        lifetime.begin_teardown(requested_at=9.95)
                    return 10.5
                with mock.patch.object(custody.time, 'monotonic', side_effect=racing):
                    budget.check()
                self.assertTrue(fired)
                self.assertAlmostEqual(lifetime.teardown_deadline, 12.95)
                self.assertEqual(budget.until, lifetime.teardown_deadline)

    def test_expiry_error_carries_its_own_phase(self):
        cases = []
        budget = custody.Budget(10)
        with mock.patch.object(custody.time, 'monotonic', return_value=9):
            with budget.operation():
                with mock.patch.object(custody.time, 'monotonic', return_value=10.5):
                    with self.assertRaises(custody.CustodyError) as error:budget.check()
                cases.append((error.exception.custody_code, error.exception.phase))
        lifetime = custody.TreeLifetime(10)
        budget = custody.Budget(10)
        with mock.patch.object(custody.time, 'monotonic', return_value=9):
            with budget.operation(lifetime=lifetime):
                lifetime.begin_teardown(requested_at=9)
                with mock.patch.object(custody.time, 'monotonic', return_value=12.5):
                    with self.assertRaises(custody.CustodyError) as error:budget.check()
                cases.append((error.exception.custody_code, error.exception.phase))
        lifetime = custody.TreeLifetime(10)
        budget = custody.Budget(10)
        with mock.patch.object(custody.time, 'monotonic', return_value=9):
            with budget.operation(9.5, lifetime=lifetime):
                with mock.patch.object(custody.time, 'monotonic', return_value=9.7):
                    with self.assertRaises(custody.CustodyError) as error:budget.check()
                cases.append((error.exception.custody_code, error.exception.phase))
        with mock.patch.object(custody.time, 'monotonic', return_value=10.5):
            with self.assertRaises(custody.CustodyError) as error:custody.TreeLifetime(10).require_work()
        cases.append((error.exception.custody_code, error.exception.phase))
        self.assertEqual(cases, [('CUSTODY_DEADLINE', 'work'), ('CUSTODY_TEARDOWN_DEADLINE', 'teardown'),
                                 ('CUSTODY_DEADLINE', 'explicit'), ('CUSTODY_DEADLINE', 'work')])

    def test_guardian_classifies_work_expiry_by_phase_after_racing_stop(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=1.2) as run:
            with fx.signal_guardian('cutoff-race'):
                process = run.spawn([sys.executable, '-I', '-S', '-B',
                    str(HERE / 'fixtures/owned_acceptance_child.py'), 'stubborn'])
            observed = []
            fx.fixture_label(process, 'ready', observed)
            cutoff = time.monotonic() + 8
            while process.process.poll() is None:
                self.assertLess(time.monotonic(), cutoff)
                process.pump(0.02)
            for _ in range(4):process.pump(0)
            races = fx.fixture_events(process, observed, 'fixture-cutoff-race')
            self.assertEqual(races, [{'code': 'CUSTODY_DEADLINE', 'phase': 'work', 'teardownStarted': True}])
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertNotIn('uncertain', json.dumps(records))
            self.assertEqual(records[0], {'workExpired': True})
            self.assertEqual(records[-1], {'treeEmpty': True})
            self.assertEqual(process.process.returncode, 124)
            self.assertIsNone(process.uncertainty)
            receipt = run.finish()
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertEqual(receipt['failure'], 'COMMAND_DEADLINE')
            self.assertTrue(receipt['teardownVerified'])


class ConstructionExpiryTests(unittest.TestCase):
    """F5: known work expiry inside construction finalizes without launch."""

    def test_construction_work_expiry_is_bounded_no_launch_hold(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=1.0) as run:
            with fx.signal_guardian('constructor-expiry'):
                process = run.spawn([sys.executable, '-I', '-S', '-B', '-c',
                                     'print("target-launched", flush=True)'])
            cutoff = time.monotonic() + 5
            while process.process.poll() is None:
                self.assertLess(time.monotonic(), cutoff)
                process.pump(0.02)
            for _ in range(4):process.pump(0)
            self.assertEqual(fx.fixture_events(process, [], 'fixture-constructor-failed'),
                             [{'code': 'CUSTODY_DEADLINE', 'phase': 'work', 'descriptors': 0}])
            self.assertEqual(fx.fixture_events(process, [], 'fixture-spawn'), [])
            self.assertNotIn(b'target-launched', process.buffers['out'])
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertEqual(records, [{'workExpired': True}, {'treeEmpty': True}])
            self.assertEqual(process.process.returncode, 124)
            self.assertIsNone(process.uncertainty)
            self.assertTrue(process.work_expired)
            receipt = run.finish()
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertEqual(receipt['failure'], 'COMMAND_DEADLINE')
            self.assertTrue(receipt['teardownVerified'])

    def test_genuine_construction_error_stays_sticky_initialization_hold(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=30) as run:
            with fx.signal_guardian('constructor-ioerror'):
                process = run.spawn([sys.executable, '-I', '-S', '-B', '-c',
                                     'print("target-launched", flush=True)'])
            cutoff = time.monotonic() + 5
            with self.assertRaises(owned.Hold) as failure:
                while True:
                    self.assertLess(time.monotonic(), cutoff)
                    process.pump(0.02)
            self.assertEqual(str(failure.exception), 'CHILD_TREE_UNCERTAIN')
            self.assertEqual(process.uncertainty, {'uncertain': 'CUSTODY_IO_ERROR', 'errno': errno.EIO})
            self.assertEqual(fx.fixture_events(process, [], 'fixture-constructor-failed'),
                             [{'code': 'CUSTODY_IO_ERROR', 'phase': None, 'descriptors': 0}])
            self.assertEqual(fx.fixture_events(process, [], 'fixture-spawn'), [])
            self.assertFalse(process.work_expired)
            self.assertIsNone(process.process.poll(), 'sticky initialization HOLD retains the guardian')
            receipt = run.finish(failure.exception)
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertFalse(receipt['teardownVerified'])


def pidfd_ready(fd):
    return bool(select.select([fd], [], [], 0)[0])


class Outside:
    """The test's OWN handles on one owned process; never the module's objects."""
    def __init__(self, pid):
        self.pid = pid
        self.pidfd = os.pidfd_open(pid)
        self.procfd = os.open('/proc/' + str(pid), os.O_RDONLY | os.O_DIRECTORY)

    def view(self):
        def outcome(call):
            try:
                call()
                return 'ok'
            except OSError as error:
                return errno.errorcode.get(error.errno, str(error.errno))
        def fd_dir():
            os.close(os.open('fd', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.procfd))
        try:
            fd = os.open('stat', os.O_RDONLY, dir_fd=self.procfd)
            try:
                fields = os.read(fd, 8192).decode().rsplit(')', 1)[-1].split()
            finally:
                os.close(fd)
            state, exiting = fields[0], bool(int(fields[6]) & PF_EXITING)
        except OSError as error:
            state, exiting = errno.errorcode.get(error.errno, str(error.errno)), None
        return {'nsnet': outcome(lambda: os.readlink('ns/net', dir_fd=self.procfd)),
                'fdDir': outcome(fd_dir), 'ready': pidfd_ready(self.pidfd), 'state': state,
                'exiting': exiting}

    def until(self, predicate, seconds=3.0):
        limit = time.monotonic() + seconds
        while time.monotonic() < limit:
            view = self.view()
            if predicate(view):
                return view
        raise AssertionError('outside kernel state not reached: %r' % (self.view(),))

    def close(self):
        os.close(self.procfd)
        os.close(self.pidfd)


EXITING_NONREADY = lambda v: v['fdDir'] == 'EACCES' and v['nsnet'] == 'ok' and not v['ready']
ZOMBIE_READY = lambda v: v['fdDir'] == 'EACCES' and v['ready'] and v['state'] == 'Z'


def reaper(children):
    """Guardian-like exact reaping of this test's own direct fixture children."""
    def reap(budget):
        for child in children.items:
            if child.returncode is None:
                pid, status = os.waitpid(child.pid, os.WNOHANG)
                if pid:
                    budget.record_reap(pid, status)
                    child.returncode = os.waitstatus_to_exitcode(status)
    return reap


class ExitWindowCutoffTests(unittest.TestCase):
    """M1: an exit-window wait ended by the work cutoff is that known work expiry."""

    def exiting_leader_command(self, run):
        # A live last thread holds the real exit window across the cutoff.
        # Kernel memory-reclamation duration is not a timing guarantee.
        return [sys.executable, '-I', '-S', '-B', CHILD, 'terminal-leader-cutoff',
                repr(run.deadline + 0.1)]

    def test_guardian_exit_window_at_work_cutoff_is_known_expiry_with_verified_cleanup(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=1.5) as run:
            process = run.spawn(self.exiting_leader_command(run))
            with self.assertRaises(owned.Hold) as failure:process.wait(4)
            self.assertEqual(str(failure.exception), 'COMMAND_DEADLINE')
            receipt = run.finish(failure.exception)
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertEqual(records, [{'workExpired': True}, {'commandExit': 0}, {'treeEmpty': True}])
            self.assertNotIn('uncertain', json.dumps(records))
            self.assertIsNone(process.uncertainty)
            self.assertTrue(process.work_expired)
            self.assertEqual((receipt['status'], receipt['failure']), ('HOLD', 'COMMAND_DEADLINE'))
            self.assertTrue(receipt['teardownVerified'])
            self.assertEqual(receipt['uncertainProcesses'], [])

    def test_parent_members_in_exit_window_at_cutoff_is_nonsticky_deadline(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=1.5) as run:
            process = run.spawn(self.exiting_leader_command(run))
            limit = time.monotonic() + 5
            with self.assertRaises(owned.Hold) as failure:
                while True:
                    self.assertLess(time.monotonic(), limit)
                    process.members()
                    time.sleep(0.002)
            self.assertEqual(str(failure.exception), 'CUSTODY_DEADLINE')
            self.assertEqual(getattr(failure.exception.__cause__, 'phase', None), 'work')
            self.assertIsNone(process.uncertainty)
            receipt = run.finish(failure.exception)
            self.assertIsNone(process.uncertainty)
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertTrue(receipt['teardownVerified'])


class FdDirectoryExitTests(unittest.TestCase):
    """M2: real kernel orderings at the FD directory; no injected errno."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    def ledger(self, owners):
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 20,
                                          reap=reaper(self.children))
        ledger.refresh()
        ordered(ledger, owners)
        return ledger

    def exit_after_validate(self, ledger, owner, condition, scan_number, *, in_verify=False):
        """Make OWNER exit after the module's real _validate(owner) returned its
        proof inside scan SCAN_NUMBER (or inside the exact socket-FD recheck), and
        return only once the test's own handles show CONDITION."""
        real_scan, real_validate, real_verify = ledger._socket_fd, ledger._validate, ledger._verify_socket_fd
        real_window = ledger._exit_window
        state = {'scans': 0, 'verify': False, 'fired': None, 'windows': []}
        outside = Outside(owner.pid)
        def scan(inode):
            state['scans'] += 1
            return real_scan(inode)
        def verify(cap, name, inode):
            state['verify'] = True
            try:return real_verify(cap, name, inode)
            finally:state['verify'] = False
        def validate(cap):
            proof = real_validate(cap)
            if state['fired'] is None and cap.pid == owner.pid and proof is not None \
                    and state['scans'] == scan_number and state['verify'] == in_verify:
                owner.stdin.write(b'exit\n');owner.stdin.flush()
                state['fired'] = outside.until(condition)
            return proof
        def window(cap, birth):
            state['windows'].append(cap.pid)
            return real_window(cap, birth)
        patches = contextlib.ExitStack()
        for name, value in (('_socket_fd', scan), ('_validate', validate),
                            ('_verify_socket_fd', verify), ('_exit_window', window)):
            patches.enter_context(mock.patch.object(ledger, name, side_effect=value))
        patches.callback(outside.close)
        return patches, state

    def two_owners(self):
        a = self.children.spawn('idle', 256)
        server = self.children.spawn('serve')
        self.assertEqual(self.children.line(a), 'ready')
        port = int(self.children.line(server))
        return a, server, port, self.ledger([a.pid, server.pid])

    def test_exiting_or_zombie_owner_at_fd_directory_restarts_and_proves_serving_peer(self):
        for how, condition in (('exiting-nonready', EXITING_NONREADY), ('zombie-ready', ZOMBIE_READY)):
            for site in ('verify', 'connect'):
                with self.subTest(how=how, site=site):
                    a, server, port, ledger = self.two_owners()
                    connects, real_connect = [], socket.socket.connect
                    def connect(sock, address):
                        connects.append(address)
                        return real_connect(sock, address)
                    patches, state = self.exit_after_validate(ledger, a, condition, 1 if site == 'verify' else 2)
                    try:
                        with patches, mock.patch.object(socket.socket, 'connect', connect):
                            try:
                                if site == 'verify':
                                    row, (cap, name) = ledger.verify_listener(port)
                                    self.assertEqual(cap.pid, server.pid)
                                    self.assertIs(ledger._caps[server.pid], cap)
                                    self.assertEqual(state['scans'], 2, 'one departure, one fresh scan')
                                else:
                                    with ledger.connect_owned(port, time.monotonic() + 5) as conn:
                                        self.assertIsNotNone(state['fired'], 'peer proof precedes any byte')
                                        conn.sendall(b'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')
                                        wire = b''
                                        while True:
                                            block = conn.recv(8192)
                                            if not block:break
                                            wire += block
                                    self.assertTrue(wire.endswith(b'owned-serving-peer'))
                                    self.assertEqual(connects, [('127.0.0.1', port)], 'exactly one connection')
                            except custody.CustodyError as error:
                                self.fail('FD-directory exit HOLD: %s errno %s' % (error.custody_code, error.errno))
                        self.assertIsNotNone(state['fired'])
                        self.assertEqual(state['windows'], [a.pid] if how == 'exiting-nonready' else [],
                                         'only a nonready exiting owner takes the bounded wait')
                        self.assertNotIn(a.pid, ledger._caps)
                        server.stdin.write(b'count\n');server.stdin.flush()
                        self.assertEqual(self.children.line(server), 'count:' + str(int(site == 'connect')))
                    finally:
                        self.children.release(server, b'exit\n')
                        finish(ledger)

    def test_sole_owner_exit_at_fd_directory_is_one_restart_then_listener_missing(self):
        for how, condition in (('exiting-nonready', EXITING_NONREADY), ('zombie-ready', ZOMBIE_READY)):
            with self.subTest(how=how):
                a = self.children.spawn('serve', 256)
                port = int(self.children.line(a))
                ledger = self.ledger([a.pid])
                patches, state = self.exit_after_validate(ledger, a, condition, 1)
                try:
                    with patches:
                        with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
                    self.assertEqual((error.exception.custody_code, error.exception.errno), ('LISTENER_MISSING', None))
                    self.assertEqual(state['scans'], 1)
                    self.assertIsNotNone(state['fired'])
                    self.assertNotIn(a.pid, ledger._caps)
                finally:
                    finish(ledger)

    def test_sole_owner_exit_after_fd_directory_open_never_becomes_empty_owner_set(self):
        a = self.children.spawn('serve', 256)
        port = int(self.children.line(a))
        ledger = self.ledger([a.pid])
        outside = Outside(a.pid)
        own_fd_dir = os.open('fd', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=outside.procfd)
        real_open, real_entries = ledger._open, ledger._entries
        target, fired = {}, []
        def open_(path, flags, **kwargs):
            fd = real_open(path, flags, **kwargs)
            cap = ledger._caps.get(a.pid)
            if path == 'fd' and cap is not None and kwargs.get('dir_fd') == cap.procfd and not fired:
                target[fd] = True
            return fd
        def entries(fd):
            if target.pop(fd, False) and not fired:
                a.stdin.write(b'exit\n');a.stdin.flush()
                limit = time.monotonic() + 3
                while os.listdir(own_fd_dir):
                    self.assertLess(time.monotonic(), limit)
                fired.append(outside.view())
            return real_entries(fd)
        try:
            with mock.patch.object(ledger, '_open', side_effect=open_), \
                    mock.patch.object(ledger, '_entries', side_effect=entries):
                with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
            self.assertEqual(len(fired), 1, 'the owner exited between open and directory read')
            self.assertEqual(error.exception.custody_code, 'LISTENER_MISSING')
            self.assertNotIn(a.pid, ledger._caps)
        finally:
            os.close(own_fd_dir)
            outside.close()
            finish(ledger)

    def test_exact_socket_fd_recheck_of_zombie_owner_is_departure(self):
        server = self.children.spawn('serve')
        port = int(self.children.line(server))
        ledger = self.ledger([server.pid])
        patches, state = self.exit_after_validate(ledger, server, ZOMBIE_READY, 1, in_verify=True)
        try:
            with patches:
                with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
            self.assertIsNotNone(state['fired'], 'the owner exited inside the exact FD recheck')
            self.assertEqual(error.exception.custody_code, 'LISTENER_MISSING')
            self.assertEqual(state['scans'], 1)
            self.assertNotIn(server.pid, ledger._caps)
        finally:
            finish(ledger)

    def test_post_release_directory_read_is_the_generator_departure_site(self):
        a = self.children.spawn('idle')
        server = self.children.spawn('serve')
        self.assertEqual(self.children.line(a), 'ready')
        port = int(self.children.line(server))
        ledger = self.ledger([a.pid, server.pid])
        own = os.pidfd_open(a.pid)
        real_open, real_entries, real_departed = ledger._open, ledger._entries, ledger._departed
        target, fired, decisions = {}, [], []
        def open_(path, flags, **kwargs):
            fd = real_open(path, flags, **kwargs)
            cap = ledger._caps.get(a.pid)
            if path == 'fd' and cap is not None and kwargs.get('dir_fd') == cap.procfd and not fired:
                target[fd] = True
            return fd
        def entries(fd):
            if target.pop(fd, False) and not fired:
                self.children.release(a)  # Reaped: released after the directory open.
                self.assertTrue(pidfd_ready(own))
                fired.append(True)
            return real_entries(fd)
        def departed(cap, error, site, birth=None):
            decisions.append((cap.pid, site, getattr(error, 'errno', None)))
            return real_departed(cap, error, site, birth)
        try:
            with mock.patch.object(ledger, '_open', side_effect=open_), \
                    mock.patch.object(ledger, '_entries', side_effect=entries), \
                    mock.patch.object(ledger, '_departed', side_effect=departed):
                row, (cap, name) = ledger.verify_listener(port)
            self.assertEqual(fired, [True])
            self.assertIn((a.pid, 'fd-dir', errno.ENOENT), decisions, 'next(entries) raised the real ENOENT')
            self.assertEqual(cap.pid, server.pid)
            self.assertNotIn(a.pid, ledger._caps)
        finally:
            os.close(own)
            self.children.release(server, b'exit\n')
            finish(ledger)

    def test_live_nondumpable_owner_fd_directory_eacces_stays_permission_hold(self):
        a = self.children.spawn('nodump')
        server = self.children.spawn('serve')
        self.assertEqual(self.children.line(a), 'ready')
        port = int(self.children.line(server))
        ledger = self.ledger([a.pid, server.pid])
        real_validate = ledger._validate
        fired = []
        def validate(cap):
            proof = real_validate(cap)
            if cap.pid == a.pid and proof is not None and not fired:
                a.stdin.write(b'nodump\n');a.stdin.flush()
                self.assertEqual(self.children.line(a), 'nodump')
                fired.append(True)
            return proof
        try:
            with mock.patch.object(ledger, '_validate', side_effect=validate):
                with self.assertRaises(custody.CustodyError) as error:ledger.verify_listener(port)
            self.assertEqual(fired, [True])
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_IO_ERROR', errno.EACCES))
            self.assertIn(a.pid, ledger._caps, 'a live owner is never retired')
            self.assertFalse(pidfd_ready(ledger._caps[a.pid].pidfd))
        finally:
            self.children.release(a, b'exit\n')
            self.children.release(server, b'exit\n')
            finish(ledger)


class AnchorExitTests(unittest.TestCase):
    """M3: an exited or exiting anchor refuses as CUSTODY_ANCHOR_GONE; it never waits."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    def anchored(self, mode, *args):
        child = self.children.spawn(mode, *args)
        self.assertEqual(self.children.line(child), 'ready')
        # The parent driver's shape: a ledger anchored at a separate owned process, reap=None.
        return child, custody.OwnedDescendants(owned.identity(child.pid), deadline=time.monotonic() + 8)

    def test_anchor_ready_at_namespace_readlink_is_anchor_gone(self):
        child, ledger = self.anchored('idle')
        outside = Outside(child.pid)
        real_link, hit = os.readlink, []
        def exiting(path, *args, **kwargs):
            if path == 'ns/net' and kwargs.get('dir_fd') == ledger.anchor.procfd and not hit:
                child.stdin.write(b'x');child.stdin.flush()
                hit.append(outside.until(lambda v: v['ready'] and v['state'] == 'Z'))
            return real_link(path, *args, **kwargs)  # The real zombie ENOENT.
        try:
            with mock.patch.object(os, 'readlink', side_effect=exiting):
                with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
            self.assertEqual(len(hit), 1)
            self.assertEqual(hit[0]['nsnet'], 'ENOENT')
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_ANCHOR_GONE', None))
        finally:
            outside.close()
            self.assertEqual(child.wait(timeout=3), 0)
            dispose(ledger)

    def test_anchor_in_real_exit_window_is_anchor_gone_without_wait(self):
        child, ledger = self.anchored('memfd-exit', 256)
        outside = Outside(child.pid)
        real_link, real_state, hit, states, waits = os.readlink, ledger._exit_state, [], [], []
        def exiting(path, *args, **kwargs):
            if path == 'ns/net' and kwargs.get('dir_fd') == ledger.anchor.procfd and not hit:
                child.stdin.write(b'exit\n');child.stdin.flush()
                hit.append(outside.until(lambda v: v['nsnet'] == 'ENOENT' and not v['ready']))
            return real_link(path, *args, **kwargs)
        def exit_state(cap):
            value = real_state(cap)
            states.append((value[1] & PF_EXITING, pidfd_ready(outside.pidfd)))
            return value
        try:
            with mock.patch.object(os, 'readlink', side_effect=exiting), \
                    mock.patch.object(ledger, '_exit_state', side_effect=exit_state), \
                    mock.patch.object(ledger, '_exit_window', side_effect=lambda *a: waits.append(a)):
                with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
            self.assertEqual(len(hit), 1)
            self.assertEqual((error.exception.custody_code, error.exception.errno), ('CUSTODY_ANCHOR_GONE', None))
            self.assertEqual(waits, [], 'an anchor never enters the exit-window wait')
            self.assertEqual(states, [(PF_EXITING, False)], 'refused on PF_EXITING before readiness')
        finally:
            outside.close()
            self.assertEqual(child.wait(timeout=3), 0)
            dispose(ledger)

    def test_driver_stop_tolerates_guardian_exit_seen_at_namespace_readlink(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=30) as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B', '-c', 'import time; time.sleep(0.3)'])
            own = os.pidfd_open(process.process.pid)
            real_link, hit = os.readlink, []
            def exiting(path, *args, **kwargs):
                ledger = process.custody
                if path == 'ns/net' and not hit and kwargs.get('dir_fd') == ledger.anchor.procfd:
                    # The guardian finishes normally (commandExit, treeEmpty) while the
                    # parent's census holds its validated anchor at this readlink.
                    self.assertTrue(select.select([own], [], [], 5)[0])
                    hit.append(True)
                return real_link(path, *args, **kwargs)
            try:
                with mock.patch.object(os, 'readlink', side_effect=exiting):
                    try:
                        process.stop()
                    except owned.Hold as error:
                        self.fail('stop() did not tolerate the exited guardian: %s %r' % (error, process.uncertainty))
            finally:
                os.close(own)
            self.assertEqual(hit, [True])
            self.assertIsNone(process.uncertainty)
            self.assertEqual(process.process.returncode, 0)
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertEqual(records[-1], {'treeEmpty': True})
            receipt = run.finish()
            self.assertTrue(receipt['teardownVerified'])
            self.assertEqual(receipt['status'], 'SAFETY_FIXTURE_COMPLETED')

    def test_custody_call_waits_bounded_for_exiting_guardian_popen(self):
        def gone():
            raise custody.CustodyError('CUSTODY_ANCHOR_GONE')
        for label, seconds, cutoff in (('exits', 0.1, 30), ('retained', 30, 0.3)):
            with self.subTest(guardian=label):
                child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c',
                                          'import time; time.sleep(%r)' % seconds])
                process = owned.OwnedProcess.__new__(owned.OwnedProcess)
                process.process, process.uncertainty = child, None
                process.lifetime = custody.TreeLifetime(time.monotonic() + cutoff)
                try:
                    started = time.monotonic()
                    with self.assertRaises(owned.Hold) as failure:process.custody_call(gone)
                    self.assertEqual(str(failure.exception), 'CUSTODY_ANCHOR_GONE')
                    if label == 'exits':
                        self.assertIsNone(process.uncertainty, 'the exact Popen exited: expected exit')
                        self.assertEqual(child.returncode, 0)
                    else:
                        self.assertEqual(process.uncertainty, {'uncertain': 'CUSTODY_ANCHOR_GONE'})
                        self.assertIsNone(child.poll())
                        self.assertLess(time.monotonic() - started, 0.7, 'bounded by the tree cutoff')
                finally:
                    if child.poll() is None:
                        fixtures.DetachedCustodyTests().terminate_fixture(child)


class TerminalLeafTests(unittest.TestCase):
    """M4: a zombie kept by a live owned parent is an inert terminal leaf."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    def test_guardian_zombie_grandchild_of_live_parent_completes_and_tears_down(self):
        fx = fixtures.DetachedCustodyTests()
        with fx.private_run(seconds=8) as run:
            process = run.spawn(['/bin/bash', '-c', '(/bin/sleep 0.2) & exec /bin/sleep 2'])
            try:
                process.wait(6)
            except owned.Hold as error:
                self.fail('zombie grandchild HOLD: %s %r' % (error, process.uncertainty))
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertEqual(records, [{'commandExit': 0}, {'treeEmpty': True}])
            self.assertIsNone(process.uncertainty)
            receipt = run.finish()
            self.assertTrue(receipt['teardownVerified'])
            self.assertEqual(receipt['status'], 'SAFETY_FIXTURE_COMPLETED')

    def holder(self):
        holder = self.children.spawn('zombie-holder')
        zombie = int(self.children.line(holder))
        zfd = os.pidfd_open(zombie)
        self.assertTrue(select.select([zfd], [], [], 3)[0], 'the held child exited')
        return holder, zombie, zfd

    def test_census_holds_live_parent_and_never_adopts_its_zombie_child(self):
        holder, zombie, zfd = self.holder()
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8,
                                          reap=reaper(self.children))
        try:
            fds, signals = ledger.budget.fds, []
            real_send = signal.pidfd_send_signal
            with mock.patch.object(signal, 'pidfd_send_signal',
                                   side_effect=lambda fd, sig: (signals.append(fd), real_send(fd, sig))):
                try:
                    proofs = ledger.refresh()
                except custody.CustodyError as error:
                    self.fail('persistent zombie leaf HOLD: %s' % error.custody_code)
                pids = [p[0] for p in proofs]
                self.assertIn(holder.pid, pids)
                self.assertNotIn(zombie, pids, 'a terminal leaf is not a live proof')
                self.assertNotIn(zombie, ledger._caps)
                self.assertNotIn(zombie, ledger._provisional)
                self.assertNotIn(('pid', zombie), ledger.budget.pins)
                self.assertEqual(ledger.budget.fds, fds + 2, 'the leaf PIDfd closes with its census pass')
                self.assertFalse(ledger.empty, 'not empty while the parent lives')
                self.assertEqual(signals, [])
            self.assertTrue(pidfd_ready(zfd))
        finally:
            os.close(zfd)
            self.children.release(holder, b'exit\n')
            finish(ledger)

    def test_leaf_released_or_replaced_during_census_restarts_it(self):
        for how in ('released', 'replaced'):
            with self.subTest(leaf=how):
                holder, zombie, zfd = self.holder()
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8,
                                                  reap=reaper(self.children))
                real_open, real_children, real_terminal = ledger._open_cap, ledger._children, \
                    getattr(ledger, '_terminal', None)
                state = {'leaf': 0, 'fired': False, 'terminal': []}
                def open_cap(pid, **kwargs):
                    cap = real_open(pid, **kwargs)
                    if pid == zombie and cap is not None and getattr(cap, 'terminal', False):
                        state['leaf'] += 1
                    return cap
                def children(cap):
                    result = real_children(cap)
                    if cap.pid == holder.pid and state['leaf'] and not state['fired']:
                        state['fired'] = True
                        holder.stdin.write(b'reap\n');holder.stdin.flush()
                        self.assertEqual(self.children.line(holder), 'reaped')
                        result = real_children(cap)
                        self.assertNotIn(zombie, result)
                        if how == 'replaced':
                            result = result | {zombie}  # Same number listed again: PID reuse.
                    return result
                def terminal(leaf):
                    value = real_terminal(leaf)
                    state['terminal'].append(value)
                    return value
                try:
                    with mock.patch.object(ledger, '_open_cap', side_effect=open_cap), \
                            mock.patch.object(ledger, '_children', side_effect=children), \
                            mock.patch.object(ledger, '_terminal', side_effect=terminal, create=True):
                        try:
                            proofs = ledger.refresh()
                        except custody.CustodyError as error:
                            self.fail('leaf change HOLD: %s' % error.custody_code)
                        self.assertEqual(ledger.budget.passes, 2, 'the changed leaf restarted the census')
                    self.assertTrue(state['fired'])
                    self.assertEqual(state['leaf'], 1)
                    if how == 'replaced':
                        self.assertIn(False, state['terminal'], 'released leaf PIDfd no longer binds the PID')
                    self.assertIn(holder.pid, [p[0] for p in proofs])
                    self.assertNotIn(zombie, [p[0] for p in proofs])
                finally:
                    os.close(zfd)
                    self.children.release(holder, b'exit\n')
                    finish(ledger)


class EmptyTaskListingTests(unittest.TestCase):
    """M5: a released non-anchor's empty task listing is a census change."""

    def setUp(self):
        self.children = _Children(self)

    def tearDown(self):
        self.children.close()

    def test_empty_task_listing_of_released_child_restarts_census(self):
        for target in ('released', 'live', 'anchor'):
            with self.subTest(target=target):
                child = self.children.spawn('idle')
                self.assertEqual(self.children.line(child), 'ready')
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 8,
                                                  reap=reaper(self.children))
                own = os.pidfd_open(child.pid)
                try:
                    ledger.refresh()
                    procfd = ledger.anchor.procfd if target == 'anchor' else ledger._caps[child.pid].procfd
                    real_open, real_entries = ledger._open, ledger._entries
                    task, fired = {}, []
                    def open_(path, flags, **kwargs):
                        fd = real_open(path, flags, **kwargs)
                        if path == 'task' and kwargs.get('dir_fd') == procfd and not fired:
                            task[fd] = True
                        return fd
                    def entries(fd):
                        if task.pop(fd, False) and not fired:
                            # Released after proc_task_readdir's dead check, before first_tid.
                            if target == 'released':
                                self.children.release(child)
                                self.assertTrue(pidfd_ready(own))
                            fired.append(True)
                            return iter(())
                        return real_entries(fd)
                    with mock.patch.object(ledger, '_open', side_effect=open_), \
                            mock.patch.object(ledger, '_entries', side_effect=entries):
                        if target == 'released':
                            try:
                                proofs = ledger.refresh()
                            except custody.CustodyError as error:
                                self.fail('released empty task listing HOLD: %s' % error.custody_code)
                            self.assertEqual([p[0] for p in proofs], [os.getpid()])
                            self.assertNotIn(child.pid, ledger._caps)
                        else:
                            with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
                            self.assertEqual(error.exception.custody_code, 'CUSTODY_TASKS_UNKNOWN')
                            self.assertFalse(pidfd_ready(own))
                    self.assertEqual(fired, [True])
                finally:
                    os.close(own)
                    self.children.release(child)
                    finish(ledger)


class SafetySuiteEntryPointTests(unittest.TestCase):
    """CI wires each owned safety suite as `python3 -B tests/<suite>` (V6R2-S1)."""
    # The final composer's SELF_EXECUTING predicate, byte for byte.
    SELF_EXECUTING = re.compile(rb'^if __name__ == [\'"]__main__[\'"]:\s*unittest\.main\(', re.M)
    DELTA_SUITES = ('test_owned_custody_departure.py', 'test_owned_custody_reproof.py',
                    'test_owned_native_acceptance.py', 'test_owned_proc_lifecycle.py',
                    'test_owned_process_custody.py')

    def test_every_owned_safety_suite_runs_its_tests_when_executed_directly(self):
        """Without the entry point the CI step runs zero tests and exits 0 (silent skip)."""
        present = sorted(path.name for path in HERE.glob('test_owned_*.py'))
        self.assertLessEqual(set(self.DELTA_SUITES), set(present))
        silent = [name for name in present if not self.SELF_EXECUTING.search((HERE / name).read_bytes())]
        self.assertEqual(silent, [], 'safety suites that would run zero tests under python3 -B')
        for name in present:
            # The entry point is the final top-level statement, so every TestCase is defined first.
            last = ast.parse((HERE / name).read_bytes(), filename=name).body[-1]
            self.assertIsInstance(last, ast.If, name)
            self.assertEqual(ast.unparse(last.test), "__name__ == '__main__'", name)
            self.assertEqual([ast.unparse(node.value.func) for node in last.body], ['unittest.main'], name)


if __name__ == '__main__':
    unittest.main(verbosity=2)
