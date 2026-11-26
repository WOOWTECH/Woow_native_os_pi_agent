#!/usr/bin/env python3
"""Linux-only session leader/subreaper for one owned acceptance command tree.

No SDK imports. Dedicated control pipe is never part of target stdout. Surviving
or escaped descendants keep this guardian alive: the parent must report HOLD.
"""
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

TERMINAL_STATES = frozenset('ZXx')
LIVE_STATES = frozenset('RSDTtKWPI')


def stat_identity(p, pid):
    """One bounded proc stat snapshot; state may change between snapshots."""
    with (p / 'stat').open() as source:
        raw = source.read(8193)
    if len(raw) > 8192:
        raise RuntimeError('PROC_STAT_BOUND')
    fields = raw.rsplit(')', 1)[-1].split()
    if len(fields) < 20 or raw.split(' ', 1)[0] != str(pid):
        raise RuntimeError('PROC_STAT_INVALID')
    return (int(fields[19]), int(fields[2]), int(fields[3]), fields[0])


def identity(pid):
    try:
        p = Path('/proc') / str(pid)
        before = stat_identity(p, pid)
        owner = p.stat().st_uid
        # pid_getattr can expose root ownership after the task disappears.
        # Confirm birth before interpreting a departing task's state/group.
        after = stat_identity(p, pid)
        if before[0] != after[0]:
            raise RuntimeError('PROC_IDENTITY_CHANGED')
        if before[3] not in LIVE_STATES | TERMINAL_STATES or after[3] not in LIVE_STATES | TERMINAL_STATES:
            raise RuntimeError('PROC_STAT_INVALID')
        if before[3] in LIVE_STATES and (before[1] <= 0 or before[2] <= 0):
            raise RuntimeError('PROC_STAT_INVALID')
        if after[3] in TERMINAL_STATES:
            # A same-birth terminal task cannot execute or be safely signalled.
            # Keep its PID in descendants(); reaping/adoption proves treeEmpty.
            return None
        if before[3] in TERMINAL_STATES:
            raise RuntimeError('PROC_IDENTITY_CHANGED')
        if after[1] <= 0 or after[2] <= 0:
            raise RuntimeError('PROC_STAT_INVALID')
        if before[1:3] != after[1:3]:
            raise RuntimeError('PROC_IDENTITY_CHANGED')
        return (pid, after[0], owner, after[1], after[2], after[3])
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ESRCH):
            raise
        return None


def descendants(pid, maximum=128):
    found = []
    todo = [pid]
    while todo:
        current = todo.pop()
        task = Path('/proc') / str(current) / 'task'
        try:
            # Children may have been forked by any thread.
            with os.scandir(task) as entries:
                tasks = []
                for entry in entries:
                    if len(tasks) >= maximum:
                        raise RuntimeError('TASK_BOUND')
                    tasks.append(entry.name)
            for tid in tasks:
                try:
                    with (task / tid / 'children').open() as source:
                        text = source.read(8193)
                except OSError as error:
                    if error.errno not in (errno.ENOENT, errno.ESRCH) or current == pid and tid == str(pid):
                        raise  # The required traversal anchor must be readable.
                    continue
                if len(text) > 8192:
                    raise RuntimeError('CHILD_BOUND')
                for child in map(int, text.split()):
                    if child not in found:
                        found.append(child)
                        todo.append(child)
                        if len(found) > maximum:
                            raise RuntimeError('CHILD_BOUND')
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ESRCH) or current == pid:
                raise
            continue
    return found


def uncertainty_record(error, operation):
    """Fixed codes and bounded errno only; never expose exception text or paths."""
    custody_code = getattr(error, 'custody_code', None)
    if isinstance(custody_code, str) and custody_code.startswith('CUSTODY_') \
            and len(custody_code) <= 64 and all(c == '_' or 'A' <= c <= 'Z' for c in custody_code):
        result = {'uncertain': custody_code}
        counts = getattr(error, 'identity_counts', None)
        if custody_code == 'CUSTODY_IDENTITY_BOUND' and type(counts) is dict \
                and set(counts) == {'pid', 'task', 'pinned', 'unique', 'limit'} \
                and all(type(n) is int and 0 <= n <= 8192 for n in counts.values()):
            result['identityCounts'] = counts.copy()
        number = getattr(error, 'errno', None)
        if type(number) is int and 0 < number <= 4095:
            result['errno'] = number
        return result
    if isinstance(error, OSError):
        number = error.errno
        return {'uncertain': operation + '_ERROR',
                'errno': number if type(number) is int and 0 < number <= 4095 else None}
    known = ('PROC_STAT_BOUND', 'PROC_STAT_INVALID', 'PROC_IDENTITY_CHANGED',
             'TASK_BOUND', 'CHILD_BOUND', 'BIRTH_IDENTITY_CHANGED')
    code = error.args[0] if len(error.args) == 1 and type(error.args[0]) is str else None
    return {'uncertain': code if code in known else operation + '_INVALID'}


