#!/usr/bin/env python3
"""Owned Linux acceptance boundary. Importing this module runs no target code.

Only the explicit acceptance CLI may invoke the installer/installed bridge.
Safety fixtures use public ownership primitives with their own local children.
"""
import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import socket
import stat
import subprocess
import sys
import time
import shutil
import tarfile
import tomllib
from owned_acceptance_supervisor import identity, descendants, uncertainty_record
from owned_process_custody import Budget, CustodyError, EXIT_WAIT_LIMIT, OwnedDescendants, TreeLifetime

BASE_COMMIT = '172522c8a4065f80e813d6d4710b26b13b6094c7'
BASE_TREE = '4ebb37ac864d1a423eccfb6cdd838f1f94bbf21f'
PLUGIN_SHA = '7ffa8983e3bb2d9790f3122fd53db3e7adca4e24aed33f37aa4cc86bbeea5bb5'
SHARED_SHA = '0914069fb0cf83f258cf81034bb16573f6e4242e8779cea47b4a5e841f98a937'
MAX_FILE = 4 * 1024 * 1024
NOFOLLOW = os.O_NOFOLLOW
SOURCE_LOCK_SHA = '8856dfd3d5d8ae25a8f5a121accdc6734a0ae2ded670aef1e7e1462aa0b1df2a'
INSTALL_STAGES = ('node', 'fetch', 'piweb', 'clis', 'shared', 'paseo', 'omnigent', 'wire')


class Hold(RuntimeError):
    """An uncertain or failed safety check; only the bounded code is public."""


def require(condition, code):
    if not condition:
        raise Hold(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def stable_read(fd, maximum=MAX_FILE):
    before = os.fstat(fd)
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, 'NONREGULAR_OR_LINKED_FILE')
    require(before.st_size <= maximum, 'FILE_SIZE_BOUND')
    data = bytearray()
    while True:
        part = os.read(fd, min(65536, maximum + 1 - len(data)))
        if not part:
            break
        data.extend(part)
        require(len(data) <= maximum, 'FILE_SIZE_BOUND')
    after = os.fstat(fd)
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode, s.st_nlink)
    require(identity(before) == identity(after) and len(data) == after.st_size, 'CONCURRENT_FILE_CHANGE')
    return bytes(data), stat.S_IMODE(after.st_mode)


class Workspace:
    """Fresh 0700 root; all file access traverses no-follow directory descriptors."""
    @classmethod
    def create(cls, parent):
        parent = Path(parent)
        require(parent.is_absolute() and parent == parent.resolve(strict=True), 'PARENT_PATH')
        pfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
        try:
            st = os.fstat(pfd)
            require(st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) == 0o700, 'PARENT_NOT_PRIVATE')
            name = 'native-acceptance-' + secrets.token_hex(12)
            os.mkdir(name, 0o700, dir_fd=pfd)
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=pfd)
            os.fchmod(fd, 0o700)
            ws = cls(parent, name, pfd, fd)
            marker = json.dumps({'schema': 1, 'token': secrets.token_hex(32), 'uid': os.getuid(),
                                 'source': BASE_COMMIT}, sort_keys=True).encode()
            mfd = os.open('.owner.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(mfd, 'wb') as out:
                os.fchmod(out.fileno(), 0o600)
                out.write(marker)
            ws.marker = marker
            ws.guard()
            return ws
        except BaseException:
            os.close(pfd)
            raise

    def __init__(self, parent, name, pfd, fd):
        self.parent, self.name, self.pfd, self.fd = parent, name, pfd, fd
        self.root = parent / name
        self.identity = (os.fstat(fd).st_dev, os.fstat(fd).st_ino)
        self.parent_identity = (os.fstat(pfd).st_dev, os.fstat(pfd).st_ino)
        self.marker = b''
        self.closed = False

    def guard(self):
        try:
            parent = os.stat(self.parent, follow_symlinks=False)
            require(stat.S_ISDIR(parent.st_mode) and (parent.st_dev, parent.st_ino) == self.parent_identity
                    and self.parent.resolve(strict=True) == self.parent, 'PARENT_IDENTITY_CHANGED')
            s = os.stat(self.name, dir_fd=self.pfd, follow_symlinks=False)
            require(stat.S_ISDIR(s.st_mode) and (s.st_dev, s.st_ino) == self.identity
                    and s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) == 0o700, 'ROOT_IDENTITY_CHANGED')
            fd = os.open('.owner.json', os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=self.fd)
            with os.fdopen(fd, 'rb') as f:
                data, mode = stable_read(f.fileno(), 4096)
            require(data == self.marker and mode == 0o600, 'MARKER_CHANGED')
        except OSError as error:
            raise Hold('ROOT_OR_MARKER_UNREADABLE') from error

    @contextlib.contextmanager
    def parent_fd(self, relative, create=False):
        self.guard()
        require(isinstance(relative, str) and len(relative) <= 1024, 'PATH_BOUND')
        parts = relative.split('/')
        require(all(p not in ('', '.', '..') for p in parts) and not relative.startswith('/'), 'PATH_ESCAPE')
        require(parts[0] != '.owner.json', 'MARKER_RESERVED')
        fd = os.dup(self.fd)
        try:
            for part in parts[:-1]:
                if create:
                    try:
                        os.mkdir(part, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
                require(os.fstat(nxt).st_uid == os.getuid(), 'FOREIGN_DIRECTORY')
                os.close(fd)
                fd = nxt
            yield fd, parts[-1]
        except OSError as error:
            raise Hold('PATH_UNSAFE_OR_UNREADABLE') from error
        finally:
            os.close(fd)

    def mkdir(self, relative):
        with self.parent_fd(relative, create=True) as (fd, name):
            created = False
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
                created = True
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            try:
                if created:
                    os.fchmod(child, 0o700)
                s = os.fstat(child)
                require(s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) == 0o700, 'PRIVATE_DIRECTORY_MODE')
            finally:
                os.close(child)
        return self.root / relative

    def write_new(self, relative, data, mode=0o600):
        require(len(data) <= MAX_FILE, 'FILE_SIZE_BOUND')
        with self.parent_fd(relative, create=True) as (fd, name):
            try:
                out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, mode, dir_fd=fd)
            except OSError as error:
                raise Hold('FILE_COLLISION') from error
            with os.fdopen(out, 'wb') as f:
                os.fchmod(f.fileno(), mode)
                f.write(data)

    def read(self, relative):
        with self.parent_fd(relative) as (fd, name):
            child = os.open(name, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=fd)
            with os.fdopen(child, 'rb') as f:
                return stable_read(f.fileno())

    def replace(self, relative, expected, data):
        require(len(data) <= MAX_FILE, 'FILE_SIZE_BOUND')
        require(self.read(relative) == expected, 'STATE_CHANGED')
        with self.parent_fd(relative) as (fd, name):
            tmp = '.replace-' + secrets.token_hex(12)
            out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, expected[1], dir_fd=fd)
            try:
                with os.fdopen(out, 'wb') as f:
                    os.fchmod(f.fileno(), expected[1])
                    f.write(data)
                require(self.read(relative) == expected, 'STATE_CHANGED')
                os.replace(tmp, name, src_dir_fd=fd, dst_dir_fd=fd)
            finally:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(tmp, dir_fd=fd)

    def remove(self, max_entries=250000, seconds=30):
        """Bounded no-follow deletion. Marker is last; uncertainty retains the root."""
        self.guard()
        deadline = time.monotonic() + seconds
        entries = []

        def scan(fd, prefix='', depth=0):
            require(depth <= 64, 'CLEANUP_DEPTH_BOUND')
            with os.scandir(fd) as iterator:
                for entry in iterator:
                    require(len(entries) < max_entries and time.monotonic() < deadline, 'CLEANUP_BOUND')
                    if not prefix and entry.name == '.owner.json':
                        continue
                    s = entry.stat(follow_symlinks=False)
                    require(s.st_uid == os.getuid() and (stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode)
                            or stat.S_ISLNK(s.st_mode)), 'CLEANUP_UNKNOWN_ITEM')
                    rel = prefix + entry.name
                    entries.append((rel, s.st_dev, s.st_ino, stat.S_ISDIR(s.st_mode)))
                    if stat.S_ISDIR(s.st_mode):
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
                        try:
                            scan(child, rel + '/', depth + 1)
                        finally:
                            os.close(child)
        scan(self.fd)
        for rel, dev, ino, directory in reversed(entries):
            require(time.monotonic() < deadline, 'CLEANUP_BOUND')
            with self.parent_fd(rel) as (fd, name):
                s = os.stat(name, dir_fd=fd, follow_symlinks=False)
                require((s.st_dev, s.st_ino) == (dev, ino), 'CLEANUP_ITEM_CHANGED')
                (os.rmdir if directory else os.unlink)(name, dir_fd=fd)
        self.guard()
        os.unlink('.owner.json', dir_fd=self.fd)
        os.rmdir(self.name, dir_fd=self.pfd)

    def close(self, remove=False):
        if not self.closed:
            try:
                if remove:
                    self.remove()
            finally:
                os.close(self.fd)
                os.close(self.pfd)
                self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, kind, value, tb):
        self.close(remove=kind is None)


