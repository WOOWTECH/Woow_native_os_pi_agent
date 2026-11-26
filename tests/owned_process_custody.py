"""Bounded Linux PIDfd custody and one-socket IPv4 peer admission.

Private capabilities never leave this module. No SDK, installer or providers.
"""
import contextlib
import errno
import os
import re
import select
import signal
import socket
import stat
import time


PHASES = ('work', 'teardown', 'explicit')
PF_EXITING = 0x4  # include/linux/sched.h: set in do_exit() before exit_task_namespaces().
EXIT_WAIT_LIMIT = 2.0


class CustodyError(RuntimeError):
    def __init__(self, code, number=None, *, phase=None):
        super().__init__(code)
        self.custody_code = code
        self.errno = number if type(number) is int and 0 < number <= 4095 else None
        # Which cutoff an expiry crossed, fixed when it was sampled; the caller
        # classifies by this value, never by lifetime state at catch time.
        self.phase = phase if phase in PHASES else None


def need(condition, code):
    if not condition:
        raise CustodyError(code)


class _Departure:
    """Borrowed validation saw a proved departure; the outer transaction restarts."""
    __slots__ = ()

    def __repr__(self):
        return 'DEPARTED'


DEPARTED = _Departure()


class Budget:
    """One process-controller budget, shared across its ledgers and nested work."""
    def __init__(self, deadline, identities=128, descriptors=128, read_bytes=4 * 1024 * 1024):
        self.deadline = deadline
        self.identities, self.descriptors, self.read_limit = identities, descriptors, read_bytes
        self.fds = 0
        self.pins = {}
        self.depth = 0
        self._operations = []
        self.seen = set()
        self.bytes = self.fd_entries = 0
        self.passes = 0
        self.reaps = []

    @contextlib.contextmanager
    def operation(self, deadline=None, *, lifetime=None, work=False):
        if lifetime is not None:
            need(lifetime.work_deadline == self.deadline, 'CUSTODY_LIFETIME_INVALID')
        outer = self.depth == 0
        if outer:
            self.seen = set(self.pins)
            self.bytes = self.fd_entries = 0
            self.passes = 0
            self.reaps = []
        self._operations.append((lifetime, work, deadline))
        self.depth += 1
        try:
            self.check()
            yield
        except CustodyError:
            raise
        except OSError as error:
            raise CustodyError('CUSTODY_IO_ERROR', error.errno) from error
        except (ValueError, IndexError, UnicodeError):
            raise CustodyError('CUSTODY_PROC_INVALID') from None
        finally:
            self.depth -= 1
            self._operations.pop()

    def check(self):
        need(self._operations, 'CUSTODY_OPERATION_INVALID')
        # Sample the clock FIRST, then evaluate the effective cutoff. A stop that
        # lands between them can only replace the work cutoff with its teardown
        # cutoff for this sample; it can never turn a pre-stop sample into a
        # stale work expiry.
        now = time.monotonic()
        limits = []
        for lifetime, work, requested in self._operations:
            if lifetime is None:
                limit, code, phase = self.deadline, 'CUSTODY_DEADLINE', 'work'
            else:
                limit, code = lifetime.cutoff(work)
                phase = 'teardown' if code == 'CUSTODY_TEARDOWN_DEADLINE' else 'work'
            if requested is not None and requested < limit:
                limit, phase = requested, 'explicit'
            limits.append((limit, code, phase))
        # A signal may change a lifetime while any nested operation is active.
        # Re-evaluate purpose/cutoff without renewing it or resetting counters.
        self.until, self.expiry_code, self.expiry_phase = min(limits, key=lambda item: item[0])
        if not now < self.until:
            raise CustodyError(self.expiry_code, phase=self.expiry_phase)

    def identity(self, key):
        self.check()
        self.seen.add(key)
        # In the verified PID namespace, a process leader PID and its TID name
        # the same Linux task. Keep role pins separate, but charge it once.
        unique = {('task', item[1]) if item[0] == 'pid' else item for item in self.seen}
        if len(unique) > self.identities:
            error = CustodyError('CUSTODY_IDENTITY_BOUND')
            error.identity_counts = {kind: sum(k[0] == kind for k in self.seen)
                                     for kind in ('pid', 'task')}
            error.identity_counts.update(pinned=len(self.pins), unique=len(unique), limit=self.identities)
            raise error

    def forget(self, key):
        """Release a census slot only after no held capability pins it."""
        if key not in self.pins:
            self.seen.discard(key)

    def census_pass(self):
        self.check()
        need(self.passes < 128, 'CUSTODY_CENSUS_BOUND')
        self.passes += 1

    def record_reap(self, pid, status):
        need(type(pid) is int and pid > 0 and type(status) is int
             and (os.WIFEXITED(status) or os.WIFSIGNALED(status)), 'CUSTODY_REAP_INVALID')
        need(len(self.reaps) < 128, 'CUSTODY_REAP_BOUND')
        self.reaps.append((pid, status))  # Account before a later bound can HOLD.
        # The positive waitpid record itself proves this process is complete;
        # it has a separate hard bound rather than consuming a live identity slot.
        self.forget(('pid', pid))
        self.check()  # The consumed waitpid result is recorded before expiry.

    def pin(self, key):
        self.identity(key)
        self.pins[key] = self.pins.get(key, 0) + 1

    def unpin(self, key):
        self.pins[key] -= 1
        if not self.pins[key]:
            del self.pins[key]

    def acquire(self):
        self.check()
        need(self.fds < self.descriptors, 'CUSTODY_DESCRIPTOR_BOUND')
        self.fds += 1

    def release(self):
        self.fds -= 1
        assert self.fds >= 0


