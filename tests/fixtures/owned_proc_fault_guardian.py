"""Synthetic procfs faults around the real guardian main; test use only."""
import errno
import os
from pathlib import Path
import sys
import types

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import owned_acceptance_supervisor as supervisor

mode = sys.argv.pop(1)
original_open, original_stat = Path.open, Path.stat
fired = 0


def open_proc(path, *args, **kwargs):
    global fired
    selected = path.parts[:2] == ('/', 'proc') and len(path.parts) > 3
    if selected and path.parts[2] != str(os.getpid()) and mode != 'foreign-uid' \
            and fired < (2 if mode == 'permission-then-io' else 1):
        fired += 1
        number = {'permission': errno.EACCES, 'io': errno.EIO,
                  'gone': errno.ESRCH,
                  'permission-then-io': errno.EACCES if fired == 1 else errno.EIO}.get(mode)
        if number is not None:
            raise OSError(number, 'PRIVATE-FIXTURE-PATH-DO-NOT-EXPORT')
        raise RuntimeError('PRIVATE-FIXTURE-UNKNOWN-DO-NOT-EXPORT')
    return original_open(path, *args, **kwargs)


def stat_proc(path, *args, **kwargs):
    observed = original_stat(path, *args, **kwargs)
    if mode == 'foreign-uid' and path.parts[:2] == ('/', 'proc') \
            and len(path.parts) == 3 and path.parts[2] != str(os.getpid()):
        return types.SimpleNamespace(st_uid=0 if os.getuid() else 1)
    return observed


Path.open, Path.stat = open_proc, stat_proc
supervisor.main()