def child_environment(ws):
    """Nothing inherited: no credentials, proxies, session HOME, XDG or tool configs."""
    for relative in ('account', 'install', 'tmp', 'xdg/config', 'xdg/data', 'xdg/cache', 'xdg/state'):
        ws.mkdir(relative)
    env = {'HOME': str(ws.root / 'account'), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
           'TMPDIR': str(ws.root / 'tmp'), 'PI_AGENT_HOME': str(ws.root / 'install'),
           'PI_AGENT_DATA_DIR': str(ws.root / 'install/data'), 'PI_WEB_HOSTNAME': '127.0.0.1',
           'PI_AGENT_LINK_KEYCHAIN': '0', 'PI_TELEMETRY': '0', 'PI_SKIP_VERSION_CHECK': '1',
           'DISABLE_AUTOUPDATER': '1', 'NEXT_TELEMETRY_DISABLED': '1',
           'npm_config_cache': str(ws.root / 'xdg/cache/npm'), 'UV_CACHE_DIR': str(ws.root / 'xdg/cache/uv'),
           'UV_LINK_MODE': 'copy', 'PYTHONNOUSERSITE': '1', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
    for key in ('CONFIG', 'DATA', 'CACHE', 'STATE'):
        env['XDG_' + key + '_HOME'] = str(ws.root / ('xdg/' + key.lower()))
    return env


class OwnedProcess:
    """A fresh Linux session with a subreaper and bounded, private output."""
    def __init__(self, command, ws, env, *, maximum=2 * 1024 * 1024, cwd=None, on_spawn=None,
                 supervisor='owned-pgid', deadline=None, custody_budget=None):
        ws.guard()
        require(bool(command) and Path(command[0]).is_absolute(), 'COMMAND_NOT_ABSOLUTE')
        self.ws, self.maximum = ws, maximum
        require(supervisor in ('owned-pgid', 'owned-subreaper'), 'UNSUPPORTED_SUPERVISOR')
        self.supervisor = supervisor
        self.custody = None
        self.custody_budget = custody_budget or Budget(deadline if deadline is not None else time.monotonic() + 1800)
        self.lifetime = TreeLifetime(self.custody_budget.deadline)
        self.work_expired = False
        self.require_work()
        self.proof = None
        self.uncertainty = None
        self.total = 0
        self.buffers = {'out': bytearray(), 'err': bytearray(), 'control': bytearray()}
        self.selector = selectors.DefaultSelector()
        read, write = os.pipe()
        guardian = str(Path(__file__).with_name('owned_acceptance_supervisor.py'))
        cwd_fd = os.dup(ws.fd)
        if cwd is not None:
            with ws.parent_fd(cwd) as (fd, name):
                os.close(cwd_fd)
                cwd_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
        try:
            arguments = [sys.executable, '-I', '-S', '-B', guardian, str(write)]
            if supervisor == 'owned-subreaper':
                arguments += ['--supervisor', supervisor, '--deadline', str(self.custody_budget.deadline), '--']
            self.process = subprocess.Popen([*arguments, *map(str, command)],
                                            cwd='/proc/' + str(os.getpid()) + '/fd/' + str(cwd_fd), env=env, start_new_session=True,
                                            umask=0o022,
                                            pass_fds=(write,), stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if on_spawn is not None:
                on_spawn(self)  # Register before any subsequent identity/descriptor check can fail.
        finally:
            os.close(write)
            os.close(cwd_fd)
        self.proof = identity(self.process.pid)
        require(self.proof is not None and self.proof[2] == os.getuid()
                and self.proof[3:5] == (self.process.pid, self.process.pid), 'CHILD_IDENTITY')
        self.stopped = False
        self.control = os.fdopen(read, 'rb', buffering=0)
        for channel, stream in [('out', self.process.stdout), ('err', self.process.stderr), ('control', self.control)]:
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, channel)
        if supervisor == 'owned-subreaper':
            self.ensure_custody()

    def custody_call(self, function, *args, **kwargs):
        try:
            return function(*args, **kwargs)
        except CustodyError as error:
            expected_exit = error.custody_code == 'CUSTODY_ANCHOR_GONE' and self.guardian_exited()
            if error.custody_code not in ('LISTENER_MISSING', 'CUSTODY_DEADLINE') \
                    and not expected_exit and self.uncertainty is None:
                self.uncertainty = uncertainty_record(error, 'CUSTODY')
            raise Hold(error.custody_code) from error

    def guardian_exited(self):
        """After a proved CUSTODY_ANCHOR_GONE (same held PIDfd ready, or the same
        guardian birth exiting with PF_EXITING), wait only for this exact Popen,
        at most min(EXIT_WAIT_LIMIT, the tree's current cutoff). Not exited by
        then stays sticky uncertainty; the final treeEmpty proof is still needed."""
        if self.process.poll() is None:
            cutoff = self.lifetime.teardown_deadline
            cutoff = self.lifetime.work_deadline if cutoff is None else cutoff
            try:
                self.process.wait(max(0.0, min(EXIT_WAIT_LIMIT, cutoff - time.monotonic())))
            except subprocess.TimeoutExpired:
                pass
        return self.process.poll() is not None

    def ensure_custody(self):
        if self.custody is None:
            self.custody = self._new_custody()
        return self.custody

    def _new_custody(self):
        return self.custody_call(OwnedDescendants, self.proof, budget=self.custody_budget,
                                 strict=self.supervisor == 'owned-pgid', lifetime=self.lifetime)

    def require_work(self):
        require(not self.work_expired, 'COMMAND_DEADLINE')
        try:
            self.lifetime.require_work()
        except CustodyError as error:
            raise Hold('COMMAND_DEADLINE' if error.custody_code == 'CUSTODY_DEADLINE'
                       else error.custody_code) from error

    def validate(self):
        self.ws.guard()
        observed = identity(self.process.pid)
        require(observed is not None and observed[:5] == self.proof[:5], 'PID_IDENTITY_CHANGED')
        self.check_control()

    def check_control(self):
        """Fail promptly on a complete bounded guardian record, not child output."""
        require(len(self.buffers['control']) <= 8192, 'CONTROL_BOUND')
        for line in self.buffers['control'].splitlines(keepends=True):
            if not line.endswith(b'\n'):
                continue
            try:
                record = json.loads(line)
            except (ValueError, UnicodeError) as error:
                raise Hold('CONTROL_INVALID') from error
            require(isinstance(record, dict), 'CONTROL_INVALID')
            if 'workExpired' in record:
                require(set(record) == {'workExpired'} and record['workExpired'] is True, 'CONTROL_INVALID')
                self.work_expired = True
            if 'uncertain' in record:
                require(set(record) <= {'uncertain', 'errno', 'identityCounts'}
                        and isinstance(record['uncertain'], str)
                        and re.fullmatch(r'[A-Z_]{1,64}', record['uncertain'])
                        and (record.get('errno') is None or
                             type(record['errno']) is int and 0 < record['errno'] <= 4095),
                        'CONTROL_INVALID')
                counts = record.get('identityCounts')
                require(counts is None or (record['uncertain'] == 'CUSTODY_IDENTITY_BOUND'
                        and type(counts) is dict and set(counts) == {'pid', 'task', 'pinned', 'unique', 'limit'}
                        and all(type(n) is int and 0 <= n <= 8192 for n in counts.values())),
                        'CONTROL_INVALID')
                if self.uncertainty is None:
                    self.uncertainty = record
        require(self.uncertainty is None, 'CHILD_TREE_UNCERTAIN')

    def pump(self, seconds=0.02):
        for key, _ in self.selector.select(seconds):
            data = os.read(key.fd, 65536)
            if not data:
                self.selector.unregister(key.fileobj)
            else:
                self.buffers[key.data].extend(data)
                self.total += len(data)
        self.check_control()
        require(self.total <= self.maximum, 'COMMAND_OUTPUT_BOUND')

    def prove_empty(self):
        for _ in range(4):
            for key, _ in self.selector.select(0):
                data = os.read(key.fd, 65536)
                if not data:
                    self.selector.unregister(key.fileobj)
                elif key.data == 'control':
                    self.buffers['control'].extend(data)
        require(len(self.buffers['control']) <= 8192, 'CONTROL_BOUND')
        self.check_control()
        records = [json.loads(line) for line in self.buffers['control'].splitlines()]
        require(records and records[-1] == {'treeEmpty': True}, 'TEARDOWN_UNCERTAIN')

    def line(self, seconds):
        self.require_work()
        deadline = min(time.monotonic() + seconds, self.custody_budget.deadline)
        while b'\n' not in self.buffers['out']:
            require(time.monotonic() < deadline, 'COMMAND_DEADLINE')
            self.pump()
            self.require_work()
            require(self.process.poll() is None or self.buffers['out'], 'COMMAND_EARLY_EXIT')
        raw, _, rest = self.buffers['out'].partition(b'\n')
        self.buffers['out'][:] = rest
        return raw.decode()

    def wait(self, seconds):
        self.require_work()
        deadline = min(time.monotonic() + seconds, self.custody_budget.deadline)
        while self.process.poll() is None:
            require(time.monotonic() < deadline, 'COMMAND_DEADLINE')
            self.pump()
            self.require_work()
        for _ in range(4):
            self.pump(0)
        self.prove_empty()
        self.require_work()
        self.stopped = True
        require(self.process.returncode == 0, 'COMMAND_FAILED')
        return bytes(self.buffers['out'])

    def members(self):
        self.validate()
        if self.supervisor == 'owned-subreaper':
            return self.custody_call(self.ensure_custody().refresh)
        result = []
        for pid in [self.process.pid, *descendants(self.process.pid)]:
            p = identity(pid)
            if p is None:
                continue
            require(p[2:5] == self.proof[2:5], 'DESCENDANT_ESCAPED')
            result.append(p)
        self.validate()
        return result

    def stop(self, seconds=3):
        if self.stopped:
            self.close_pipes()
            return
        if self.lifetime.teardown_deadline is None and time.monotonic() >= self.lifetime.work_deadline:
            self.work_expired = True
        deadline = self.lifetime.begin_teardown(seconds)
        # A completed subreaper has already reaped its entire tree.
        if self.process.poll() is not None:
            self.prove_empty()
            self.stopped = True
            self.close_pipes()
            return
        try:
            require(time.monotonic() < deadline, 'TEARDOWN_UNCERTAIN')
            self.validate()
            self.members()
            # The per-tree cleanup lifetime cannot authorize new target work.
            if self.supervisor == 'owned-subreaper':
                self.custody_call(self.ensure_custody().signal_anchor, signal.SIGTERM)
            else:
                pidfd = os.pidfd_open(self.proof[0])
                try:
                    self.validate()
                    require(time.monotonic() < deadline, 'TEARDOWN_UNCERTAIN')
                    signal.pidfd_send_signal(pidfd, signal.SIGTERM)
                finally:
                    os.close(pidfd)
        except Hold as error:
            if str(error) not in ('PID_IDENTITY_CHANGED', 'CUSTODY_ANCHOR_GONE') \
                    or self.process.poll() is None:
                raise
        while self.process.poll() is None:
            require(time.monotonic() < deadline, 'TEARDOWN_UNCERTAIN')
            # Continue draining without allowing an output failure to hide teardown.
            for key, _ in self.selector.select(0.02):
                data = os.read(key.fd, 65536)
                if not data:
                    self.selector.unregister(key.fileobj)
                elif key.data == 'control':
                    self.buffers['control'].extend(data)
            if self.process.poll() is None:
                try:
                    self.validate()
                except Hold as error:
                    # Exit can occur between poll and identity. Only the real
                    # Popen exit plus final treeEmpty below resolves that race.
                    if str(error) != 'PID_IDENTITY_CHANGED' or self.process.poll() is None:
                        raise
        self.prove_empty()
        self.stopped = True
        self.close_pipes()

    def close_pipes(self):
        self.lifetime.begin_teardown()
        if self.custody is not None and not self.custody.closed:
            self.custody_call(self.custody.close)
        self.selector.close()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr, self.control):
            stream.close()