class TreeLifetime:
    """Fixed work cutoff and one nonrenewable cleanup allowance for one tree."""
    def __init__(self, work_deadline):
        self.work_deadline = work_deadline
        self.teardown_deadline = None

    def begin_teardown(self, seconds=3, *, requested_at=None):
        need(0 < seconds <= 3, 'CUSTODY_TEARDOWN_BOUND')
        if self.teardown_deadline is None:
            now = time.monotonic()
            self.teardown_deadline = min(now, self.work_deadline,
                now if requested_at is None else requested_at) + seconds
        return self.teardown_deadline

    def cutoff(self, work=False):
        if work:
            need(self.teardown_deadline is None, 'CUSTODY_STOPPING')
        if self.teardown_deadline is not None and not work:
            return self.teardown_deadline, 'CUSTODY_TEARDOWN_DEADLINE'
        return self.work_deadline, 'CUSTODY_DEADLINE'

    def require_work(self):
        now = time.monotonic()
        limit, code = self.cutoff(work=True)
        if not now < limit:
            raise CustodyError(code, phase='work')


class _Capability:
    def __init__(self, pid, pidfd):
        self.pid, self.pidfd, self.procfd = pid, pidfd, None
        self.proof = None
        self.pinned = False
        self.terminal = False  # An inert terminal leaf: never a live capability.
        self.tasks = set()  # Charged TIDs stay with this exact capability.
        self.retirement_error = None


class _CensusChanged(Exception):
    pass


