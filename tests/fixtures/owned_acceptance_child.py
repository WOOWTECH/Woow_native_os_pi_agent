"""Plainly synthetic owned child. Never imports an installer or SDK."""
import http.server
import json
import os
import sys
import time

if sys.argv[1] in ('listen', 'trickle'):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if sys.argv[1] == 'trickle':
                self.connection.sendall(b'HTTP/1.1 200 OK\r\nX-Slow: ')
                for _ in range(1000):
                    self.connection.sendall(b'x')
                    time.sleep(0.02)
                return
            body = b'owned-loopback-fixture'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
elif sys.argv[1] == 'sleep':
    print('ready', flush=True)
    time.sleep(60)
elif sys.argv[1] == 'stubborn':
    import signal
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('ready', flush=True)
    time.sleep(60)
elif sys.argv[1] == 'doublefork':
    first = os.fork()
    if first:
        os.waitpid(first, 0)
        os._exit(0)
    second = os.fork()
    if second:
        os._exit(0)
    print(os.getpid(), flush=True)
    time.sleep(60)
elif sys.argv[1] == 'flood':
    os.write(1, b'x' * 200000)
elif sys.argv[1] == 'fail':
    sys.exit(7)
elif sys.argv[1] == 'env':
    print(json.dumps(dict(os.environ)), flush=True)
elif sys.argv[1] == 'bridge':
    for line in sys.stdin:
        r = json.loads(line)
        if 'id' not in r:
            continue
        if r['method'] == 'initialize':
            result = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}},
                      'serverInfo': {'name': 'synthetic-owned-safety-fixture', 'version': '1'}}
        else:
            result = {'content': [{'type': 'text', 'text': 'synthetic-result'}],
                      'isError': r['params']['name'] == 'refuse'}
        print(json.dumps({'jsonrpc': '2.0', 'id': r['id'], 'result': result}), flush=True)
elif sys.argv[1] == 'interrupt-run':
    from pathlib import Path
    import signal
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import owned_native_acceptance as owned
    run = owned.OwnedRun(Path(sys.argv[2]), scope='safety-fixture')
    prior = owned.arm_interrupts()
    failure = None
    try:
        child = run.spawn([sys.executable, '-I', '-S', '-B', __file__, 'sleep'])
        child.line(3)
        print(json.dumps({'ready': True, 'childProof': child.proof[:5]}), flush=True)
        signal.pause()
    except BaseException as error:
        failure = error
    finally:
        for sig in prior:
            signal.signal(sig, signal.SIG_IGN)
        print(json.dumps(run.finish(failure)), flush=True)
else:
    raise SystemExit('Unknown synthetic fixture action')