def run_command(command, ws, env, seconds=600, maximum=2 * 1024 * 1024):
    process = OwnedProcess(command, ws, env, maximum=maximum)
    try:
        return process.wait(seconds)
    finally:
        process.stop()


class Endpoint:
    """No HTTP until the selected IPv4 loopback listener belongs to this tree."""
    def __init__(self, process, port):
        require(isinstance(port, int) and 1024 <= port <= 65535, 'PORT_BOUND')
        self.process, self.port = process, port

    def verify(self):
        self.process.require_work()
        if self.process.supervisor == 'owned-subreaper':
            self.process.validate()
            self.process.custody_call(self.process.ensure_custody().verify_listener, self.port)
            return
        members = self.process.members()
        sockets = set()
        for proof in members:
            try:
                with os.scandir('/proc/' + str(proof[0]) + '/fd') as fds:
                    count = 0
                    for fd in fds:
                        count += 1
                        require(count <= 4096, 'FD_BOUND')
                        try:
                            target = os.readlink(fd.path)
                        except FileNotFoundError:
                            continue
                        match = re.fullmatch(r'socket:\[(\d+)\]', target)
                        if match:
                            sockets.add(match[1])
            except FileNotFoundError:
                continue
        matching = []
        # Only selected loopback/port records are used or retained. No process sweep.
        with open('/proc/' + str(self.process.process.pid) + '/net/tcp') as table:
            size = 0
            while True:
                line = table.readline(4097)
                if not line:
                    break
                require(len(line) <= 4096, 'SOCKET_RECORD_BOUND')
                size += len(line)
                require(size <= 4 * 1024 * 1024, 'SOCKET_TABLE_BOUND')
                fields = line.split()
                if len(fields) > 9 and fields[1] == '0100007F:' + format(self.port, '04X') and fields[3] == '0A':
                    matching.append(fields)
        require(matching, 'LISTENER_MISSING')
        require(len(matching) == 1 and matching[0][9] in sockets
                and int(matching[0][7]) == os.getuid(), 'LISTENER_NOT_OWNED')
        self.process.validate()

    def get(self, route, seconds=3):
        require(re.fullmatch(r'/[A-Za-z0-9/_-]*', route) and len(route) <= 128, 'HTTP_ROUTE')
        require(0 < seconds <= 3, 'HTTP_DEADLINE_BOUND')
        self.verify()
        deadline = min(time.monotonic() + seconds, self.process.custody_budget.deadline)
        # A wall deadline applies even to a slow peer that trickles bytes before
        # each socket timeout. Parse HTTP only after bounded transport completes.
        try:
            connection = self.process.ensure_custody().connect_owned(self.port, deadline)
            with connection as conn:
                return self._response(conn, route, deadline)
        except CustodyError as error:
            raise Hold(error.custody_code) from error

    def _response(self, conn, route, deadline):
        import io
        self.process.require_work()
        wire = bytearray()
        conn.settimeout(max(0.001, deadline - time.monotonic()))
        conn.sendall(('GET ' + route + ' HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n').encode())
        conn.setblocking(False)
        with selectors.DefaultSelector() as selector:
            selector.register(conn, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0 and selector.select(remaining), 'HTTP_DEADLINE')
                block = conn.recv(8192)
                if not block:
                    break
                wire.extend(block)
                require(len(wire) <= 131072, 'HTTP_WIRE_BOUND')
        class MemorySocket:
            def makefile(self, mode):
                return io.BytesIO(wire)
        response = http.client.HTTPResponse(MemorySocket())
        try:
            response.begin()
            body = response.read(65537)
            require(response.status == 200 and len(body) <= 65536, 'HTTP_RESPONSE')
        finally:
            response.close()
        return body


