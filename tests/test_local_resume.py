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

    def test_missing_and_remote_connections_do_not_launch(self):
        def fail(*args):
            self.fail('unexpected network or boot')
        for server in ('https://example.invalid', 'http://192.0.2.1:8000', 'http://user@localhost:8000'):
            self.proof['server'] = server
            self.write()
            self.assertEqual(self.run_resume(ready=fail, launch=fail), 'remote-or-unsupported-server')
        self.receipt.unlink()
        self.assertEqual(self.run_resume(ready=fail, launch=fail), 'no-recorded-connection')

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
