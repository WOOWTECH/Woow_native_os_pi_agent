"""Owned signal barriers around the actual guardian; never a runtime seam."""
import importlib.util
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import owned_acceptance_supervisor as supervisor

mode = sys.argv.pop(1)
real_spec = importlib.util.spec_from_file_location
real_signal = signal.signal
real_popen = supervisor.subprocess.Popen
launched = active_fired = False
target_pid = None


def emit(label, value=None):
    raw = label if value is None else label + ':' + json.dumps(value, separators=(',', ':'))
    os.write(1, (raw + '\n').encode('ascii'))


def barrier(label):
    emit('fixture-barrier:' + label)
    if not select.select([0], [], [], 5)[0] or os.read(0, 1) != b'x':
        raise RuntimeError('FIXTURE_BARRIER_TIMEOUT')


def register(number, handler):
    if number not in (signal.SIGTERM, signal.SIGINT) or not callable(handler):
        return real_signal(number, handler)
    def observed(*args):
        handler(*args)
        emit('fixture-stop-latched')
    return real_signal(number, observed)


def popen(*args, **kwargs):
    global launched, target_pid
    child = real_popen(*args, **kwargs)
    target_pid = child.pid
    launched = True
    emit('fixture-spawn', {'pid': child.pid, 'proof': supervisor.identity(child.pid)})
    return child