def source_file(root, relative, maximum=MAX_FILE):
    require(Path(root).is_absolute() and Path(root).resolve(strict=True) == Path(root), 'SOURCE_ROOT_PATH')
    parts = relative.split('/')
    require(all(p not in ('', '.', '..') for p in parts), 'SOURCE_PATH')
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
    try:
        for part in parts[:-1]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        child = os.open(parts[-1], os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=fd)
        with os.fdopen(child, 'rb') as stream:
            return stable_read(stream.fileno(), maximum)
    except OSError as error:
        raise Hold('SOURCE_PATH_UNSAFE') from error
    finally:
        os.close(fd)


def verify_source(root):
    raw, _ = source_file(root, 'tests/owned-native-acceptance.lock.json')
    require(digest(raw) == SOURCE_LOCK_SHA, 'SOURCE_LOCK_DRIFT')
    lock = json.loads(raw)
    require(lock['baseCommit'] == BASE_COMMIT and lock['baseTree'] == BASE_TREE
            and lock['pluginSha256'] == PLUGIN_SHA and lock['sharedSha256'] == SHARED_SHA, 'SOURCE_LOCK_IDENTITY')
    total = 0
    require(1 <= len(lock['files']) <= 128, 'SOURCE_COUNT_BOUND')
    for entry in lock['files']:
        data, mode = source_file(root, entry['path'])
        total += len(data)
        require(total <= 16 * 1024 * 1024, 'SOURCE_BYTES_BOUND')
        require(len(data) == entry['bytes'] and mode == entry['mode'] and digest(data) == entry['sha256'],
                'SOURCE_INPUT_DRIFT')
    return lock


def platform_evidence(platform, release_text, kernel, supervisor):
    require(platform in ('ubuntu', 'wsl2') and supervisor in ('owned-pgid', 'owned-subreaper'), 'UNSUPPORTED_PLATFORM_OR_SUPERVISOR')
    release = dict(line.split('=', 1) for line in release_text.splitlines() if '=' in line)
    require(release.get('ID', '').strip('"') == 'ubuntu', 'UBUNTU_REQUIRED')
    wsl = 'microsoft-standard-wsl2' in kernel.lower()
    require(wsl if platform == 'wsl2' else 'microsoft' not in kernel.lower(), 'PLATFORM_MISMATCH')
    return {'requested': platform, 'ubuntuVersion': release.get('VERSION_ID', '').strip('"'),
            'kernel': kernel, 'wsl2KernelObserved': wsl, 'supervisor': supervisor,
            'persistentServiceTested': False, 'rebootTested': False}


