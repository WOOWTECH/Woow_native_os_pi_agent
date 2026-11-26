"""Pure-mock regressions for the two remaining runtime P2 custody defects."""
import ast
import errno
from pathlib import Path
import textwrap
from types import SimpleNamespace
import itertools
import time
import unittest
from unittest import mock

import owned_process_custody as custody


def empty_ledger():
    ledger = custody.OwnedDescendants.__new__(custody.OwnedDescendants)
    ledger._caps = {}
    ledger._provisional = {}
    ledger._retained = []
    ledger._close_failure = None
    ledger._census_depth = 0
    ledger.anchor_proof = (1, 1, 1, 1, 1)
    ledger.rootfd = 40
    ledger.budget = custody.Budget(time.monotonic() + 30)
    ledger.lifetime = None
    return ledger


class ProvisionalExpiryTests(unittest.TestCase):
    def test_work_cutoff_after_pidfd_registration_retires_before_next_census(self):
        ledger = empty_ledger()
        expiry = custody.CustodyError('CUSTODY_DEADLINE', phase='work')
        with mock.patch.object(custody.os, 'pidfd_open', return_value=41001), \
                mock.patch.object(custody.os, 'close') as close_fd, \
                mock.patch.object(custody.os, 'open', return_value=41002), \
                mock.patch.object(ledger, '_fdinfo', side_effect=[expiry, False]), \
                mock.patch.object(ledger, '_validate', return_value=(123, 4, 5, 'R')):
            with ledger._operation():
                with self.assertRaises(custody.CustodyError) as caught:
                    ledger._open_cap(123)
                self.assertIs(caught.exception, expiry)
                self.assertEqual(ledger._provisional, {})
                self.assertEqual(ledger.budget.pins, {})
                self.assertEqual(ledger.budget.fds, 0)

            # A fresh pass can reacquire the same still-live PID. A stale
            # procfd-less provisional must never turn this into EBADF/IO_ERROR.
            with ledger._operation():
                cap = ledger._open_cap(123)
                self.assertIs(ledger._provisional[123], cap)
                ledger._close_cap(cap)
            self.assertEqual(ledger.budget.fds, 0)
            self.assertEqual(ledger.budget.pins, {})
            self.assertEqual(close_fd.call_count, 3)


class BoundedChurnAccountingTests(unittest.TestCase):
    def test_retired_proved_pid_slots_are_reused_without_raising_the_bound(self):
        ledger = empty_ledger()
        ledger.budget.identities = 128
        # An anchor remains pinned throughout the operation.
        ledger.budget.pins[('pid', 1)] = 1
        pidfds = itertools.count(43000)
        procfds = itertools.count(44000)
        with mock.patch.object(custody.os, 'pidfd_open', side_effect=lambda *_: next(pidfds)), \
                mock.patch.object(custody.os, 'open', side_effect=lambda *_args, **_kwargs: next(procfds)), \
                mock.patch.object(custody.os, 'close'), \
                mock.patch.object(ledger, '_fdinfo', return_value=False), \
                mock.patch.object(ledger, '_validate', return_value=(123, 4, 5, 'R')):
            with ledger._operation():
                for pid in range(2, 202):
                    cap = ledger._open_cap(pid)
                    ledger._close_cap(cap)
                self.assertEqual(ledger.budget.identities, 128)
                self.assertEqual(ledger.budget.seen, {('pid', 1)})
                self.assertEqual(ledger.budget.pins, {('pid', 1): 1})
                self.assertEqual(ledger.budget.fds, 0)
                self.assertEqual(ledger._provisional, {})

    def test_close_failure_keeps_identity_and_descriptor_charges(self):
        ledger = empty_ledger()
        cap = custody._Capability(7, 47007)
        cap.procfd = 47008
        cap.pinned = True
        ledger._provisional[7] = cap
        with mock.patch.object(custody.os, 'close', side_effect=OSError(5, 'mock close failure')):
            with ledger._operation():
                ledger.budget.acquire()
                ledger.budget.acquire()
                ledger.budget.pin(('pid', 7))
                with self.assertRaises(custody.CustodyError) as caught:
                    ledger._close_cap(cap)
                self.assertEqual(caught.exception.custody_code, 'CUSTODY_CLOSE_FAILED')
                self.assertIn(('pid', 7), ledger.budget.seen)
                self.assertEqual(ledger.budget.pins, {('pid', 7): 1})
                self.assertEqual(ledger.budget.fds, 2)
                self.assertEqual(ledger._retained, [(7, 'procfd', 47008), (7, 'pidfd', 47007)])

    def test_reap_records_remain_bounded_without_retaining_dead_identity_slots(self):
        ledger = empty_ledger()
        ledger.budget.identities = 1
        ledger.budget.pins[('pid', 1)] = 1
        with mock.patch.object(custody.os, 'close'):
            with ledger._operation():
                for pid in range(2, 102):
                    ledger.budget.record_reap(pid, 0)
                self.assertEqual(len(ledger.budget.reaps), 100)
                self.assertEqual(ledger.budget.seen, {('pid', 1)})


