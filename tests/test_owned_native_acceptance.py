"""Owned local safety fixtures; no installer, SDK, provider or service imports."""
import importlib.util
import os
from pathlib import Path
import tempfile
import sys
import time
import json
import shutil
import subprocess
import tarfile
import io
import ast
import unittest
import shlex
import re
import stat
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('owned_acceptance', HERE / 'owned_native_acceptance.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


FIXTURE_NODE = None


def resolve_fixture_node(search_path=None, *, seconds=3):
    """Select PATH's Node once; owned version probe has 3s/256-byte limits."""
    mod.require(0 < seconds <= 3, 'FIXTURE_NODE_PROBE_BOUND')
    if search_path is None:
        search_path = os.environ.get('PATH')
    mod.require(bool(search_path), 'FIXTURE_NODE_PATH_REQUIRED')
    selected = shutil.which('node', path=search_path)
    mod.require(selected is not None, 'FIXTURE_NODE_NOT_FOUND')
    node = Path(selected).resolve(strict=True)
    mod.require(stat.S_ISREG(node.stat().st_mode) and os.access(node, os.X_OK), 'FIXTURE_NODE_PATH')
    with tempfile.TemporaryDirectory() as parent:
        os.chmod(parent, 0o700)
        with mod.Workspace.create(Path(parent)) as ws:
            version = mod.run_command([str(node), '--version'], ws, mod.child_environment(ws),
                                      seconds=seconds, maximum=256)
    mod.require(len(version) <= 64 and re.fullmatch(rb'v22\.\d+\.\d+\n?', version) is not None,
                'FIXTURE_NODE_VERSION')
    return str(node)


def setUpModule():
    global FIXTURE_NODE
    FIXTURE_NODE = resolve_fixture_node()


def fixture_node_wrapper(node):
    mod.require(Path(node).is_absolute(), 'FIXTURE_NODE_PATH')
    return ('#!/bin/sh\nexec ' + shlex.quote(node) + ' "$@"\n').encode()


def fixture_manifest(run, node):
    module = (run.ws.root / 'source/lib/artifact-manifest.mjs').as_uri()
    code = ("import {expectedManifest} from " + json.dumps(module)
            + ";console.log(JSON.stringify(expectedManifest(process.argv[1], 'linux', 'x64', '0.10.0',"
            + "'6fcd7d44981ab51a21d6cd6eb06d361d0e3d3068',"
            + "'13775483ce327a544b2604f4205db11ec0eec516e0765c44bebf72a133503dbb')));")
    return json.loads(run.command([node, '--input-type=module', '-e', code,
                                   str(run.ws.root / 'source')], seconds=5))


class FixtureNodeTests(unittest.TestCase):
    def script(self, directory, body):
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / 'node'
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)
        return path

    def test_provisioned_node_outside_system_path_binds_both_fixture_consumers(self):
        """Real Node delegates at a quoted toolcache path; child PATH cannot find it."""
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            directory = Path(parent) / "tool cache's bin"
            candidate = self.script(directory, 'exec ' + shlex.quote(FIXTURE_NODE) + ' "$@"')
            selected = resolve_fixture_node(str(directory))
            self.assertEqual(selected, str(candidate.resolve()))
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            failure = None
            try:
                mod.stage_source(run, HERE.parent)
                run.ws.write_new('install/node/bin/node', fixture_node_wrapper(selected), 0o755)
                env = dict(run.env, PATH='/no-node-on-this-path')
                version = mod.run_command([str(run.ws.root / 'install/node/bin/node'), '--version'],
                                          run.ws, env, seconds=3, maximum=256)
                self.assertTrue(version.startswith(b'v22.'))
                run.env['PATH'] = '/no-node-on-this-path'
                manifest = fixture_manifest(run, selected)
                self.assertEqual(manifest['version'], '0.2.16-rc.4')
                self.assertEqual(next(p['sha256'] for p in manifest['packages'] if 'omnigent' in p['file']),
                                 mod.PLUGIN_SHA)
            except BaseException as error:
                failure = error
                raise
            finally:
                run.finish(failure)

    def test_missing_path_node_has_no_system_fallback(self):
        with tempfile.TemporaryDirectory() as parent:
            with self.assertRaisesRegex(mod.Hold, 'FIXTURE_NODE_NOT_FOUND'):
                resolve_fixture_node(parent)

    def test_unset_or_empty_path_refuses_before_lookup_or_probe(self):
        for ambient, argument in [(None, None), ('', None), ('/fixture-path', '')]:
            with self.subTest(ambient=ambient, argument=argument):
                environment = {} if ambient is None else {'PATH': ambient}
                with mock.patch.dict(os.environ, environment, clear=True), \
                     mock.patch.object(shutil, 'which', side_effect=AssertionError('unexpected lookup')) as lookup, \
                     mock.patch.object(mod, 'run_command', side_effect=AssertionError('unexpected probe')) as probe:
                    with self.assertRaisesRegex(mod.Hold, 'FIXTURE_NODE_PATH_REQUIRED'):
                        resolve_fixture_node(argument)
                    lookup.assert_not_called()
                    probe.assert_not_called()

    def test_wrong_failed_or_malformed_version_refuses_without_fallback(self):
        with tempfile.TemporaryDirectory() as parent:
            directory = Path(parent) / 'first'
            for body, code in [("printf 'v20.19.0\\n'", 'FIXTURE_NODE_VERSION'),
                               ("printf 'v22.23.3\\n'; exit 7", 'COMMAND_FAILED'),
                               ("printf 'v22.23.3\\nextra\\n'", 'FIXTURE_NODE_VERSION')]:
                with self.subTest(code=code, body=body):
                    self.script(directory, body)
                    search = str(directory) + os.pathsep + str(Path(FIXTURE_NODE).parent)
                    with self.assertRaisesRegex(mod.Hold, code):
                        resolve_fixture_node(search)

    def test_version_probe_has_time_and_output_bounds(self):
        with tempfile.TemporaryDirectory() as parent:
            directory = Path(parent) / 'bounded'
            self.script(directory, 'exec /bin/sleep 5')
            began = time.monotonic()
            with self.assertRaisesRegex(mod.Hold, 'COMMAND_DEADLINE'):
                resolve_fixture_node(str(directory), seconds=0.1)
            self.assertLess(time.monotonic() - began, 2)
            self.script(directory, 'exec /bin/dd if=/dev/zero bs=1024 count=1')
            with self.assertRaisesRegex(mod.Hold, 'COMMAND_OUTPUT_BOUND'):
                resolve_fixture_node(str(directory))