def prerequisites():
    # Pure path checks; never apt/sudo/install preflight or probe provider CLIs.
    for name in ('bash', 'curl', 'git', 'gpg', 'jq', 'ssh', 'xz', 'python3', 'flock', 'tmux'):
        require(shutil.which(name, path='/usr/bin:/bin') is not None, 'PREREQUISITE_MISSING_' + name.upper())
    require(hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'), 'PIDFD_REQUIRED')


class Rpc:
    """Bounded MCP stdio client; command selection is the caller's fixed pipeline."""
    def __init__(self, process, seconds=30):
        self.process, self.seconds, self.next_id = process, seconds, 0
        self.deadline = time.monotonic() + seconds
        os.set_blocking(process.process.stdin.fileno(), False)

    def send(self, obj):
        data = json.dumps(obj, separators=(',', ':')).encode() + b'\n'
        require(len(data) <= 8192, 'RPC_REQUEST_BOUND')
        deadline = self.deadline
        while data:
            require(time.monotonic() < deadline, 'RPC_WRITE_DEADLINE')
            try:
                count = os.write(self.process.process.stdin.fileno(), data)
                data = data[count:]
            except BlockingIOError:
                self.process.pump()

    def request(self, method, params):
        self.next_id += 1
        self.send({'jsonrpc': '2.0', 'id': self.next_id, 'method': method, 'params': params})
        deadline = self.deadline
        for _ in range(64):
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'RPC_DEADLINE')
            value = json.loads(self.process.line(remaining))
            require(value.get('jsonrpc') == '2.0', 'RPC_PROTOCOL')
            if 'id' not in value:
                continue
            require(value['id'] == self.next_id and 'result' in value and 'error' not in value, 'RPC_REFUSED')
            return value['result']
        raise Hold('RPC_MESSAGE_BOUND')

    def initialize(self, expected_name='pi-agent-shared-runtime'):
        result = self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                              'clientInfo': {'name': 'owned-native-acceptance', 'version': '1'}})
        require(result.get('protocolVersion') in ('2024-11-05', '2025-03-26', '2025-06-18'), 'RPC_VERSION')
        require(result.get('serverInfo', {}).get('name') == expected_name, 'RPC_SERVER_IDENTITY')
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def tool(self, name, arguments=None):
        result = self.request('tools/call', {'name': name, 'arguments': arguments or {}})
        require(result.get('isError', False) is False, 'BRIDGE_TOOL_REFUSED')
        text = [c['text'] for c in result.get('content', []) if c.get('type') == 'text']
        require(len(text) == 1, 'BRIDGE_CONTENT')
        return text[0]


class Sentinels:
    """Unrelated synthetic files are byte/mode exact; mutable maps are semantic."""
    def __init__(self, ws):
        self.ws = ws
        self.tag = 'owned_' + secrets.token_hex(8)
        self.files = {}

    def seed(self):
        for relative, mode in [('install/data/unrelated.bin', 0o640),
                               ('install/home/.claude/unrelated.bin', 0o600),
                               ('install/home/.codex/unrelated.bin', 0o640),
                               ('install/data/skills/' + self.tag + '_keep/SKILL.md', 0o640)]:
            data = (('---\nname: ' + self.tag + '_keep\ndescription: unrelated sentinel\n---\n')
                    if relative.endswith('SKILL.md') else 'unrelated\x00' + self.tag).encode()
            self.ws.write_new(relative, data, mode)
            self.files[relative] = (data, mode)

    def check(self):
        for relative, expected in self.files.items():
            require(self.ws.read(relative) == expected, 'UNRELATED_SENTINEL_CHANGED')


def check_provider_bridges(ws, node, bundle, keep):
    claude_raw, cmode = ws.read('install/home/.claude.json')
    codex_raw, tmode = ws.read('install/home/.codex/config.toml')
    claude, codex = json.loads(claude_raw), tomllib.loads(codex_raw.decode())
    require(cmode == 0o600 and tmode == 0o600, 'PROVIDER_CONFIG_MODE')
    require(claude.get('ownedSentinel') == keep and codex.get('owned_sentinel') == keep, 'PROVIDER_SENTINEL_CHANGED')
    for entry in (claude.get('mcpServers', {}).get('pi_shared_runtime'), codex.get('mcp_servers', {}).get('pi_shared_runtime')):
        require(isinstance(entry, dict) and entry.get('command') == str(node)
                and entry.get('args') == [str(bundle / 'bin/bridge.mjs')], 'PROVIDER_BRIDGE_BINDING')
        env = entry.get('env', {})
        require(env == {'PI_SHARED_DATA_DIR': str(ws.root / 'install/data'),
                        'PI_SHARED_HOME': str(ws.root / 'install/home'), 'PI_SHARED_BRIDGE': '1'}, 'PROVIDER_BRIDGE_ENV')


def check_sync(ws, previous):
    raw, _ = ws.read('install/data/shared-runtime/last-sync.json')
    require(raw != previous, 'SYNC_DID_NOT_ADVANCE')
    report = json.loads(raw)
    servers = json.loads(ws.read('install/data/mcp.json')[0])['mcpServers']
    require(report.get('conflicts') == [] and set(report.get('mcpNames', [])) == set(servers)
            and 'pi_shared_memory' in servers and report.get('claudeHash') and report.get('codexHash'), 'SYNC_REFUSED')
    return raw


class OwnedRun:
    """Public lifecycle seam shared by future acceptance and synthetic safety tests."""
    def __init__(self, parent, *, scope, seconds=1800, supervisor='owned-pgid'):
        require(scope in ('safety-fixture', 'owned-platform-scenario'), 'RUN_SCOPE')
        require(supervisor in ('owned-pgid', 'owned-subreaper'), 'UNSUPPORTED_SUPERVISOR')
        self.ws = Workspace.create(parent)
        self.env = child_environment(self.ws)
        self.scope = scope
        self.deadline = time.monotonic() + seconds
        self.supervisor = supervisor
        self.custody_budget = Budget(self.deadline)
        self.processes = []
        self.receipt = {'schema': 1, 'scope': scope, 'status': 'RUNNING', 'checks': [],
                        'baseSourceReference': BASE_COMMIT, 'baseTreeReference': BASE_TREE,
                        'sourceLockSha256': SOURCE_LOCK_SHA, 'pluginSha256': PLUGIN_SHA,
                        'realUbuntuAcceptance': False, 'realWSL2Acceptance': False,
                        'providerAcceptance': False, 'rebootAcceptance': False,
                        'persistentServiceTested': False, 'supervisor': supervisor,
                        'providerTurns': 0, 'modelCredentialsAdopted': False}

    def remaining(self, maximum):
        result = min(maximum, self.deadline - time.monotonic())
        require(result > 0, 'RUN_DEADLINE')
        return result

    def spawn(self, command, *, env=None, cwd=None):
        self.remaining(1)
        require(len(self.processes) < 32, 'COMMAND_COUNT_BOUND')
        process = OwnedProcess(command, self.ws, self.env if env is None else env, cwd=cwd,
                               on_spawn=self.processes.append, supervisor=self.supervisor,
                               custody_budget=self.custody_budget)
        return process

    def command(self, command, *, seconds=600, env=None):
        process = self.spawn(command, env=env)
        try:
            return process.wait(self.remaining(seconds))
        finally:
            process.stop()

    def finish(self, failure=None):
        uncertain = []
        for process in reversed(self.processes):
            try:
                process.stop()
            except BaseException:
                proof = process.proof or (process.process.pid, None, None, None, None)
                entry = {'pid': proof[0], 'birthTicks': proof[1],
                         'uid': proof[2], 'pgid': proof[3], 'session': proof[4]}
                if process.uncertainty is not None:
                    entry['firstUncertainty'] = dict(process.uncertainty)
                uncertain.append(entry)
        if failure is None and any(process.work_expired for process in self.processes):
            failure = Hold('COMMAND_DEADLINE')
        self.receipt['teardownVerified'] = not uncertain
        self.receipt['uncertainProcesses'] = uncertain
        self.receipt['status'] = ('HOLD' if failure or uncertain else
                                 'SAFETY_FIXTURE_COMPLETED' if self.scope == 'safety-fixture' else 'OWNED_SCENARIO_COMPLETED')
        if failure:
            self.receipt['failure'] = str(failure) if isinstance(failure, Hold) else type(failure).__name__
        if not uncertain:
            try:
                self.ws.close(remove=not failure)
            except BaseException:
                self.receipt['status'] = 'HOLD'
                self.receipt['filesystemCleanup'] = 'UNCERTAIN'
        self.receipt['privateRootRetained'] = self.ws.root.exists()
        if self.receipt['privateRootRetained']:
            self.receipt['privateRoot'] = str(self.ws.root)
        return self.receipt