def known_work_expiry(error):
    """Classify by the error's own sampled phase, never by lifetime state now."""
    return getattr(error, 'custody_code', None) == 'CUSTODY_DEADLINE' \
        and getattr(error, 'phase', None) == 'work'


def main():
    control = int(sys.argv[1])
    command = sys.argv[2:]
    mode, deadline = 'owned-pgid', None
    if command[:1] == ['--supervisor']:
        mode, deadline = command[1], float(command[3])
        if command[2] != '--deadline' or command[4] != '--' or mode != 'owned-subreaper':
            raise SystemExit(125)
        command = command[5:]
    os.set_inheritable(control, False)
    def emit(data):
        try:
            os.write(control, data)
        except BrokenPipeError:
            pass  # Observer death cannot discard adopted descendants.
    stopped = [None]
    custody = None
    lifetime = None
    work_expired = False
    def request_stop(*_):
        if stopped[0] is None:
            stopped[0] = time.monotonic()
        if lifetime is not None:
            lifetime.begin_teardown(requested_at=stopped[0])
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise SystemExit(125)
    leader = identity(os.getpid())
    parent = os.getppid()
    child = None
    exit_code = None
    reap_epoch = 0
    def reap_owned(budget=None):
        nonlocal exit_code, reap_epoch
        statuses = []
        for _ in range(129):
            if budget is not None:
                budget.check()
                if len(budget.reaps) >= 128:
                    raise RuntimeError('CHILD_BOUND')
            elif len(statuses) >= 128:
                raise RuntimeError('CHILD_BOUND')
            try:
                pid, status = os.waitpid(-1, os.WNOHANG | 0x40000000)  # __WALL: all direct children.
            except ChildProcessError:
                return True  # Kernel proves this guardian has no children.
            if not pid:
                return False
            statuses.append((pid, status))
            reap_epoch += 1
            # waitpid consumed this status permanently. Preserve the command
            # result before accounting can raise on a post-wait deadline.
            if child is not None and pid == child.pid:
                exit_code = os.waitstatus_to_exitcode(status)
            if budget is not None:
                budget.record_reap(pid, status)
        raise RuntimeError('CHILD_BOUND')
    def expire_work():
        nonlocal work_expired
        if not work_expired:
            work_expired = True
            emit(b'{"workExpired":true}\n')
        request_stop()

    def sync_stop():
        if parent <= 1 or os.getppid() != parent:
            request_stop()
        if deadline is not None and time.monotonic() >= deadline \
                and (stopped[0] is None or stopped[0] >= deadline):
            expire_work()
        if lifetime is not None and stopped[0] is not None:
            lifetime.begin_teardown(requested_at=stopped[0])

    def hold_initialization(error):
        emit((json.dumps(uncertainty_record(error, 'OWNED_INIT')) + '\n').encode())
        while True:
            time.sleep(0.05)  # Sticky unknowns retain adoption; never launch.

    def within_cleanup_allowance():
        # Only the remaining one-time cleanup allowance; it is never renewed.
        if lifetime is not None and lifetime.teardown_deadline is not None \
                and time.monotonic() >= lifetime.teardown_deadline:
            raise module.CustodyError('CUSTODY_TEARDOWN_DEADLINE', phase='teardown')

    def finish_without_launch():
        try:
            if custody is not None:
                with custody._operation():
                    if not reap_owned(custody.budget):
                        raise RuntimeError('CHILD_BOUND')
                custody.close()
            else:
                within_cleanup_allowance()
                observed = identity(os.getpid())
                if observed is None or observed[:5] != leader[:5] or not reap_owned():
                    raise RuntimeError('BIRTH_IDENTITY_CHANGED')
                within_cleanup_allowance()
        except (OSError, ValueError, RuntimeError) as error:
            hold_initialization(error)
        # No command was created; do not invent a commandExit record.
        emit(b'{"treeEmpty":true}\n')
        os.close(control)
        os._exit(124)  # Refusal stays a failed command/HOLD at the caller.

    if mode == 'owned-subreaper':
        # -I -S excludes sibling imports: load this exact source file explicitly.
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location('owned_custody_guardian',
                      Path(__file__).with_name('owned_process_custody.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            lifetime = module.TreeLifetime(deadline)
            sync_stop()  # Apply a stop recorded before the module even existed.
            if stopped[0] is not None:
                finish_without_launch()
            try:
                custody = module.OwnedDescendants(leader, deadline=deadline,
                                                 lifetime=lifetime, reap=reap_owned)
            except module.CustodyError as error:
                if not known_work_expiry(error):
                    raise
                # Known work expiry inside construction: the constructor already
                # closed what it opened. Publish workExpired, latch cleanup at
                # the original work cutoff, launch nothing and finalize within
                # the remaining one-time allowance; any proof failure HOLDs.
                expire_work()
                finish_without_launch()
        except (OSError, ValueError, RuntimeError) as error:
            hold_initialization(error)
    # Inspect pending stop signals before the launch gate. Restore the mask
    # before fork/exec so the target never inherits blocked TERM/INT. The final
    # stopped check is the launch commit point; a later stop retains adoption
    # and cleans the registered child normally.
    stop_signals = {signal.SIGTERM, signal.SIGINT}
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, stop_signals)
    try:
        sync_stop()
        if signal.sigpending() & stop_signals:
            request_stop()
        if stopped[0] is None and lifetime is not None:
            try:
                lifetime.require_work()
            except module.CustodyError as error:
                if error.custody_code != 'CUSTODY_DEADLINE':
                    raise
                expire_work()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    sync_stop()
    if stopped[0] is None:
        child = subprocess.Popen(command, close_fds=True)
    if child is None:
        finish_without_launch()
    reported = False
    uncertain = None
    uncertain_reported = False
    def send_owned(proof, sig):
        try:
            fd = os.pidfd_open(proof[0])
        except ProcessLookupError:
            return
        try:
            observed = identity(proof[0])
            if observed is None:
                return
            if observed[:5] != proof[:5]:
                raise RuntimeError('BIRTH_IDENTITY_CHANGED')
            signal.pidfd_send_signal(fd, sig)
        except ProcessLookupError:
            pass
        finally:
            os.close(fd)

    term_sent = set()
    while True:
        if os.getppid() != parent and stopped[0] is None:
            request_stop()
        if custody is not None and time.monotonic() >= deadline \
                and (stopped[0] is None or stopped[0] >= deadline) and not work_expired:
            expire_work()
        try:
            if custody is None:
                reap_owned()
                children = descendants(os.getpid())
                live = [identity(pid) for pid in children]
            else:
                live = [p for p in custody.refresh() if p[0] != leader[0]]
                children = [p[0] for p in live]
        except (OSError, ValueError, RuntimeError) as error:
            if custody is not None and known_work_expiry(error):
                # Phase fixed at the cutoff sample: a stop that raced in after
                # it continues cleanup inside the one-shot allowance.
                expire_work()
                continue  # Known expiry is not a cleared ownership uncertainty.
            if uncertain is None:
                uncertain = uncertainty_record(error, 'PROC_DISCOVERY')
            children, live = [None], []
        if custody is None and any(p and (p[2:5] != leader[2:5]) for p in live):
            if uncertain is None:
                uncertain = {'uncertain': 'DESCENDANT_IDENTITY_MISMATCH'}
        if exit_code is not None and not reported:
            emit((json.dumps({'commandExit': exit_code}) + '\n').encode())
            reported = True
        if uncertain:
            if not uncertain_reported:
                emit((json.dumps(uncertain) + '\n').encode())
                uncertain_reported = True
            # Deliberately retain adoption. Never drop unknown descendants to PID1.
            time.sleep(0.05)
            continue
        if not children and exit_code is not None:
            if custody is not None:
                try:
                    with custody._operation():
                        completed = False
                        for _ in range(128):
                            # A positive final reap invalidates the old empty
                            # epoch, even when that wait also reaches ECHILD.
                            if any(p[0] != leader[0] for p in custody.refresh()):
                                break
                            epoch = reap_epoch
                            no_children = reap_owned(custody.budget)
                            if not no_children or reap_epoch != epoch:
                                continue
                            custody.close()
                            completed = True
                            break
                    if not completed:
                        continue
                except (OSError, RuntimeError) as error:
                    if known_work_expiry(error):
                        expire_work()
                    elif uncertain is None:
                        uncertain = uncertainty_record(error, 'OWNED_EMPTY')
                    continue
            emit(b'{"treeEmpty":true}\n')
            os.close(control)
            os._exit(exit_code if 0 <= exit_code <= 124 else 124)
        if stopped[0] is not None:
            if custody is not None:
                try:
                    started = custody.lifetime.teardown_deadline - 3
                    custody.signal_owned(signal.SIGTERM if time.monotonic() - started <= 0.3 else signal.SIGKILL)
                except (OSError, RuntimeError) as error:
                    if known_work_expiry(error):
                        expire_work()
                    elif uncertain is None:
                        uncertain = uncertainty_record(error, 'OWNED_SIGNAL')
                time.sleep(0.01)
                continue
            for proof in live:
                if proof and proof[5] != 'Z':
                    try:
                        if proof[:2] not in term_sent:
                            send_owned(proof, signal.SIGTERM)
                            term_sent.add(proof[:2])
                        if time.monotonic() - stopped[0] > 0.3:
                            send_owned(proof, signal.SIGKILL)
                    except (OSError, RuntimeError) as error:
                        if uncertain is None:
                            uncertain = uncertainty_record(error, 'OWNED_SIGNAL')
                        break
        time.sleep(0.01)


if __name__ == '__main__':
    main()