class OwnedDescendants:
    def __init__(self, anchor_proof, *, deadline=None, budget=None, strict=False, lifetime=None, reap=None):
        need(isinstance(anchor_proof, tuple) and len(anchor_proof) >= 5,
             'CUSTODY_ANCHOR_INVALID')
        need(all(type(x) is int and x >= 0 for x in anchor_proof[:5])
             and anchor_proof[0] > 0 and anchor_proof[2] == os.getuid(), 'CUSTODY_ANCHOR_INVALID')
        self.anchor_proof = anchor_proof
        self.strict = strict
        self.budget = budget or Budget(deadline if deadline is not None else time.monotonic() + 1800)
        self.lifetime = lifetime or TreeLifetime(self.budget.deadline)
        need(reap is None or anchor_proof[0] == os.getpid(), 'CUSTODY_REAPER_INVALID')
        self._reap = reap
        self._caps = {}
        self._provisional = {}
        self._edges = {}
        self._leases = 0
        self._census_depth = 0
        self._retained = []  # (pid or 0, field, number) whose close reported an error.
        self._close_failure = None
        self.closed = False
        self.rootfd = self.selffd = None
        with self._operation():
            try:
                self.rootfd = self._open('/proc', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                self.root_identity = self._dir_identity(self.rootfd)
                self.selffd = self._open(str(os.getpid()), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                         dir_fd=self.rootfd)
                self.pidns = os.readlink('ns/pid', dir_fd=self.selffd)
                self.netns = os.readlink('ns/net', dir_fd=self.selffd)
                need(re.fullmatch(r'pid:\[\d+\]', self.pidns)
                     and re.fullmatch(r'net:\[\d+\]', self.netns), 'CUSTODY_NAMESPACE_INVALID')
                cap = self._open_cap(anchor_proof[0])
                need(cap is not None, 'CUSTODY_ANCHOR_GONE')
                self.anchor = cap
                need(cap.proof[:5] == anchor_proof[:5], 'CUSTODY_ANCHOR_CHANGED')
                self._caps[cap.pid] = cap
                self._provisional.pop(cap.pid, None)
            except BaseException as error:
                # Attempt every independent handle even after one close fails.
                failures = [self._retire(cap) for cap in
                            list(self._provisional.values()) + list(self._caps.values())]
                failures += [self._close_field(self, field, 0) for field in ('selffd', 'rootfd')]
                first = next((item for item in failures if item is not None), None)
                if first is not None:
                    self._latch_close_failure(first)
                    raise CustodyError('CUSTODY_CLOSE_FAILED', self._close_failure) from error
                raise

    def _operation(self, deadline=None, *, work=False):
        if self._close_failure is not None:
            # A descriptor whose close failed is retained, never retried.
            raise CustodyError('CUSTODY_CLOSE_FAILED', self._close_failure)
        return self.budget.operation(deadline, lifetime=self.lifetime, work=work)

    def begin_teardown(self, seconds=3):
        return self.lifetime.begin_teardown(seconds)

    def _open(self, path, flags, **kwargs):
        self.budget.acquire()
        try:
            return os.open(path, flags, **kwargs)
        except BaseException:
            self.budget.release()
            raise

    def _close_fd(self, fd):
        try:
            os.close(fd)
        finally:
            self.budget.release()

    def _close_field(self, owner, field, pid):
        """Close one held descriptor field exactly once; return its close error.

        The field is cleared right after a successful close and its Budget FD is
        released then. A failed close moves the number to the retained ledger
        (Linux releases the number even when close reports an error, so it is
        never retried) and keeps its Budget FD charge.
        """
        fd = getattr(owner, field)
        if fd is None:
            return None
        try:
            os.close(fd)
        except OSError as error:
            setattr(owner, field, None)
            self._retained.append((pid, field, fd))
            return error
        setattr(owner, field, None)
        self.budget.release()
        return None

    def _latch_close_failure(self, error):
        if self._close_failure is None:
            self._close_failure = error.errno if type(error.errno) is int and error.errno > 0 else errno.EIO

    @staticmethod
    def _dir_identity(fd):
        s = os.fstat(fd)
        need(stat.S_ISDIR(s.st_mode), 'CUSTODY_PROC_INVALID')
        return s.st_dev, s.st_ino

    def _read(self, directory, relative, maximum=8192):
        self.budget.check()
        fd = self._open(relative, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
        try:
            data = bytearray()
            while True:
                self.budget.check()
                block = os.read(fd, min(65536, maximum + 1 - len(data)))
                if not block:
                    break
                data.extend(block)
                self.budget.bytes += len(block)
                need(len(data) <= maximum and self.budget.bytes <= self.budget.read_limit,
                     'CUSTODY_READ_BOUND')
            return data.decode('ascii')
        finally:
            self._close_fd(fd)

    def _entries(self, fd):
        self.budget.acquire()  # scandir duplicates a supplied directory descriptor.
        try:
            with os.scandir(fd) as entries:
                for entry in entries:
                    self.budget.check()
                    yield entry.name
        finally:
            self.budget.release()

    def _fdinfo(self, cap):
        return self._pidfd_status(cap)[0]

    def _pidfd_status(self, cap):
        """(ready, kernel Pid) of the held PIDfd; Pid is -1 once released."""
        text = self._read(self.selffd, 'fdinfo/' + str(cap.pidfd))
        values = {}
        for line in text.splitlines():
            key, sep, value = line.partition(':')
            if key in ('Pid', 'NSpid'):
                need(sep and key not in values, 'CUSTODY_PIDFD_INVALID')
                values[key] = value.split()
        need(set(values) == {'Pid', 'NSpid'} and len(values['Pid']) == 1
             and len(values['NSpid']) == 1, 'CUSTODY_PIDFD_NAMESPACE')
        pid, nspid = int(values['Pid'][0]), int(values['NSpid'][0])
        poll = select.poll()
        poll.register(cap.pidfd, select.POLLIN)
        flags = sum(item[1] for item in poll.poll(0))
        need(not flags & (select.POLLERR | select.POLLNVAL), 'CUSTODY_PIDFD_INVALID')
        ready = bool(flags & (select.POLLIN | select.POLLHUP))
        need((pid == cap.pid and nspid == cap.pid) or
             (ready and pid == -1 and nspid == -1), 'CUSTODY_PIDFD_SUBSTITUTED')
        return ready, pid

    def _terminal(self, leaf):
        """The SAME held PIDfd is still a ready, unreleased zombie of that PID.

        A released zombie reports Pid -1 for good, so a listed number that is
        still bound here cannot have been reaped and reused."""
        ready, pid = self._pidfd_status(leaf)
        return ready and pid == leaf.pid

    def _stat_fields(self, cap):
        raw = self._read(cap.procfd, 'stat')
        fields = raw.rsplit(')', 1)[-1].split()
        need(raw.split(' ', 1)[0] == str(cap.pid) and len(fields) >= 20,
             'CUSTODY_PROC_INVALID')
        state = fields[0]
        need(len(state) == 1 and state in 'RSDTtKWPI' + 'ZXx', 'CUSTODY_PROC_INVALID')
        return fields

    def _stat(self, cap):
        fields = self._stat_fields(cap)
        return int(fields[19]), int(fields[2]), int(fields[3]), fields[0]

    def _exit_state(self, cap):
        """Birth, kernel task flags (stat field 9) and state, via the held procfd."""
        fields = self._stat_fields(cap)
        return int(fields[19]), int(fields[6]), fields[0]

    # The kernel's own errno for an exiting task at each held-capability site:
    # exit_task_namespaces() clears nsproxy (namespace links: ENOENT); exit_mm()
    # clears mm, so /proc/<pid>/fd becomes root-owned 0500 (FD directory: EACCES).
    _EXITING_ERRNO = {'namespace': errno.ENOENT, 'fd-dir': errno.EACCES}

    def _departed(self, cap, error, site, birth=None):
        """The one site-aware held-PIDfd departure decision.

        Returns True only for a proved departure of this held capability at this
        exact site; False means the caller re-raises the original error (HOLD).
        Departure is always whole-process readiness of the SAME held PIDfd. An
        anchor never departs and never waits: an exited or exiting anchor raises
        CUSTODY_ANCHOR_GONE, any other anchor outcome is the caller's HOLD.
        """
        need(site in ('stat', 'procdir', 'children', 'empty-tasks', 'fd-dir', 'namespace'),
             'CUSTODY_SITE_INVALID')
        number = getattr(error, 'errno', None)
        anchor = cap.pid == self.anchor_proof[0]
        if site in ('stat', 'procdir', 'children'):
            # Unchanged prior rule; an anchor outcome only ever refuses as gone.
            return number in (errno.ENOENT, errno.ESRCH) and self._fdinfo(cap)
        if site == 'empty-tasks':
            # An empty task listing carries no errno: a task released after
            # proc_task_readdir's dead check. Children-site rule, non-anchor only.
            return not anchor and self._fdinfo(cap)
        if number not in (errno.ENOENT, errno.ESRCH, errno.EACCES):
            return False
        exiting = number == self._EXITING_ERRNO[site]
        if anchor:
            self._anchor_gone(cap, exiting)
            return False
        if self._fdinfo(cap):
            return True
        if not exiting:
            # Namespace EACCES/ESRCH and FD-directory ENOENT/ESRCH: immediate
            # same-PIDfd readiness only (the accepted rules, unchanged).
            return False
        return self._exit_window(cap, birth)

    def _anchor_gone(self, cap, exiting):
        """Refuse as gone, without waiting, an anchor whose same held PIDfd is ready
        or whose stat shows the same birth, the anchor UID and PF_EXITING."""
        if self._fdinfo(cap):
            raise CustodyError('CUSTODY_ANCHOR_GONE')
        if not exiting:
            return
        try:
            birth, flags, _ = self._exit_state(cap)
            uid = os.fstat(cap.procfd).st_uid
        except OSError:
            return  # The original error stays a HOLD.
        if birth == self.anchor_proof[1] and uid == self.anchor_proof[2] and flags & PF_EXITING:
            raise CustodyError('CUSTODY_ANCHOR_GONE')

    def _exit_window(self, cap, birth):
        """The site's exiting errno while the same held PIDfd is not yet ready.

        do_exit() sets PF_EXITING, clears mm in exit_mm() and nsproxy in
        exit_task_namespaces(), and only later, in exit_notify(), makes the
        PIDfd readable; mm teardown and deferred final fput work widen that
        window to tens or hundreds of milliseconds. Only a same-birth, anchor-UID
        task with PF_EXITING may wait, and only on the SAME held PIDfd, for at
        most EXIT_WAIT_LIMIT from the start of the wait and never past the
        current operation cutoff. A wait ended by that cutoff raises the cutoff's
        own phase-tagged expiry; CUSTODY_EXIT_UNCONFIRMED means the full bound
        elapsed without readiness. Nothing is renewed, no identity is charged and
        a census is not required.
        """
        try:
            observed_birth, flags, _ = self._exit_state(cap)
            uid = os.fstat(cap.procfd).st_uid
        except OSError as error:
            # Stat unavailable: only immediate same-PIDfd readiness; else HOLD.
            return error.errno in (errno.ENOENT, errno.ESRCH) and self._fdinfo(cap)
        if self._fdinfo(cap):
            # Exited (and possibly released, after which pid_getattr reports
            # root ownership) since the failing call: same-PIDfd readiness decides.
            return True
        need(type(birth) is int and observed_birth == birth
             and (cap.proof is None or cap.proof[1] == birth), 'CUSTODY_BIRTH_CHANGED')
        need(uid == self.anchor_proof[2], 'CUSTODY_UID_CHANGED')
        if not flags & PF_EXITING:
            return False  # Genuinely unknown: the original error stays a HOLD.
        limit = time.monotonic() + EXIT_WAIT_LIMIT  # Fixed once; never extended.
        poll = select.poll()
        poll.register(cap.pidfd, select.POLLIN)
        while True:
            # The operation cutoff first: a truncated wait is that cutoff's own
            # expiry (work, teardown or explicit phase), never an unconfirmed exit.
            self.budget.check()
            now = time.monotonic()
            if not now < limit:
                raise CustodyError('CUSTODY_EXIT_UNCONFIRMED')
            if poll.poll(max(0.0, min(limit, self.budget.until) - now) * 1000):
                if self._fdinfo(cap):
                    return True
                raise CustodyError('CUSTODY_EXIT_UNCONFIRMED')

    def _namespace_link(self, cap, relative, birth):
        """Nonmutating: return the link, or None for a proved departure."""
        need(relative in ('ns/pid', 'ns/net'), 'CUSTODY_NAMESPACE_INVALID')
        try:
            return os.readlink(relative, dir_fd=cap.procfd)
        except OSError as error:
            if self._departed(cap, error, 'namespace', birth):
                return None
            raise

    def _validate(self, cap):
        """Nonmutating proof of one held capability; None means proved departure.

        Validation never closes a capability or refreshes underneath a caller:
        only the census retires, and outer transactions restart on departure.
        """
        if self._fdinfo(cap):
            return None  # Whole-process readiness, never terminal leader state alone.
        try:
            before = self._stat(cap)
            uid = os.fstat(cap.procfd).st_uid
            after = self._stat(cap)
            uid_after = os.fstat(cap.procfd).st_uid
        except OSError as error:
            if self._departed(cap, error, 'stat'):
                return None
            raise
        if self._fdinfo(cap):
            return None
        need(before[0] == after[0], 'CUSTODY_BIRTH_CHANGED')
        need(before[3] not in 'ZXx' or after[3] in 'ZXx', 'CUSTODY_PROC_INVALID')
        need(uid == uid_after == self.anchor_proof[2], 'CUSTODY_UID_CHANGED')
        proof = (cap.pid, after[0], uid_after, after[1], after[2], after[3])
        if cap.proof is not None:
            need(proof[:3] == cap.proof[:3], 'CUSTODY_BIRTH_CHANGED')
        if cap.pid == self.anchor_proof[0]:
            need(proof[:5] == self.anchor_proof[:5], 'CUSTODY_ANCHOR_CHANGED')
        elif self.strict:
            need(before[1:3] == after[1:3] == self.anchor_proof[3:5],
                 'CUSTODY_GROUP_CHANGED')
        elif after[3] not in 'ZXx':
            need(before[1] > 0 and before[2] > 0,
                 'CUSTODY_PROC_INVALID')
            need(after[1] > 0 and after[2] > 0, 'CUSTODY_PROC_INVALID')
        for relative, expected in (('ns/pid', self.pidns), ('ns/net', self.netns)):
            observed = self._namespace_link(cap, relative, after[0])
            if observed is None:
                return None
            need(observed == expected, 'CUSTODY_NAMESPACE_CHANGED')
        if self._fdinfo(cap):
            return None
        cap.proof = proof
        return proof

    def _open_cap(self, pid, *, discovered=False, terminal=False):
        need(type(pid) is int and pid > 0, 'CUSTODY_PID_INVALID')
        need(pid not in self._caps and pid not in self._provisional, 'CUSTODY_ALREADY_HELD')
        self.budget.identity(('pid', pid))
        self.budget.acquire()
        try:
            fd = os.pidfd_open(pid, 0)
        except OSError as error:
            self.budget.release()
            if error.errno == errno.EINVAL and discovered is True and self._census_depth \
                    and pid != self.anchor_proof[0]:
                # No FD, no death/ownership proof: discard this incomplete pass.
                # Existing live capabilities and cumulative charges stay held.
                raise _CensusChanged() from None
            if error.errno == errno.ESRCH:
                self.budget.forget(('pid', pid))
                return None
            raise
        cap = _Capability(pid, fd)
        self._provisional[pid] = cap  # Retain before any subsequent setup can fail.
        # identity() already charged this key before PIDfd acquisition. Bind
        # that charge without another fallible clock check after acquiring FD.
        key = ('pid', pid)
        self.budget.pins[key] = self.budget.pins.get(key, 0) + 1
        cap.pinned = True
        try:
            try:
                if self._fdinfo(cap):
                    if terminal is True and discovered is True and self._census_depth \
                            and pid != self.anchor_proof[0]:
                        del self._provisional[pid]
                        cap.terminal = True
                        return cap
                    self._close_cap(cap)
                    return None
                cap.procfd = self._open(str(pid), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                        dir_fd=self.rootfd)
                if self._validate(cap) is None:
                    self._close_cap(cap)
                    return None
            except OSError as error:
                if self._departed(cap, error, 'procdir'):
                    self._close_cap(cap)
                    return None
                raise
        except CustodyError as error:
            # Known work/explicit expiry cannot authorize reuse of an incomplete
            # provisional. Ownership/I/O/exit uncertainty instead retains it.
            if error.custody_code == 'CUSTODY_DEADLINE' and error.phase in ('work', 'explicit') \
                    and cap.procfd is None and self._provisional.get(pid) is cap:
                self._close_cap(cap)
            raise
        return cap

    def _retire(self, cap):
        """Retire exactly this object; return the first close error, or None.

        Removal is by object identity, so a newer object for the same PID is
        never popped. procfd and PIDfd close independently; each field is
        cleared when consumed, so repeated retirement never closes a reused
        number. Budget FDs release and the PID unpins exactly once.
        """
        if self._caps.get(cap.pid) is cap:
            del self._caps[cap.pid]
        if self._provisional.get(cap.pid) is cap:
            del self._provisional[cap.pid]
        failures = [self._close_field(cap, field, cap.pid) for field in ('procfd', 'pidfd')]
        first = cap.retirement_error or next((item for item in failures if item is not None), None)
        cap.retirement_error = first  # A second retirement cannot erase failed-close charges.
        if first is None:
            for tid in cap.tasks:
                self.budget.unpin(('task', tid))
                self.budget.forget(('task', tid))
            cap.tasks.clear()
        if first is None and cap.pinned:
            cap.pinned = False
            self.budget.unpin(('pid', cap.pid))
        if first is None:
            self.budget.forget(('pid', cap.pid))
        return first  # On failure the pin stays with the retained handle.

    def _close_cap(self, cap):
        first = self._retire(cap)
        if first is not None:
            self._latch_close_failure(first)
            raise CustodyError('CUSTODY_CLOSE_FAILED', self._close_failure)

    def _guard(self):
        need(not self.closed, 'CUSTODY_CLOSED')
        s = os.stat('/proc', follow_symlinks=False)
        need((s.st_dev, s.st_ino) == self.root_identity, 'CUSTODY_PROC_CHANGED')
        need(os.readlink('ns/pid', dir_fd=self.selffd) == self.pidns
             and os.readlink('ns/net', dir_fd=self.selffd) == self.netns,
             'CUSTODY_NAMESPACE_CHANGED')
        need(self._validate(self.anchor) is not None, 'CUSTODY_ANCHOR_GONE')

    def _children(self, cap):
        try:
            return self._live_children(cap)
        except OSError as error:
            if self._departed(cap, error, 'children'):
                raise _CensusChanged() from None
            raise

    def _live_children(self, cap):
        if self._validate(cap) is None:
            raise _CensusChanged()
        fd = self._open('task', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cap.procfd)
        result = set()
        try:
            tids = []
            for name in self._entries(fd):
                need(name.isdecimal(), 'CUSTODY_PROC_INVALID')
                tid = int(name)
                key = ('task', tid)
                self.budget.identity(key)
                if tid not in cap.tasks:
                    # Keep the successfully charged observation even if this
                    # snapshot later fails. Another ledger can pin the same TID.
                    self.budget.pins[key] = self.budget.pins.get(key, 0) + 1
                    cap.tasks.add(tid)
                tids.append(name)
            if not tids:
                # Released between the listing's dead check and its first tid:
                # its children were already reparented to the subreaper, which a
                # fresh census sees. Anchor or nonready: unknown, never empty.
                if self._departed(cap, None, 'empty-tasks'):
                    raise _CensusChanged()
                raise CustodyError('CUSTODY_TASKS_UNKNOWN')
            for tid in tids:
                try:
                    text = self._read(fd, tid + '/children')
                except OSError as error:
                    if error.errno in (errno.ENOENT, errno.ESRCH):
                        if cap is self.anchor and tid == str(cap.pid):
                            raise  # A required live anchor's data is not optional.
                        raise _CensusChanged() from None
                    raise
                for item in text.split():
                    need(item.isdecimal() and int(item) > 0, 'CUSTODY_PROC_INVALID')
                    value = int(item)
                    self.budget.identity(('pid', value))
                    result.add(value)
        finally:
            self._close_fd(fd)
        if self._validate(cap) is None:
            raise _CensusChanged()
        return result

    @contextlib.contextmanager
    def _census(self):
        self._census_depth += 1
        try:
            yield
        finally:
            self._census_depth -= 1

    def refresh(self):
        with self._operation(), self._census():
            need(not self._leases, 'CUSTODY_CONNECTION_ACTIVE')
            self._guard()
            # Churning children may depart between each edge read. Reproof uses
            # the same global identity/read/FD counters and absolute deadline;
            # neither progress nor a new pass resets those limits.
            for attempt in range(128):
                self.budget.census_pass()
                leaves = {}  # pid -> (terminal leaf, parent pid); this pass only.
                try:
                    try:
                        return self._census_pass(leaves)
                    finally:
                        self._close_leaves(leaves)
                except _CensusChanged:
                    self.budget.check()
                    time.sleep(min(0.001, max(0, self.budget.until - time.monotonic())))
                    continue
            raise CustodyError('CUSTODY_ANCESTRY_UNKNOWN')

    def _close_leaves(self, leaves):
        """Close every terminal leaf of one pass; the first close error is sticky."""
        failures = [self._retire(leaf) for leaf, _ in leaves.values()]
        leaves.clear()
        first = next((item for item in failures if item is not None), None)
        if first is not None:
            self._latch_close_failure(first)
            raise CustodyError('CUSTODY_CLOSE_FAILED', self._close_failure)

    def _census_pass(self, leaves):
        self._guard()
        if self._reap is not None:
            self._reap(self.budget)
        for cap in list(self._caps.values()) + list(self._provisional.values()):
            if cap is not self.anchor and self._fdinfo(cap):
                self._close_cap(cap)
        queue, seen, edges = [self.anchor], {self.anchor.pid}, {}
        while queue:
            parent = queue.pop(0)
            for pid in self._children(parent):
                need(pid != self.anchor.pid and pid not in leaves, 'CUSTODY_ANCESTRY_INVALID')
                child = self._caps.get(pid) or self._provisional.get(pid)
                if child is None:
                    child = self._open_cap(pid, discovered=True, terminal=True)
                    if child is not None and child.terminal:
                        # A zombie its live owned parent has not reaped: re-read
                        # the edge with both held, then keep it only as an inert
                        # leaf of that parent while its SAME PIDfd stays bound.
                        leaves[pid] = (child, parent.pid)
                        if pid not in self._children(parent) or self._validate(parent) is None \
                                or not self._terminal(child):
                            raise _CensusChanged()
                        need(pid not in edges, 'CUSTODY_ANCESTRY_INVALID')
                        continue
                if child is None or self._validate(child) is None:
                    raise _CensusChanged()
                # Re-read the edge with both capabilities already retained.
                if pid not in self._children(parent):
                    raise _CensusChanged()
                if self._validate(parent) is None or self._validate(child) is None:
                    raise _CensusChanged()
                need(pid not in edges or edges[pid] == parent.pid,
                     'CUSTODY_ANCESTRY_INVALID')
                edges[pid] = parent.pid
                if pid not in seen:
                    seen.add(pid)
                    queue.append(child)
                self._caps[pid] = child
                self._provisional.pop(pid, None)
        for cap in list(self._caps.values()) + list(self._provisional.values()):
            if self._fdinfo(cap):
                if cap is not self.anchor:
                    self._close_cap(cap)
                    raise _CensusChanged()
            else:
                if cap.pid not in seen:
                    raise _CensusChanged()
        # Cover every parent's complete child set again, including an anchor
        # with no saved edges and each terminal leaf of that parent. New
        # adoption invalidates the entire old census rather than manufacturing
        # empty.
        for parent in list(self._caps.values()):
            expected = {pid for pid, owner in edges.items() if owner == parent.pid}
            expected |= {pid for pid, (_, owner) in leaves.items() if owner == parent.pid}
            if self._children(parent) != expected:
                raise _CensusChanged()
        for pid, parent_pid in edges.items():
            child, parent = self._caps.get(pid), self._caps.get(parent_pid)
            if child is None or parent is None or pid not in self._children(parent) \
                    or self._validate(child) is None:
                raise _CensusChanged()
        for leaf, parent_pid in leaves.values():
            # Checked after the closure re-read: an unreleased zombie then was
            # the same zombie when its number was listed. Any change restarts.
            if self._caps.get(parent_pid) is None or not self._terminal(leaf):
                raise _CensusChanged()
        self._guard()
        self._edges = edges
        live = []
        for cap in list(self._caps.values()):
            if self._fdinfo(cap):
                need(cap is not self.anchor, 'CUSTODY_ANCHOR_GONE')
                self._close_cap(cap)
                raise _CensusChanged()
            live.append(cap.proof)
        return live  # Terminal leaves are never live proofs.

    @property
    def empty(self):
        self.refresh()
        return len(self._caps) == 1 and not self._provisional

    def signal_anchor(self, sig):
        with self._operation():
            self._guard()
            try:
                signal.pidfd_send_signal(self.anchor.pidfd, sig)
            except OSError as error:
                if error.errno != errno.ESRCH or not self._fdinfo(self.anchor):
                    raise
                # Parent must still reap this exact Popen and prove its final
                # treeEmpty control record. A departed anchor is not empty proof.

    def signal_owned(self, sig):
        with self._operation():
            self.refresh()
            for pid in reversed(list(self._caps)):
                if pid == self.anchor.pid:
                    continue
                self.refresh()
                cap = self._caps.get(pid)  # Fresh object after this census.
                if cap is None:
                    continue
                if self._validate(cap) is None:
                    self.refresh()  # Departure: the census retires it, same budget.
                    continue
                try:
                    signal.pidfd_send_signal(cap.pidfd, sig)
                except OSError as error:
                    if error.errno != errno.ESRCH or not self._fdinfo(cap):
                        raise
                    self.refresh()  # Reprove adoption using the same budget.

    def _tcp(self):
        text = self._read(self.anchor.procfd, 'net/tcp', maximum=2 * 1024 * 1024)
        rows = []
        for line in text.splitlines()[1:]:
            self.budget.check()
            need(len(line) <= 4096, 'CUSTODY_TCP_BOUND')
            f = line.split()
            need(len(f) >= 10, 'CUSTODY_TCP_INVALID')
            def address(value):
                host, port = value.split(':')
                need(re.fullmatch(r'[0-9A-F]{8}', host) and re.fullmatch(r'[0-9A-F]{4}', port),
                     'CUSTODY_TCP_INVALID')
                return socket.inet_ntoa(bytes.fromhex(host)[::-1]), int(port, 16)
            rows.append((address(f[1]), address(f[2]), f[3], int(f[7]), int(f[9])))
        return rows

    def _socket_fd(self, inode):
        """Borrowed, nonmutating scan: (cap, name), None, or DEPARTED.

        Every FD-derived site of a held capability (directory open, directory
        read, per-entry readlink, exact recheck) goes through the one departure
        helper. Any proved departure returns DEPARTED at once; the enclosing
        transaction must refresh and restart with fresh objects. A departing
        owner never becomes an empty owner set.
        """
        for cap in list(self._caps.values()):
            if self._validate(cap) is None:
                return DEPARTED
            birth = cap.proof[1]
            try:
                fd = self._open('fd', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cap.procfd)
            except OSError as error:
                if self._departed(cap, error, 'fd-dir', birth):
                    return DEPARTED
                raise
            try:
                found = None
                entries = self._entries(fd)  # A generator: the read happens in next().
                with contextlib.closing(entries):
                    while found is None:
                        try:
                            name = next(entries)
                        except StopIteration:
                            break
                        except OSError as error:
                            if self._departed(cap, error, 'fd-dir', birth):
                                return DEPARTED
                            raise
                        self.budget.fd_entries += 1
                        need(self.budget.fd_entries <= 4096, 'CUSTODY_FD_SCAN_BOUND')
                        try:
                            link = os.readlink(name, dir_fd=fd)
                        except FileNotFoundError:
                            continue  # That descriptor closed; a fruitless scan rechecks the owner.
                        except OSError as error:
                            if self._departed(cap, error, 'fd-dir', birth):
                                return DEPARTED
                            raise
                        if link == 'socket:[' + str(inode) + ']':
                            found = name
                if found is not None:
                    if self._verify_socket_fd(cap, found, inode) is DEPARTED:
                        return DEPARTED
                    return cap, found
                if self._scan_departed(cap, birth):
                    return DEPARTED
            finally:
                self._close_fd(fd)
        return None

    def _scan_departed(self, cap, birth):
        """A fruitless scan proves nothing about a departing owner: its files may
        already be gone (empty listing). Ready, or PF_EXITING then the bounded
        same-PIDfd wait, is a departure; a live non-exiting owner has no match."""
        if cap.pid == self.anchor_proof[0]:
            self._anchor_gone(cap, True)
            return False
        if self._fdinfo(cap):
            return True
        try:
            flags = self._exit_state(cap)[1]
        except OSError as error:
            if self._departed(cap, error, 'stat'):
                return True
            raise
        return bool(flags & PF_EXITING) and self._exit_window(cap, birth)

    def _verify_socket_fd(self, cap, name, inode):
        """Nonmutating exact FD recheck: True, or DEPARTED for the outer restart."""
        if self._validate(cap) is None:
            return DEPARTED
        try:
            link = os.readlink('fd/' + name, dir_fd=cap.procfd)
        except OSError as error:
            if self._departed(cap, error, 'fd-dir', cap.proof[1]):
                return DEPARTED
            raise
        need(link == 'socket:[' + str(inode) + ']', 'CUSTODY_PEER_CHANGED')
        if self._validate(cap) is None:
            return DEPARTED
        return True

    def verify_listener(self, port):
        with self._operation(work=True):
            need(type(port) is int and 1024 <= port <= 65535, 'CUSTODY_PORT_INVALID')
            # Restarts share this operation's Budget, deadline and cumulative
            # census-pass bound; each restart takes fresh objects from a census.
            for _ in range(128):
                self.refresh()
                rows = [r for r in self._tcp() if r[0] == ('127.0.0.1', port) and r[2] == '0A']
                need(rows, 'LISTENER_MISSING')
                need(len(rows) == 1 and rows[0][3] == self.anchor_proof[2] and rows[0][4] > 0,
                     'CUSTODY_LISTENER_INVALID')
                proof = self._socket_fd(rows[0][4])
                if proof is DEPARTED:
                    continue
                need(proof is not None, 'CUSTODY_LISTENER_FOREIGN')
                return rows[0], proof
            raise CustodyError('CUSTODY_ANCESTRY_UNKNOWN')

    @contextlib.contextmanager
    def connect_owned(self, port, deadline):
        with self._operation(deadline, work=True):
            listener, listener_fd = self.verify_listener(port)
            listener_proof = listener_fd[0].proof[:3]  # Data only; no borrowed object kept.
            self.budget.acquire()
            conn = None
            try:
                conn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                conn.settimeout(max(0.001, self.budget.until - time.monotonic()))
                conn.connect(('127.0.0.1', port))  # Exactly once; no request bytes yet.
                local, peer = conn.getsockname(), conn.getpeername()
                need(local[0] == peer[0] == '127.0.0.1' and peer[1] == port,
                     'CUSTODY_PEER_INVALID')
                while True:
                    self.budget.check()
                    # Until the kernel reports an established peer socket, no
                    # process is being trusted. Poll only the bounded TCP table;
                    # a full ancestry census is required as soon as a candidate
                    # accepted socket appears, before inspecting or granting it.
                    matches = [r for r in self._tcp() if r[0] == peer and r[1] == local and r[2] == '01']
                    need(len(matches) <= 1, 'CUSTODY_PEER_AMBIGUOUS')
                    if matches and matches[0][4] > 0:
                        row = matches[0]
                        need(row[3] == self.anchor_proof[2], 'CUSTODY_PEER_FOREIGN')
                        self.refresh()
                        owned_fd = self._socket_fd(row[4])
                        if owned_fd is DEPARTED:
                            continue  # Fresh bounded census and fresh objects.
                        need(owned_fd is not None, 'CUSTODY_PEER_FOREIGN')
                        cap, name = owned_fd
                        self.refresh()
                        if self._caps.get(cap.pid) is not cap:
                            continue  # Retired or replaced: never use a stale object.
                        current = [r for r in self._tcp() if r[0] == peer and r[1] == local and r[2] == '01']
                        need(current == [row], 'CUSTODY_PEER_CHANGED')
                        if self._verify_socket_fd(cap, name, row[4]) is DEPARTED:
                            continue
                        need([r for r in self._tcp() if r[0] == peer and r[1] == local and r[2] == '01'] == [row],
                             'CUSTODY_PEER_CHANGED')
                        if self._verify_socket_fd(cap, name, row[4]) is DEPARTED:
                            continue
                        token = (listener, listener_proof, row, cap.proof[:3], name)
                        break
                    # No accepted FD yet: prove only this existing connection again.
                    readable, _, _ = select.select([conn], [], [], 0)
                    if readable:
                        need(conn.recv(1, socket.MSG_PEEK) != b'', 'CUSTODY_PEER_GONE')
                    time.sleep(min(0.005, max(0, self.budget.until - time.monotonic())))
                self._leases += 1
                try:
                    yield conn
                finally:
                    self._leases -= 1
                    del token
            finally:
                if conn is not None:
                    conn.close()
                self.budget.release()

    def close(self):
        need(not self._leases, 'CUSTODY_CONNECTION_ACTIVE')
        self.begin_teardown()
        with self._operation():
            need(not self._leases, 'CUSTODY_CONNECTION_ACTIVE')
            for cap in list(self._caps.values()) + list(self._provisional.values()):
                need(self._fdinfo(cap) or cap is self.anchor and cap.pid == os.getpid()
                     and len(self._caps) == 1 and not self._provisional, 'CUSTODY_LIVE_CLOSE')
            # Attempt every independent handle; the first close error is sticky.
            failures = [self._retire(cap) for cap in
                        list(self._caps.values()) + list(self._provisional.values())]
            failures += [self._close_field(self, field, 0) for field in ('selffd', 'rootfd')]
            first = next((item for item in failures if item is not None), None)
            if first is not None:
                self._latch_close_failure(first)
                raise CustodyError('CUSTODY_CLOSE_FAILED', self._close_failure)
            self.closed = True