def archive_bindings(run, source):
    """Bind every package member, including exact native source overlays."""
    lock = verify_source(source)
    for package, destination, expected in [
            ('woowtech-pi-agent-shared-runtime-0.1.6.tgz', 'install/shared-runtime', SHARED_SHA),
            ('woowtech-pi-omnigent-plugin-0.3.42.tgz', 'install/plugins/pi-omnigent-plugin', PLUGIN_SHA)]:
        raw, _ = source_file(source, 'candidate-packages/' + package)
        require(digest(raw) == expected, 'ARCHIVE_DRIFT')
        import io
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
            count = total = 0
            for member in archive:
                count += 1
                require(count <= 128 and member.name.startswith('package/'), 'ARCHIVE_MEMBER_BOUND')
                if member.isdir():
                    continue
                relative = member.name.removeprefix('package/')
                require(member.isfile() and '..' not in relative.split('/') and not relative.startswith('/'), 'ARCHIVE_PATH')
                total += member.size
                require(total <= 4 * 1024 * 1024, 'ARCHIVE_SIZE_BOUND')
                actual, mode = run.ws.read(destination + '/' + relative)
                if 'plugin' in package:
                    expected = lock['installedLinuxPluginMembers'].get(relative)
                    require(expected and digest(actual) == expected['sha256'] and len(actual) == expected['bytes']
                            and mode == expected['mode'], 'INSTALLED_PLUGIN_OVERLAY_DRIFT')
                else:
                    require(actual == archive.extractfile(member).read(), 'INSTALLED_PACKAGE_DRIFT')


ECHO_SOURCE = r'''import json, sys
while True:
 line=sys.stdin.readline(8193)
 if not line: break
 if len(line) > 8192: raise SystemExit(2)
 r=json.loads(line)
 if "id" not in r: continue
 method=r.get("method")
 if method=="initialize":
  result={"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"owned-local-echo","version":"1"}}
 elif method=="tools/list":
  result={"tools":[{"name":"readonly_echo","description":"owned acceptance echo", "inputSchema":{"type":"object","properties":{"marker":{"type":"string"}},"required":["marker"]}}]}
 elif method=="tools/call":
  result={"content":[{"type":"text","text":"OWNED_ECHO:"+r["params"]["arguments"]["marker"]}]}
 else: raise SystemExit(3)
 print(json.dumps({"jsonrpc":"2.0","id":r["id"],"result":result}),flush=True)
'''


class SharingScenario:
    def __init__(self, run):
        self.run, self.ws = run, run.ws
        self.sentinels = Sentinels(self.ws)
        self.sentinels.seed()
        self.tag = self.sentinels.tag
        self.node = self.ws.root / 'install/node/bin/node'
        self.bundle = self.ws.root / 'install/shared-runtime'
        self.data = 'install/data/mcp.json'
        self.ws.write_new('echo.py', ECHO_SOURCE.encode())
        self.entry = {'command': '/usr/bin/python3', 'args': ['-I', '-S', '-B', str(self.ws.root / 'echo.py')]}
        self.keep_name, self.test_name = self.tag + '_keep', self.tag + '_test'
        self.ws.write_new(self.data, json.dumps({'mcpServers': {self.keep_name: self.entry}}).encode())
        self.ws.write_new('install/home/.claude.json', json.dumps({'ownedSentinel': self.tag}).encode())
        self.ws.write_new('install/home/.codex/config.toml',
                          ('# unrelated owned sentinel\nowned_sentinel = ' + json.dumps(self.tag) + '\n').encode())
        self.skill = 'install/data/skills/' + self.test_name + '/SKILL.md'

    def synchronize(self):
        try:
            previous = self.ws.read('install/data/shared-runtime/last-sync.json')[0]
        except Hold as error:
            if not isinstance(error.__cause__, FileNotFoundError):
                raise
            previous = None
        env = self.run.env.copy()
        env.update({'HOME': str(self.ws.root / 'install/home'), 'PATH': str(self.node.parent) + ':/usr/bin:/bin',
                    'PI_SHARED_RUNTIME_BUNDLE_DIR': str(self.bundle), 'PI_SHARED_DATA_DIR': str(self.ws.root / 'install/data'),
                    'PI_CODING_AGENT_DIR': str(self.ws.root / 'install/data'),
                    'PI_SHARED_SDK_ROOT': str(self.ws.root / 'install/piweb/lib/node_modules/@agegr/pi-web')})
        self.run.command([str(self.node), str(self.ws.root / 'install/bin/pi-agent-share-state.mjs')], env=env, seconds=90)
        check_sync(self.ws, previous)
        check_provider_bridges(self.ws, self.node, self.bundle, self.tag)
        self.sentinels.check()
        require(json.loads(self.ws.read(self.data)[0])['mcpServers'].get(self.keep_name) == self.entry, 'MCP_SENTINEL_CHANGED')
        return env

    def bridge(self, present):
        env = self.synchronize()
        process = self.run.spawn([str(self.node), str(self.bundle / 'bin/bridge.mjs')], env=env, cwd='install/home')
        try:
            rpc = Rpc(process, self.run.remaining(30))
            rpc.initialize()
            status = json.loads(rpc.tool('pi_shared_status'))
            require(status.get('runtimeErrors') == [] and self.keep_name in status.get('mcp', []), 'BRIDGE_STATUS')
            require((self.test_name in status.get('mcp', [])) == present
                    and (self.test_name in status.get('skills', [])) == present, 'BRIDGE_RESOURCE_COVERAGE')
            if present:
                require(self.tag in rpc.tool('Skill', {'skill': self.test_name}), 'BRIDGE_SKILL')
                rpc.tool('pi_global_mcp', {'connect': self.test_name})
                value = rpc.tool('pi_global_mcp', {'tool': self.test_name + '_readonly_echo', 'args': {'marker': self.tag}})
                require('OWNED_ECHO:' + self.tag in value, 'BRIDGE_ECHO')
        finally:
            process.stop()
        self.sentinels.check()

    def add(self):
        self.ws.write_new(self.skill, ('---\nname: ' + self.test_name + '\ndescription: owned acceptance\n---\n' + self.tag).encode())
        before = self.ws.read(self.data)
        value = json.loads(before[0])
        require(self.test_name not in value['mcpServers'], 'FIXTURE_NAME_COLLISION')
        value['mcpServers'][self.test_name] = self.entry
        self.ws.replace(self.data, before, json.dumps(value).encode())

    def remove(self):
        before = self.ws.read(self.data)
        value = json.loads(before[0])
        require(value['mcpServers'].pop(self.test_name, None) == self.entry, 'FIXTURE_CHANGED')
        self.ws.replace(self.data, before, json.dumps(value).encode())
        with self.ws.parent_fd(self.skill) as (fd, name):
            os.unlink(name, dir_fd=fd)
        self.sentinels.check()