class WorkflowTests(unittest.TestCase):
    def test_deployment_ci_always_runs_owned_safety_and_existing_maintenance(self):
        """Parse the real workflow; no path/condition/allow-failure escape hatch."""
        import yaml
        workflow = yaml.safe_load((HERE.parent / '.github/workflows/deployment-ci.yml').read_text())
        # PyYAML's YAML 1.1 parser interprets the GitHub key 'on' as True.
        events = workflow.get('on', workflow.get(True))
        for event in ('pull_request', 'push'):
            self.assertIn(event, events)
            for filter_name in ('paths', 'paths-ignore', 'branches-ignore'):
                self.assertNotIn(filter_name, events[event] or {})
        job = workflow['jobs']['recovery-and-plugin']
        self.assertNotIn('if', job)
        self.assertNotIn('continue-on-error', job)
        steps = job['steps']
        command = 'python3 -B tests/test_owned_native_acceptance.py'
        indexes = [i for i, step in enumerate(steps) if step.get('run') == command]
        self.assertEqual(len(indexes), 1, 'the owned safety suite must run unconditionally exactly once')
        selected = steps[indexes[0]]
        self.assertNotIn('if', selected)
        self.assertNotIn('continue-on-error', selected)
        for action, key, version in [('actions/setup-node@v4', 'node-version', '22'),
                                     ('actions/setup-python@v5', 'python-version', '3.12')]:
            setup = [(i, step) for i, step in enumerate(steps) if step.get('uses') == action]
            self.assertEqual(len(setup), 1)
            self.assertLess(setup[0][0], indexes[0])
            self.assertEqual(str(setup[0][1]['with'][key]), version)
        self.assertEqual(sum(step.get('run') == 'python3 -B tests/native-maintenance-consumers.test.py'
                             for step in steps), 1, 'retain the existing seven-test maintenance suite')
        self.assertLess(indexes[0], next(i for i, step in enumerate(steps)
                                        if step.get('name') == 'Shared runtime archive and migration contracts'))