class AccountingBoundaryTests(unittest.TestCase):
    def test_exit_uncertainty_retains_provisional_handles_and_charges(self):
        ledger = empty_ledger()
        uncertainty = custody.CustodyError('CUSTODY_EXIT_UNCONFIRMED')
        with ledger._operation(), \
                mock.patch.object(custody.os, 'pidfd_open', return_value=51001), \
                mock.patch.object(custody.os, 'open', return_value=51002), \
                mock.patch.object(custody.os, 'close') as close, \
                mock.patch.object(ledger, '_fdinfo', return_value=False), \
                mock.patch.object(ledger, '_validate', side_effect=uncertainty):
            with self.assertRaises(custody.CustodyError) as caught:
                ledger._open_cap(22)
            self.assertIs(caught.exception, uncertainty)
            cap = ledger._provisional[22]
            self.assertEqual((cap.pidfd, cap.procfd), (51001, 51002))
            self.assertEqual(ledger.budget.pins, {('pid', 22): 1})
            self.assertEqual(ledger.budget.fds, 2)
            close.assert_not_called()
            ledger._close_cap(cap)  # Mock-only fixture cleanup.

    def test_identity_bound_diagnostic_contains_counts_only(self):
        from owned_acceptance_supervisor import uncertainty_record
        budget = custody.Budget(time.monotonic() + 30, identities=2)
        with budget.operation():
            budget.pin(('pid', 12345))
            budget.identity(('task', 23456))
            with self.assertRaises(custody.CustodyError) as caught:
                budget.identity(('task', 34567))
            record = uncertainty_record(caught.exception, 'CUSTODY')
            self.assertEqual(record, {'uncertain': 'CUSTODY_IDENTITY_BOUND',
                'identityCounts': {'pid': 1, 'task': 2, 'pinned': 1, 'limit': 2}})
            caught.exception.identity_counts['task'] = 'PRIVATE-DO-NOT-EXPORT'
            self.assertEqual(uncertainty_record(caught.exception, 'CUSTODY'),
                             {'uncertain': 'CUSTODY_IDENTITY_BOUND'})

    def test_cutoff_immediately_after_pidfd_acquisition_closes_or_retains_charge(self):
        for fail_close in (False, True):
            with self.subTest(fail_close=fail_close):
                ledger = empty_ledger()
                def acquired(pid, flags):
                    ledger.budget.deadline = time.monotonic() - 1
                    return 48001
                with mock.patch.object(custody.os, 'pidfd_open', side_effect=acquired), \
                        mock.patch.object(custody.os, 'close', side_effect=(
                            OSError(errno.EIO, 'mock failure') if fail_close else None)), \
                        mock.patch.object(ledger, '_fdinfo', side_effect=lambda cap: ledger.budget.check()):
                    with ledger._operation():
                        with self.assertRaises(custody.CustodyError) as caught:
                            ledger._open_cap(8)
                        self.assertEqual(ledger._provisional, {})
                        if fail_close:
                            self.assertEqual(caught.exception.custody_code, 'CUSTODY_CLOSE_FAILED')
                            self.assertEqual(ledger.budget.pins, {('pid', 8): 1})
                            self.assertIn(('pid', 8), ledger.budget.seen)
                            self.assertEqual(ledger.budget.fds, 1)
                            self.assertEqual(ledger._retained, [(8, 'pidfd', 48001)])
                        else:
                            self.assertEqual(caught.exception.phase, 'work')
                            self.assertEqual(ledger.budget.pins, {})
                            self.assertEqual(ledger.budget.fds, 0)

    def test_positive_reap_is_recorded_before_post_wait_expiry(self):
        budget = custody.Budget(time.monotonic() + 30)
        with budget.operation():
            budget.identity(('pid', 9))
            budget.deadline = time.monotonic() - 1
            with self.assertRaises(custody.CustodyError) as caught:
                budget.record_reap(9, 0)
            self.assertEqual(caught.exception.phase, 'work')
            self.assertEqual(budget.reaps, [(9, 0)])
            self.assertNotIn(('pid', 9), budget.seen)

    def test_reap_recycles_charged_slot_preserves_pin_and_stops_at_128(self):
        budget = custody.Budget(time.monotonic() + 30)
        with budget.operation():
            budget.pin(('pid', 1))
            budget.record_reap(1, 0)
            self.assertIn(('pid', 1), budget.seen)
            self.assertEqual(budget.pins[('pid', 1)], 1)
            for pid in range(2, 129):
                budget.identity(('pid', pid))
                budget.record_reap(pid, 0)
                self.assertNotIn(('pid', pid), budget.seen)
            with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_REAP_BOUND'):
                budget.record_reap(129, 0)
            self.assertEqual(len(budget.reaps), 128)

    def test_two_ledgers_retain_the_shared_pid_charge_until_both_retire(self):
        one, two = empty_ledger(), empty_ledger()
        two.budget = one.budget
        with one._operation(), mock.patch.object(custody.os, 'close'):
            caps = []
            for ledger, fd in ((one, 49001), (two, 49002)):
                cap = custody._Capability(10, fd)
                cap.pinned = True
                ledger._provisional[10] = cap
                ledger.budget.acquire()
                ledger.budget.pin(('pid', 10))
                caps.append(cap)
            one._close_cap(caps[0])
            self.assertEqual(one.budget.pins, {('pid', 10): 1})
            self.assertIn(('pid', 10), one.budget.seen)
            two._close_cap(caps[1])
            self.assertEqual(one.budget.pins, {})
            self.assertNotIn(('pid', 10), one.budget.seen)

    def test_esrch_before_pidfd_releases_only_unpinned_candidate(self):
        ledger = empty_ledger()
        with ledger._operation(), mock.patch.object(custody.os, 'pidfd_open',
                side_effect=ProcessLookupError(errno.ESRCH, 'gone')):
            ledger.budget.pin(('pid', 1))
            self.assertIsNone(ledger._open_cap(11))
            self.assertEqual(ledger.budget.seen, {('pid', 1)})
            self.assertEqual(ledger.budget.pins, {('pid', 1): 1})
            self.assertEqual(ledger.budget.fds, 0)

    def test_task_snapshots_keep_one_aggregate_bound_across_parents(self):
        ledger = empty_ledger()
        cap = custody._Capability(12, 50001)
        cap.procfd = 50002
        with ledger._operation(), \
                mock.patch.object(ledger, '_validate', return_value=(12, 1, 1, 'R')), \
                mock.patch.object(ledger, '_open', return_value=50003), \
                mock.patch.object(ledger, '_close_fd'), \
                mock.patch.object(ledger, '_read', return_value=''), \
                mock.patch.object(ledger, '_entries', side_effect=[
                    [str(i) for i in range(100, 170)],
                    [str(i) for i in range(200, 270)]]):
            self.assertEqual(ledger._live_children(cap), set())
            self.assertEqual(len(ledger.budget.seen), 70)
            with self.assertRaisesRegex(custody.CustodyError, 'CUSTODY_IDENTITY_BOUND'):
                ledger._live_children(cap)