def reserve_port(port=0):
    reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        reservation.bind(('127.0.0.1', port))
        require(reservation.getsockname()[1] >= 1024, 'PORT_BOUND')
        return reservation
    except OSError as error:
        reservation.close()
        raise Hold('PORT_COLLISION') from error


def copy_artifact(run, artifact, expected):
    require(re.fullmatch('[0-9a-f]{64}', expected or '') is not None, 'ARTIFACT_HASH_REQUIRED')
    artifact = Path(artifact)
    require(artifact.is_absolute() and artifact.resolve(strict=True) == artifact, 'ARTIFACT_PATH')
    source = os.open(artifact, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW)
    dest = run.ws.root / 'piweb-artifact.tar.gz'
    with os.fdopen(source, 'rb') as inp:
        before = os.fstat(inp.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= 512 * 1024 * 1024,
                'ARTIFACT_BOUND')
        hasher, count = hashlib.sha256(), 0
        with run.ws.parent_fd('piweb-artifact.tar.gz') as (fd, name):
            output = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(output, 'wb') as out:
            os.fchmod(out.fileno(), 0o600)
            while True:
                run.remaining(1)
                block = inp.read(65536)
                if not block:
                    break
                count += len(block)
                require(count <= 512 * 1024 * 1024, 'ARTIFACT_BOUND')
                out.write(block)
                hasher.update(block)
        after = os.fstat(inp.fileno())
    fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_nlink)
    require(fields(before) == fields(after) and count == before.st_size, 'ARTIFACT_CHANGED')
    require(hasher.hexdigest() == expected, 'ARTIFACT_HASH_MISMATCH')
    run.receipt['piwebArtifactSha256'] = expected
    validate_artifact_archive(dest, run.remaining(30))
    return dest


def validate_artifact_archive(path, seconds=30):
    """Preflight before the locked installer's tar extraction; no escape links/types."""
    import gzip
    deadline = time.monotonic() + seconds
    names, links, files, total = set(), {}, set(), 0
    class MetadataReader:
        def __init__(self, stream):
            self.stream = stream

        def check(self):
            require(time.monotonic() < deadline, 'ARTIFACT_ENUMERATION_BOUND')
            require(self.stream.tell() <= 4 * 1024 * 1024 * 1024, 'ARTIFACT_EXPANSION_BOUND')

        def read(self, size):
            self.check()
            require(0 <= size <= 1024 * 1024, 'ARTIFACT_METADATA_BOUND')
            data = self.stream.read(size)
            self.check()
            return data

        def tell(self):
            return self.stream.tell()

        def seek(self, offset, whence=0):
            require(whence in (0, 1), 'ARTIFACT_SEEK')
            target = offset if whence == 0 else self.tell() + offset
            require(0 <= target <= 4 * 1024 * 1024 * 1024, 'ARTIFACT_EXPANSION_BOUND')
            result = self.stream.seek(target)
            self.check()
            return result

    with gzip.open(path, 'rb') as stream, tarfile.open(fileobj=MetadataReader(stream), mode='r:') as archive:
        for member in archive:
            require(time.monotonic() < deadline and len(names) < 250000, 'ARTIFACT_ENUMERATION_BOUND')
            name = member.name.removeprefix('./').rstrip('/')
            if name in ('', '.') and member.isdir():
                continue
            require(name and len(name) <= 1024 and not name.startswith('/') and '\\' not in name
                    and all(p not in ('', '.', '..') for p in name.split('/')) and name not in names, 'ARTIFACT_MEMBER_PATH')
            require(member.isfile() or member.isdir() or member.issym(), 'ARTIFACT_MEMBER_TYPE')
            require(not member.mode & 0o7000, 'ARTIFACT_SPECIAL_MODE')
            names.add(name)
            if member.isfile():
                files.add(name)
            total += member.size
            require(0 <= member.size <= 512 * 1024 * 1024 and total <= 4 * 1024 * 1024 * 1024, 'ARTIFACT_EXPANSION_BOUND')
            if member.issym():
                require(member.linkname and len(member.linkname) <= 1024 and not member.linkname.startswith('/')
                        and '\\' not in member.linkname, 'ARTIFACT_LINK_ESCAPE')
                links[name] = member.linkname
        for name in names:
            require(time.monotonic() < deadline, 'ARTIFACT_ENUMERATION_BOUND')
            parts = name.split('/')
            require(not any('/'.join(parts[:i]) in links for i in range(1, len(parts))), 'ARTIFACT_LINK_PARENT')
        resolve_archive_links(links, files, deadline)
    require(names, 'ARTIFACT_EMPTY')


def resolve_archive_links(links, files, deadline):
    """Expand the complete graph before applying '..'; never lexical-normalize it.

    All resolutions share the archive deadline, one million component steps and
    16384 link expansions. A resolution may nest at most 64 links. Targets can
    refer forward in tar order; no file or symlink is created during inspection.
    """
    steps = hops = 0

    def walk(parts, stack, active):
        nonlocal steps, hops
        stack = list(stack)
        for part in parts:
            steps += 1
            require(time.monotonic() < deadline, 'ARTIFACT_ENUMERATION_BOUND')
            require(steps <= 1000000, 'ARTIFACT_LINK_COMPONENT_BOUND')
            require('/'.join(stack) not in files, 'ARTIFACT_LINK_NON_DIRECTORY')
            if part in ('', '.'):
                continue
            if part == '..':
                require(stack, 'ARTIFACT_LINK_ESCAPE')
                stack.pop()
                continue
            candidate = '/'.join([*stack, part])
            if candidate in links:
                hops += 1
                require(hops <= 16384 and len(active) < 64, 'ARTIFACT_LINK_HOP_BOUND')
                require(candidate not in active, 'ARTIFACT_LINK_CYCLE')
                stack = walk(links[candidate].split('/'), stack, active | {candidate})
            else:
                stack.append(part)
        return stack

    for name in links:
        require(walk(name.split('/'), [], set()), 'ARTIFACT_LINK_ESCAPE')


