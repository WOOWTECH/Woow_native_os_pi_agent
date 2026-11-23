#!/usr/bin/env python3
"""Give every file of the plugin-managed Omnigent its own inode (docs/OPERATIONS-GOTCHAS.md section 22).

Plugin <= 0.3.34 installed its Omnigent with uv's default Linux link mode, so every
file of data/omnigent-plugin/uv/tools/omnigent is a hard link into the plugin's uv
cache. Plugin 0.3.35's maintenance preservation guard reads SDK files only when they
have a single link, and the plugin does not reinstall an Omnigent of the pinned
version, so after an upgrade the host never starts (DEPENDENCIES_MISSING, "Omnigent
maintenance preservation could not be verified").

Each multi-linked regular file is replaced, in its own directory, by a byte-identical
copy with the same mode and timestamps, through an atomic rename. The cache keeps
its own copy. Symlinks are never followed, nothing outside the managed tool tree is
written, and no path or file content is printed. Nothing is changed when ownership,
permissions or free space do not allow the whole repair.

usage: python3 -I -B pi-agent-unshare-omnigent.py <PI_AGENT_HOME> [--check]
prints one JSON line; exit 0 = nothing left to do, 3 = --check found shared files,
1 = refused or failed (the reason is in the JSON line), 2 = usage.
"""
import hashlib
import json
import os
import stat
import sys

USAGE = 'usage: pi-agent-unshare-omnigent.py <PI_AGENT_HOME> [--check]'
TOOL = ('data', 'omnigent-plugin', 'uv', 'tools', 'omnigent')
TEMP_PREFIX = '.pi-agent-unshare.'
MARGIN = 64 * 1024 * 1024
CHUNK = 1024 * 1024
NOFOLLOW_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Refused(Exception):
    """A fixed reason token; the repair stopped or never started."""


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid, info.st_gid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def open_tool_root(home):
    """fd of <home>/data/omnigent-plugin/uv/tools/omnigent, or None when it does not exist.

    PI_AGENT_HOME itself may sit below a symlinked directory; nothing under it may.
    """
    try:
        fd = os.open(os.path.abspath(home), os.O_RDONLY | os.O_DIRECTORY)
    except FileNotFoundError:
        return None  # a first install: nothing was installed by an older plugin
    try:
        for part in TOOL:
            try:
                child = os.open(part, NOFOLLOW_DIR, dir_fd=fd)
            except FileNotFoundError:
                return None
            except OSError as error:  # ELOOP for a symlink, ENOTDIR for a file
                raise Refused('unsafe-tool-path') from error
            os.close(fd)
            fd = child
        if os.fstat(fd).st_uid != os.getuid():
            raise Refused('foreign-owner')
        result, fd = fd, None
        return result
    finally:
        if fd is not None:
            os.close(fd)


def walk(dir_fd, visit, leave=None):
    """visit(dir_fd, dir_info, name, info) per regular file, then leave(dir_fd); real directories only."""
    dir_info = os.fstat(dir_fd)
    with os.scandir(dir_fd) as listing:
        names = sorted(entry.name for entry in listing)
    for name in names:
        info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            try:
                child = os.open(name, NOFOLLOW_DIR, dir_fd=dir_fd)
            except OSError as error:
                raise Refused('changed-during-scan') from error
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    raise Refused('changed-during-scan')
                walk(child, visit, leave)
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode):
            visit(dir_fd, dir_info, name, info)
    if leave:
        leave(dir_fd)


def survey(root_fd):
    found = {'files': 0, 'shared': 0, 'sharedBytes': 0, 'staleTemps': 0, 'blocked': 0}
    uid = os.getuid()

    def visit(dir_fd, dir_info, name, info):
        found['files'] += 1
        if name.startswith(TEMP_PREFIX):
            found['staleTemps'] += 1
        elif info.st_nlink > 1:
            found['shared'] += 1
            found['sharedBytes'] += info.st_size
            # The copy is created and renamed in this directory, as this user.
            if (info.st_uid != uid or dir_info.st_uid != uid
                    or not dir_info.st_mode & stat.S_IWUSR or not dir_info.st_mode & stat.S_IXUSR):
                found['blocked'] += 1

    walk(root_fd, visit)
    return found


