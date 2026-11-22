#!/usr/bin/env python3
"""Linux-only session leader/subreaper for one owned acceptance command tree.

No SDK imports. Dedicated control pipe is never part of target stdout. Surviving
or escaped descendants keep this guardian alive: the parent must report HOLD.
"""
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def identity(pid):
    try:
        p = Path('/proc') / str(pid)
        with (p / 'stat').open() as source:
            raw = source.read(8193)
        if len(raw) > 8192:
            raise RuntimeError('PROC_STAT_BOUND')
        fields = raw.rsplit(')', 1)[1].split()
        return (pid, int(fields[19]), p.stat().st_uid, int(fields[2]), int(fields[3]), fields[0])
    except FileNotFoundError:
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
                except FileNotFoundError:
                    continue
                if len(text) > 8192:
                    raise RuntimeError('CHILD_BOUND')
                for child in map(int, text.split()):
                    if child not in found:
                        found.append(child)
                        todo.append(child)
                        if len(found) > maximum:
                            raise RuntimeError('CHILD_BOUND')
        except FileNotFoundError:
            continue
    return found


def main():
    control = int(sys.argv[1])
    command = sys.argv[2:]
    os.set_inheritable(control, False)
    stopped = [None]
    signal.signal(signal.SIGTERM, lambda *_: stopped.__setitem__(0, time.monotonic()))
    signal.signal(signal.SIGINT, lambda *_: stopped.__setitem__(0, time.monotonic()))
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise SystemExit(125)
    leader = identity(os.getpid())
    parent = os.getppid()
    child = subprocess.Popen(command, close_fds=True)
    exit_code = None
    reported = False
    uncertain = False
    uncertain_reported = False
    def emit(data):
        try:
            os.write(control, data)
        except BrokenPipeError:
            pass  # Observer death must not orphan our adopted descendants.

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
            stopped[0] = time.monotonic()
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if not pid:
                break
            if pid == child.pid:
                exit_code = os.waitstatus_to_exitcode(status)
        try:
            children = descendants(os.getpid())
            live = [identity(pid) for pid in children]
        except (OSError, ValueError, RuntimeError):
            uncertain = True
            children, live = [None], []
        if any(p and (p[2:5] != leader[2:5]) for p in live):
            uncertain = True
        if exit_code is not None and not reported:
            emit((json.dumps({'commandExit': exit_code}) + '\n').encode())
            reported = True
        if uncertain:
            if not uncertain_reported:
                emit(b'{"uncertain":"DESCENDANT_ESCAPED_OR_UNKNOWN"}\n')
                uncertain_reported = True
            # Deliberately retain adoption. Never drop unknown descendants to PID1.
            time.sleep(0.05)
            continue
        if not children and exit_code is not None:
            emit(b'{"treeEmpty":true}\n')
            os.close(control)
            os._exit(exit_code if 0 <= exit_code <= 124 else 124)
        if stopped[0] is not None:
            for proof in live:
                if proof and proof[5] != 'Z':
                    try:
                        if proof[:2] not in term_sent:
                            send_owned(proof, signal.SIGTERM)
                            term_sent.add(proof[:2])
                        if time.monotonic() - stopped[0] > 0.3:
                            send_owned(proof, signal.SIGKILL)
                    except (OSError, RuntimeError):
                        uncertain = True
                        break
        time.sleep(0.01)


if __name__ == '__main__':
    main()
