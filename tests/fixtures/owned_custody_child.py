"""Only synthetic custody scenarios. No installer, SDK, provider or service."""
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time

mode = sys.argv[1]


def touch(megabytes):
    """Fully written private anonymous memory: every page is resident, so the
    kernel's exit_mm() teardown (mm cleared, PIDfd not yet readable) is long."""
    if not 1 <= megabytes <= 256:
        raise SystemExit(64)
    return b'\xa5' * (megabytes << 20)


if mode == 'foreign':
    port, behavior = int(sys.argv[2]), sys.argv[3]
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(1)
    listener.settimeout(3)
    print('ready', flush=True)
    peer, _ = listener.accept()
    peer.settimeout(1)
    if behavior in ('queued', 'fast-close'):
        peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nFOREIGN')
    count = 0
    if behavior != 'fast-close':
        try:
            count = len(peer.recv(8192))
        except (TimeoutError, ConnectionResetError):
            pass
    peer.close()
    listener.close()
    print('received:' + str(count), flush=True)
elif mode == 'terminal-leader':
    import ctypes
    import threading
    def worker():
        print(os.getpid(), flush=True)
        # Outlives the custody module's bounded 2 s exit-window wait.
        time.sleep(3.0)
    thread = threading.Thread(target=worker)
    thread.start()
    libc = ctypes.CDLL(None)
    libc.pthread_exit.argtypes = [ctypes.c_void_p]
    libc.pthread_exit.restype = None
    libc.pthread_exit(None)
elif mode in ('terminal-leader-held', 'terminal-leader-cutoff'):
    # Leader thread exits (its namespace links vanish, PF_EXITING set) while a
    # worker keeps the thread group, and so the PIDfd, nonready until released.
    import ctypes
    import select
    import threading
    if mode == 'terminal-leader-cutoff':
        # Keep one real thread alive across the declared work cutoff, then exit
        # normally inside the cleanup allowance despite the guardian's TERM.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        release_at = float(sys.argv[2])
    def worker():
        print(os.getpid(), flush=True)
        if mode == 'terminal-leader-cutoff':
            time.sleep(max(0, release_at - time.monotonic()))
        else:
            select.select([0], [], [], 20)
        os._exit(0)
    thread = threading.Thread(target=worker)
    thread.start()
    libc = ctypes.CDLL(None)
    libc.pthread_exit.argtypes = [ctypes.c_void_p]
    libc.pthread_exit.restype = None
    libc.pthread_exit(None)
elif mode == 'memfd-exit':
    # Deferred final fput of a large private memfd widens the kernel exit
    # window between exit_task_namespaces() and exit_notify().
    megabytes = int(sys.argv[2])
    if not 1 <= megabytes <= 256:
        raise SystemExit(64)
    memory = os.memfd_create('owned-exit-window')
    block = b'\xa5' * (1 << 20)
    for _ in range(megabytes):
        os.write(memory, block)
    print('ready', flush=True)
    if sys.stdin.readline() != 'exit\n':
        os._exit(65)
    os._exit(0)
elif mode == 'memfd-exit-at':
    # Same deferred-fput exit window, exiting at an exact monotonic instant.
    megabytes, exit_at = int(sys.argv[2]), float(sys.argv[3])
    if not 1 <= megabytes <= 256:
        raise SystemExit(64)
    memory = os.memfd_create('owned-exit-window')
    block = b'\xa5' * (1 << 20)
    for _ in range(megabytes):
        os.write(memory, block)
    print('ready', flush=True)
    time.sleep(max(0.0, exit_at - time.monotonic()))
    os._exit(0)
elif mode == 'idle':
    memory = touch(int(sys.argv[2])) if len(sys.argv) > 2 else None
    print('ready', flush=True)
    sys.stdin.read(1)
    os._exit(0)
elif mode == 'zombie-holder':
    # A live owned parent that does not reap its exited child until asked.
    child = os.fork()
    if not child:
        os._exit(0)
    print(child, flush=True)
    while True:
        line = sys.stdin.readline()
        if line == 'reap\n':
            os.waitpid(child, 0)
            print('reaped', flush=True)
            continue
        try:
            os.waitpid(child, 0)
        except ChildProcessError:
            pass
        os._exit(0)
