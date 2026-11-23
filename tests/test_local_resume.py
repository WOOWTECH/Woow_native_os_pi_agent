import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('resume', Path(__file__).resolve().parents[1] / 'rootfs/bin/pi-agent-resume.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipt = self.root / 'data/omnigent-plugin/connection.json'
        self.receipt.parent.mkdir(parents=True)
        self.proof = {'server': 'http://127.0.0.1:8000', 'host': {'id': 'fixture-host'}}
        self.write()
        self.now = 0
        self.calls = 0

    def write(self):
        self.receipt.write_text(json.dumps(self.proof))

    def sleep(self, duration):
        self.now += duration

    def run_resume(self, **kwargs):
        return module.resume(self.root, clock=lambda: self.now, sleep=self.sleep, budget=30, **kwargs)

    def test_cold_start_retries_then_preserves_identity(self):
        before = self.receipt.read_bytes()
        def launch(root):
            self.assertEqual(root, self.root)
            self.calls += 1
            if self.calls == 1:
                return {'resumption': {'reason': 'host_connect_timeout'}}
            return {'resumption': {'resumed': True, 'host': {'id': 'fixture-host'}}}
        self.assertEqual(self.run_resume(ready=lambda url: self.now >= 10, launch=launch), 'resumed')
        self.assertEqual(self.calls, 2)
        self.assertEqual(before, self.receipt.read_bytes())

    def test_missing_and_unsupported_connections_do_not_launch(self):
        def fail(*args):
            self.fail('unexpected network or boot')
        for server in ('http://192.0.2.1:8000', 'http://user@localhost:8000', 'https://user@example.invalid',
                       'https://example.invalid/path', 'https://example.invalid/?q=1', 'https://example.invalid/#f',
                       'https://localhost', 'ftp://example.invalid', '', 'not a url'):
            self.proof['server'] = server
            self.write()
            self.assertEqual(self.run_resume(ready=fail, launch=fail), 'unsupported-server', server)
        self.receipt.unlink()
        self.assertEqual(self.run_resume(ready=fail, launch=fail), 'no-recorded-connection')

    def test_remote_https_waits_for_the_network_then_resumes(self):
        # Pi Web's own boot worker gives up once when the network comes up late.
        self.proof['server'] = 'https://omnigent.example.invalid'
        self.write()
        before = self.receipt.read_bytes()
        targets = []
        def ready(target):
            targets.append(target)
            if self.now < 10:
                raise OSError('network is unreachable')
            return True
        def launch(root):
            self.calls += 1
            return {'resumption': {'resumed': True, 'host': {'id': 'fixture-host'}}}
        self.assertEqual(self.run_resume(ready=ready, launch=launch), 'resumed')
        self.assertEqual(self.calls, 1)
        self.assertEqual(targets, [('omnigent.example.invalid', 443)] * 2)
        self.assertEqual(before, self.receipt.read_bytes())

    def test_remote_port_and_authorization_stop(self):
        self.proof['server'] = 'https://omnigent.example.invalid:8443/'
        self.write()
        targets = []
        self.assertEqual(self.run_resume(ready=lambda target: targets.append(target) or True,
            launch=lambda _: {'resumption': {'reason': 'fresh-login-required'}}), 'authorization-needs-setup')
        self.assertEqual(targets, [('omnigent.example.invalid', 8443)])
        self.assertEqual(self.now, 0)

    def test_remote_wrong_host_never_counts_as_recovered(self):
        self.proof['server'] = 'https://omnigent.example.invalid'
        self.write()
        self.assertEqual(self.run_resume(ready=lambda _: True,
            launch=lambda _: {'resumption': {'resumed': True, 'host': {'id': 'other'}}}), 'identity-needs-setup')

    def test_malformed_or_zero_remote_port_is_unsupported_before_any_command(self):
        for server in ('https://omnigent.example.invalid:99999', 'https://omnigent.example.invalid:0',
                       'https://omnigent.example.invalid:x'):
            self.proof['server'] = server
            self.write()
            self.assertEqual(self.run_resume(ready=lambda _: self.fail('probe'), launch=lambda _: self.fail('boot')),
                             'unsupported-server', server)

    def test_odd_receipts_do_not_crash(self):
        for proof in ([], {'server': 7, 'host': {'id': 'x'}}, {'server': 'https://omnigent.example.invalid', 'host': 'x'}):
            self.receipt.write_text(json.dumps(proof))
            self.assertIn(self.run_resume(ready=lambda _: self.fail('probe'), launch=lambda _: self.fail('boot')),
                          ('unsupported-server', 'identity-needs-setup'))

    def remote(self):
        self.proof['server'] = 'https://omnigent.example.invalid'
        self.write()

    def test_remote_persistent_failures_stop_after_one_boot(self):
        # Host-name collisions, a refused SDK, a disabled plugin or the CLI's
        # string error must not become a signed-in retry every few seconds.
        self.remote()
        for data in ({'resumption': {'ok': False, 'error': {'code': 'HOST_NAME_COLLISION'}}},
                     {'resumption': {'ok': False, 'error': {'code': 'MAINTENANCE_PRESERVATION_REQUIRED'}}},
                     {'initialization': {'phase': 'disabled'}, 'startup': {'status': 'disabled'}},
                     {'initialization': {'ok': False, 'phase': 'error'}, 'startup': {'status': 'settings-required'}},
                     {'phase': 'error', 'error': 'Operation failed (ENOSPC).'}, {}, []):
            calls = []
            self.assertEqual(self.run_resume(ready=lambda _: True, launch=lambda _: calls.append(1) or data),
                             'needs-attention', data)
            self.assertEqual(len(calls), 1)
        self.assertEqual(self.now, 0)

    def test_remote_transient_failure_backs_off_then_resumes(self):
        self.remote()
        outcomes = [{'resumption': {'ok': False, 'error': {'code': 'SERVER_UNREACHABLE'}}},
                    {'resumption': {'ok': False, 'error': {'code': 'OPERATION_BUSY'}}},
                    {'resumption': {'resumed': True, 'host': {'id': 'fixture-host'}}}]
        pauses = []
        def sleep(duration):
            pauses.append(duration)
            self.now += duration
        result = module.resume(self.root, ready=lambda _: True, launch=lambda _: outcomes.pop(0),
                               clock=lambda: self.now, sleep=sleep, budget=600)
        self.assertEqual(result, 'resumed')
        self.assertEqual(pauses, [module.REMOTE_BACKOFF] * 2)

    def test_remote_budget_ends_cleanly_without_a_restart_loop(self):
        self.remote()
        self.assertEqual(self.run_resume(ready=lambda _: False, launch=lambda _: self.fail('boot')), 'remote-not-resumed')
        self.assertEqual(self.now, 30)

    def test_local_cli_string_error_keeps_retrying_without_crashing(self):
        with self.assertRaises(TimeoutError):
            self.run_resume(ready=lambda _: True, launch=lambda _: {'phase': 'error', 'error': 'Operation failed (x).'})

    def test_default_remote_probe_is_a_bounded_tcp_connect(self):
        calls = []
        class Connection:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
        def connect(address, timeout):
            calls.append((address, timeout))
            return Connection()
        original = module.socket.create_connection
        module.socket.create_connection = connect
        try:
            self.assertTrue(module.reachable(('omnigent.example.invalid', 443)))
        finally:
            module.socket.create_connection = original
        self.assertEqual(calls, [(('omnigent.example.invalid', 443), 10)])

    def test_authorization_failures_stop_without_retry(self):
        for reason in module.STOP_REASONS:
            self.assertEqual(self.run_resume(ready=lambda _: True,
                launch=lambda _: {'resumption': {'reason': reason}}), 'authorization-needs-setup')
        self.assertEqual(self.now, 0)

    def test_wrong_host_never_counts_as_recovered(self):
        self.assertEqual(self.run_resume(ready=lambda _: True,
            launch=lambda _: {'resumption': {'resumed': True, 'host': {'id': 'other'}}}), 'identity-needs-setup')

    def test_changed_receipt_stops_retry(self):
        def launch(_):
            self.receipt.unlink()
            return {}
        self.assertEqual(self.run_resume(ready=lambda _: True, launch=launch), 'connection-changed')

    def test_offline_budget_is_bounded(self):
        with self.assertRaises(TimeoutError):
            self.run_resume(ready=lambda _: False)
        self.assertEqual(self.now, 30)


if __name__ == '__main__':
    unittest.main()
