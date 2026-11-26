#!/usr/bin/env python3
"""Source-only controller contracts; synthetic metadata, no SDK or installer."""
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tracemalloc
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('owned_ci_controller', ROOT / 'scripts/owned-ubuntu-acceptance-ci.py')
controller = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(controller)


def raw_json(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def row(root, name):
    raw = (root / name).read_bytes()
    mode = (root / name).stat().st_mode & 0o777
    return dict(path=name, sha256=digest(raw), bytes=len(raw), mode=mode,
                gitMode='100755' if mode == 0o755 else '100644',
                gitBlob=hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest())


class SyntheticAuthority:
    """Independent temp-only documents. Never final authority or a real driver."""
    def __init__(self, root):
        self.root = root
        root.chmod(0o700)  # Clear a temporary parent's inherited setgid bit; do not weaken private().
        self.lock = json.loads((ROOT / controller.LOCK).read_text())
        installer = json.loads((ROOT / 'tests/owned-native-acceptance.lock.json').read_text())
        names = [r['path'] for r in installer['files']]
        names += ['tests/owned-native-acceptance.lock.json', 'scripts/build-piweb-artifact.sh']
        for name in names:
            self.copy(name)
        roles = {
            'driver': ['tests/owned_native_acceptance.py'],
            'supervisor': ['tests/owned_acceptance_supervisor.py'],
            'controller': ['scripts/owned-ubuntu-acceptance-ci.py'],
            'procHelpers': ['tests/synthetic_proc.py'],
            'custodyHelpers': ['tests/synthetic_custody.py'],
            'fixtures': ['tests/fixtures/owned_acceptance_child.py'],
            'safetySuites': ['tests/test_owned_native_acceptance.py', 'tests/test_owned_ci_authority.py'],
            'workflows': ['.github/workflows/deployment-ci.yml', '.github/workflows/owned-ubuntu-acceptance.yml'],
            'docs': ['docs/OWNED-NATIVE-ACCEPTANCE.md', 'docs/OWNED-UBUNTU-GENUINE-CI.md',
                     'docs/TESTING.md', 'docs/plans/2026-11-22-owned-native-acceptance.md',
                     'docs/plans/2026-11-22-owned-ubuntu-genuine-ci.md'],
            'compatibilityEntries': ['tests/smoke.sh'],
        }
        roles = {key: sorted(value) for key, value in roles.items()}
        for name in sorted({n for names in roles.values() for n in names}):
            if name.startswith('tests/synthetic_'):
                self.write(name, b'# SYNTHETIC temp-only source; never executed.\n')
            else:
                self.copy(name)
        fields = {k: '/' + k for k in (
            'schema', 'scope', 'status', 'piwebArtifactSha256', 'runToken',
            'sourceAuthoritySha256', 'supervisor', 'teardownVerified', 'privateRootRetained',
            'realUbuntuAcceptance', 'realWSL2Acceptance', 'providerAcceptance', 'rebootAcceptance',
            'baseSourceReference', 'sourceLockSha256', 'pluginSha256')}
        self.invocation = {
            'schema': 'owned-driver-invocation/v1', 'custodyMode': 'synthetic-custody',
            'argv': ['{python}', '-B', '{driver}', '--mode', 'acceptance', '--platform', 'ubuntu',
                     '--supervisor', '{custody_mode}', '--parent', '{parent}',
                     '--piweb-artifact', '{artifact}', '--piweb-artifact-sha256', '{artifact_sha256}',
                     '--deadline-seconds', '1800', '--fixture-run-token', '{run_token}',
                     '--fixture-source-authority', '{authority_sha256}'],
            'receiptContract': {'schema': 'owned-driver-receipt-contract/v1', 'schemaValue': 1,
                                'scopeValue': 'owned-platform-scenario',
                                'completedStatus': 'OWNED_SCENARIO_COMPLETED',
                                'filePattern': 'native-acceptance-*.receipt.json', 'fields': fields},
        }
        self.freeze = {'schema': 'owned-component-source/v1', 'classification': 'SYNTHETIC_FIXTURE',
                       'files': [], 'roles': roles, 'sourceRowsSha256': ''}
        self.refresh()

    def write(self, name, raw, mode=0o644):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(mode)

    def copy(self, name):
        path = ROOT / name
        self.write(name, path.read_bytes(), path.stat().st_mode & 0o777)

    def refresh(self):
        names = sorted({n for names in self.freeze['roles'].values() for n in names})
        self.freeze['files'] = [row(self.root, n) for n in names]
        self.freeze['sourceRowsSha256'] = digest(json.dumps(
            self.freeze['files'], sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode())
        fraw = raw_json(self.freeze)
        # A real in-memory source tar of these synthetic fixture inputs. Never final authority.
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as tar:
            for item in self.freeze['files']:
                raw = (self.root / item['path']).read_bytes()
                member = tarfile.TarInfo(item['path'])
                member.size, member.mode, member.mtime = len(raw), item['mode'], 0
                tar.addfile(member, io.BytesIO(raw))
        self.synthetic_archive = stream.getvalue()
        archive = {'sha256': digest(self.synthetic_archive), 'bytes': len(self.synthetic_archive),
                   'memberCount': len(names), 'sourceRowsSha256': self.freeze['sourceRowsSha256']}
        self.handoff = {'schema': 'owned-component-handoff/v1', 'classification': 'SYNTHETIC_FIXTURE',
                        'freezeSha256': digest(fraw), 'archive': archive, 'roles': self.freeze['roles'],
                        'closure': names, 'invocation': self.invocation}
        self.publish()

    def publish(self):
        """Re-pin mutated temp documents, without repairing their semantic disagreements."""
        names = [r['path'] for r in self.freeze['files']]
        fraw = raw_json(self.freeze)
        self.handoff['freezeSha256'] = digest(fraw)
        self.write('tests/owned-acceptance-component-source.json', fraw)
        self.write('tests/owned-acceptance-component-handoff.json', raw_json(self.handoff))
        pin = lambda name: {k: v for k, v in row(self.root, name).items() if k in ('path', 'sha256', 'bytes', 'mode')}
        self.lock.update(status='COMPOSED', componentSource={
            'freeze': pin('tests/owned-acceptance-component-source.json'),
            'handoff': pin('tests/owned-acceptance-component-handoff.json'),
            'files': self.freeze['files'], 'fileCount': len(names),
            'sourceRowsSha256': self.freeze['sourceRowsSha256'], 'roles': self.freeze['roles'],
            'archive': self.handoff['archive']})
        self.write(controller.LOCK, raw_json(self.lock))

    def state_and_receipt(self):
        authority = controller.verify_authority(self.root)
        state = {'sourceAuthority': authority, 'candidateCommit': 'a' * 40, 'candidateTree': 'b' * 40,
                 'runToken': 'c' * 64,
                 'runner': {'CI_REPOSITORY': 'synthetic/fixture', 'CI_RUN_ID': '123', 'CI_RUN_ATTEMPT': '1'}}
        receipt = {'schema': 1, 'scope': 'owned-platform-scenario', 'status': 'OWNED_SCENARIO_COMPLETED',
                   'piwebArtifactSha256': 'd' * 64, 'runToken': state['runToken'],
                   'sourceAuthoritySha256': authority['authoritySha256'], 'supervisor': 'synthetic-custody',
                   'teardownVerified': True, 'privateRootRetained': False,
                   'realUbuntuAcceptance': False, 'realWSL2Acceptance': False,
                   'providerAcceptance': False, 'rebootAcceptance': False,
                   'baseSourceReference': controller.BASE_COMMIT,
                   'sourceLockSha256': controller.INSTALLER['sha256'],
                   'pluginSha256': '4763b1bc98eb64a7f8cba890a9c7fdf8907a3cab001eb5ccaa246cd45642a846'}
        return state, receipt


class AuthorityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixture = SyntheticAuthority(Path(self.temp.name))

    def test_uncomposed_interim_cannot_admit_a_target(self):
        self.fixture.lock['status'] = 'COMPOSITION_PENDING'
        self.fixture.write(controller.LOCK, raw_json(self.fixture.lock))
        with self.assertRaisesRegex(controller.Hold, 'COMPOSITION_PENDING'):
            controller.verify_authority(self.fixture.root)

    def test_current_composition_binds_the_reviewed_source(self):
        proof = controller.verify_authority(ROOT)
        self.assertEqual(proof['classification'], 'REVIEWED_SOURCE_ONLY')
        self.assertEqual(proof['custodyMode'], 'owned-subreaper')
        self.assertIn('tests/test_owned_custody_runtime_p2.py', proof['roles']['safetySuites'])

    def test_complete_synthetic_closure_is_verified_but_not_production_authority(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = SyntheticAuthority(Path(tmp))
            proof = controller.verify_authority(fixture.root)
            self.assertEqual(proof['classification'], 'SYNTHETIC_FIXTURE')
            self.assertEqual(proof['custodyMode'], 'synthetic-custody')
            self.assertEqual(len(proof['files']), 16)

    def test_legacy_v4_cannot_authorize_changed_controller(self):
        fixture = self.fixture
        legacy = dict(fixture.lock, schema='owned-ubuntu-genuine-ci-inputs/v1')
        fixture.write(controller.LOCK, raw_json(legacy))
        with self.assertRaisesRegex(controller.Hold, 'AUTHORITY_SCHEMA'):
            controller.verify_authority(fixture.root)

    def test_synthetic_authority_never_reaches_operational_head_or_target_probe(self):
        with mock.patch.object(controller, 'git', side_effect=AssertionError('must refuse before Git/target')):
            with self.assertRaisesRegex(controller.Hold, 'SYNTHETIC_AUTHORITY_NOT_OPERATIONAL'):
                controller.source_identity('a' * 40, source=self.fixture.root)

    def test_prepared_authority_rejects_new_valid_but_different_component(self):
        fixture = self.fixture
        prepared = controller.verify_authority(fixture.root)
        fixture.write('tests/synthetic_proc.py', b'# Different SYNTHETIC source\n')
        fixture.refresh()
        self.assertNotEqual(prepared, controller.verify_authority(fixture.root))
        with self.assertRaisesRegex(controller.Hold, 'PREPARED_AUTHORITY_CHANGED'):
            controller.check_prepared_authority(prepared, fixture.root)

    def test_source_drift_after_preparation_is_rejected(self):
        fixture = self.fixture
        prepared = controller.verify_authority(fixture.root)
        fixture.write('tests/synthetic_custody.py', b'# changed without a new freeze\n')
        with self.assertRaisesRegex(controller.Hold, 'SOURCE_PIN_DRIFT'):
            controller.check_prepared_authority(prepared, fixture.root)

    def test_new_row_under_old_freeze_is_rejected(self):
        fixture = self.fixture
        lock = json.loads((fixture.root / controller.LOCK).read_text())
        lock['componentSource']['files'][0]['sha256'] = '0' * 64
        fixture.write(controller.LOCK, raw_json(lock))
        with self.assertRaisesRegex(controller.Hold, 'COMPONENT_BINDING'):
            controller.verify_authority(fixture.root)

    def test_immutable_packager_and_installer_inputs_cannot_be_rebased(self):
        fixture = self.fixture
        for name in ['scripts/build-piweb-artifact.sh', 'VERSION',
                     'rootfs/bin/omnigent-plugin-session-home-patch.mjs']:
            with self.subTest(path=name):
                original = (fixture.root / name).read_bytes()
                fixture.write(name, original + b'\n')
                with self.assertRaisesRegex(controller.Hold, 'IMMUTABLE_SOURCE_DRIFT'):
                    controller.verify_authority(fixture.root)
                fixture.write(name, original, (ROOT / name).stat().st_mode & 0o777)

    def test_duplicate_json_key_is_not_last_writer_wins(self):
        fixture = self.fixture
        raw = (fixture.root / controller.LOCK).read_bytes()
        fixture.write(controller.LOCK, raw.replace(b'{', b'{"status":"COMPOSED",', 1))
        with self.assertRaisesRegex(controller.Hold, 'DUPLICATE_JSON_KEY'):
            controller.verify_authority(fixture.root)

    def test_metadata_raw_reformat_requires_new_pin(self):
        fixture = self.fixture
        path = fixture.root / controller.FREEZE
        fixture.write(controller.FREEZE, path.read_bytes() + b'\n')
        with self.assertRaisesRegex(controller.Hold, 'METADATA_PIN_DRIFT'):
            controller.verify_authority(fixture.root)

    def test_linked_and_hardlinked_component_files_are_rejected(self):
        fixture = self.fixture
        path = fixture.root / 'tests/synthetic_proc.py'
        original = path.read_bytes()
        path.unlink()
        path.symlink_to(ROOT / 'tests/owned_native_acceptance.py')
        with self.assertRaisesRegex(controller.Hold, 'LINKED_PATH'):
            controller.verify_authority(fixture.root)
        path.unlink()
        fixture.write('tests/original.py', original)
        os.link(fixture.root / 'tests/original.py', path)
        with self.assertRaisesRegex(controller.Hold, 'FILE_TYPE_OR_BOUND'):
            controller.verify_authority(fixture.root)

    def test_raw_receipt_binding_does_not_reformat_original(self):
        state, receipt = self.fixture.state_and_receipt()
        raw = json.dumps(receipt, separators=(', ', ': ')).encode() + b'\n\n'
        proof = controller.bind_receipt(raw, state, 'd' * 64)
        self.assertEqual(proof['rawReceiptSha256'], digest(raw))
        self.assertEqual(proof['classification'], 'SYNTHETIC_FIXTURE')
        self.assertFalse(proof['productionAdmission'])
        self.assertEqual(proof['receiptStatus'], 'OWNED_SCENARIO_COMPLETED')

    def test_receipt_replay_or_narrowed_admission_cannot_get_new_envelope(self):
        state, receipt = self.fixture.state_and_receipt()
        mutations = {'runToken': '0' * 64, 'sourceAuthoritySha256': '0' * 64,
                     'supervisor': 'owned-pgid', 'piwebArtifactSha256': '0' * 64,
                     'baseSourceReference': '0' * 40, 'scope': 'safety-fixture',
                     'sourceLockSha256': '0' * 64, 'pluginSha256': '0' * 64,
                     'providerAcceptance': True, 'realUbuntuAcceptance': True}
        for field, value in mutations.items():
            with self.subTest(field=field):
                altered = dict(receipt, **{field: value})
                with self.assertRaises(controller.Hold):
                    controller.bind_receipt(raw_json(altered), state, 'd' * 64)

    def test_failure_and_uncertain_private_root_are_preserved_as_hold(self):
        state, receipt = self.fixture.state_and_receipt()
        receipt.update(status='HOLD', teardownVerified=False, privateRootRetained=True)
        proof = controller.bind_receipt(raw_json(receipt), state, 'd' * 64)
        self.assertEqual(proof['receiptStatus'], 'HOLD')
        self.assertFalse(proof['teardownVerified'])
        self.assertTrue(proof['privateRootRetained'])
        self.assertEqual(proof['bindingOutcome'], 'HOLD')

    def test_collection_preserves_raw_bytes_with_no_twelfth_artifact(self):
        fixture = self.fixture
        state, receipt = fixture.state_and_receipt()
        raw = raw_json(receipt) + b'\n'
        acceptance = fixture.root / 'acceptance'
        acceptance.mkdir(mode=0o700)
        path = acceptance / 'native-acceptance-synthetic.receipt.json'
        path.write_bytes(raw)
        path.chmod(0o600)
        evidence = fixture.root / 'evidence'
        evidence.mkdir(mode=0o700)
        result = controller.collect_bound_receipt(state, fixture.root, evidence, 'd' * 64)
        self.assertEqual((evidence / 'driver-receipt.json').read_bytes(), raw)
        self.assertEqual(sorted(x.name for x in evidence.iterdir()), ['driver-receipt.json'])
        self.assertEqual(result['sourceRunReceiptBinding']['rawReceiptSha256'], digest(raw))

    def test_invocation_comes_from_handoff_with_explicit_nonce_and_authority(self):
        fixture = self.fixture
        state, _ = fixture.state_and_receipt()
        recorded = {'path': str(fixture.root / 'artifact.tar.gz'), 'sha256': 'd' * 64}
        argv = controller.render_invocation(state, fixture.root, recorded)
        self.assertEqual(argv[:3], ['/usr/bin/python3', '-B', str(ROOT / state['sourceAuthority']['roles']['driver'][0])])
        self.assertIn('synthetic-custody', argv)
        self.assertIn(state['runToken'], argv)
        self.assertIn(state['sourceAuthority']['authoritySha256'], argv)
        self.assertNotIn('owned-pgid', argv)

    def test_target_guard_denies_pending_source_before_any_target_spawn(self):
        marker = self.fixture.root / 'SHOULD_NOT_EXIST'
        self.fixture.lock['status'] = 'COMPOSITION_PENDING'
        self.fixture.write(controller.LOCK, raw_json(self.fixture.lock))
        with mock.patch.object(controller, 'SOURCE', self.fixture.root):
            with self.assertRaisesRegex(controller.Hold, 'COMPOSITION_PENDING'):
                controller.command({'candidateCommit': 'a' * 40, 'sourceAuthority': {}}, self.fixture.root, 'not-started',
                                   [sys.executable, '-c', 'open(' + repr(str(marker)) + ',"w").write("bad")'], {}, 1)
        self.assertFalse(marker.exists())

    def test_metadata_mutations_fail_even_with_refreshed_outer_document_pins(self):
        mutations = [
            ('missing_helper_role', lambda f: f.freeze['roles']['procHelpers'].clear()),
            ('unknown_role', lambda f: f.freeze['roles'].update(provider=['tests/synthetic_proc.py'])),
            ('omitted_source', lambda f: f.freeze['files'].pop()),
            ('duplicate_row', lambda f: f.freeze['files'].append(dict(f.freeze['files'][0]))),
            ('outside_path', lambda f: f.freeze['files'][0].update(path='../outside.py')),
            ('boolean_size', lambda f: f.freeze['files'][0].update(bytes=True)),
            ('git_mode', lambda f: f.freeze['files'][0].update(gitMode='120000')),
            ('special_mode', lambda f: f.freeze['files'][0].update(mode=0o4755)),
            ('self_pinning_lock', lambda f: f.freeze['files'][0].update(path=controller.LOCK)),
            ('missing_closure', lambda f: f.handoff['closure'].pop()),
            ('archive_count', lambda f: f.handoff['archive'].update(memberCount=1)),
            ('unknown_invocation', lambda f: f.invocation.update(schema='unknown/v99')),
            ('missing_mode', lambda f: f.invocation.pop('custodyMode')),
            ('missing_run_token', lambda f: f.invocation['argv'].remove('{run_token}')),
            ('unknown_token', lambda f: f.invocation['argv'].append('{ambient_home}')),
            ('python_command_injection', lambda f: f.invocation['argv'].insert(1, '-c')),
            ('source_plan_substitution', lambda f: f.invocation['argv'].__setitem__(
                f.invocation['argv'].index('acceptance'), 'source-plan')),
            ('receipt_pointer_escape', lambda f: f.invocation['receiptContract']['fields'].update(runToken='/../secret')),
        ]
        for name, mutate in mutations:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as tmp:
                fixture = SyntheticAuthority(Path(tmp))
                mutate(fixture)
                fixture.publish()
                with self.assertRaises(controller.Hold):
                    controller.verify_authority(fixture.root)

    def test_handoff_cannot_substitute_roles_from_another_component(self):
        fixture = self.fixture
        fixture.handoff['roles'] = json.loads(json.dumps(fixture.handoff['roles']))
        fixture.handoff['roles']['driver'] = ['tests/synthetic_proc.py']
        fixture.publish()
        with self.assertRaisesRegex(controller.Hold, 'COMPONENT_BINDING'):
            controller.verify_authority(fixture.root)

    def test_source_mode_drift_cannot_be_hidden_by_identical_bytes(self):
        path = self.fixture.root / 'tests/synthetic_proc.py'
        path.chmod(0o755)
        with self.assertRaisesRegex(controller.Hold, 'SOURCE_PIN_DRIFT'):
            controller.verify_authority(self.fixture.root)

    def test_missing_component_metadata_is_not_an_old_v4_fallback(self):
        (self.fixture.root / controller.HANDOFF).unlink()
        with self.assertRaisesRegex(controller.Hold, 'AUTHORITY_UNREADABLE'):
            controller.verify_authority(self.fixture.root)

    def test_oversized_component_metadata_is_bounded(self):
        self.fixture.write(controller.FREEZE, b' ' * 65537)
        with self.assertRaisesRegex(controller.Hold, 'FILE_TYPE_OR_BOUND'):
            controller.verify_authority(self.fixture.root)

    def test_ambiguous_receipts_never_select_the_newest(self):
        fixture = self.fixture
        state, receipt = fixture.state_and_receipt()
        acceptance = fixture.root / 'acceptance'
        acceptance.mkdir(mode=0o700)
        for tag in ('first', 'second'):
            path = acceptance / ('native-acceptance-' + tag + '.receipt.json')
            path.write_bytes(raw_json(receipt))
            path.chmod(0o600)
        evidence = fixture.root / 'evidence'
        evidence.mkdir(mode=0o700)
        with self.assertRaisesRegex(controller.Hold, 'MISSING_OR_AMBIGUOUS'):
            controller.collect_bound_receipt(state, fixture.root, evidence, 'd' * 64)
        self.assertEqual(list(evidence.iterdir()), [])

    def test_rejected_identity_still_preserves_raw_receipt_without_a_success_envelope(self):
        fixture = self.fixture
        state, receipt = fixture.state_and_receipt()
        receipt['runToken'] = '0' * 64
        raw = raw_json(receipt)
        acceptance = fixture.root / 'acceptance'
        acceptance.mkdir(mode=0o700)
        path = acceptance / 'native-acceptance-wrong.receipt.json'
        path.write_bytes(raw)
        path.chmod(0o600)
        evidence = fixture.root / 'evidence'
        evidence.mkdir(mode=0o700)
        with self.assertRaisesRegex(controller.Hold, 'RECEIPT_IDENTITY'):
            controller.collect_bound_receipt(state, fixture.root, evidence, 'd' * 64)
        self.assertEqual((evidence / 'driver-receipt.json').read_bytes(), raw)

    def test_nonsecret_envelope_does_not_forward_unknown_control_state_fields(self):
        state, receipt = self.fixture.state_and_receipt()
        state['runner']['UNKNOWN_PRIVATE_VALUE'] = 'MUST_NOT_BE_COPIED'
        envelope = controller.bind_receipt(raw_json(receipt), state, 'd' * 64)
        self.assertNotIn('MUST_NOT_BE_COPIED', json.dumps(envelope))

    def test_completed_label_cannot_hide_failed_teardown(self):
        state, receipt = self.fixture.state_and_receipt()
        receipt['teardownVerified'] = False
        envelope = controller.bind_receipt(raw_json(receipt), state, 'd' * 64)
        self.assertEqual(envelope['bindingOutcome'], 'HOLD')

    def test_receipt_pointer_contract_may_bind_nested_final_identity_without_relabeling(self):
        fixture = self.fixture
        fixture.invocation['receiptContract']['fields']['runToken'] = '/identity/runToken'
        fixture.publish()
        state, receipt = fixture.state_and_receipt()
        receipt['identity'] = {'runToken': receipt.pop('runToken')}
        envelope = controller.bind_receipt(raw_json(receipt), state, 'd' * 64)
        self.assertEqual(envelope['bindingOutcome'], 'SOURCE_BOUND_RECEIPT')


    def test_l_copied_rows_and_archive_reject_float_and_boolean_scalars_independently(self):
        fixture = self.fixture
        # One byte makes True numerically equal to the valid F row size. Keep
        # F/H and their raw pins untouched while mutating only L's copied data.
        fixture.write('tests/synthetic_custody.py', b'x')
        fixture.refresh()
        baseline = json.loads((fixture.root / controller.LOCK).read_text())
        index = next(i for i, r in enumerate(baseline['componentSource']['files'])
                     if r['path'] == 'tests/synthetic_custody.py')
        for owner, key in [('row', 'mode'), ('row', 'bytes'),
                           ('archive', 'bytes'), ('archive', 'memberCount')]:
            for cast in (float, bool):
                with self.subTest(owner=owner, field=key, cast=cast.__name__):
                    changed = json.loads(json.dumps(baseline))
                    target = (changed['componentSource']['files'][index] if owner == 'row'
                              else changed['componentSource']['archive'])
                    target[key] = cast(target[key])
                    fixture.write(controller.LOCK, raw_json(changed))
                    expected = 'SOURCE_ROW_VALUE' if owner == 'row' else 'ARCHIVE_BINDING'
                    with self.assertRaisesRegex(controller.Hold, expected):
                        controller.verify_authority(fixture.root)
        fixture.write(controller.LOCK, raw_json(baseline))
        self.assertEqual(controller.verify_authority(fixture.root)['classification'], 'SYNTHETIC_FIXTURE')

    def test_reserved_scenario_alternate_spellings_refuse_before_any_target_or_git_probe(self):
        fixture = self.fixture
        state, _ = fixture.state_and_receipt()
        baseline = list(fixture.invocation['argv'])
        alternatives = [
            ['--mode=source-plan'], ['--mode=acceptance'],
            ['--platform=wsl2'], ['--platform=ubuntu'],
            ['--mode', 'source-plan'], ['--platform', 'wsl2'], ['--'],
            ['--m=source-plan'], ['--plat=windows'],
            *[[name, 'source-plan'] for name in ('--m', '--mo', '--mod')],
            *[[name, 'wsl2'] for name in ('--p', '--pl', '--pla', '--plat', '--platf', '--platfo', '--platfor')],
        ]
        for extra in alternatives:
            with self.subTest(extra=extra):
                fixture.invocation['argv'] = baseline + extra
                fixture.publish()
                with mock.patch.object(controller, 'SOURCE', fixture.root), \
                     mock.patch.object(controller, 'git', side_effect=AssertionError('no Git probe')) as git_probe, \
                     mock.patch.object(controller.subprocess, 'run', side_effect=AssertionError('no target')) as target:
                    with self.assertRaisesRegex(controller.Hold, 'INVOCATION_SCENARIO'):
                        controller.command(state, fixture.root, 'not-started', ['NEVER_SPAWN'], {}, 1)
                    git_probe.assert_not_called()
                    target.assert_not_called()
        self.assertFalse((fixture.root / 'not-started.json').exists())

    def test_authority_raw_and_fingerprint_consumers_use_one_descriptor_per_path(self):
        fixture = self.fixture
        real_open = os.open
        with mock.patch.object(controller.os, 'open', wraps=real_open) as opened, \
             mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('unbounded reopen')):
            proof = controller.verify_authority(fixture.root)
        self.assertEqual(proof['classification'], 'SYNTHETIC_FIXTURE')
        for name in (controller.LOCK, controller.FREEZE, controller.HANDOFF,
                     controller.INSTALLER['path'], 'scripts/owned-ubuntu-acceptance-ci.py'):
            self.assertEqual(sum(Path(call.args[0]) == fixture.root / name
                                 for call in opened.call_args_list), 1, name)


class FileObservationTests(unittest.TestCase):
    """Real owned files; mutation hooks change only these temporary fixtures."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.path = self.root / 'input'
        self.path.write_bytes(b'original bytes')
        self.path.chmod(0o600)

    def during_read(self, mutation):
        real_read = os.read
        invoked = False

        def read_and_mutate(fd, size):
            nonlocal invoked
            block = real_read(fd, size)
            if not invoked:
                invoked = True
                mutation()
            return block

        return mock.patch.object(controller.os, 'read', side_effect=read_and_mutate)

    def test_exact_limit_raw_hash_mode_and_single_open_without_path_read_bytes(self):
        raw = b'x' * 65536
        self.path.write_bytes(raw)
        real_open = os.open
        with mock.patch.object(controller.os, 'open', wraps=real_open) as opened, \
             mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('unbounded reopen')):
            observed_raw, observed = controller.read_with_fingerprint(self.path)
        self.assertEqual(observed_raw, raw)
        self.assertEqual(observed, {'sha256': digest(raw), 'bytes': len(raw), 'mode': 0o600})
        opened.assert_called_once()
        flags = opened.call_args.args[1]
        self.assertTrue(flags & os.O_NOFOLLOW)
        self.assertTrue(flags & os.O_NONBLOCK)

    def test_raw_read_wrapper_never_calls_fingerprint_then_reopens(self):
        with mock.patch.object(controller, 'fingerprint', side_effect=AssertionError('separate observation')), \
             mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('unbounded reopen')):
            self.assertEqual(controller.read(self.path), b'original bytes')

    def test_one_byte_over_limit_refused_before_read(self):
        self.path.write_bytes(b'x' * 65537)
        with mock.patch.object(controller.os, 'read', side_effect=AssertionError('must reject before read')):
            with self.assertRaisesRegex(controller.Hold, 'FILE_TYPE_OR_BOUND'):
                controller.read(self.path)

    def test_actual_fifo_refuses_without_open_or_read_hang_in_bounded_child(self):
        fifo = self.root / 'fifo'
        os.mkfifo(fifo, 0o600)
        script = '''import importlib.util,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('controller',sys.argv[1])
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
try:c.read(Path(sys.argv[2]))
except c.Hold as e:
 print(str(e));sys.exit(0)
raise SystemExit('FIFO wrongly admitted')
'''
        result = subprocess.run([sys.executable, '-B', '-c', script,
                                 str(ROOT / 'scripts/owned-ubuntu-acceptance-ci.py'), str(fifo)],
                                env={'PATH': os.environ['PATH'], 'PYTHONNOUSERSITE': '1'},
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=3, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), b'FILE_TYPE_OR_BOUND')
        self.assertLessEqual(len(result.stdout) + len(result.stderr), 1024)

    def test_owned_symlink_refused_before_reading_target(self):
        link = self.root / 'link'
        link.symlink_to(self.path.name)
        with mock.patch.object(controller.os, 'read', side_effect=AssertionError('linked target read')):
            with self.assertRaisesRegex(controller.Hold, 'LINKED_PATH'):
                controller.read(link)
        self.assertEqual(self.path.read_bytes(), b'original bytes')

    def test_symlink_substitution_between_path_check_and_open_refuses(self):
        target = self.root / 'sentinel'
        target.write_bytes(b'UNRELATED SYNTHETIC sentinel')
        real_open = os.open

        def substitute(path, flags):
            self.path.unlink()
            self.path.symlink_to(target.name)
            return real_open(path, flags)

        with mock.patch.object(controller.os, 'open', side_effect=substitute), \
             mock.patch.object(controller.os, 'read', side_effect=AssertionError('replacement read')):
            with self.assertRaises(OSError):
                controller.read(self.path)
        self.assertEqual(target.read_bytes(), b'UNRELATED SYNTHETIC sentinel')

    def test_regular_substitution_before_open_rejects_inode_change(self):
        replacement = self.root / 'replacement'
        replacement.write_bytes(b'original bytes')
        replacement.chmod(0o600)
        real_open = os.open

        def substitute(path, flags):
            replacement.replace(self.path)
            return real_open(path, flags)

        with mock.patch.object(controller.os, 'open', side_effect=substitute):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.read(self.path)

    def test_regular_replacement_during_read_rejects_even_identical_content_and_mode(self):
        replacement = self.root / 'replacement'
        replacement.write_bytes(b'original bytes')
        replacement.chmod(0o600)
        with self.during_read(lambda: replacement.replace(self.path)):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.read(self.path)

    def test_growth_within_cap_refuses_changed_size(self):
        def grow():
            with self.path.open('ab') as out:
                out.write(b'+')
        with self.during_read(grow):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.read(self.path)

    def test_growth_past_cap_is_bounded_during_read_and_closes_descriptor(self):
        descriptors, requests = [], []
        real_read = os.read

        def grow(fd, size):
            descriptors.append(fd)
            requests.append(size)
            block = real_read(fd, size)
            if len(requests) == 1:
                with self.path.open('ab') as out:
                    out.write(b'x' * 1024)
            return block

        with mock.patch.object(controller.os, 'read', side_effect=grow):
            with self.assertRaisesRegex(controller.Hold, 'FILE_BOUND'):
                controller.read(self.path, 32)
        self.assertLessEqual(sum(requests), 33 + 33)
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[-1], 32 - len(b'original bytes') + 1)
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])

    def test_truncation_during_read_refuses(self):
        with self.during_read(lambda: self.path.write_bytes(b'x')):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.read(self.path)

    def test_mode_change_during_read_refuses(self):
        with self.during_read(lambda: self.path.chmod(0o644)):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.read(self.path)

    def test_hardlink_created_during_read_refuses(self):
        with self.during_read(lambda: os.link(self.path, self.root / 'alias')):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.read(self.path)

    def test_preexisting_hardlink_refused_before_read(self):
        os.link(self.path, self.root / 'alias')
        with mock.patch.object(controller.os, 'read', side_effect=AssertionError('linked read')):
            with self.assertRaisesRegex(controller.Hold, 'FILE_TYPE_OR_BOUND'):
                controller.read(self.path)

    def test_artifact_fingerprint_streams_without_accumulating_raw_bytes(self):
        size = 8 * 1024 * 1024
        with self.path.open('wb') as out:
            out.truncate(size)
        expected = hashlib.sha256()
        for _ in range(size // 65536):
            expected.update(b'\0' * 65536)
        tracemalloc.start()
        try:
            observed = controller.fingerprint(self.path, 512 * 1024 * 1024)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(observed['bytes'], size)
        self.assertEqual(observed['sha256'], expected.hexdigest())
        self.assertLess(peak, 1024 * 1024, 'artifact bytes must not accumulate')

    def test_artifact_512_mib_cap_rejects_sparse_oversize_before_read(self):
        with self.path.open('wb') as out:
            out.truncate(512 * 1024 * 1024 + 1)
        with mock.patch.object(controller.os, 'read', side_effect=AssertionError('oversize artifact read')):
            with self.assertRaisesRegex(controller.Hold, 'FILE_TYPE_OR_BOUND'):
                controller.fingerprint(self.path, 512 * 1024 * 1024)

    def receipt(self):
        directory = self.root / 'acceptance'
        directory.mkdir(mode=0o700)
        path = directory / 'native-acceptance-synthetic.receipt.json'
        path.write_bytes(b' {"schema":1}\n\n')
        path.chmod(0o600)
        authority = {'invocation': {'receiptContract': {'filePattern': 'native-acceptance-*.receipt.json'}}}
        return path, authority

    def test_receipt_mode_and_raw_bytes_are_one_observation_without_fingerprint_reopen(self):
        path, authority = self.receipt()
        real_open = os.open
        with mock.patch.object(controller.os, 'open', wraps=real_open) as opened, \
             mock.patch.object(controller, 'fingerprint', side_effect=AssertionError('separate mode observation')), \
             mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('unbounded reopen')):
            raw = controller.raw_driver_receipt(self.root, authority)
        self.assertEqual(raw, b' {"schema":1}\n\n')
        opened.assert_called_once()
        self.assertEqual(Path(opened.call_args.args[0]), path)

    def test_receipt_initial_wrong_mode_refuses(self):
        path, authority = self.receipt()
        path.chmod(0o644)
        with self.assertRaisesRegex(controller.Hold, 'DRIVER_RECEIPT_MODE'):
            controller.raw_driver_receipt(self.root, authority)

    def test_receipt_mode_change_during_same_descriptor_read_refuses(self):
        path, authority = self.receipt()
        with self.during_read(lambda: path.chmod(0o644)):
            with self.assertRaisesRegex(controller.Hold, 'FILE_CHANGED'):
                controller.raw_driver_receipt(self.root, authority)


class WorkflowTests(unittest.TestCase):
    def test_authority_suite_is_unconditional_under_actual_target_toolchains(self):
        import yaml
        workflow = yaml.safe_load((ROOT / '.github/workflows/deployment-ci.yml').read_text())
        job = workflow['jobs']['recovery-and-plugin']
        steps = job['steps']
        selected = [i for i, s in enumerate(steps) if s.get('run') == 'python3 -B tests/test_owned_ci_authority.py']
        self.assertEqual(len(selected), 1)
        step = steps[selected[0]]
        for object_ in (job, step):
            self.assertNotIn('if', object_)
            self.assertNotIn('continue-on-error', object_)
        for action, key, value in [('actions/setup-python@v5', 'python-version', '3.12'),
                                   ('actions/setup-node@v4', 'node-version', '22')]:
            setup = [(i, s) for i, s in enumerate(steps) if s.get('uses') == action]
            self.assertEqual(len(setup), 1)
            self.assertLess(setup[0][0], selected[0])
            self.assertEqual(str(setup[0][1]['with'][key]), value)
        for command in ('python3 -B tests/test_owned_native_acceptance.py',
                        'python3 -B tests/native-maintenance-consumers.test.py'):
            self.assertEqual(sum(s.get('run') == command for s in steps), 1)
        events = workflow.get('on', workflow.get(True))
        for event in ('pull_request', 'push'):
            self.assertNotIn('paths', events[event] or {})
            self.assertNotIn('paths-ignore', events[event] or {})

    def test_genuine_workflow_retains_exact_eleven_file_evidence_boundary(self):
        import yaml
        workflow = yaml.safe_load((ROOT / '.github/workflows/owned-ubuntu-acceptance.yml').read_text())
        job = workflow['jobs']['genuine-owned-ubuntu']
        self.assertEqual(job['runs-on'], 'ubuntu-24.04')
        self.assertEqual(job['permissions'], {'contents': 'read'})
        checkout = next(s for s in job['steps'] if s.get('uses') == 'actions/checkout@v4')
        self.assertEqual(checkout['with']['ref'], '${{ github.event.pull_request.head.sha }}')
        self.assertFalse(checkout['with']['persist-credentials'])
        upload = next(s for s in job['steps'] if s.get('uses') == 'actions/upload-artifact@v4')
        names = [line.rsplit('/', 1)[-1] for line in upload['with']['path'].splitlines()]
        self.assertEqual(len(names), 11)
        self.assertEqual(set(names), {'identity.json', 'prepare-result.json', 'build-command.json',
            'package-command.json', 'build-result.json', 'artifact.sha256', 'artifact-manifest.json',
            'acceptance-command.json', 'accept-result.json', 'driver-receipt.json', 'collect-result.json'})
        for step in job['steps']:
            self.assertNotIn('continue-on-error', step)
        runs = '\n'.join(s.get('run', '') for s in job['steps'])
        self.assertLess(runs.index('prepare '), runs.index('build '))
        self.assertLess(runs.index('build '), runs.index('accept '))
        self.assertNotIn('--supervisor owned-pgid', runs)

    def test_fixture_node_is_the_provisioned_node22(self):
        search = os.environ.get('PATH')
        self.assertIsNotNone(search)
        self.assertTrue(search)
        node = shutil.which('node', path=search)
        self.assertIsNotNone(node)
        result = subprocess.run([str(Path(node).resolve()), '--version'], capture_output=True, timeout=3, check=True)
        self.assertLessEqual(len(result.stdout), 128)
        self.assertRegex(result.stdout.decode().strip(), r'^v22\.[0-9]+\.[0-9]+$')


if __name__ == '__main__':
    unittest.main(verbosity=2)