class BarrierLoader:
    def __init__(self, original):
        self.original = original

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        self.original.exec_module(module)
        original_close = module.OwnedDescendants.close
        def close(instance):
            original_close(instance)
            emit('fixture-custody-closed', {'descriptors': instance.budget.fds})
        module.OwnedDescendants.close = close
        if mode == 'wall-reap':
            instances = []
            original_init = module.OwnedDescendants.__init__
            original_refresh = module.OwnedDescendants.refresh
            original_wait = os.waitpid
            state = {'commandReaped': False, 'clone': None, 'cloneReaped': False}
            def construct(instance, *args, **kwargs):
                original_init(instance, *args, **kwargs)
                instances.append(instance)
            def refresh(instance):
                result = original_refresh(instance)
                if state['cloneReaped']:
                    emit('fixture-post-reap-census', {'proofs': len(result)})
                return result
            def wait(pid, flags):
                if state['commandReaped'] and instances and not instances[0]._census_depth and state['clone'] is None:
                    read, write = os.pipe()
                    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
                    @callback_type
                    def worker(_):
                        os.close(write);os.read(read, 1);os._exit(0)
                    stack = ctypes.create_string_buffer(1024 * 1024)
                    libc = ctypes.CDLL(None, use_errno=True)
                    libc.clone.argtypes = [callback_type, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
                    libc.clone.restype = ctypes.c_int
                    # Non-SIGCHLD clone is a direct private guardian child.
                    signal.signal(signal.SIGUSR1, signal.SIG_IGN)
                    clone = libc.clone(worker, ctypes.addressof(stack) + len(stack), signal.SIGUSR1, None)
                    if clone <= 0:raise RuntimeError('FIXTURE_CLONE_FAILED')
                    state['clone'] = clone
                    os.close(read)
                    fd = os.pidfd_open(clone, 0)
                    os.write(write, b'x');os.close(write)
                    if not select.select([fd], [], [], 2)[0]:raise RuntimeError('FIXTURE_CLONE_TIMEOUT')
                    os.close(fd)
                    emit('fixture-wall-clone', {'pid': clone})
                result = original_wait(pid, flags)
                if result[0] == target_pid:state['commandReaped'] = True
                if result[0] == state['clone']:state['cloneReaped'] = True
                return result
            if hasattr(module.Budget, 'record_reap'):
                original_record = module.Budget.record_reap
                def record(instance, pid, status):
                    original_record(instance, pid, status)
                    emit('fixture-reap-accounted', {'pid': pid, 'status': status})
                module.Budget.record_reap = record
            module.OwnedDescendants.__init__ = construct
            module.OwnedDescendants.refresh = refresh
            os.waitpid = wait
        if mode == 'namespace-live':
            original_validate = module.OwnedDescendants._validate
            fired = []
            def validate(instance, cap):
                original_link = module.os.readlink
                def denied(path, *args, **kwargs):
                    if path == 'ns/net' and cap.pid == target_pid and kwargs.get('dir_fd') == cap.procfd and not fired:
                        fired.append(cap.pid)
                        emit('fixture-namespace-denied', {'pid': cap.pid,
                             'ready': bool(select.select([cap.pidfd], [], [], 0)[0])})
                        raise PermissionError(13, 'owned live namespace fixture')
                    return original_link(path, *args, **kwargs)
                module.os.readlink = denied
                try:return original_validate(instance, cap)
                finally:module.os.readlink = original_link
            module.OwnedDescendants._validate = validate
        if mode in ('constructor-expiry', 'constructor-ioerror'):
            original_init = module.OwnedDescendants.__init__
            original_open_cap = module.OwnedDescendants._open_cap
            def open_cap(instance, pid, **kwargs):
                if mode == 'constructor-ioerror':
                    raise OSError(5, 'owned constructor fixture')
                # Known work expiry inside construction, after /proc and self
                # descriptors are held and before the anchor capability exists.
                while time.monotonic() < instance.budget.deadline + 0.02:
                    time.sleep(0.005)
                return original_open_cap(instance, pid, **kwargs)
            def construct(instance, *args, **kwargs):
                try:
                    original_init(instance, *args, **kwargs)
                except BaseException as error:
                    emit('fixture-constructor-failed', {'code': getattr(error, 'custody_code', None),
                         'phase': getattr(error, 'phase', None), 'descriptors': instance.budget.fds})
                    raise
            module.OwnedDescendants._open_cap = open_cap
            module.OwnedDescendants.__init__ = construct
        if mode == 'cutoff-race':
            original_check = module.Budget.check
            def check(instance):
                global active_fired
                lifetime = instance._operations[-1][0] if getattr(instance, '_operations', None) else None
                if launched and instance.depth and not active_fired and lifetime is not None \
                        and lifetime.teardown_deadline is None and time.monotonic() >= instance.deadline - 0.15:
                    active_fired = True
                    while time.monotonic() < instance.deadline + 0.01:
                        time.sleep(0.002)
                    try:
                        original_check(instance)
                    except module.CustodyError as error:
                        # Stop arrives after the work-cutoff sample/comparison,
                        # before the guardian classifies this known expiry.
                        signal.raise_signal(signal.SIGTERM)
                        emit('fixture-cutoff-race', {'code': error.custody_code,
                             'phase': getattr(error, 'phase', None),
                             'teardownStarted': lifetime.teardown_deadline is not None})
                        raise
                    emit('fixture-cutoff-race', {'code': None})
                    return
                return original_check(instance)
            module.Budget.check = check
        if mode == 'loader':
            barrier('loader')
        if mode == 'constructor':
            original_init = module.OwnedDescendants.__init__
            def construct(instance, *args, **kwargs):
                original_init(instance, *args, **kwargs)
                barrier('constructor')  # Resources held, guardian assignment pending.
            module.OwnedDescendants.__init__ = construct
        if mode == 'active':
            original_check = module.Budget.check
            def check(instance):
                global active_fired
                if launched and instance.depth and not active_fired:
                    active_fired = True
                    before = [instance.depth, instance.bytes, len(instance.seen), instance.fds]
                    barrier('active')
                    original_check(instance)
                    emit('fixture-budget-resumed', {'before': before,
                        'after': [instance.depth, instance.bytes, len(instance.seen), instance.fds],
                        'workCutoff': instance.deadline, 'effectiveCutoff': instance.until})
                    return
                return original_check(instance)
            module.Budget.check = check


def spec(name, location, *args, **kwargs):
    result = real_spec(name, location, *args, **kwargs)
    if name == 'owned_custody_guardian':
        result.loader = BarrierLoader(result.loader)
    return result


importlib.util.spec_from_file_location = spec
signal.signal = register
supervisor.subprocess.Popen = popen
supervisor.main()