class SupervisorReapBoundaryTests(unittest.TestCase):
    def test_command_exit_survives_post_wait_accounting_expiry(self):
        # Execute the actual nested reaper in a tiny lexical scope, with no
        # supervisor initialization, signals, subprocesses, or real waitpid.
        path = Path(__file__).with_name('owned_acceptance_supervisor.py')
        tree = ast.parse(path.read_text())
        reapers = [node for node in ast.walk(tree)
                   if isinstance(node, ast.FunctionDef) and node.name == 'reap_owned']
        self.assertEqual(len(reapers), 1)
        factory = ('def make_reaper():\n'
                   '    exit_code = None\n'
                   '    reap_epoch = 0\n'
                   '    child = SimpleNamespace(pid=21)\n'
                   + textwrap.indent(ast.unparse(reapers[0]), '    ') + '\n'
                   '    return reap_owned, lambda: (exit_code, reap_epoch)\n')
        fake_os = SimpleNamespace(WNOHANG=1, waitpid=mock.Mock(return_value=(21, 7 << 8)),
                                  waitstatus_to_exitcode=lambda status: status >> 8)
        scope = {'os': fake_os, 'SimpleNamespace': SimpleNamespace}
        exec(compile(factory, str(path), 'exec'), scope)
        reap, result = scope['make_reaper']()
        expiry = custody.CustodyError('CUSTODY_DEADLINE', phase='work')
        budget = SimpleNamespace(check=lambda: None, reaps=[],
                                 record_reap=mock.Mock(side_effect=expiry))
        with self.assertRaises(custody.CustodyError) as caught:
            reap(budget)
        self.assertIs(caught.exception, expiry)
        self.assertEqual(result(), (7, 1))
        fake_os.waitpid.assert_called_once_with(-1, 1 | 0x40000000)
        budget.record_reap.assert_called_once_with(21, 7 << 8)


if __name__ == '__main__':
    unittest.main()
