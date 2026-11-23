#!/usr/bin/env python3
"""Resume an authorized Omnigent connection after a cold boot or Pi Web restart.

A loopback HTTP server is ready once it answers /health; an HTTPS server once it
accepts a TCP connection (the network may come up after Pi Web). Then the
plugin's supported `boot` lifecycle resumes the recorded host. No login,
password copying, host replacement, or model conversation is performed.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.parse
import urllib.request

STOP_REASONS = {'fresh-login-required', 'NEEDS_LOGIN', 'UNAUTHORIZED', 'HTTP_401',
                'CONNECTION_IDENTITY_MISMATCH', 'inactive', 'superseded'}
# A remote server is shared: retry only what clears up by itself (the plugin's
# own retryable set without NEEDS_LOGIN/409, plus its lock and host-online
# waits), so a persistent refusal never becomes a signed-in call every few
# seconds. Anything else stops with needs-attention.
REMOTE_RETRY_REASONS = {'SERVER_UNREACHABLE', 'HOST_CONNECT_TIMEOUT', 'host_connect_timeout', 'HOST_OFFLINE',
                        'LOCK_UNAVAILABLE', 'OPERATION_BUSY', 'ETIMEDOUT', 'TIMEOUT', 'HTTP_408', 'HTTP_425',
                        'HTTP_429', 'HTTP_500', 'HTTP_502', 'HTTP_503', 'HTTP_504'}
REMOTE_BACKOFF = 60


def local_health_url(proof):
    url = urllib.parse.urlsplit(proof.get('server', ''))
    if (url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1')
            or url.username or url.password or url.query or url.fragment or url.path not in ('', '/')):
        return None
    _ = url.port  # Reject malformed ports before running any command.
    return urllib.parse.urlunsplit((url.scheme, url.netloc, '/health', '', ''))


def remote_address(proof):
    url = urllib.parse.urlsplit(proof.get('server', ''))
    if (url.scheme != 'https' or not url.hostname or url.hostname in ('127.0.0.1', 'localhost', '::1')
            or url.username or url.password or url.query or url.fragment or url.path not in ('', '/')):
        return None
    try:
        port = url.port
    except ValueError:
        return None
    return None if port == 0 else (url.hostname, 443 if port is None else port)


def field(value, *keys):
    """Nested lookup that tolerates the CLI's string error form."""
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def health(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return response.status == 200


def reachable(address):
    with socket.create_connection(address, timeout=10):
        return True


def boot(root):
    result = subprocess.run([root / 'bin/pi-omnigent', 'boot'], capture_output=True,
                            text=True, timeout=180)
    # The CLI can return useful structured failures with a nonzero exit code.
    return json.loads(result.stdout) if result.stdout.strip() else {}


def resume(root, *, ready=None, launch=boot, clock=time.monotonic, sleep=time.sleep, budget=780):
    receipt = root / 'data/omnigent-plugin/connection.json'
    if not receipt.is_file():
        return 'no-recorded-connection'
    proof = json.loads(receipt.read_text())
    if not isinstance(proof, dict) or not isinstance(proof.get('server'), str):
        return 'unsupported-server'
    target, check, remote = local_health_url(proof), health, False
    if not target:
        target, check, remote = remote_address(proof), reachable, True
    if not target:
        return 'unsupported-server'
    check = ready or check
    host_id = field(proof, 'host', 'id')
    if not host_id:
        return 'identity-needs-setup'
    deadline = clock() + budget
    while clock() < deadline:
        # A user can disconnect or change servers while the local stack starts.
        if not receipt.is_file() or json.loads(receipt.read_text()) != proof:
            return 'connection-changed'
        pause = 10
        try:
            if check(target):
                # Every boot can reach the server; a remote one waits longer after any failure.
                pause = REMOTE_BACKOFF if remote else 10
                data = launch(root)
                result = field(data, 'resumption')
                if field(result, 'resumed'):
                    return 'resumed' if field(result, 'host', 'id') == host_id else 'identity-needs-setup'
                reason = field(result, 'reason') or field(result, 'error', 'code') or field(data, 'error', 'code')
                if reason in STOP_REASONS:
                    return 'authorization-needs-setup'
                if remote and reason not in REMOTE_RETRY_REASONS:
                    return 'needs-attention'
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
        sleep(pause)
    if remote:
        # Exit cleanly: Restart=on-failure must not loop against a shared server.
        return 'remote-not-resumed'
    raise TimeoutError('Omnigent did not resume within the cold-start budget')


if __name__ == '__main__':
    root = Path(os.environ.get('PI_AGENT_HOME', Path.home() / '.local/share/pi-agent'))
    print('Omnigent recovery: ' + resume(root))