class WorkspaceTests(unittest.TestCase):
    def test_special_file_and_oversized_read_refused_without_blocking(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                os.mkfifo(ws.root / 'fifo', 0o600)
                started = time.monotonic()
                with self.assertRaisesRegex(mod.Hold, 'NONREGULAR_OR_LINKED_FILE'):
                    ws.read('fifo')
                self.assertLess(time.monotonic() - started, 1)
                with (ws.root / 'large').open('wb') as f:
                    f.truncate(mod.MAX_FILE + 1)
                with self.assertRaisesRegex(mod.Hold, 'FILE_SIZE_BOUND'):
                    ws.read('large')
                os.unlink(ws.root / 'fifo')

    def test_root_replacement_is_not_followed(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                saved = Path(parent) / 'saved-root'
                ws.root.rename(saved)
                ws.root.mkdir(mode=0o700)
                try:
                    with self.assertRaisesRegex(mod.Hold, 'ROOT_IDENTITY_CHANGED'):
                        ws.write_new('never-created', b'x')
                    self.assertEqual(list(ws.root.iterdir()), [])
                finally:
                    ws.root.rmdir()
                    saved.rename(ws.root)

    def test_cleanup_bound_refuses_before_deleting_anything(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                ws.write_new('one', b'one', 0o640)
                ws.write_new('two', b'two')
                with self.assertRaisesRegex(mod.Hold, 'CLEANUP_BOUND'):
                    ws.remove(max_entries=1)
                self.assertEqual(ws.read('one'), (b'one', 0o640))
                self.assertTrue((ws.root / '.owner.json').exists())

    def test_exclusive_files_preserve_collision(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                self.assertEqual(ws.root.stat().st_mode & 0o777, 0o700)
                ws.write_new('data/mcp.json', b'original', 0o640)
                with self.assertRaises(mod.Hold):
                    ws.write_new('data/mcp.json', b'overwritten')
                self.assertEqual(ws.read('data/mcp.json'), (b'original', 0o640))

    def test_escape_symlink_hardlink_and_marker_refused(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                outside = Path(parent) / 'outside'
                outside.mkdir()
                (ws.root / 'escape').symlink_to(outside, target_is_directory=True)
                for path in ('../outside/x', '/tmp/never-write', 'escape/x'):
                    with self.assertRaises(mod.Hold):
                        ws.write_new(path, b'wrong')
                self.assertEqual(list(outside.iterdir()), [])
                ws.write_new('original', b'exact')
                os.link(ws.root / 'original', ws.root / 'alias')
                with self.assertRaises(mod.Hold):
                    ws.read('alias')
                saved = (ws.root / '.owner.json').read_bytes()
                (ws.root / '.owner.json').write_bytes(b'changed')
                with self.assertRaises(mod.Hold):
                    ws.write_new('blocked', b'wrong')
                (ws.root / '.owner.json').write_bytes(saved)

    def test_child_environment_has_no_ambient_authority(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                env = mod.child_environment(ws)
                for key in ('OPENAI_API_KEY', 'KUBECONFIG', 'HTTP_PROXY', 'PI_AGENT_SESSION_HOME',
                            'OMNIGENT_CONFIG_HOME', 'PYTHONPATH', 'NODE_OPTIONS', 'BASH_ENV', 'SSH_AUTH_SOCK'):
                    self.assertNotIn(key, env)
                self.assertEqual(env['UV_LINK_MODE'], 'copy')
                self.assertEqual(env['HOME'], str(ws.root / 'account'))


class ProcessTests(unittest.TestCase):
    def test_http_total_deadline_rejects_slow_trickle(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                process = self.child(ws, 'trickle')
                try:
                    endpoint = mod.Endpoint(process, int(process.line(3)))
                    began = time.monotonic()
                    with self.assertRaisesRegex(mod.Hold, 'HTTP_DEADLINE'):
                        endpoint.get('/identity', seconds=0.15)
                    self.assertLess(time.monotonic() - began, 1)
                finally:
                    process.stop()

    def child(self, ws, action, **options):
        return mod.OwnedProcess([sys.executable, str(HERE / 'fixtures/owned_acceptance_child.py'), action],
                                ws, mod.child_environment(ws), **options)

    def test_owned_listener_and_bounded_stop(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                env = mod.child_environment(ws)
                process = mod.OwnedProcess([sys.executable, str(HERE / 'fixtures/owned_acceptance_child.py'),
                                            'listen'], ws, env)
                try:
                    port = int(process.line(3))
                    endpoint = mod.Endpoint(process, port)
                    self.assertEqual(endpoint.get('/identity'), b'owned-loopback-fixture')
                finally:
                    process.stop()
                self.assertTrue(process.stopped)

    def test_unrelated_listener_is_not_even_requested(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                other = self.child(ws, 'listen')
                target = self.child(ws, 'sleep')
                try:
                    port = int(other.line(3))
                    target.line(3)
                    with self.assertRaisesRegex(mod.Hold, 'LISTENER_NOT_OWNED'):
                        mod.Endpoint(target, port).get('/identity')
                    self.assertIsNone(other.process.poll())
                finally:
                    other.stop()
                    target.stop()

    def test_command_failure_output_and_time_bounds(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                for action, seconds, maximum, code in [('fail', 3, 4096, 'COMMAND_FAILED'),
                        ('flood', 3, 4096, 'COMMAND_OUTPUT_BOUND'), ('sleep', 0.1, 4096, 'COMMAND_DEADLINE')]:
                    with self.subTest(action=action):
                        process = self.child(ws, action, maximum=maximum)
                        try:
                            with self.assertRaisesRegex(mod.Hold, code):
                                process.wait(seconds)
                        finally:
                            process.stop()
                        self.assertTrue(process.stopped)

    def test_replaced_pid_proof_refuses_signalling_other_child(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                a, b = self.child(ws, 'sleep'), self.child(ws, 'sleep')
                proof = a.proof
                try:
                    a.line(3)
                    b.line(3)
                    a.proof = b.proof  # Simulated substituted saved birth identity, not a live PID reuse claim.
                    with self.assertRaisesRegex(mod.Hold, 'PID_IDENTITY_CHANGED'):
                        a.stop()
                    self.assertIsNone(a.process.poll())
                    self.assertIsNone(b.process.poll())
                finally:
                    a.proof = proof
                    a.stop()
                    b.stop()

    def test_abnormal_guardian_exit_requires_hold(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                process = self.child(ws, 'sleep')
                process.line(3)
                os.killpg(process.proof[3], mod.signal.SIGKILL)
                process.process.wait(timeout=3)
                try:
                    with self.assertRaisesRegex(mod.Hold, 'TEARDOWN_UNCERTAIN'):
                        process.stop()
                finally:
                    process.close_pipes()

    def test_rpc_is_bounded_and_denial_propagates(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                process = self.child(ws, 'bridge')
                try:
                    rpc = mod.Rpc(process, 3)
                    rpc.initialize('synthetic-owned-safety-fixture')
                    self.assertEqual(rpc.tool('echo'), 'synthetic-result')
                    with self.assertRaisesRegex(mod.Hold, 'BRIDGE_TOOL_REFUSED'):
                        rpc.tool('refuse')
                finally:
                    process.stop()

    def test_doublefork_adopted_and_stubborn_child_escalated(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                for action in ('doublefork', 'stubborn'):
                    with self.subTest(action=action):
                        process = self.child(ws, action)
                        try:
                            line = process.line(3)
                            if action == 'doublefork':
                                adopted = int(line)
                                time.sleep(0.05)
                                self.assertIn(adopted, [p[0] for p in process.members()])
                                with self.assertRaisesRegex(mod.Hold, 'COMMAND_DEADLINE'):
                                    process.wait(0.05)
                        finally:
                            process.stop()
                        self.assertTrue(process.stopped)

    def test_hostile_parent_env_does_not_reach_actual_child(self):
        keys = {'OWNED_TEST_SECRET': 'not-forwarded', 'BASH_ENV': '/outside/do-not-source',
                'UV_LINK_MODE': 'hardlink', 'PI_AGENT_SESSION_HOME': '/outside/home'}
        saved = {k: os.environ.get(k) for k in keys}
        try:
            os.environ.update(keys)
            with tempfile.TemporaryDirectory() as parent:
                os.chmod(parent, 0o700)
                with mod.Workspace.create(Path(parent)) as ws:
                    result = mod.run_command([sys.executable, '-I', '-S', '-B',
                                              str(HERE / 'fixtures/owned_acceptance_child.py'), 'env'],
                                             ws, mod.child_environment(ws), 3)
                    actual = json.loads(result)
                    self.assertNotIn('OWNED_TEST_SECRET', actual)
                    self.assertNotIn('BASH_ENV', actual)
                    self.assertNotIn('PI_AGENT_SESSION_HOME', actual)
                    self.assertEqual(actual['UV_LINK_MODE'], 'copy')
                    self.assertEqual(actual['HOME'], str(ws.root / 'account'))
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


class ScenarioTests(unittest.TestCase):
    def test_selected_pipeline_executes_closure_overlay_binding_before_owned_web_fixture(self):
        """Execute pipeline source with explicit install/SDK test doubles only.

        Real closure staging, static Node overlays, binding and owned loopback
        lifecycle run. Installer commands and SDK bridge calls never execute.
        There is no fixture option or replacement guard in the production CLI.
        """
        events = []
        case = self
        class FixtureRun(mod.OwnedRun):
            def command(self, command, **kwargs):
                if command[:1] == ['/bin/bash']:
                    case.assertEqual(command[1], str(self.ws.root / 'source/install.sh'))
                    case.assertIn(command[2], mod.INSTALL_STAGES)
                    events.append('fixture-install-' + command[2])
                    if command[2] == 'wire':
                        case.seed_static_packages(self)
                    return b''
                case.assertEqual(command[0], str(self.ws.root / 'install/node/bin/node'))
                case.assertTrue(command[1].startswith(str(self.ws.root / 'source/rootfs/bin/omnigent-plugin-')))
                events.append('static-overlay')
                return super().command(command, **kwargs)

        class FixtureSharing(mod.SharingScenario):
            def bridge(self, present):
                events.append('fixture-sharing-' + str(present))
                self.sentinels.check()

        def finalize(run, source):
            mod.finalize_installed_sources(run, source)
            events.append('all37-bound')

        def owned_web_fixture(run, port):
            case.assertIn('all37-bound', events)
            events.append('owned-loopback-web-fixture')
            child = run.spawn([sys.executable, '-I', '-S', '-B',
                               str(HERE / 'fixtures/owned_acceptance_child.py'), 'listen'])
            endpoint = mod.Endpoint(child, int(child.line(3)))
            case.assertEqual(endpoint.get('/identity'), b'owned-loopback-fixture')
            return child

        tree = ast.parse((HERE / 'owned_native_acceptance.py').read_text())
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'acceptance_pipeline')
        namespace = {'stage_source': mod.stage_source, 'copy_artifact': mod.copy_artifact,
                     'INSTALL_STAGES': mod.INSTALL_STAGES, 'finalize_installed_sources': finalize,
                     'SharingScenario': FixtureSharing, 'reserve_port': mod.reserve_port,
                     'installed_web': owned_web_fixture, 'require': mod.require}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<selected-owned-pipeline>', 'exec'), namespace)
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            path = Path(parent) / 'synthetic-source-only-artifact.tar.gz'
            with tarfile.open(path, 'w:gz') as archive:
                member = tarfile.TarInfo('synthetic-only')
                member.mode = 0o600
                archive.addfile(member)
            run = FixtureRun(Path(parent), scope='safety-fixture')
            failure = None
            try:
                namespace['acceptance_pipeline'](run, HERE.parent, path, mod.digest(path.read_bytes()))
                self.assertEqual(events[:8], ['fixture-install-' + s for s in mod.INSTALL_STAGES])
                self.assertEqual(events[8:12], ['static-overlay'] * 3 + ['all37-bound'])
                self.assertEqual(events.count('owned-loopback-web-fixture'), 2)
                self.assertEqual(run.ws.read('source/VERSION')[0].strip(), b'0.2.16-rc.4')
            except BaseException as error:
                failure = error
                raise
            finally:
                receipt = run.finish(failure)
            self.assertEqual(receipt['status'], 'SAFETY_FIXTURE_COMPLETED')
            self.assertFalse(receipt['realUbuntuAcceptance'])
            self.assertFalse(receipt['realWSL2Acceptance'])

    def seed_static_packages(self, run):
        for name, dest in [('woowtech-pi-omnigent-plugin-0.3.42-rc.4.tgz', 'install/plugins/pi-omnigent-plugin'),
                           ('woowtech-pi-agent-shared-runtime-0.1.6.tgz', 'install/shared-runtime')]:
            with tarfile.open(HERE.parent / 'candidate-packages' / name) as archive:
                for member in archive:
                    self.assertTrue(member.isfile())
                    run.ws.write_new(dest + '/' + member.name.removeprefix('package/'),
                                     archive.extractfile(member).read(), member.mode)
        run.ws.write_new('install/node/bin/node', fixture_node_wrapper(FIXTURE_NODE), 0o755)

    def test_symlink_graph_shared_hop_component_and_deadline_bounds(self):
        with tempfile.TemporaryDirectory() as parent:
            path = Path(parent) / 'bounded-graph.tar.gz'
            def archive(links):
                with tarfile.open(path, 'w:gz') as tar:
                    for name, target in links:
                        member = tarfile.TarInfo(name)
                        member.mode = 0o644
                        member.type = tarfile.SYMTYPE
                        member.linkname = target
                        tar.addfile(member)
            # One chain exceeds per-resolution nesting; many shorter resolutions
            # exceed the shared expansion count despite each staying below 64.
            cases = [([(f'link{i}', f'link{i+1}') for i in range(65)] + [('link65', 'inside')], 'ARTIFACT_LINK_HOP_BOUND'),
                     ([(f'chain{i}', f'chain{i+1}') for i in range(59)] + [('chain59', 'inside')]
                      + [(f'alias{i}', 'chain0') for i in range(300)], 'ARTIFACT_LINK_HOP_BOUND'),
                     ([(f'alias{i}', './' * 490 + 'inside') for i in range(2100)], 'ARTIFACT_LINK_COMPONENT_BOUND')]
            for links, code in cases:
                with self.subTest(code=code):
                    archive(links)
                    with self.assertRaisesRegex(mod.Hold, code):
                        mod.validate_artifact_archive(path)
            with self.assertRaisesRegex(mod.Hold, 'ARTIFACT_ENUMERATION_BOUND'):
                mod.resolve_archive_links({'owned': 'inside'}, set(), time.monotonic() - 1)

    def test_complete_symlink_graph_rejects_chained_escape_and_cycles(self):
        with tempfile.TemporaryDirectory() as parent:
            path = Path(parent) / 'source-only-links.tar.gz'
            def archive(members):
                with tarfile.open(path, 'w:gz') as tar:
                    for name, target in members:
                        info = tarfile.TarInfo(name)
                        info.mode = 0o644
                        info.type = tarfile.SYMTYPE if target is not None else tarfile.REGTYPE
                        info.linkname = target or ''
                        tar.addfile(info, io.BytesIO(b''))
            cases = [
                [('deep/up', '../shallow'), ('escape', 'deep/up/../../victim')],
                [('one/two/up', '../../shallow'), ('escape', 'one/two/up/../../victim')],
                [('deep/up', '../shallow'), ('relay', 'deep/up'), ('escape', 'relay/../../victim')],
                [('a', 'b'), ('b', 'a')], [('a', 'a')],
                [('inside/a', '../b'), ('b', 'inside/a')],
                [('a', '.')], [('a', 'inside/..')],
            ]
            for members in cases:
                with self.subTest(members=members):
                    archive(members)
                    with self.assertRaises(mod.Hold):
                        mod.validate_artifact_archive(path)

    def test_complete_symlink_graph_accepts_legitimate_internal_node_bin_chain(self):
        with tempfile.TemporaryDirectory() as parent:
            path = Path(parent) / 'node-bin-links.tar.gz'
            with tarfile.open(path, 'w:gz') as tar:
                for name, target in [('node_modules/.bin/tool', '../pkg/bin/alias'),
                                     ('node_modules/pkg/bin/alias', './tool.js'),
                                     ('node_modules/pkg/bin/tool.js', None),
                                     ('dir/up', '../node_modules/pkg'),
                                     ('alias-to-node-bin', 'dir/up/bin/alias')]:
                    member = tarfile.TarInfo(name)
                    member.mode = 0o644
                    member.type = tarfile.SYMTYPE if target is not None else tarfile.REGTYPE
                    member.linkname = target or ''
                    tar.addfile(member, io.BytesIO(b''))
            mod.validate_artifact_archive(path)

    def test_fresh_real_package_overlays_precede_binding_and_web_start(self):
        """Static package patching only; no installed SDK or installer execution."""
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            failure = None
            try:
                mod.stage_source(run, HERE.parent)
                self.seed_static_packages(run)
                with self.assertRaisesRegex(mod.Hold, 'INSTALLED_PLUGIN_OVERLAY_DRIFT'):
                    mod.archive_bindings(run, HERE.parent)
                mod.finalize_installed_sources(run, HERE.parent)
                lock = mod.verify_source(HERE.parent)
                expected = lock['installedLinuxPluginMembers']
                self.assertEqual(len(expected), 37)
                for name, row in expected.items():
                    data, mode = run.ws.read('install/plugins/pi-omnigent-plugin/' + name)
                    self.assertEqual((mod.digest(data), len(data), mode), (row['sha256'], row['bytes'], row['mode']))
                mod.finalize_installed_sources(run, HERE.parent)  # Exact same scripts are idempotent.
                tree = ast.parse((HERE / 'owned_native_acceptance.py').read_text())
                pipeline = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'acceptance_pipeline')
                calls = sorted((n.lineno, n.func.id) for n in ast.walk(pipeline)
                               if isinstance(n, ast.Call) and isinstance(n.func, ast.Name))
                after = [line for line, name in calls if name == 'finalize_installed_sources']
                web = [line for line, name in calls if name == 'installed_web']
                self.assertEqual(len(after), 1)
                self.assertEqual(len(web), 2)
                self.assertLess(after[0], min(web))
            except BaseException as error:
                failure = error
                raise
            finally:
                run.finish(failure)

    def test_actual_manifest_helper_reads_complete_copied_source_closure(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            failure = None
            try:
                mod.stage_source(run, HERE.parent)
                result = fixture_manifest(run, FIXTURE_NODE)
                self.assertEqual(result['version'], '0.2.16-rc.4')
                self.assertEqual(len(result['packages']), 3)
                plugin = next(x for x in result['packages'] if 'omnigent' in x['file'])
                self.assertEqual(plugin['sha256'], mod.PLUGIN_SHA)
                self.assertEqual(run.ws.read('source/VERSION')[0].strip(), b'0.2.16-rc.4')
            except BaseException as error:
                failure = error
                raise
            finally:
                run.finish(failure)

    def test_legacy_entrypoint_is_an_unconditional_literal_refusal(self):
        """Inspect only: never execute the historical entrypoint."""
        import shlex
        lines = (HERE / 'smoke.sh').read_text().splitlines()
        commands = [line for line in lines if line and not line.startswith('#')]
        self.assertEqual(len(commands), 4)
        self.assertTrue(all(shlex.split(line)[0] == 'printf' and line.endswith('>&2') for line in commands[:-1]))
        self.assertEqual(commands[-1], 'exit 64')
        self.assertEqual(os.readlink(HERE / 'smoke-linux.sh'), 'smoke.sh')

    def test_synthetic_composition_listener_rpc_state_restart_cleanup(self):
        """Public safety composition; no installed helper/SDK/installer is run."""
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            failure = None
            try:
                scenario = mod.SharingScenario(run)
                listener = run.spawn([sys.executable, '-I', '-S', '-B', str(HERE / 'fixtures/owned_acceptance_child.py'), 'listen'])
                endpoint = mod.Endpoint(listener, int(listener.line(3)))
                self.assertEqual(endpoint.get('/identity'), b'owned-loopback-fixture')
                first = listener.proof
                scenario.add()
                bridge = run.spawn([sys.executable, '-I', '-S', '-B', str(HERE / 'fixtures/owned_acceptance_child.py'), 'bridge'])
                rpc = mod.Rpc(bridge, 3)
                rpc.initialize('synthetic-owned-safety-fixture')
                self.assertEqual(rpc.tool('echo'), 'synthetic-result')
                bridge.stop()
                scenario.remove()
                scenario.sentinels.check()
                listener.stop()
                replacement = run.spawn([sys.executable, '-I', '-S', '-B', str(HERE / 'fixtures/owned_acceptance_child.py'), 'listen'])
                port = int(replacement.line(3))
                self.assertNotEqual(first[:2], replacement.proof[:2])
                self.assertEqual(mod.Endpoint(replacement, port).get('/identity'), b'owned-loopback-fixture')
                scenario.sentinels.check()
            except BaseException as error:
                failure = error
                raise
            finally:
                receipt = run.finish(failure)
            self.assertEqual(receipt['status'], 'SAFETY_FIXTURE_COMPLETED')
            self.assertTrue(receipt['teardownVerified'])
            self.assertFalse(receipt['privateRootRetained'])
            for key in ('realUbuntuAcceptance', 'realWSL2Acceptance', 'providerAcceptance', 'rebootAcceptance'):
                self.assertIs(receipt[key], False)

    def test_artifact_archive_escape_types_and_link_parents_refused(self):
        with tempfile.TemporaryDirectory() as parent:
            path = Path(parent) / 'synthetic.tar.gz'
            def archive(members):
                with tarfile.open(path, 'w:gz') as tar:
                    for name, kind, link in members:
                        info = tarfile.TarInfo(name)
                        info.mode = 0o644
                        info.type = kind
                        info.linkname = link
                        tar.addfile(info, io.BytesIO(b''))
            archive([('node_modules/.bin/tool', tarfile.SYMTYPE, '../pkg/bin/tool'),
                     ('node_modules/pkg/bin/tool', tarfile.REGTYPE, '')])
            mod.validate_artifact_archive(path)
            cases = [[('../escape', tarfile.REGTYPE, '')], [('/outside', tarfile.REGTYPE, '')],
                     [('a', tarfile.SYMTYPE, '../../outside')], [('a', tarfile.LNKTYPE, 'b')],
                     [('a', tarfile.FIFOTYPE, '')], [('a', tarfile.REGTYPE, ''), ('a', tarfile.REGTYPE, '')],
                     [('a', tarfile.SYMTYPE, 'inside'), ('a/file', tarfile.REGTYPE, '')]]
            for members in cases:
                with self.subTest(members=members):
                    archive(members)
                    with self.assertRaises(mod.Hold):
                        mod.validate_artifact_archive(path)
            with self.assertRaisesRegex(mod.Hold, 'ARTIFACT_ENUMERATION_BOUND'):
                mod.validate_artifact_archive(path, seconds=0)
            with tarfile.open(path, 'w:gz', format=tarfile.PAX_FORMAT) as archive:
                member = tarfile.TarInfo('owned')
                member.pax_headers = {'comment': 'x' * (1024 * 1024 + 1)}
                archive.addfile(member)
            with self.assertRaisesRegex(mod.Hold, 'ARTIFACT_METADATA_BOUND'):
                mod.validate_artifact_archive(path)

    def test_actual_sigterm_uses_shared_interrupt_cleanup(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            child = subprocess.Popen([sys.executable, '-I', '-S', '-B',
                                      str(HERE / 'fixtures/owned_acceptance_child.py'), 'interrupt-run', parent],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                with mod.selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, mod.selectors.EVENT_READ)
                    self.assertTrue(selector.select(5), 'owned fixture readiness deadline')
                ready = json.loads(child.stdout.readline(8193))
                self.assertTrue(ready['ready'])
                os.kill(child.pid, mod.signal.SIGTERM)
                stdout, stderr = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, stderr.decode())
                receipt = json.loads(stdout)
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertEqual(receipt['failure'], 'INTERRUPTED')
                self.assertTrue(receipt['teardownVerified'])
                self.assertTrue(receipt['privateRootRetained'])
                self.assertIsNone(mod.identity(ready['childProof'][0]))
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
                child.stdout.close()
                child.stderr.close()

    def test_provider_bridge_binding_and_sentinel_changes_refused(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            scenario = mod.SharingScenario(run)
            env = {'PI_SHARED_DATA_DIR': str(run.ws.root / 'install/data'),
                   'PI_SHARED_HOME': str(run.ws.root / 'install/home'), 'PI_SHARED_BRIDGE': '1'}
            entry = {'command': str(scenario.node), 'args': [str(scenario.bundle / 'bin/bridge.mjs')], 'env': env}
            cpath = 'install/home/.claude.json'
            tpath = 'install/home/.codex/config.toml'
            value = {'ownedSentinel': scenario.tag, 'mcpServers': {'pi_shared_runtime': entry}}
            run.ws.replace(cpath, run.ws.read(cpath), json.dumps(value).encode())
            toml = ('owned_sentinel = ' + json.dumps(scenario.tag) + '\n[mcp_servers.pi_shared_runtime]\ncommand = '
                    + json.dumps(str(scenario.node)) + '\nargs = [' + json.dumps(str(scenario.bundle / 'bin/bridge.mjs'))
                    + ']\n[mcp_servers.pi_shared_runtime.env]\n'
                    + ''.join(k + ' = ' + json.dumps(v) + '\n' for k, v in env.items())).encode()
            run.ws.replace(tpath, run.ws.read(tpath), toml)
            mod.check_provider_bridges(run.ws, scenario.node, scenario.bundle, scenario.tag)
            value['mcpServers']['pi_shared_runtime']['command'] = '/outside/node'
            run.ws.replace(cpath, run.ws.read(cpath), json.dumps(value).encode())
            with self.assertRaisesRegex(mod.Hold, 'PROVIDER_BRIDGE_BINDING'):
                mod.check_provider_bridges(run.ws, scenario.node, scenario.bundle, scenario.tag)
            path, original = next(iter(scenario.sentinels.files.items()))
            run.ws.replace(path, original, b'changed')
            with self.assertRaisesRegex(mod.Hold, 'UNRELATED_SENTINEL_CHANGED'):
                scenario.sentinels.check()
            run.finish(mod.Hold('synthetic-substitution'))

    def test_sync_command_refusal_cannot_produce_completed_receipt(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            sentinels = mod.Sentinels(run.ws)
            sentinels.seed()
            try:
                run.command([sys.executable, '-I', '-S', '-B', str(HERE / 'fixtures/owned_acceptance_child.py'), 'fail'], seconds=3)
                self.fail('refusal was swallowed')
            except mod.Hold as error:
                sentinels.check()
                receipt = run.finish(error)
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertEqual(receipt['failure'], 'COMMAND_FAILED')

    def test_source_plan_never_starts_runtime_and_excludes_service_stages(self):
        result = subprocess.run([sys.executable, '-B', str(HERE / 'owned_native_acceptance.py'),
                                 '--mode', 'source-plan', '--platform', 'wsl2', '--supervisor', 'owned-pgid'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan['status'], 'SOURCE_PLAN_ONLY')
        self.assertEqual(plan['installStages'], ['node', 'fetch', 'piweb', 'clis', 'shared', 'paseo', 'omnigent', 'wire'])
        self.assertFalse(plan['realUbuntuAcceptance'])
        self.assertFalse(plan['realWSL2Acceptance'])
        self.assertFalse(plan['providerAcceptance'])
        self.assertFalse(plan['rebootAcceptance'])

    def test_artifact_hash_and_symlink_substitution_refused_before_child(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            original = Path(parent) / 'fixture.tar.gz'
            original.write_bytes(b'not-an-install-artifact')
            alias = Path(parent) / 'alias'
            alias.symlink_to(original)
            for path, expected, code in [(alias, mod.digest(original.read_bytes()), 'ARTIFACT_PATH'),
                                        (original, '0' * 64, 'ARTIFACT_HASH_MISMATCH')]:
                with self.subTest(code=code), self.assertRaisesRegex(mod.Hold, code):
                    mod.copy_artifact(run, path, expected)
            self.assertEqual(run.processes, [])
            run.finish(mod.Hold('fixture-refusal'))

    def test_source_lock_substitution_and_mode_rejected(self):
        self.assertEqual(len(mod.verify_source(HERE.parent)['files']), 40)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            lock = mod.verify_source(HERE.parent)
            for row in lock['files'] + [{'path': 'tests/owned-native-acceptance.lock.json'}]:
                src, dest = HERE.parent / row['path'], root / row['path']
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)
            mod.verify_source(root)
            path = root / 'lib/pins.sh'
            original = path.read_bytes()
            path.write_bytes(original + b'\n# substitution\n')
            with self.assertRaisesRegex(mod.Hold, 'SOURCE_INPUT_DRIFT'):
                mod.verify_source(root)
            path.write_bytes(original)
            path.chmod(0o600)
            with self.assertRaisesRegex(mod.Hold, 'SOURCE_INPUT_DRIFT'):
                mod.verify_source(root)
            lockfile = root / 'tests/owned-native-acceptance.lock.json'
            lockfile.write_bytes(b'{}')
            with self.assertRaisesRegex(mod.Hold, 'SOURCE_LOCK_DRIFT'):
                mod.verify_source(root)

    def test_platform_and_supervisor_limits_are_explicit(self):
        release = 'ID=ubuntu\nVERSION_ID="24.04"\n'
        self.assertFalse(mod.platform_evidence('ubuntu', release, '6.8.0-generic', 'owned-pgid')['rebootTested'])
        self.assertTrue(mod.platform_evidence('wsl2', release, '6.6.87.2-microsoft-standard-WSL2', 'owned-pgid')['wsl2KernelObserved'])
        for args in [('wsl2', release, '6.8.0-generic', 'owned-pgid'),
                     ('ubuntu', release, 'microsoft-standard-WSL2', 'owned-pgid'),
                     ('wsl2', release, '4.4.0-Microsoft', 'owned-pgid'),
                     ('ubuntu', 'ID=debian', 'generic', 'owned-pgid'),
                     ('ubuntu', release, 'generic', 'systemd')]:
            with self.subTest(args=args), self.assertRaises(mod.Hold):
                mod.platform_evidence(*args)

    def test_skill_mcp_and_unrelated_sentinels_preserved(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            scenario = mod.SharingScenario(run)
            scenario.add()
            self.assertIn(scenario.test_name, json.loads(run.ws.read(scenario.data)[0])['mcpServers'])
            scenario.remove()
            remaining = json.loads(run.ws.read(scenario.data)[0])['mcpServers']
            self.assertEqual(remaining, {scenario.keep_name: scenario.entry})
            scenario.sentinels.check()
            receipt = run.finish()
            self.assertEqual(receipt['status'], 'SAFETY_FIXTURE_COMPLETED')
            self.assertFalse(receipt['realUbuntuAcceptance'])
            self.assertFalse(receipt['realWSL2Acceptance'])

    def test_interruption_stops_exact_child_and_retains_private_evidence(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            process = run.spawn([sys.executable, str(HERE / 'fixtures/owned_acceptance_child.py'), 'listen'])
            process.line(3)
            receipt = run.finish(KeyboardInterrupt())
            self.assertEqual(receipt['status'], 'HOLD')
            self.assertEqual(receipt['failure'], 'KeyboardInterrupt')
            self.assertTrue(receipt['teardownVerified'])
            self.assertTrue(receipt['privateRootRetained'])
            self.assertIsNotNone(process.process.poll())

    def test_failed_teardown_holds_and_does_not_remove_root(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            run = mod.OwnedRun(Path(parent), scope='safety-fixture')
            process = run.spawn([sys.executable, str(HERE / 'fixtures/owned_acceptance_child.py'), 'sleep'])
            process.line(3)
            proof = process.proof
            try:
                process.proof = (proof[0], proof[1] + 1, *proof[2:])
                receipt = run.finish()
                self.assertEqual(receipt['status'], 'HOLD')
                self.assertFalse(receipt['teardownVerified'])
                self.assertTrue(run.ws.root.exists())
                self.assertIsNone(process.process.poll())
            finally:
                process.proof = proof
                process.stop()
                run.ws.close(remove=True)

    def test_occupied_loopback_port_refused(self):
        with mod.reserve_port() as first:
            with self.assertRaisesRegex(mod.Hold, 'PORT_COLLISION'):
                mod.reserve_port(first.getsockname()[1])

    def test_sync_failure_or_stale_report_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as parent:
            os.chmod(parent, 0o700)
            with mod.Workspace.create(Path(parent)) as ws:
                ws.write_new('install/data/mcp.json', b'{"mcpServers":{"pi_shared_memory":{}}}')
                body = json.dumps({'conflicts': ['refused'], 'mcpNames': ['pi_shared_memory']}).encode()
                ws.write_new('install/data/shared-runtime/last-sync.json', body)
                with self.assertRaisesRegex(mod.Hold, 'SYNC_REFUSED'):
                    mod.check_sync(ws, None)
                with self.assertRaisesRegex(mod.Hold, 'SYNC_DID_NOT_ADVANCE'):
                    mod.check_sync(ws, body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