elif mode == 'nodump':
    # Live, never exiting, made non-dumpable on request (root-owned fd dir).
    import ctypes
    print('ready', flush=True)
    if sys.stdin.readline() == 'nodump\n':
        if ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) != 0:  # PR_SET_DUMPABLE
            os._exit(67)
        print('nodump', flush=True)
        sys.stdin.readline()
    os._exit(0)
elif mode == 'serve':
    # One private loopback server; counts accepted connections for the test.
    import select
    memory = touch(int(sys.argv[2])) if len(sys.argv) > 2 else None
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(4)
    print(listener.getsockname()[1], flush=True)
    accepted = 0
    while True:
        readable, _, _ = select.select([listener, 0], [], [], 20)
        if not readable:
            os._exit(66)
        if 0 in readable:
            line = sys.stdin.readline()
            if line == 'count\n':
                print('count:' + str(accepted), flush=True)
                continue
            os._exit(0)
        peer, _ = listener.accept()
        accepted += 1
        peer.settimeout(2)
        request = b''
        try:
            while b'\r\n\r\n' not in request and len(request) < 8192:
                block = peer.recv(8192)
                if not block:
                    break
                request += block
        except TimeoutError:
            pass
        if request.startswith(b'GET / HTTP/1.1\r\n'):
            body = b'owned-serving-peer'
            peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode()
                         + b'\r\nConnection: close\r\n\r\n' + body)
        peer.close()
elif mode == 'move-session':
    print('ready', flush=True)
    sys.stdin.read(1)
    os.setsid()
    print('moved', flush=True)
    time.sleep(30)
elif mode == 'thread-exit-barrier':
    import threading
    leave = threading.Event()
    def worker():
        print('thread:' + str(threading.get_native_id()), flush=True)
        leave.wait()
    thread = threading.Thread(target=worker)
    thread.start()
    sys.stdin.read(1)
    leave.set()
    thread.join()
    print('thread-gone', flush=True)
    time.sleep(30)
elif mode == 'late-departure-barrier':
    read, write = os.pipe()
    child = os.fork()
    if child:
        os.close(write)
        if os.read(read, 1) != b'1':os._exit(66)
        os.close(read)
        os._exit(0)
    os.close(read)
    os.setsid()
    print('worker:' + str(os.getpid()), flush=True)
    os.write(write, b'1')
    os.close(write)
    if sys.stdin.readline() != 'exit\n':os._exit(65)
    os._exit(0)
elif mode == 'adoption-barrier':
    print('ready', flush=True)
    if sys.stdin.readline() != 'fork\n':
        raise SystemExit(65)
    read, write = os.pipe()
    child = os.fork()
    if not child:
        os.close(read)
        os.setsid()
        print('adopted:' + str(os.getpid()), flush=True)
        os.write(write, b'1')
        os.close(write)
        while True:
            signal.pause()
    os.close(write)
    if os.read(read, 1) != b'1':
        os._exit(66)
    os.close(read)
    os._exit(0)
elif mode in ('parent-death', 'parent-death-expiry'):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import owned_native_acceptance as owned
    run = owned.OwnedRun(Path(sys.argv[2]), scope='safety-fixture', supervisor='owned-subreaper',
                         seconds=0.4 if mode == 'parent-death-expiry' else 1800)
    process = run.spawn([sys.executable, '-I', '-S', '-B',
                        str(Path(__file__).with_name('owned_acceptance_child.py')), 'stubborn'])
    process.line(3)
    proof = {'guardian': process.proof[:5], 'children': [p[:5] for p in process.members()[1:]]}
    if mode == 'parent-death-expiry':
        time.sleep(max(0, run.deadline - time.monotonic()) + 0.04)
        proof['parentExitAfterExpiry'] = time.monotonic() >= run.deadline
    print(json.dumps(proof), flush=True)
    os._exit(0)  # Guardian must retain and clean this private tree after observer loss.
else:
    raise SystemExit(64)
