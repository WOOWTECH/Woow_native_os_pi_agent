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
    return url.hostname, url.port or 443  # A malformed port raises before any command runs.


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
    target, check = local_health_url(proof), health
    if not target:
        target, check = remote_address(proof), reachable
    if not target:
        return 'unsupported-server'
    check = ready or check
    host_id = proof.get('host', {}).get('id')
    if not host_id:
        return 'identity-needs-setup'
    deadline = clock() + budget
    while clock() < deadline:
        # A user can disconnect or change servers while the local stack starts.
        if not receipt.is_file() or json.loads(receipt.read_text()) != proof:
            return 'connection-changed'
        try:
            if check(target):
                data = launch(root)
                result = data.get('resumption', {})
                if result.get('resumed'):
                    return 'resumed' if result.get('host', {}).get('id') == host_id else 'identity-needs-setup'
                reason = result.get('reason') or result.get('error', {}).get('code') or data.get('error', {}).get('code')
                if reason in STOP_REASONS:
                    return 'authorization-needs-setup'
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
        sleep(10)
    raise TimeoutError('Omnigent did not resume within the cold-start budget')


if __name__ == '__main__':
    root = Path(os.environ.get('PI_AGENT_HOME', Path.home() / '.local/share/pi-agent'))
    print('Omnigent recovery: ' + resume(root))
