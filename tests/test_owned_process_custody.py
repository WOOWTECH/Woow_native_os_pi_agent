"""Owned synthetic detached custody; no installer, SDK or provider imports."""
import os
import contextlib
import ctypes
import errno
import io
import json
import shutil
import socket
import subprocess
import sys
from unittest import mock

import owned_process_custody as custody
from pathlib import Path
import tempfile
import signal
import select
import time
import unittest

import owned_native_acceptance as owned
from test_owned_native_acceptance import resolve_fixture_node, fixture_node_wrapper

HERE = Path(__file__).resolve().parent
NODE = None


def setUpModule():
    global NODE
    NODE = resolve_fixture_node()


class DetachedCustodyTests(unittest.TestCase):
    def fixture_record(self, run, phase):
        path = os.environ.get('OWNED_CUSTODY_FIXTURE_LEDGER')
        if path:
            record = {'test': self.id(), 'phase': phase, 'processes': []}
            for process in run.processes:
                record['processes'].append({'guardianProof': process.proof,
                    'returncode': process.process.poll(),
                    'custodyProofs': [] if process.custody is None else [cap.proof for cap in
                        list(process.custody._caps.values()) + list(process.custody._provisional.values())]})
            with open(path, 'a', encoding='ascii') as out:
                out.write(json.dumps(record) + '\n')

    def terminate_fixture(self, child):
        if child.poll() is None:
            proof = owned.identity(child.pid)
            fd = os.pidfd_open(child.pid)
            try:
                self.assertIsNotNone(proof)
                self.assertEqual(owned.identity(child.pid)[:5], proof[:5])
                self.assertEqual(proof[2], os.getuid())
                signal.pidfd_send_signal(fd, signal.SIGTERM)
            finally:
                os.close(fd)
            child.wait(timeout=3)

    def cleanup_fixture(self, run):
        """Only known private test descendants; never a production cleanup path."""
        self.fixture_record(run, 'before-fixture-cleanup')
        for process in run.processes:
            if process.process.poll() is None:
                proofs = [owned.identity(pid) for pid in owned.descendants(process.process.pid)]
                for proof in proofs:
                    if proof is None:
                        continue
                    self.assertEqual(proof[2], os.getuid())
                    try:
                        fd = os.pidfd_open(proof[0])
                    except ProcessLookupError:
                        continue
                    try:
                        current = owned.identity(proof[0])
                        if current is not None:
                            self.assertEqual(current[:5], proof[:5])
                            signal.pidfd_send_signal(fd, signal.SIGKILL)
                        self.assertTrue(select.select([fd], [], [], 3)[0])
                    finally:
                        os.close(fd)
                if process.custody is not None:
                    for cap in list(process.custody._caps.values()) + list(process.custody._provisional.values()):
                        if cap.pid != process.proof[0]:
                            self.assertTrue(select.select([cap.pidfd], [], [], 3)[0],
                                            'unknown fixture process must depart before guardian cleanup')
                time.sleep(0.03)
                if process.process.poll() is None:
                    fd = os.pidfd_open(process.proof[0])
                    try:
                        current = owned.identity(process.proof[0])
                        if current is not None:
                            self.assertEqual(current[:5], process.proof[:5])
                            signal.pidfd_send_signal(fd, signal.SIGKILL)
                    finally:
                        os.close(fd)
                    process.process.wait(timeout=3)
            if process.custody is not None and not process.custody.closed:
                try:
                    process.custody.close()
                except custody.CustodyError as error:
                    # Fixture disposal only, after every retained process has
                    # exited. Never renew a production cleanup deadline.
                    self.assertIn(error.custody_code, ('CUSTODY_DEADLINE', 'CUSTODY_TEARDOWN_DEADLINE'))
                    ledger = process.custody
                    self.assertFalse(ledger._leases)
                    for cap in list(ledger._caps.values()) + list(ledger._provisional.values()):
                        self.assertTrue(select.select([cap.pidfd], [], [], 0)[0])
                        ledger._close_cap(cap)
                    ledger._close_fd(ledger.selffd)
                    ledger._close_fd(ledger.rootfd)
                    ledger.closed = True
            process.close_pipes()
        run.ws.close()
        self.fixture_record(run, 'fixture-cleanup-complete')

    def test_real_detached_node_with_quoted_provisioned_path(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)
            parent.chmod(0o700)
            node = parent / "provisioned tool's bin" / 'node'
            node.parent.mkdir()
            node.write_bytes(fixture_node_wrapper(NODE))
            node.chmod(0o755)
            selected = resolve_fixture_node(str(node.parent))
            run = owned.OwnedRun(parent, scope='safety-fixture', supervisor='owned-subreaper')
            failure = None
            try:
                process = run.spawn([selected, str(HERE / 'fixtures/owned_detached_child.mjs')])
                self.assertEqual(process.process.args[1:4], ['-I', '-S', '-B'])
                self.assertIn('--supervisor', process.process.args)
                port = int(process.line(5))
                self.assertEqual(owned.Endpoint(process, port).get('/'), b'owned-detached-response')
                self.assertTrue(any(p[4] != process.proof[4] for p in process.members()))
            except BaseException as error:
                failure = error
                raise
            finally:
                receipt = run.finish(failure)
                self.cleanup_fixture(run)
            self.assertTrue(receipt['teardownVerified'])
            self.assertFalse(receipt['privateRootRetained'])
            self.assertEqual(receipt['supervisor'], 'owned-subreaper')
            self.assertFalse(receipt['realUbuntuAcceptance'])


    @contextlib.contextmanager
    def private_run(self, supervisor='owned-subreaper', seconds=1800):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)
            parent.chmod(0o700)
            run = owned.OwnedRun(parent, scope='safety-fixture', supervisor=supervisor, seconds=seconds)
            try:
                yield run
            finally:
                self.last_receipt = run.finish(owned.Hold('FIXTURE_SCOPE_END'))
                self.cleanup_fixture(run)

    def node_server(self, run):
        process = run.spawn([NODE, str(HERE / 'fixtures/owned_detached_child.mjs'), 'server'])
        return process, int(process.line(5))

    def command(self, process, text):
        process.process.stdin.write((text + '\n').encode())
        process.process.stdin.flush()
        return process.line(3)

    def test_same_detached_node_is_refused_by_default_strict_mode(self):
        with self.private_run('owned-pgid') as run:
            process = run.spawn([NODE, str(HERE / 'fixtures/owned_detached_child.mjs')])
            with self.assertRaises(owned.Hold):
                process.wait(2)
            self.assertEqual(run.receipt['supervisor'], 'owned-pgid')

    def test_double_detached_adoption_and_same_owned_session_movement(self):
        with self.private_run() as run:
            process = run.spawn([NODE, str(HERE / 'fixtures/owned_detached_child.mjs'), 'double'])
            self.assertEqual(owned.Endpoint(process, int(process.line(5))).get('/'), b'owned-detached-response')
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_custody_child.py'), 'move-session'])
            self.assertEqual(process.line(3), 'ready')
            before = process.members()[1:]
            process.process.stdin.write(b'x');process.process.stdin.flush()
            self.assertEqual(process.line(3), 'moved')
            after = process.members()[1:]
            self.assertEqual(before[0][:3], after[0][:3])
            self.assertNotEqual(before[0][4], after[0][4])

    def test_foreign_listener_handover_queued_and_fast_close_sends_no_http(self):
        for behavior in ('wait', 'queued', 'fast-close'):
            with self.subTest(behavior=behavior), self.private_run() as run:
                process, port = self.node_server(run)
                real_connect = socket.socket.connect
                outsider = []
                attempts = []
                def handover(conn, address):
                    attempts.append(address)
                    self.assertEqual(self.command(process, 'close'), 'closed')
                    child = subprocess.Popen([sys.executable, '-I', '-S', '-B',
                        str(HERE / 'fixtures/owned_custody_child.py'), 'foreign', str(port), behavior],
                        env=run.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    outsider.append(child)
                    with owned.selectors.DefaultSelector() as selector:
                        selector.register(child.stdout, owned.selectors.EVENT_READ)
                        self.assertTrue(selector.select(3))
                    self.assertEqual(child.stdout.readline(), b'ready\n')
                    return real_connect(conn, address)
                try:
                    with mock.patch.object(socket.socket, 'connect', handover):
                        with self.assertRaises(owned.Hold):
                            owned.Endpoint(process, port).get('/', seconds=0.3)
                    self.assertEqual(attempts, [('127.0.0.1', port)])
                    stdout, stderr = outsider[0].communicate(timeout=3)
                    self.assertEqual(outsider[0].returncode, 0, stderr)
                    self.assertEqual(stdout, b'received:0\n')
                    self.assertEqual(self.command(process, 'count'), 'count:0')
                finally:
                    for child in outsider:
                        if child.poll() is None:
                            self.terminate_fixture(child)
                        child.stdout.close();child.stderr.close()

    def test_complete_peer_fd_association_rechecked_before_token_grant(self):
        with self.private_run() as run:
            process, port = self.node_server(run)
            ledger = process.ensure_custody()
            listener, _ = ledger.verify_listener(port)
            listener_inode = listener[4]
            real_link = os.readlink
            closed = []
            def lose_accepted(path, *args, **kwargs):
                link = real_link(path, *args, **kwargs)
                if link.startswith('socket:[') and link != 'socket:[' + str(listener_inode) + ']' and not closed:
                    closed.append(link)
                    self.assertEqual(self.command(process, 'close-accepted'), 'closed-accepted')
                return link
            with mock.patch.object(os, 'readlink', lose_accepted):
                with self.assertRaises(owned.Hold):
                    owned.Endpoint(process, port).get('/')
            self.assertTrue(closed)
            self.assertEqual(self.command(process, 'count'), 'count:0')

    def test_pidfd_substitution_cannot_use_matching_numeric_claim(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B', str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
            self.assertEqual(process.line(3), 'ready')
            foreign = subprocess.Popen(['/bin/sleep', '2'], env=run.env)
            foreign_fd = os.pidfd_open(foreign.pid)
            ledger = process.ensure_custody()
            real_open = os.pidfd_open
            try:
                with mock.patch.object(os, 'pidfd_open', side_effect=lambda pid, flags=0: os.dup(foreign_fd)
                                       if pid != process.proof[0] else real_open(pid, flags)):
                    with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_PIDFD_SUBSTITUTED'):
                        ledger.refresh()
                self.assertIsNone(foreign.poll())
            finally:
                # Discard only the injected borrowed duplicate; never signal foreign.
                for cap in list(ledger._provisional.values()):
                    ledger._close_cap(cap)
                os.close(foreign_fd)
                self.terminate_fixture(foreign)

    def test_matching_foreign_pidfd_claim_still_needs_owned_ancestry_edge(self):
        with self.private_run() as run:
            process, _ = self.node_server(run)
            ledger = process.ensure_custody()
            foreign = subprocess.Popen(['/bin/sleep', '3'], env=run.env)
            try:
                # Deliberate numeric-hint injection: kernel fdinfo really matches
                # the claimed foreign PID, but no bound guardian edge admits it.
                with ledger.budget.operation():
                    cap = ledger._open_cap(foreign.pid)
                self.assertEqual(cap.proof[0], foreign.pid)
                with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_ANCESTRY_UNKNOWN'):
                    ledger.refresh()
                self.assertNotIn(foreign.pid, ledger._caps)
                self.assertIsNone(foreign.poll())
            finally:
                for cap in list(ledger._provisional.values()):
                    ledger._close_cap(cap)
                self.terminate_fixture(foreign)

    def test_nested_thread_identities_share_one_global_census_cap(self):
        with self.private_run() as run:
            process = run.spawn([NODE, str(HERE / 'fixtures/owned_detached_child.mjs'), 'nested-hold'])
            process.line(5)
            ledger = process.ensure_custody()
            process.members()
            original = ledger.budget.identities
            try:
                ledger.budget.identities = 10
                with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_IDENTITY_BOUND'):
                    ledger.refresh()
            finally:
                ledger.budget.identities = original

    def test_same_connected_socket_is_leased_until_owned_response_close(self):
        with self.private_run() as run:
            process, port = self.node_server(run)
            ledger = process.ensure_custody()
            with ledger.connect_owned(port, time.monotonic() + 2) as conn:
                saved = conn.fileno()
                with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_CONNECTION_ACTIVE'):
                    ledger.close()
                with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_CONNECTION_ACTIVE'):
                    ledger.refresh()
                conn.sendall(b'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')
                wire = b''
                while True:
                    block = conn.recv(8192)
                    if not block:
                        break
                    wire += block
                    self.assertLess(len(wire), 8192)
                self.assertEqual(conn.fileno(), saved)
                self.assertIn(b'owned-detached-response', wire)
            self.assertEqual(conn.fileno(), -1)

    def test_failed_teardown_is_hold_without_signalling_substituted_proof(self):
        with self.private_run() as run:
            process, _ = self.node_server(run)
            original = process.proof
            try:
                process.proof = (original[0], original[1] + 1, *original[2:])
                with mock.patch.object(signal, 'pidfd_send_signal', side_effect=AssertionError('must not signal')):
                    receipt = json.loads(json.dumps(run.finish()))
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertFalse(receipt['teardownVerified'])
                self.assertTrue(receipt['privateRootRetained'])
            finally:
                process.proof = original

    def test_actual_rapid_exit_sampling_and_output_bound(self):
        with self.private_run() as run:
            process = run.spawn(['/bin/bash', '-c',
                'for ((i=0;i<30;i++)); do /bin/true | /bin/true; done'])
            try:
                process.wait(4)
            except owned.Hold as error:
                self.fail('rapid-exit first bounded reason: ' + json.dumps(process.uncertainty))
            self.assertTrue(process.stopped)
        with self.private_run() as run:
            process = owned.OwnedProcess([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_acceptance_child.py'), 'flood'], run.ws, run.env,
                maximum=1024, on_spawn=run.processes.append, supervisor='owned-subreaper',
                custody_budget=run.custody_budget)
            with self.assertRaisesRegex(owned.Hold, 'COMMAND_OUTPUT_BOUND'):
                process.wait(3)

    def test_live_uid_and_retained_ancestry_birth_changes_are_refused(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B', str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
            self.assertEqual(process.line(3), 'ready')
            ledger = process.ensure_custody()
            process.members()
            child = next(cap for cap in ledger._caps.values() if cap.pid != process.proof[0])
            real_stat, real_read = os.fstat, os.read
            def foreign_uid(fd):
                observed = real_stat(fd)
                if fd == child.procfd:
                    values = list(observed);values[4] = os.getuid() + 1
                    return os.stat_result(values)
                return observed
            with mock.patch.object(os, 'fstat', foreign_uid):
                with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_UID_CHANGED'):
                    ledger.refresh()
            def reused_birth(fd, size):
                raw = real_read(fd, size)
                if raw and os.readlink('/proc/self/fd/' + str(fd)) == '/proc/' + str(child.pid) + '/stat':
                    head, tail = raw.rsplit(b')', 1);fields = tail.split()
                    fields[19] = str(int(fields[19]) + 1).encode()
                    return head + b') ' + b' '.join(fields)
                return raw
            with mock.patch.object(os, 'read', reused_birth):
                with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_BIRTH_CHANGED'):
                    ledger.refresh()

    def test_fdinfo_malformed_missing_or_namespace_metadata_fails_closed(self):
        with self.private_run() as run:
            process = run.spawn(['/bin/sleep', '2'])
            ledger = process.ensure_custody()
            real_read = os.read
            for payload in (b'Pid: 1\n', b'Pid: 1\nPid: 1\nNSpid: 1\n',
                            b'Pid: 1\nNSpid: 1 2\n', b'Pid: 0\nNSpid: 0\n'):
                def corrupt(fd, size):
                    if '/fdinfo/' in os.readlink('/proc/self/fd/' + str(fd)):
                        return payload if size > 1024 else b''
                    return real_read(fd, size)
                with self.subTest(payload=payload), mock.patch.object(os, 'read', corrupt):
                    with self.assertRaises(custody.CustodyError):
                        ledger.refresh()

    def test_terminal_snapshot_cannot_revive_or_retire_nonready_capability(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
            self.assertEqual(process.line(3), 'ready')
            ledger = process.ensure_custody()
            process.members()
            child = next(cap for cap in ledger._caps.values() if cap.pid != process.proof[0])
            self.assertFalse(select.select([child.pidfd], [], [], 0)[0])

            with ledger.budget.operation():
                live = ledger._stat(child)
                terminal = (live[0], -1, -1, 'Z')
                # Deterministic contradictory snapshots; no real PID reuse claim.
                with mock.patch.object(ledger, '_stat', side_effect=[terminal, live]):
                    with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_PROC_INVALID'):
                        ledger._validate(child)
                real_stat = os.fstat
                def ghost_owner(fd):
                    observed = real_stat(fd)
                    if fd == child.procfd:
                        values = list(observed);values[4] = 0
                        return os.stat_result(values)
                    return observed
                with mock.patch.object(ledger, '_stat', return_value=terminal), \
                        mock.patch.object(os, 'fstat', ghost_owner):
                    with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_UID_CHANGED'):
                        ledger._validate(child)
            self.assertIn(child.pid, ledger._caps)
            self.assertFalse(select.select([child.pidfd], [], [], 0)[0])

    def test_actual_cli_binds_supplied_identity_in_real_hold_receipt(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw);parent.chmod(0o700)
            token, authority, artifact = '1' * 64, '2' * 64, '3' * 64
            arguments = ['--mode', 'acceptance', '--platform', 'ubuntu',
                '--supervisor', 'owned-subreaper', '--parent', str(parent),
                '--piweb-artifact', str(parent / 'not-executed.tar.gz'),
                '--piweb-artifact-sha256', artifact, '--run-token', token,
                '--source-authority-sha256', authority]
            def no_install(run, source, path, expected):
                self.assertEqual(run.receipt['runToken'], token)
                self.assertEqual(run.receipt['sourceAuthoritySha256'], authority)
                self.assertEqual(run.receipt['piwebArtifactSha256'], artifact)
                run.ws.guard()
                raise owned.Hold('SYNTHETIC_BEFORE_INSTALL')
            # Only platform/prerequisites and the install boundary are synthetic.
            # Real CLI, source lock, workspace, finish and receipt writer execute.
            with mock.patch.object(owned, 'platform_evidence', return_value={'synthetic': True}), \
                    mock.patch.object(owned, 'prerequisites'), \
                    mock.patch.object(owned, 'acceptance_pipeline', side_effect=no_install), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(owned.main(arguments), 1)
            receipts = list(parent.glob('native-acceptance-*.receipt.json'))
            self.assertEqual(len(receipts), 1)
            receipt = json.loads(receipts[0].read_bytes())
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertEqual(receipt['failure'], 'SYNTHETIC_BEFORE_INSTALL')
            self.assertEqual(receipt['supervisor'], 'owned-subreaper')
            self.assertEqual(receipt['scope'], 'owned-platform-scenario')
            self.assertEqual(receipt['runToken'], token)
            self.assertEqual(receipt['sourceAuthoritySha256'], authority)
            self.assertEqual(receipt['piwebArtifactSha256'], artifact)
            self.assertTrue(receipt['teardownVerified'])
            self.assertTrue(receipt['privateRootRetained'])
            self.assertLess(receipts[0].stat().st_size, 65536)
            for key in ('realUbuntuAcceptance', 'realWSL2Acceptance', 'providerAcceptance', 'rebootAcceptance'):
                self.assertIs(receipt[key], False)

    def test_cli_identity_missing_malformed_or_uppercase_refused_before_workspace(self):
        base = ['--mode', 'acceptance', '--platform', 'ubuntu', '--supervisor', 'owned-subreaper',
                '--parent', '/not-created', '--piweb-artifact', '/not-read']
        flags = ['--piweb-artifact-sha256', '--run-token', '--source-authority-sha256']
        for missing in range(3):
            for bad in (None, '', 'x' * 64, 'A' * 64, '1' * 63, '1' * 65):
                args = list(base)
                for i, flag in enumerate(flags):
                    value = bad if i == missing else '1' * 64
                    if value is not None:
                        args += [flag, value]
                with self.subTest(field=flags[missing], bad=bad), \
                        mock.patch.object(owned.Workspace, 'create', side_effect=AssertionError('must not create')), \
                        contextlib.redirect_stderr(io.StringIO()) as output:
                    self.assertEqual(owned.main(args), 1)
                    self.assertIn('RUN_BINDING_REQUIRED', output.getvalue())

    def test_cli_abbreviated_reserved_options_refused_before_source_or_workspace(self):
        for option in ('--superv', '--run-tok', '--source-authority-sha'):
            args = ['--mode', 'source-plan', '--platform', 'ubuntu', option, '1' * 64]
            with self.subTest(option=option), \
                    mock.patch.object(owned, 'verify_source', side_effect=AssertionError('must not read')), \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    owned.main(args)
                self.assertEqual(error.exception.code, 2)

    def test_global_identity_descriptor_read_deadline_and_permission_bounds(self):
        with self.private_run() as run:
            process = run.spawn(['/bin/sleep', '2'])
            ledger = process.ensure_custody()
            for field, value, expected in [('identities', 1, 'IDENTITY_BOUND'),
                    ('descriptors', ledger.budget.fds, 'DESCRIPTOR_BOUND'),
                    ('read_limit', 1, 'READ_BOUND')]:
                previous = getattr(ledger.budget, field)
                try:
                    setattr(ledger.budget, field, value)
                    with self.assertRaisesRegex(custody.CustodyError, expected):
                        ledger.refresh()
                finally:
                    setattr(ledger.budget, field, previous)
            for number in (errno.EACCES, errno.EPERM, errno.EIO):
                real_open = os.open
                def denied(path, flags, **kwargs):
                    if str(path).startswith('fdinfo/'):
                        raise OSError(number, 'PRIVATE-DO-NOT-EXPORT')
                    return real_open(path, flags, **kwargs)
                with self.subTest(errno=number), mock.patch.object(os, 'open', denied):
                    with self.assertRaises(custody.CustodyError) as error:
                        ledger.refresh()
                    self.assertEqual(error.exception.errno, number)
                    self.assertNotIn('PRIVATE', str(error.exception))
            with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_DEADLINE'):
                custody.OwnedDescendants(process.proof, budget=custody.Budget(time.monotonic() - 1))
            with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_ANCHOR_INVALID'):
                custody.OwnedDescendants((0, 1, os.getuid(), 1, 1))

    def test_nonready_terminal_leader_retained_until_last_thread_exit(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_custody_child.py'), 'terminal-leader'])
            pid = int(process.line(3))
            # The leader's namespace links can disappear while another thread
            # remains. This unknown live process must HOLD, never look empty:
            # the bounded PF_EXITING wait on the same PIDfd expires unconfirmed.
            with self.assertRaises(owned.Hold) as held:
                process.members()
            self.assertEqual(str(held.exception), 'CUSTODY_EXIT_UNCONFIRMED')
            cap = process.custody._caps.get(pid) or process.custody._provisional[pid]
            self.assertFalse(select.select([cap.pidfd], [], [], 0)[0])
            with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_LIVE_CLOSE'):
                process.custody.close()
            self.assertTrue(select.select([cap.pidfd], [], [], 3)[0])
            self.assertIsNone(process.process.poll())  # Sticky HOLD retains the guardian.

    def test_parent_death_guardian_cleans_owned_stubborn_descendants(self):
        self.parent_death_case('parent-death')

    def test_parent_death_after_work_expiry_still_cleans_stubborn_tree(self):
        self.parent_death_case('parent-death-expiry')

    def parent_death_case(self, mode):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw);parent.chmod(0o700)
            libc = ctypes.CDLL(None)
            previous = ctypes.c_int()
            self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
            self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
            try:
                child = subprocess.Popen([sys.executable, '-I', '-S', '-B',
                    str(HERE / 'fixtures/owned_custody_child.py'), mode, str(parent)],
                    env={'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                stdout, stderr = child.communicate(timeout=6)
                self.assertEqual(child.returncode, 0, stderr)
                proof = json.loads(stdout)
                if mode == 'parent-death-expiry':
                    self.assertIs(proof['parentExitAfterExpiry'], True)
                cutoff = time.monotonic() + 3
                while True:
                    got, _ = os.waitpid(proof['guardian'][0], os.WNOHANG)
                    if got:
                        break
                    self.assertLess(time.monotonic(), cutoff)
                    time.sleep(0.01)
                self.assertIsNone(owned.identity(proof['guardian'][0]))
                for p in proof['children']:
                    self.assertIsNone(owned.identity(p[0]))
            finally:
                libc.prctl(36, previous.value, 0, 0, 0)

    def test_open_pipe_adopted_child_prevents_false_empty_then_cleans(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_acceptance_child.py'), 'doublefork'])
            pid = int(process.line(3))
            self.assertIn(pid, [p[0] for p in process.members()])
            with self.assertRaisesRegex(owned.Hold, 'COMMAND_DEADLINE'):
                process.wait(0.03)
            process.stop()
            self.assertTrue(process.stopped)
            self.assertEqual(run.custody_budget.fds, 0)

    def test_known_work_expiry_still_allows_verified_stop_and_preserves_hold(self):
        with self.private_run(seconds=0.35) as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
            self.assertEqual(process.line(3), 'ready')
            time.sleep(max(0, run.deadline - time.monotonic()) + 0.04)
            process.stop()
            self.assertTrue(process.stopped)
            receipt = run.finish()
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertEqual(receipt['failure'], 'COMMAND_DEADLINE')
            self.assertTrue(receipt['teardownVerified'])
            self.assertTrue(receipt['privateRootRetained'])
            self.assertEqual(run.custody_budget.fds, 0)

    def test_departing_candidate_invalidates_snapshot_and_captures_new_adoptee(self):
        libc = ctypes.CDLL(None)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        child = subprocess.Popen([sys.executable, '-I', '-S', '-B',
            str(HERE / 'fixtures/owned_custody_child.py'), 'adoption-barrier'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
        adopted_fd = None
        try:
            self.assertTrue(select.select([child.stdout], [], [], 2)[0])
            self.assertEqual(child.stdout.readline(), b'ready\n')
            original_open = ledger._open_cap
            barrier = []
            def depart_at_open(pid, **kwargs):
                nonlocal adopted_fd
                if pid == child.pid and not barrier:
                    child.stdin.write(b'fork\n');child.stdin.flush()
                    self.assertTrue(select.select([child.stdout], [], [], 2)[0])
                    line = child.stdout.readline().decode()
                    self.assertTrue(line.startswith('adopted:'))
                    adopted = int(line.split(':')[1])
                    adopted_fd = os.pidfd_open(adopted)
                    self.assertEqual(child.wait(timeout=2), 0)
                    barrier.append(adopted)
                return original_open(pid, **kwargs)
            with mock.patch.object(ledger, '_open_cap', side_effect=depart_at_open):
                proofs = ledger.refresh()
            self.assertEqual(len(barrier), 1)
            self.assertIn(barrier[0], [p[0] for p in proofs])
            self.assertFalse(ledger.empty)
        finally:
            if child.poll() is None:
                self.terminate_fixture(child)
            if adopted_fd is not None:
                signal.pidfd_send_signal(adopted_fd, signal.SIGTERM)
                self.assertTrue(select.select([adopted_fd], [], [], 2)[0])
                os.waitpid(barrier[0], 0)
                os.close(adopted_fd)
            ledger.refresh()
            ledger.close()
            for stream in (child.stdin, child.stdout, child.stderr):stream.close()
            libc.prctl(36, previous.value, 0, 0, 0)

    def test_missing_live_anchor_children_is_hold_and_cannot_delete_root(self):
        for number in (errno.ENOENT, errno.ESRCH):
            with self.subTest(errno=number), self.private_run() as run:
                process = run.spawn([sys.executable, '-I', '-S', '-B',
                    str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
                self.assertEqual(process.line(3), 'ready')
                ledger = process.ensure_custody()
                real_read = ledger._read
                def missing(directory, path, maximum=8192):
                    if path == str(process.proof[0]) + '/children':
                        raise OSError(number, 'private')
                    return real_read(directory, path, maximum)
                self.assertFalse(select.select([ledger.anchor.pidfd], [], [], 0)[0])
                with mock.patch.object(ledger, '_read', side_effect=missing):
                    with self.assertRaises(owned.Hold):
                        process.members()
                receipt = run.finish(owned.Hold('MISSING_REQUIRED_CHILDREN'))
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertFalse(receipt['teardownVerified'])
                self.assertTrue(receipt['privateRootRetained'])
                self.assertNotIn(b'"treeEmpty":true', process.buffers['control'])

    def test_signal_esrch_requires_same_held_pidfd_departure(self):
        for departed, number in ((True, errno.ESRCH), (False, errno.ESRCH),
                                 (False, errno.EACCES), (False, errno.EIO)):
            with self.subTest(departed=departed, errno=number):
                child = subprocess.Popen(['/bin/sleep', '4'])
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 3)
                ledger.refresh()
                cap = ledger._caps[child.pid]
                real_signal = signal.pidfd_send_signal
                def exit_at_signal(fd, sig):
                    self.assertEqual(fd, cap.pidfd)
                    if departed:
                        real_signal(fd, signal.SIGTERM)
                        child.wait(timeout=2)
                    raise OSError(number, 'private')
                try:
                    with mock.patch.object(signal, 'pidfd_send_signal', side_effect=exit_at_signal):
                        if departed:
                            ledger.signal_owned(signal.SIGTERM)
                            self.assertTrue(ledger.empty)
                        else:
                            with self.assertRaises(custody.CustodyError) as error:
                                ledger.signal_owned(signal.SIGTERM)
                            self.assertEqual(error.exception.errno, number)
                            self.assertIsNone(child.poll())
                finally:
                    self.terminate_fixture(child)
                    ledger.refresh()
                    ledger.close()

    def test_hup_only_pidfd_readiness_requires_consistent_dead_metadata(self):
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 3)
        try:
            for flags in (select.POLLHUP, select.POLLIN | select.POLLHUP, select.POLLERR,
                          select.POLLHUP | select.POLLERR, select.POLLNVAL, 0):
                fake = mock.Mock()
                fake.poll.return_value = [(ledger.anchor.pidfd, flags)]
                with ledger.budget.operation(), mock.patch.object(select, 'poll', return_value=fake), \
                        mock.patch.object(ledger, '_read', return_value='Pid: -1\nNSpid: -1\n'):
                    if flags in (select.POLLHUP, select.POLLIN | select.POLLHUP):
                        self.assertTrue(ledger._fdinfo(ledger.anchor))
                    else:
                        with self.assertRaises(custody.CustodyError):
                            ledger._fdinfo(ledger.anchor)
            fake = mock.Mock()
            fake.poll.return_value = [(ledger.anchor.pidfd, select.POLLHUP)]
            for text in ('Pid: -1\nNSpid: 1\n', 'Pid: 1\nNSpid: -1\n'):
                with ledger.budget.operation(), mock.patch.object(select, 'poll', return_value=fake), \
                        mock.patch.object(ledger, '_read', return_value=text):
                    with self.assertRaises(custody.CustodyError):ledger._fdinfo(ledger.anchor)
        finally:
            ledger.close()

    def test_global_timeout_cleans_stubborn_child_and_keeps_failure_hold(self):
        with self.private_run(seconds=0.4) as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_acceptance_child.py'), 'stubborn'])
            process.line(3)
            with self.assertRaisesRegex(owned.Hold, 'COMMAND_DEADLINE') as error:
                process.wait(2)
            receipt = run.finish(error.exception)
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertTrue(receipt['teardownVerified'])
            self.assertTrue(receipt['privateRootRetained'])
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertIn({'commandExit': -signal.SIGKILL}, records)
            self.assertLessEqual(process.lifetime.teardown_deadline, run.deadline + 3)
            self.assertEqual(run.custody_budget.fds, 0)

    def test_repeated_stop_signals_do_not_postpone_guardian_escalation(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_acceptance_child.py'), 'stubborn'])
            process.line(3)
            ledger = process.ensure_custody()
            cutoff = ledger.begin_teardown()
            started = time.monotonic()
            while process.process.poll() is None and time.monotonic() - started < 1:
                try:
                    ledger.signal_anchor(signal.SIGTERM)
                except custody.CustodyError as error:
                    if error.custody_code != 'CUSTODY_ANCHOR_GONE' or process.process.poll() is None:
                        raise
                self.assertEqual(ledger.begin_teardown(), cutoff)
                time.sleep(0.025)
            self.assertIsNotNone(process.process.poll())
            process.stop()
            self.assertTrue(process.stopped)
            records = [json.loads(line) for line in process.buffers['control'].splitlines()]
            self.assertIn({'commandExit': -signal.SIGKILL}, records)

    def test_completed_tree_cleanup_does_not_shorten_shared_future_work(self):
        with self.private_run(seconds=5) as run:
            first = run.spawn(['/bin/true'])
            first.wait(1)
            first.stop()
            first_cutoff = first.lifetime.teardown_deadline
            time.sleep(max(0, first_cutoff - time.monotonic()) + 0.03)
            self.assertEqual(run.custody_budget.deadline, run.deadline)
            second = run.spawn(['/bin/true'])
            second.wait(1)
            second.stop()
            self.assertIsNone(first.uncertainty)
            self.assertIsNone(second.uncertainty)
            self.assertNotEqual(first.lifetime.teardown_deadline, second.lifetime.teardown_deadline)
            self.assertEqual(run.custody_budget.fds, 0)

    def test_cleanup_nonrenewal_and_sticky_ownership_errors_never_grant_work(self):
        for code in ('CUSTODY_PIDFD_SUBSTITUTED', 'CUSTODY_UID_CHANGED', 'CUSTODY_IO_ERROR'):
            with self.subTest(code=code), self.private_run() as run:
                process = run.spawn([sys.executable, '-I', '-S', '-B',
                    str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
                process.line(3)
                ledger = process.ensure_custody()
                with mock.patch.object(ledger, '_guard', side_effect=custody.CustodyError(code, errno.EACCES)):
                    with self.assertRaises(owned.Hold):process.members()
                with mock.patch.object(signal, 'pidfd_send_signal', side_effect=AssertionError('unknown custody must not signal')):
                    with self.assertRaises(owned.Hold):process.stop(0.05)
                    cutoff = process.lifetime.teardown_deadline
                    time.sleep(0.07)
                    with self.assertRaises(owned.Hold):process.stop(3)
                self.assertEqual(process.lifetime.teardown_deadline, cutoff)
                self.assertEqual(process.uncertainty, {'uncertain': code, 'errno': errno.EACCES})
                with mock.patch.object(socket.socket, 'connect', side_effect=AssertionError('no endpoint in cleanup')):
                    with self.assertRaisesRegex(owned.Hold, 'CUSTODY_STOPPING'):
                        owned.Endpoint(process, 18000).get('/')
                receipt = run.finish()
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertFalse(receipt['teardownVerified'])
                self.assertTrue(receipt['privateRootRetained'])

    def test_expired_work_cannot_launch_or_issue_request_even_in_cleanup(self):
        with self.private_run(seconds=0.7) as run:
            process, port = self.node_server(run)
            time.sleep(max(0, run.deadline - time.monotonic()) + 0.02)
            with mock.patch.object(subprocess, 'Popen', side_effect=AssertionError('no launch')):
                with self.assertRaises(owned.Hold):run.spawn(['/bin/true'])
                with self.assertRaises(owned.Hold):
                    owned.OwnedProcess(['/bin/true'], run.ws, run.env, custody_budget=run.custody_budget)
            with mock.patch.object(socket.socket, 'connect', side_effect=AssertionError('no connection')):
                with self.assertRaises(owned.Hold):owned.Endpoint(process, port).get('/')
            process.stop()

    def test_departing_nonanchor_thread_requires_complete_fresh_census(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B',
                str(HERE / 'fixtures/owned_custody_child.py'), 'thread-exit-barrier'])
            tid = int(process.line(3).split(':')[1])
            ledger = process.ensure_custody()
            real_read, real_entries = ledger._read, ledger._entries
            disappeared, scans = [], []
            def leave_at_read(directory, relative, maximum=8192):
                if relative == str(tid) + '/children' and not disappeared:
                    process.process.stdin.write(b'x');process.process.stdin.flush()
                    self.assertEqual(process.line(3), 'thread-gone')
                    disappeared.append(True)
                return real_read(directory, relative, maximum)
            def count_scan(fd):
                if os.readlink('/proc/self/fd/' + str(fd)).endswith('/task'):
                    scans.append(os.readlink('/proc/self/fd/' + str(fd)))
                yield from real_entries(fd)
            with mock.patch.object(ledger, '_read', side_effect=leave_at_read), \
                    mock.patch.object(ledger, '_entries', side_effect=count_scan):
                proofs = ledger.refresh()
            self.assertTrue(disappeared)
            child_pid = next(p[0] for p in proofs if p[0] != process.proof[0])
            self.assertGreaterEqual(scans.count('/proc/' + str(child_pid) + '/task'), 2)

    def test_anchor_signal_esrch_departure_still_requires_final_empty_proof(self):
        for departed in (True, False):
            child = subprocess.Popen(['/bin/sleep', '4'], start_new_session=True)
            ledger = custody.OwnedDescendants(owned.identity(child.pid), deadline=time.monotonic() + 3)
            real_signal = signal.pidfd_send_signal
            def at_signal(fd, sig):
                self.assertEqual(fd, ledger.anchor.pidfd)
                if departed:
                    real_signal(fd, signal.SIGTERM)
                    child.wait(timeout=2)
                raise ProcessLookupError(errno.ESRCH, 'private')
            try:
                with mock.patch.object(signal, 'pidfd_send_signal', side_effect=at_signal):
                    if departed:
                        ledger.signal_anchor(signal.SIGTERM)
                        with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_ANCHOR_GONE'):
                            ledger.refresh()
                    else:
                        with self.assertRaises(custody.CustodyError):ledger.signal_anchor(signal.SIGTERM)
                        self.assertIsNone(child.poll())
            finally:
                self.terminate_fixture(child)
                ledger.close()

    def test_known_expiry_control_cannot_clear_or_replace_sticky_uncertainty(self):
        process = owned.OwnedProcess.__new__(owned.OwnedProcess)
        process.buffers = {'control': bytearray(b'{"workExpired":true}\n')}
        process.uncertainty, process.work_expired = None, False
        process.check_control()
        self.assertTrue(process.work_expired)
        self.assertIsNone(process.uncertainty)
        process.buffers['control'].extend(b'{"uncertain":"CUSTODY_UID_CHANGED"}\n')
        with self.assertRaisesRegex(owned.Hold, 'CHILD_TREE_UNCERTAIN'):process.check_control()
        self.assertEqual(process.uncertainty, {'uncertain': 'CUSTODY_UID_CHANGED'})
        for payload in (b'{"workExpired":1}\n', b'{"workExpired":false}\n',
                        b'{"workExpired":true,"extra":1}\n'):
            process.buffers['control'] = bytearray(payload)
            with self.assertRaisesRegex(owned.Hold, 'CONTROL_INVALID'):process.check_control()

    def signal_guardian(self, mode):
        original = owned.subprocess.Popen
        def launch(argv, **kwargs):
            argv = list(argv)
            self.assertEqual(Path(argv[4]).name, 'owned_acceptance_supervisor.py')
            self.assertEqual(argv[1:4], ['-I', '-S', '-B'])
            argv[4:5] = [str(HERE / 'fixtures/owned_custody_signal_guardian.py'), mode]
            return original(argv, **kwargs)
        return mock.patch.object(owned.subprocess, 'Popen', side_effect=launch)

    def fixture_label(self, process, expected, observed):
        for _ in range(8):
            line = process.line(2)
            observed.append(line)
            if line == expected:return
        self.fail('bounded fixture label not received: ' + expected)

    def fixture_events(self, process, observed, label):
        lines = observed + bytes(process.buffers['out']).decode('ascii').splitlines()
        return [json.loads(line[len(label) + 1:]) for line in lines if line.startswith(label + ':')]

    def test_launch_gate_does_not_inherit_blocked_stop_signals(self):
        with self.private_run() as run:
            process = run.spawn([sys.executable, '-I', '-S', '-B', '-c',
                'import signal; blocked=signal.pthread_sigmask(signal.SIG_BLOCK, []); '
                'print("unblocked" if not blocked & {signal.SIGTERM, signal.SIGINT} '
                'else "blocked", flush=True); input()'])
            self.assertEqual(process.line(3), 'unblocked')
            process.process.stdin.write(b'x\n');process.process.stdin.flush()
            process.wait(2)
            self.assertTrue(run.finish()['teardownVerified'])

    def test_active_teardown_keeps_work_refusal_explicit_cutoffs_and_counters(self):
        budget = custody.Budget(10)
        lifetime = custody.TreeLifetime(10)
        with mock.patch.object(custody.time, 'monotonic', return_value=9):
            with budget.operation(lifetime=lifetime):
                budget.identity(('fixture', 1))
                budget.bytes = 17
                cutoff = lifetime.begin_teardown(requested_at=9)
                self.assertEqual(cutoff, 12)
                with mock.patch.object(custody.time, 'monotonic', return_value=10.1):
                    budget.check()
                    self.assertEqual((budget.bytes, budget.seen), (17, {('fixture', 1)}))
                    with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_STOPPING'):
                        with budget.operation(lifetime=lifetime, work=True):pass
                    with self.assertRaises(custody.CustodyError):
                        with budget.operation(10, lifetime=lifetime):pass
                    self.assertEqual(lifetime.begin_teardown(), cutoff)
                    budget.check()
                    self.assertEqual((budget.depth, budget.bytes), (1, 17))
                with mock.patch.object(custody.time, 'monotonic', return_value=12):
                    with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_TEARDOWN_DEADLINE'):
                        budget.check()

    def test_signal_before_custody_assignment_refuses_launch_and_closes_resources(self):
        libc = ctypes.CDLL(None)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        try:
            for mode in ('loader', 'constructor'):
                with self.subTest(mode=mode), self.private_run(seconds=3) as run:
                    with self.signal_guardian(mode):
                        process = run.spawn([sys.executable, '-I', '-S', '-B', '-c',
                            'import time; time.sleep(0.15)'])
                    observed = []
                    try:
                        self.fixture_label(process, 'fixture-barrier:' + mode, observed)
                        process.ensure_custody().signal_anchor(signal.SIGTERM)
                        self.fixture_label(process, 'fixture-stop-latched', observed)
                        process.process.stdin.write(b'x');process.process.stdin.flush()
                        with self.assertRaises(owned.Hold) as failure:process.wait(2)
                        spawns = self.fixture_events(process, observed, 'fixture-spawn')
                        self.assertEqual(spawns, [], 'stopped initialization must not launch a target')
                        if mode == 'constructor':
                            closed = self.fixture_events(process, observed, 'fixture-custody-closed')
                            self.assertEqual(closed, [{'descriptors': 0}])
                        receipt = run.finish(failure.exception)
                        self.assertEqual(receipt['status'], 'HOLD')
                        self.assertTrue(receipt['teardownVerified'])
                    finally:
                        # The old RED launches a short private child then exits.
                        # Reap only those exact, fixture-reported child IDs after
                        # their guardian exit; no scan, numeric signal or retry.
                        if process.process.poll() is not None:
                            for item in self.fixture_events(process, observed, 'fixture-spawn'):
                                cutoff = time.monotonic() + 2
                                while True:
                                    try:pid, _ = os.waitpid(item['pid'], os.WNOHANG)
                                    except ChildProcessError:break
                                    if pid:break
                                    self.assertLess(time.monotonic(), cutoff)
                                    time.sleep(0.01)
        finally:
            libc.prctl(36, previous.value, 0, 0, 0)

    def test_stop_during_active_census_crosses_work_cutoff_without_reset(self):
        with self.private_run(seconds=1.2) as run:
            with self.signal_guardian('active'):
                process = run.spawn([sys.executable, '-I', '-S', '-B',
                    str(HERE / 'fixtures/owned_acceptance_child.py'), 'stubborn'])
            observed = []
            self.fixture_label(process, 'fixture-barrier:active', observed)
            time.sleep(max(0, run.deadline - 0.2 - time.monotonic()))
            process.ensure_custody().signal_anchor(signal.SIGTERM)
            self.fixture_label(process, 'fixture-stop-latched', observed)
            time.sleep(max(0, run.deadline - time.monotonic()) + 0.03)
            process.process.stdin.write(b'x');process.process.stdin.flush()
            cutoff = time.monotonic() + 1
            while not self.fixture_events(process, observed, 'fixture-budget-resumed'):
                self.assertLess(time.monotonic(), cutoff)
                process.pump(0.01)
            resumed = self.fixture_events(process, observed, 'fixture-budget-resumed')
            self.assertEqual(len(resumed), 1)
            self.assertEqual(resumed[0]['before'], resumed[0]['after'])
            self.assertGreater(resumed[0]['before'][0], 0)
            self.assertGreater(resumed[0]['effectiveCutoff'], resumed[0]['workCutoff'])
            process.stop()
            self.assertIsNone(process.uncertainty)
            receipt = run.finish()
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertTrue(receipt['teardownVerified'])

    def test_final_return_departure_restarts_census_before_live_anchor_close(self):
        libc = ctypes.CDLL(None)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        command = subprocess.Popen([sys.executable, '-I', '-S', '-B',
            str(HERE / 'fixtures/owned_custody_child.py'), 'late-departure-barrier'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
        worker, worker_fd = None, None
        try:
            self.assertTrue(select.select([command.stdout], [], [], 2)[0])
            worker = int(command.stdout.readline().decode().split(':')[1])
            worker_fd = os.pidfd_open(worker)
            self.assertEqual(command.wait(timeout=2), 0)  # Original command already exited.
            self.assertIn(worker, [p[0] for p in ledger.refresh()])
            original = ledger._fdinfo
            ledger._edges = {}
            departed = []
            def exit_at_final_return(cap):
                if cap.pid == worker and ledger._edges.get(worker) == os.getpid() and not departed:
                    command.stdin.write(b'exit\n');command.stdin.flush()
                    self.assertTrue(select.select([worker_fd], [], [], 2)[0])
                    self.assertEqual(os.waitpid(worker, 0)[0], worker)
                    departed.append(True)
                return original(cap)
            with mock.patch.object(ledger, '_fdinfo', side_effect=exit_at_final_return):
                self.assertEqual([p[0] for p in ledger.refresh()], [os.getpid()])
            self.assertTrue(departed)
            self.assertEqual(len(ledger._caps), 1)
            ledger.close()
        finally:
            if worker_fd is not None:
                if not select.select([worker_fd], [], [], 0)[0]:
                    command.stdin.write(b'exit\n');command.stdin.flush()
                    self.assertTrue(select.select([worker_fd], [], [], 2)[0])
                    os.waitpid(worker, 0)
                os.close(worker_fd)
            if command.poll() is None:self.terminate_fixture(command)
            if not ledger.closed:
                ledger.refresh();ledger.close()
            for stream in (command.stdin, command.stdout, command.stderr):stream.close()
            libc.prctl(36, previous.value, 0, 0, 0)

    def test_namespace_eacces_immediately_ready_candidate_restarts_complete_census(self):
        for relative, outside_census in (('ns/pid', False), ('ns/net', False),
                                         ('ns/pid', True), ('ns/net', True)):
            with self.subTest(namespace=relative, outsideCensus=outside_census):
                child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c',
                    'import sys; print("ready",flush=True); sys.stdin.read(1)'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
                real_link, real_children = os.readlink, ledger._children
                hit, fresh_anchor = [], []
                def children(cap):
                    if hit and cap is ledger.anchor:fresh_anchor.append(cap.pid)
                    return real_children(cap)
                def departed(path, *args, **kwargs):
                    cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
                    if path == relative and cap is not None and kwargs.get('dir_fd') == cap.procfd and not hit:
                        child.stdin.write(b'x');child.stdin.flush()
                        self.assertEqual(child.wait(timeout=2), 0)
                        self.assertTrue(select.select([cap.pidfd], [], [], 0)[0])
                        hit.append(cap.pid)
                        raise PermissionError(errno.EACCES, 'owned namespace fixture')
                    return real_link(path, *args, **kwargs)
                try:
                    self.assertTrue(select.select([child.stdout], [], [], 2)[0])
                    self.assertEqual(child.stdout.readline(), b'ready\n')
                    if outside_census:ledger.refresh()
                    with mock.patch.object(os, 'readlink', side_effect=departed), \
                            mock.patch.object(ledger, '_children', side_effect=children):
                        if outside_census:
                            with ledger._operation():
                                held = ledger._caps[child.pid]
                                self.assertIsNone(ledger._validate(held))
                                # Borrowed validation is nonmutating: no retirement
                                # and no nested census underneath its caller.
                                self.assertIs(ledger._caps[child.pid], held)
                                self.assertIsNotNone(held.pidfd)
                                self.assertFalse(fresh_anchor)
                                # The enclosing transaction completes the fresh
                                # bounded guardian-rooted reproof before any use.
                                proofs = ledger.refresh()
                        else:proofs = ledger.refresh()
                    self.assertEqual(hit, [child.pid])
                    self.assertTrue(fresh_anchor)
                    self.assertEqual(ledger._census_depth, 0)
                    self.assertEqual([p[0] for p in proofs], [os.getpid()])
                    self.assertNotIn(child.pid, ledger._caps)
                    self.assertNotIn(child.pid, ledger._provisional)
                    ledger.close()
                finally:
                    if child.poll() is None:self.terminate_fixture(child)
                    if not ledger.closed:ledger.refresh();ledger.close()
                    for stream in (child.stdin, child.stdout, child.stderr):stream.close()

    def test_namespace_eacces_nonready_stays_sticky_after_later_exit(self):
        with self.private_run() as run:
            with self.signal_guardian('namespace-live'):
                process = run.spawn([sys.executable, '-I', '-S', '-B', '-c',
                    'import sys; print("target-ready",flush=True); sys.stdin.read(1)'])
            with self.assertRaisesRegex(owned.Hold, 'CHILD_TREE_UNCERTAIN'):process.wait(2)
            first = dict(process.uncertainty)
            self.assertEqual(first, {'uncertain': 'CUSTODY_IO_ERROR', 'errno': errno.EACCES})
            with self.assertRaises(owned.Hold):process.pump(0)
            events = self.fixture_events(process, [], 'fixture-namespace-denied')
            self.assertEqual(len(events), 1)
            self.assertFalse(events[0]['ready'])
            fd = os.pidfd_open(events[0]['pid'])
            try:
                process.process.stdin.write(b'x');process.process.stdin.flush()
                self.assertTrue(select.select([fd], [], [], 2)[0])
                with self.assertRaises(owned.Hold):process.pump(0.03)
                self.assertEqual(process.uncertainty, first)
                self.assertNotIn(b'"treeEmpty": true', process.buffers['control'])
                self.assertNotIn(b'"treeEmpty":true', process.buffers['control'])
                receipt = run.finish(owned.Hold('FIXTURE_PERMISSION_HOLD'))
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertFalse(receipt['teardownVerified'])
                self.assertTrue(receipt['privateRootRetained'])
            finally:os.close(fd)

    def test_namespace_rule_refuses_anchor_other_permissions_and_unknown_pidfd(self):
        cases = ('anchor', 'stat', 'fdinfo', 'namespace-eperm', 'namespace-eio', 'bad-pidfd')
        for case in cases:
            with self.subTest(case=case):
                child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c',
                    'import sys; print("ready",flush=True); sys.stdin.read(1)'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
                real_link, real_read, real_fdinfo = os.readlink, ledger._read, ledger._fdinfo
                hit = []
                def exit_child():
                    if child.poll() is None:
                        child.stdin.write(b'x');child.stdin.flush();self.assertEqual(child.wait(timeout=2), 0)
                def fail_link(path, *args, **kwargs):
                    cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
                    target = ledger.anchor if case == 'anchor' else cap
                    if path == 'ns/net' and target is not None and kwargs.get('dir_fd') == target.procfd and not hit \
                            and case not in ('stat', 'fdinfo'):
                        if case != 'anchor':exit_child()
                        hit.append(target.pid)
                        number = errno.EPERM if case == 'namespace-eperm' else errno.EIO if case == 'namespace-eio' else errno.EACCES
                        raise OSError(number, 'owned permission fixture')
                    return real_link(path, *args, **kwargs)
                def fail_read(directory, relative, maximum=8192):
                    cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
                    if cap is not None and cap.procfd is not None and not hit and \
                            ((case == 'stat' and directory == cap.procfd and relative == 'stat') or
                             (case == 'fdinfo' and relative == 'fdinfo/' + str(cap.pidfd))):
                        exit_child();hit.append(cap.pid)
                        raise PermissionError(errno.EACCES, 'owned other read fixture')
                    return real_read(directory, relative, maximum)
                def fdinfo(cap):
                    if case == 'bad-pidfd' and hit and cap.pid == child.pid:
                        raise custody.CustodyError('CUSTODY_PIDFD_SUBSTITUTED')
                    return real_fdinfo(cap)
                try:
                    self.assertTrue(select.select([child.stdout], [], [], 2)[0])
                    self.assertEqual(child.stdout.readline(), b'ready\n')
                    with mock.patch.object(os, 'readlink', side_effect=fail_link), \
                            mock.patch.object(ledger, '_read', side_effect=fail_read), \
                            mock.patch.object(ledger, '_fdinfo', side_effect=fdinfo):
                        with self.assertRaises(custody.CustodyError) as error:ledger.refresh()
                    self.assertEqual(len(hit), 1)
                    if case == 'bad-pidfd':
                        self.assertEqual(error.exception.custody_code, 'CUSTODY_PIDFD_SUBSTITUTED')
                    else:
                        self.assertEqual(error.exception.custody_code, 'CUSTODY_IO_ERROR')
                        self.assertEqual(error.exception.errno, errno.EPERM if case == 'namespace-eperm' else errno.EIO if case == 'namespace-eio' else errno.EACCES)
                finally:
                    if child.poll() is None:self.terminate_fixture(child)
                    ledger.refresh();ledger.close()
                    for stream in (child.stdin, child.stdout, child.stderr):stream.close()

    def test_namespace_departure_after_fork_retains_new_adoptee(self):
        libc = ctypes.CDLL(None)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        child = subprocess.Popen([sys.executable, '-I', '-S', '-B',
            str(HERE / 'fixtures/owned_custody_child.py'), 'adoption-barrier'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        ledger = custody.OwnedDescendants(owned.identity(os.getpid()), deadline=time.monotonic() + 4)
        adopted_fd, adopted = None, None
        real_link = os.readlink
        hit = []
        def depart_namespace(path, *args, **kwargs):
            nonlocal adopted_fd, adopted
            cap = ledger._caps.get(child.pid) or ledger._provisional.get(child.pid)
            if path == 'ns/net' and cap is not None and kwargs.get('dir_fd') == cap.procfd and not hit:
                child.stdin.write(b'fork\n');child.stdin.flush()
                self.assertTrue(select.select([child.stdout], [], [], 2)[0])
                line = child.stdout.readline().decode()
                self.assertTrue(line.startswith('adopted:'))
                adopted = int(line.split(':')[1]);adopted_fd = os.pidfd_open(adopted)
                self.assertEqual(child.wait(timeout=2), 0)
                self.assertTrue(select.select([cap.pidfd], [], [], 0)[0])
                hit.append(cap.pid)
                raise PermissionError(errno.EACCES, 'owned namespace adoption fixture')
            return real_link(path, *args, **kwargs)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 2)[0])
            self.assertEqual(child.stdout.readline(), b'ready\n')
            with mock.patch.object(os, 'readlink', side_effect=depart_namespace):proofs = ledger.refresh()
            self.assertEqual(hit, [child.pid])
            self.assertIn(adopted, [p[0] for p in proofs])
            self.assertNotIn(child.pid, ledger._caps)
            self.assertFalse(ledger.empty)
        finally:
            if child.poll() is None:self.terminate_fixture(child)
            if adopted_fd is not None:
                signal.pidfd_send_signal(adopted_fd, signal.SIGTERM)
                self.assertTrue(select.select([adopted_fd], [], [], 2)[0])
                os.waitpid(adopted, 0);os.close(adopted_fd)
            ledger.refresh();ledger.close()
            for stream in (child.stdin, child.stdout, child.stderr):stream.close()
            libc.prctl(36, previous.value, 0, 0, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