def write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def digest_of(dir_fd, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    try:
        value = hashlib.sha256()
        while True:
            chunk = os.read(fd, CHUNK)
            if not chunk:
                return value.hexdigest()
            value.update(chunk)
    finally:
        os.close(fd)


def unshare(dir_fd, name, info):
    """Replace one multi-linked file by an identical single-link copy.

    Returns the bytes copied, or None when the file no longer needed it.
    """
    source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    temp = TEMP_PREFIX + hashlib.sha256(os.fsencode(name)).hexdigest()[:16] + '.%d' % os.getpid()
    created = renamed = False
    try:
        first = os.fstat(source)
        if not stat.S_ISREG(first.st_mode) or (first.st_dev, first.st_ino) != (info.st_dev, info.st_ino):
            raise Refused('changed-during-repair')
        if first.st_nlink == 1:
            return None
        if first.st_uid != os.getuid():
            raise Refused('foreign-owner')
        copy = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
        created = True
        try:
            value, size = hashlib.sha256(), 0
            while True:
                chunk = os.read(source, CHUNK)
                if not chunk:
                    break
                value.update(chunk)
                write_all(copy, chunk)
                size += len(chunk)
            os.fchmod(copy, stat.S_IMODE(first.st_mode))
            try:
                os.fchown(copy, -1, first.st_gid)
            except PermissionError:
                pass  # a group this user cannot give; the owner is already the same
            os.utime(copy, ns=(first.st_atime_ns, first.st_mtime_ns))
            os.fsync(copy)
        finally:
            os.close(copy)
        # A writer during the copy changes size, mtime or ctime: keep the original then.
        if (size != first.st_size or fingerprint(os.fstat(source)) != fingerprint(first)
                or digest_of(dir_fd, temp) != value.hexdigest()):
            raise Refused('changed-during-repair')
        os.rename(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        renamed = True
    finally:
        os.close(source)
        if created and not renamed:
            try:
                os.unlink(temp, dir_fd=dir_fd)
            except FileNotFoundError:
                pass
    after = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if after.st_nlink != 1 or after.st_size != first.st_size or after.st_mtime_ns != first.st_mtime_ns:
        raise Refused('repair-not-confirmed')
    return first.st_size


def repair(root_fd):
    done = {'repaired': 0, 'repairedBytes': 0, 'staleTempsRemoved': 0}
    dirty = set()

    def visit(dir_fd, dir_info, name, info):
        if name.startswith(TEMP_PREFIX):
            # Left by a repair that was killed mid-copy; never a name uv or Omnigent writes.
            if info.st_uid == os.getuid() and info.st_nlink == 1:
                os.unlink(name, dir_fd=dir_fd)
                done['staleTempsRemoved'] += 1
                dirty.add(dir_fd)
            return
        if info.st_nlink > 1:
            size = unshare(dir_fd, name, info)
            if size is not None:
                done['repaired'] += 1
                done['repairedBytes'] += size
                dirty.add(dir_fd)

    def leave(dir_fd):
        if dir_fd in dirty:
            os.fsync(dir_fd)  # make the renames durable before the plugin reads them
            dirty.discard(dir_fd)

    walk(root_fd, visit, leave)
    return done


def main(argv):
    if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] != '--check'):
        print(USAGE, file=sys.stderr)
        return 2
    report = {'tool': '/'.join(TOOL)}
    try:
        root = open_tool_root(argv[1])
        if root is None:
            report['status'] = 'absent'
            print(json.dumps(report, sort_keys=True))
            return 0
        try:
            found = survey(root)
            report.update(found)
            if not found['shared'] and not found['staleTemps']:
                report['status'] = 'clean'
            elif len(argv) == 3:
                report['status'] = 'shared' if found['shared'] else 'stale-temps'
                print(json.dumps(report, sort_keys=True))
                return 3 if found['shared'] else 0
            else:
                if found['blocked']:
                    raise Refused('foreign-owner-or-read-only')
                space = os.statvfs(root)
                if found['sharedBytes'] + MARGIN > space.f_bavail * space.f_frsize:
                    raise Refused('insufficient-space')
                report.update(repair(root))
                left = survey(root)
                report['remaining'] = left['shared']
                if left['shared'] or left['staleTemps']:
                    raise Refused('repair-incomplete')
                report['status'] = 'repaired'
        finally:
            os.close(root)
    except Refused as error:
        report.update(status='refused', reason=str(error))
        print(json.dumps(report, sort_keys=True))
        return 1
    except OSError as error:  # the kind only; paths and messages stay local
        report.update(status='failed', reason='os-error', errno=error.errno)
        print(json.dumps(report, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