def installed_web(run, port):
    process = run.spawn(['/bin/bash', str(run.ws.root / 'install/bin/pi-web-start.sh')])
    endpoint = Endpoint(process, port)
    deadline = time.monotonic() + run.remaining(90)
    while True:
        process.pump()
        try:
            endpoint.verify()
            break
        except Hold as error:
            require(str(error) == 'LISTENER_MISSING', str(error))
        require(process.process.poll() is None, 'WEB_EARLY_EXIT')
        require(time.monotonic() < deadline, 'WEB_START_DEADLINE')
        time.sleep(0.05)
    for route in ('/', '/api/home', '/omnigent'):
        endpoint.get(route)
    plugin = json.loads(endpoint.get('/api/omnigent'))
    require(plugin.get('active') is True and plugin.get('version') == '0.3.42', 'PLUGIN_HTTP_IDENTITY')
    run.receipt['checks'].append('owned-http-plugin-0.3.42')
    return process


def stage_source(run, source):
    lock = verify_source(source)
    run.receipt['sourceInputCount'] = len(lock['files'])
    # Copy only locked inputs into the private run; execute neither a drifting
    # checkout nor an ambient source/plugin directory.
    for entry in lock['files']:
        data, mode = source_file(source, entry['path'])
        require(digest(data) == entry['sha256'], 'SOURCE_INPUT_DRIFT')
        run.ws.write_new('source/' + entry['path'], data, mode)
    return lock


def finalize_installed_sources(run, source):
    # Session-home is normally installed by the first web start. Validate only
    # after explicitly applying every exact locked Linux overlay, before any web
    # or SDK can load the module. No patch success message substitutes for hashes.
    lock = verify_source(source)
    node = run.ws.root / 'install/node/bin/node'
    for name in ('host-name-guard', 'model-options-hook', 'session-home'):
        relative = 'rootfs/bin/omnigent-plugin-' + name + '-patch.mjs'
        entry = next(row for row in lock['files'] if row['path'] == relative)
        data, mode = run.ws.read('source/' + relative)
        require(digest(data) == entry['sha256'] and mode == entry['mode'], 'STAGED_PATCH_DRIFT')
        run.command([str(node), str(run.ws.root / 'source' / relative),
                     str(run.ws.root / 'install/plugins/pi-omnigent-plugin')], seconds=10)
    archive_bindings(run, source)


def acceptance_pipeline(run, source, artifact, artifact_sha):
    stage_source(run, source)
    copied_artifact = copy_artifact(run, artifact, artifact_sha)
    run.env['PI_AGENT_PIWEB_ARTIFACT'] = str(copied_artifact)
    for stage in INSTALL_STAGES:
        run.command(['/bin/bash', str(run.ws.root / 'source/install.sh'), stage])
        run.receipt['checks'].append('install-' + stage)
    finalize_installed_sources(run, source)
    run.receipt['checks'].append('immutable-installed-package-members')
    scenario = SharingScenario(run)
    reservation = reserve_port()
    port = reservation.getsockname()[1]
    run.env['PI_WEB_PORT'] = str(port)
    reservation.close()  # A bind race is rejected by identity checks, never retried on another listener.
    web = installed_web(run, port)
    first = web.proof
    scenario.add()
    scenario.bridge(True)
    scenario.bridge(True)  # Fresh bridge process, warm cached state.
    scenario.remove()
    scenario.bridge(False)
    run.receipt['checks'].append('current-bridge-add-remove-and-unrelated-sentinels')
    web.stop()
    web = installed_web(run, port)
    require(web.proof[:2] != first[:2], 'RESTART_IDENTITY')
    scenario.sentinels.check()
    scenario.bridge(False)
    run.receipt['checks'].append('owned-restart-sentinel-preservation')


def arm_interrupts():
    def interrupted(signum, frame):
        raise Hold('INTERRUPTED')
    return {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--mode', choices=('source-plan', 'acceptance'), required=True)
    parser.add_argument('--platform', choices=('ubuntu', 'wsl2'), required=True)
    parser.add_argument('--supervisor', choices=('owned-pgid', 'owned-subreaper'), default='owned-pgid')
    parser.add_argument('--parent', type=Path)
    parser.add_argument('--piweb-artifact', type=Path)
    parser.add_argument('--piweb-artifact-sha256')
    parser.add_argument('--run-token')
    parser.add_argument('--source-authority-sha256')
    parser.add_argument('--deadline-seconds', type=int, default=1800)
    args = parser.parse_args(argv)
    source = Path(__file__).resolve().parent.parent
    try:
        lock = verify_source(source)
        if args.mode == 'source-plan':
            print(json.dumps({'status': 'SOURCE_PLAN_ONLY', 'platformRequested': args.platform,
                              'baseSourceReference': BASE_COMMIT, 'sourceLockSha256': SOURCE_LOCK_SHA,
                              'sourceInputCount': len(lock['files']), 'supervisor': args.supervisor,
                              'installStages': INSTALL_STAGES,
                              'realUbuntuAcceptance': False, 'realWSL2Acceptance': False,
                              'providerAcceptance': False, 'rebootAcceptance': False}))
            return 0
        require(args.parent is not None and args.piweb_artifact is not None, 'PRIVATE_PARENT_AND_ARTIFACT_REQUIRED')
        require(os.geteuid() != 0, 'NORMAL_USER_REQUIRED')
        binding = {'runToken': args.run_token, 'sourceAuthoritySha256': args.source_authority_sha256,
                   'piwebArtifactSha256': args.piweb_artifact_sha256}
        require(all(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)
                    for value in binding.values()), 'RUN_BINDING_REQUIRED')
        require(60 <= args.deadline_seconds <= 3600, 'DEADLINE_BOUND')
        platform = platform_evidence(args.platform, Path('/etc/os-release').read_text(), os.uname().release, args.supervisor)
        prerequisites()
        run = OwnedRun(args.parent, scope='owned-platform-scenario', seconds=args.deadline_seconds,
                       supervisor=args.supervisor)
        # External identity transport, not a local authority grant. The caller
        # validates source authority; artifact bytes still pass copy_artifact.
        run.receipt.update(binding)
        report_name = run.ws.name + '.receipt.json'
        report = os.open(report_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=run.ws.pfd)
        os.fchmod(report, 0o600)
        run.receipt['platform'] = platform
        previous = arm_interrupts()
        failure = None
        try:
            acceptance_pipeline(run, source, args.piweb_artifact, args.piweb_artifact_sha256)
        except BaseException as error:
            failure = error
        finally:
            # Finish bounded teardown even if another interrupt arrives.
            for sig in previous:
                signal.signal(sig, signal.SIG_IGN)
            receipt = run.finish(failure)
            with os.fdopen(report, 'w') as output:
                output.write(json.dumps(receipt, indent=2) + '\n')
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        print(json.dumps({'status': receipt['status'], 'receipt': str(args.parent / report_name)}))
        return 0 if receipt['status'] == 'OWNED_SCENARIO_COMPLETED' else 1
    except (Hold, OSError, ValueError, KeyError) as error:
        # Error strings can contain paths or untrusted child data. Only a code escapes.
        code = str(error) if isinstance(error, Hold) else type(error).__name__
        print(json.dumps({'status': 'HOLD', 'code': code}), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
