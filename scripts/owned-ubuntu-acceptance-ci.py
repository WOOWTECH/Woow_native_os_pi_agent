#!/usr/bin/env python3
"""Direct disposable Ubuntu CI route. No fixture, SDK import or release publisher.

Only a later authorized workflow invokes these phases. Never run this helper as
a source check. Raw build/runtime output is discarded; private roots are retained
on failure until runner disposal. Uploaded evidence is an explicit allowlist.
"""
import argparse
import ctypes
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).resolve().parent.parent
PATH = '/usr/bin:/bin'
ARTIFACT = 'piweb-0.10.0-linux-x64.tar.gz'
LOCK = 'scripts/owned-ubuntu-acceptance-ci.lock.json'
FREEZE = 'tests/owned-acceptance-component-source.json'
HANDOFF = 'tests/owned-acceptance-component-handoff.json'
INSTALLER = {'path': 'tests/owned-native-acceptance.lock.json',
             'sha256': '1d840f8ebed510e48ba02da6d95172aea9b763b6c91f0d33a88440a0053e2418', 'count': 40, 'bytes': 16373}
PACKAGER = {'path': 'scripts/build-piweb-artifact.sh',
            'sha256': '157eae7044a6dcb641f60306fb60cf1e2d024be9c64130ca714a170648ad0263',
            'bytes': 2416, 'mode': 0o755}
BASE_COMMIT = '172522c8a4065f80e813d6d4710b26b13b6094c7'
BASE_TREE = '4ebb37ac864d1a423eccfb6cdd838f1f94bbf21f'
ROLE_BASE = {
    'driver': ['tests/owned_native_acceptance.py'],
    'supervisor': ['tests/owned_acceptance_supervisor.py'],
    'controller': ['scripts/owned-ubuntu-acceptance-ci.py'],
    'procHelpers': [], 'custodyHelpers': [],
    'fixtures': ['tests/fixtures/owned_acceptance_child.py'],
    'safetySuites': ['tests/test_owned_native_acceptance.py', 'tests/test_owned_ci_authority.py'],
    'workflows': ['.github/workflows/deployment-ci.yml', '.github/workflows/owned-ubuntu-acceptance.yml'],
    'docs': ['docs/OWNED-NATIVE-ACCEPTANCE.md', 'docs/OWNED-UBUNTU-GENUINE-CI.md', 'docs/TESTING.md',
             'docs/plans/2026-11-22-owned-native-acceptance.md', 'docs/plans/2026-11-22-owned-ubuntu-genuine-ci.md'],
    'compatibilityEntries': ['tests/smoke.sh'],
}
RECEIPT_FIELDS = {'schema', 'scope', 'status', 'piwebArtifactSha256', 'runToken',
                  'sourceAuthoritySha256', 'supervisor', 'teardownVerified', 'privateRootRetained',
                  'realUbuntuAcceptance', 'realWSL2Acceptance', 'providerAcceptance', 'rebootAcceptance',
                  'baseSourceReference', 'sourceLockSha256', 'pluginSha256'}
TEMPLATE_VALUES = {'python', 'driver', 'custody_mode', 'parent', 'artifact',
                   'artifact_sha256', 'run_token', 'authority_sha256'}
RUNNER_KEYS = ('CI_REPOSITORY', 'CI_RUN_ID', 'CI_RUN_ATTEMPT', 'CI_EVENT_SHA',
               'CI_WORKFLOW_SHA', 'CI_WORKFLOW_REF')
ROUTE_FILES = ('.github/workflows/owned-ubuntu-acceptance.yml',
               'scripts/owned-ubuntu-acceptance-ci.py', LOCK,
               'docs/OWNED-UBUNTU-GENUINE-CI.md',
               'docs/plans/2026-11-22-owned-ubuntu-genuine-ci.md')
TOOLS = ('bash', 'curl', 'git', 'gpg', 'jq', 'ssh', 'xz', 'python3',
         'flock', 'tmux', 'tar', 'gzip', 'timeout', 'make', 'cc', 'c++',
         'g++', 'find', 'grep', 'sed', 'awk', 'sha256sum', 'readlink',
         'install', 'cp', 'mv', 'rm', 'mkdir', 'ln', 'chmod', 'cat',
         'head', 'tail', 'cut', 'du', 'wc', 'tr', 'xargs', 'uname', 'basename',
         'dirname', 'patch')
MINIMAL = {'PATH': PATH, 'LANG': 'C.UTF-8', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_CONFIG_GLOBAL': '/dev/null', 'PYTHONNOUSERSITE': '1',
           'PYTHONDONTWRITEBYTECODE': '1'}


class Hold(RuntimeError):
    pass


def need(ok, code):
    if not ok:
        raise Hold(code)


def private(path):
    need(path.is_absolute() and path.resolve(strict=True) == path, 'NONCANONICAL_ROOT')
    s = path.lstat()
    need(stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid()
         and stat.S_IMODE(s.st_mode) == 0o700, 'ROOT_NOT_PRIVATE')


def new_directory(path):
    need(path.parent.resolve(strict=True) == path.parent, 'NONCANONICAL_PARENT')
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    private(path)
    return path


def file_observation(path, maximum, *, retain=False):
    """Read/hash one retained descriptor; raw bytes and metadata share custody."""
    need(type(maximum) is int and 0 <= maximum <= 512 * 1024 * 1024, 'FILE_MAXIMUM')
    need(path.resolve(strict=True) == path, 'LINKED_PATH')
    fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns,
                        s.st_ctime_ns, s.st_mode, s.st_nlink, s.st_uid, s.st_gid)
    entry = path.lstat()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
             and 0 <= before.st_size <= maximum, 'FILE_TYPE_OR_BOUND')
        need(fields(entry) == fields(before), 'FILE_CHANGED')
        h = hashlib.sha256()
        size = 0
        blocks = [] if retain else None
        while True:
            # At most one byte beyond the caller's cap, including growth at EOF.
            block = os.read(fd, min(65536, maximum - size + 1))
            if not block:
                break
            size += len(block)
            need(size <= maximum, 'FILE_BOUND')
            h.update(block)
            if retain:
                blocks.append(block)
        after = os.fstat(fd)
        need(fields(before) == fields(after) == fields(path.lstat())
             and size == before.st_size, 'FILE_CHANGED')
        need(path.resolve(strict=True) == path, 'LINKED_PATH')
        return (b''.join(blocks) if retain else None,
                {'sha256': h.hexdigest(), 'bytes': size,
                 'mode': stat.S_IMODE(before.st_mode)})
    finally:
        os.close(fd)


def fingerprint(path, maximum):
    # In particular, the 512 MiB artifact cap must not allocate the artifact.
    return file_observation(path, maximum)[1]


def read_with_fingerprint(path, maximum=65536):
    need(type(maximum) is int and 0 <= maximum <= 4 * 1024 * 1024, 'RAW_READ_MAXIMUM')
    return file_observation(path, maximum, retain=True)


def read(path, maximum=65536):
    return read_with_fingerprint(path, maximum)[0]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def strict_json(raw):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, 'DUPLICATE_JSON_KEY')
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=object_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Hold('JSON_CONSTANT')))
    except (ValueError, UnicodeError, RecursionError):
        raise Hold('JSON_INVALID') from None


def shape(value, keys, code='METADATA_SHAPE'):
    need(type(value) is dict and set(value) == set(keys), code)


def hex_sha(value, length=64):
    return type(value) is str and re.fullmatch('[a-f0-9]{' + str(length) + '}', value) is not None


def relative_path(value):
    need(type(value) is str and len(value) <= 256
         and re.fullmatch(r'[A-Za-z0-9_.@/-]+', value)
         and not value.startswith('/')
         and all(part not in ('', '.', '..') for part in value.split('/')), 'SOURCE_PATH')
    return value


def pinned(source, pin, expected_path):
    shape(pin, ('path', 'sha256', 'bytes', 'mode'))
    need(pin['path'] == expected_path and hex_sha(pin['sha256'])
         and type(pin['bytes']) is int and 0 < pin['bytes'] <= 65536
         and type(pin['mode']) is int and pin['mode'] == 0o644, 'METADATA_PIN')
    raw, observed = read_with_fingerprint(source / expected_path)
    need(observed ==
         {k: pin[k] for k in ('sha256', 'bytes', 'mode')}, 'METADATA_PIN_DRIFT')
    need(sha(raw) == pin['sha256'], 'METADATA_READ_DRIFT')
    return strict_json(raw), raw


def validate_rows(rows):
    need(type(rows) is list and 1 <= len(rows) <= 128, 'SOURCE_ROW_COUNT')
    paths, total = [], 0
    for row in rows:
        shape(row, ('path', 'sha256', 'bytes', 'mode', 'gitMode', 'gitBlob'), 'SOURCE_ROW_SHAPE')
        paths.append(relative_path(row['path']))
        need(hex_sha(row['sha256']) and hex_sha(row['gitBlob'], 40)
             and type(row['bytes']) is int and 0 <= row['bytes'] <= 4 * 1024 * 1024
             and type(row['mode']) is int and row['mode'] in (0o644, 0o755)
             and row['gitMode'] == ('100755' if row['mode'] == 0o755 else '100644'), 'SOURCE_ROW_VALUE')
        total += row['bytes']
    need(paths == sorted(set(paths)) and total <= 16 * 1024 * 1024, 'SOURCE_ROW_SET')
    need(not set(paths) & {LOCK, FREEZE, HANDOFF, INSTALLER['path'], PACKAGER['path']}, 'CIRCULAR_OR_IMMUTABLE_ROW')
    return paths


def validate_roles(roles, paths):
    shape(roles, ROLE_BASE, 'SOURCE_ROLES')
    declared = set()
    for role, required in ROLE_BASE.items():
        members = roles[role]
        need(type(members) is list and 1 <= len(members) <= 128
             and all(type(v) is str for v in members)
             and members == sorted(set(members)), 'ROLE_MEMBERS')
        for name in members:
            relative_path(name)
        need(set(required) <= set(members), 'ROLE_BASELINE_MISSING')
        if role in ('driver', 'supervisor', 'controller'):
            need(members == required, 'ROLE_ENTRYPOINT')
        if role in ('procHelpers', 'custodyHelpers'):
            need(not set(members) & {n for values in ROLE_BASE.values() for n in values}, 'HELPER_ROLE_ALIAS')
        declared.update(members)
    need(declared == set(paths), 'SOURCE_CLOSURE')


def validate_archive(archive, paths, rows_sha):
    shape(archive, ('sha256', 'bytes', 'memberCount', 'sourceRowsSha256'), 'ARCHIVE_PROVENANCE')
    need(hex_sha(archive['sha256']) and type(archive['bytes']) is int
         and 0 < archive['bytes'] <= 16 * 1024 * 1024
         and type(archive['memberCount']) is int and archive['memberCount'] == len(paths)
         and archive['sourceRowsSha256'] == rows_sha, 'ARCHIVE_BINDING')


def validate_invocation(value):
    shape(value, ('schema', 'custodyMode', 'argv', 'receiptContract'), 'INVOCATION_SHAPE')
    need(value['schema'] == 'owned-driver-invocation/v1'
         and type(value['custodyMode']) is str
         and re.fullmatch('[a-z][a-z0-9-]{0,63}', value['custodyMode']), 'INVOCATION_UNSUPPORTED')
    args = value['argv']
    need(type(args) is list and 2 <= len(args) <= 64
         and (args[:2] == ['{python}', '{driver}']
              or args[:3] == ['{python}', '-B', '{driver}']), 'INVOCATION_ENTRYPOINT')
    references = []
    for argument in args:
        need(type(argument) is str and 0 < len(argument) <= 256
             and not any(ord(c) < 32 or ord(c) == 127 for c in argument), 'INVOCATION_ARGUMENT')
        if '{' in argument or '}' in argument:
            need(argument.startswith('{') and argument.endswith('}')
                 and argument[1:-1] in TEMPLATE_VALUES, 'INVOCATION_TOKEN')
            references.append(argument[1:-1])
    need(sorted(references) == sorted(TEMPLATE_VALUES), 'INVOCATION_BINDINGS')
    reserved = ('--mode', '--platform')
    for argument in args:
        option = argument.split('=', 1)[0]
        if option.startswith('--'):
            # argparse accepts long-option abbreviations and equals forms. The
            # reserved scenario grammar permits only the two exact spellings.
            need(option != '--' and not any(
                (name.startswith(option) and option != name)
                or (option == name and argument != name)
                for name in reserved), 'INVOCATION_SCENARIO')
    for option, expected in (('--mode', 'acceptance'), ('--platform', 'ubuntu')):
        need(args.count(option) == 1 and args.index(option) + 1 < len(args)
             and args[args.index(option) + 1] == expected, 'INVOCATION_SCENARIO')
    contract = value['receiptContract']
    shape(contract, ('schema', 'schemaValue', 'scopeValue', 'completedStatus', 'filePattern', 'fields'), 'RECEIPT_CONTRACT')
    need(contract['schema'] == 'owned-driver-receipt-contract/v1'
         and type(contract['schemaValue']) is int and 1 <= contract['schemaValue'] <= 32
         and contract['scopeValue'] == 'owned-platform-scenario'
         and contract['completedStatus'] == 'OWNED_SCENARIO_COMPLETED', 'RECEIPT_CONTRACT_UNSUPPORTED')
    need(type(contract['filePattern']) is str
         and re.fullmatch(r'[a-z][a-z0-9_-]{0,63}\*\.receipt\.json', contract['filePattern']), 'RECEIPT_FILE_PATTERN')
    shape(contract['fields'], RECEIPT_FIELDS, 'RECEIPT_FIELDS')
    pointers = list(contract['fields'].values())
    need(all(type(v) is str and re.fullmatch(r'(?:/[A-Za-z][A-Za-z0-9_]{0,63}){1,4}', v)
             for v in pointers) and len(set(pointers)) == len(pointers), 'RECEIPT_POINTER')


def verify_authority(source):
    try:
        return _verify_authority(source)
    except (OSError, KeyError, TypeError, ValueError, RecursionError):
        raise Hold('AUTHORITY_UNREADABLE') from None


def _verify_authority(source):
    """Verify documents and bytes. Independent root approval is still external.

    Synthetic documents are observable by fixture tests but cannot pass the
    operational source_identity gate. The repository lock binds the reviewed component bytes and invocation.
    """
    source = source.resolve(strict=True)
    lraw, lock_observed = read_with_fingerprint(source / LOCK)
    need(lock_observed['mode'] == 0o644, 'AUTHORITY_LOCK_MODE')
    pins = strict_json(lraw)
    shape(pins, ('schema', 'status', 'baseCommit', 'baseTree', 'installerInputLock',
                 'packager', 'componentSource', 'historicalSupersededAuthority'), 'AUTHORITY_SHAPE')
    need(pins['schema'] == 'owned-ubuntu-genuine-ci-inputs/v2', 'AUTHORITY_SCHEMA')
    need(pins['status'] == 'COMPOSED', 'COMPOSITION_PENDING')
    need(pins['baseCommit'] == BASE_COMMIT and pins['baseTree'] == BASE_TREE
         and pins['installerInputLock'] == INSTALLER and pins['packager'] == PACKAGER, 'IMMUTABLE_AUTHORITY')
    iraw, installer_observed = read_with_fingerprint(source / INSTALLER['path'])
    need(sha(iraw) == INSTALLER['sha256'] and len(iraw) == INSTALLER['bytes']
         and installer_observed['mode'] == 0o644, 'INSTALLER_LOCK_DRIFT')
    installer = strict_json(iraw)
    need(installer['baseCommit'] == BASE_COMMIT and installer['baseTree'] == BASE_TREE
         and len(installer['files']) == INSTALLER['count'], 'BASE_IDENTITY')
    for item in [PACKAGER, *installer['files']]:
        relative_path(item['path'])
        actual = fingerprint(source / item['path'], 4 * 1024 * 1024)
        need(all(actual[k] == item[k] for k in ('sha256', 'bytes', 'mode')), 'IMMUTABLE_SOURCE_DRIFT')
    component = pins['componentSource']
    shape(component, ('freeze', 'handoff', 'files', 'fileCount', 'sourceRowsSha256', 'roles', 'archive'), 'COMPONENT_SHAPE')
    freeze, fraw = pinned(source, component['freeze'], FREEZE)
    handoff, hraw = pinned(source, component['handoff'], HANDOFF)
    shape(freeze, ('schema', 'classification', 'files', 'roles', 'sourceRowsSha256'), 'FREEZE_SHAPE')
    shape(handoff, ('schema', 'classification', 'freezeSha256', 'archive', 'roles', 'closure', 'invocation'), 'HANDOFF_SHAPE')
    need(freeze['schema'] == 'owned-component-source/v1'
         and handoff['schema'] == 'owned-component-handoff/v1'
         and freeze['classification'] in ('SYNTHETIC_FIXTURE', 'REVIEWED_SOURCE_ONLY')
         and handoff['classification'] == freeze['classification'], 'COMPONENT_SCHEMA')
    paths = validate_rows(freeze['files'])
    validate_rows(component['files'])
    need(not set(paths) & {r['path'] for r in installer['files']}, 'IMMUTABLE_COMPONENT_OVERLAP')
    validate_roles(freeze['roles'], paths)
    rows_sha = sha(canonical(freeze['files']))
    need(freeze['sourceRowsSha256'] == rows_sha
         and type(component['fileCount']) is int and component['fileCount'] == len(paths)
         and canonical(component['files']) == canonical(freeze['files'])
         and component['sourceRowsSha256'] == rows_sha
         and component['roles'] == freeze['roles'] == handoff['roles']
         and handoff['freezeSha256'] == sha(fraw) and handoff['closure'] == paths, 'COMPONENT_BINDING')
    archive = handoff['archive']
    validate_archive(archive, paths, rows_sha)
    validate_archive(component['archive'], paths, rows_sha)
    need(canonical(component['archive']) == canonical(archive), 'ARCHIVE_BINDING')
    validate_invocation(handoff['invocation'])
    for item in freeze['files']:
        path = source / item['path']
        raw, actual = read_with_fingerprint(path, 4 * 1024 * 1024)
        need(all(actual[k] == item[k] for k in ('sha256', 'bytes', 'mode'))
             and sha(raw) == item['sha256']
             and hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest() == item['gitBlob'], 'SOURCE_PIN_DRIFT')
    proof = {'schema': 'owned-ci-source-authority/v1', 'classification': freeze['classification'],
             'lockSha256': sha(lraw), 'freezeSha256': sha(fraw), 'handoffSha256': sha(hraw),
             'sourceRowsSha256': rows_sha, 'files': freeze['files'], 'roles': freeze['roles'],
             'archiveProvenance': archive, 'custodyMode': handoff['invocation']['custodyMode'],
             'invocation': handoff['invocation']}
    proof['authoritySha256'] = sha(canonical(proof))
    return proof


def save(directory, name, value):
    private(directory)
    raw = value if isinstance(value, bytes) else (
        json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    need(len(raw) <= 65536 and '/' not in name, 'EVIDENCE_BOUND')
    path = directory / name
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as out:
        os.fchmod(out.fileno(), 0o600)
        out.write(raw)
        out.flush()
        os.fsync(out.fileno())


def git(*args, source=None):
    result = subprocess.run(['/usr/bin/git', '-C', str(SOURCE if source is None else source), *args],
                            env=MINIMAL, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=10, check=False)
    need(result.returncode == 0 and len(result.stdout) <= 4096, 'GIT_IDENTITY')
    return result.stdout.decode().strip()


def source_identity(expected_head, *, source=None, prepared=None):
    source = SOURCE if source is None else source
    authority = (verify_authority(source) if prepared is None
                 else check_prepared_authority(prepared, source))
    need(authority['classification'] == 'REVIEWED_SOURCE_ONLY', 'SYNTHETIC_AUTHORITY_NOT_OPERATIONAL')
    need(re.fullmatch('[a-f0-9]{40}', expected_head or ''), 'EXPECTED_PR_HEAD')
    need(git('rev-parse', 'HEAD', source=source) == expected_head, 'CHECKOUT_NOT_PR_HEAD')
    need(not git('status', '--porcelain', '--untracked-files=normal', source=source), 'DIRTY_CHECKOUT')
    installer = strict_json(read(source / INSTALLER['path']))
    return {'candidateCommit': expected_head, 'candidateTree': git('rev-parse', 'HEAD^{tree}', source=source),
            'baseReference': BASE_COMMIT, 'baseTreeReference': BASE_TREE,
            'installerInputLock': INSTALLER, 'installerInputs': installer['files'],
            'originalPackager': PACKAGER, 'sourceAuthority': authority,
            'routeFiles': {p: fingerprint(source / p, 131072) for p in ROUTE_FILES}}


def check_prepared_authority(prepared, source):
    observed = verify_authority(source)
    need(observed == prepared, 'PREPARED_AUTHORITY_CHANGED')
    return observed


def prepared_source(state):
    need(type(state.get('sourceAuthority')) is dict, 'PREPARED_STATE_MISSING')
    observed = source_identity(state['candidateCommit'], prepared=state['sourceAuthority'])
    need(observed['sourceAuthority'] == state['sourceAuthority']
         and observed['candidateTree'] == state['candidateTree'], 'PREPARED_AUTHORITY_CHANGED')
    return observed


def environment(prefix):
    private(prefix)
    return {**MINIMAL, 'HOME': str(prefix / 'account'),
            'TMPDIR': str(prefix / 'tmp'), 'PI_AGENT_HOME': str(prefix / 'install'),
            'PI_AGENT_DATA_DIR': str(prefix / 'install/data'),
            'XDG_CONFIG_HOME': str(prefix / 'xdg/config'),
            'XDG_DATA_HOME': str(prefix / 'xdg/data'),
            'XDG_CACHE_HOME': str(prefix / 'xdg/cache'),
            'XDG_STATE_HOME': str(prefix / 'xdg/state'),
            'npm_config_cache': str(prefix / 'xdg/cache/npm'),
            'UV_CACHE_DIR': str(prefix / 'xdg/cache/uv'), 'UV_LINK_MODE': 'copy',
            'PI_AGENT_LINK_KEYCHAIN': '0', 'PI_TELEMETRY': '0',
            'PI_SKIP_VERSION_CHECK': '1', 'DISABLE_AUTOUPDATER': '1',
            'NEXT_TELEMETRY_DISABLED': '1'}


def context(state_dir, evidence):
    private(state_dir)
    private(evidence)
    state = strict_json(read(state_dir / 'state.json'))
    root = Path(state['root'])
    private(root)
    need(root.parent == Path('/tmp') and root.name.startswith('own-ub-'), 'ROOT_BINDING')
    for name in ('build', 'controller', 'artifact', 'acceptance'):
        private(root / name)
    prepared_source(state)
    return state, root


def prepare(state_dir, evidence):
    need(os.getuid() == os.geteuid() != 0, 'NONROOT_REQUIRED')
    new_directory(evidence)
    new_directory(state_dir)
    identity = source_identity(os.environ.get('CI_EXPECTED_HEAD'))
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line)
    need(release.get('ID', '').strip('"') == 'ubuntu'
         and release.get('VERSION_ID', '').strip('"') == '24.04'
         and sys.platform == 'linux' and platform.machine() == 'x86_64'
         and 'microsoft' not in platform.release().lower(), 'UBUNTU_2404_X64_REQUIRED')
    need(sys.version_info >= (3, 11), 'SYSTEM_PYTHON_REQUIRED')
    need(hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'), 'PIDFD_REQUIRED')
    pidfd = os.pidfd_open(os.getpid())
    try:
        signal.pidfd_send_signal(pidfd, 0)
    finally:
        os.close(pidfd)
    libc = ctypes.CDLL(None)
    subreaper = ctypes.c_int()
    need(libc.prctl(36, 1, 0, 0, 0) == 0
         and libc.prctl(37, ctypes.byref(subreaper), 0, 0, 0) == 0
         and subreaper.value == 1, 'SUBREAPER_REQUIRED')
    tools = {}
    for name in TOOLS:
        chosen = shutil.which(name, path=PATH)
        need(chosen is not None, 'PREREQUISITE_MISSING_' + name)
        target = Path(chosen).resolve(strict=True)
        need(target.is_file() and os.access(target, os.X_OK), 'PREREQUISITE_NOT_EXECUTABLE')
        tools[name] = str(target)
    need(Path('/proc/self/stat').is_file()
         and Path('/etc/ssl/certs/ca-certificates.crt').is_file(), 'PROCFS_OR_CA_REQUIRED')
    root = Path(tempfile.mkdtemp(prefix='own-ub-', dir='/tmp')).resolve(strict=True)
    root.chmod(0o700)
    for name in ('build', 'controller'):
        prefix = new_directory(root / name)
        for relative in ('account', 'install', 'tmp', 'xdg', 'xdg/config',
                         'xdg/data', 'xdg/cache', 'xdg/state'):
            new_directory(prefix / relative)
    for name in ('artifact', 'acceptance'):
        new_directory(root / name)
    state = {'root': str(root), 'candidateCommit': identity['candidateCommit'],
             'candidateTree': identity['candidateTree'], 'sourceAuthority': identity['sourceAuthority'],
             'runToken': secrets.token_hex(32),
             'runner': {key: os.environ.get(key) for key in RUNNER_KEYS}, 'tools': tools}
    save(state_dir, 'state.json', state)
    identity.update(schema=1, scope='genuine-disposable-hosted-ubuntu-only',
                    osRelease={k: release.get(k) for k in ('ID', 'VERSION_ID')},
                    kernel=platform.release(), architecture=platform.machine(),
                    uid=os.getuid(), python={'path': str(Path(sys.executable).resolve()),
                                             'version': platform.python_version(),
                                             **fingerprint(Path(sys.executable).resolve(), 64 * 1024 * 1024)},
                    tools=tools, procfs=True, pidfd=True, subreaper=True,
                    runner={key: os.environ.get(key) for key in
                            ('CI_REPOSITORY', 'CI_RUN_ID', 'CI_RUN_ATTEMPT',
                             'CI_EVENT_SHA', 'CI_WORKFLOW_SHA', 'CI_WORKFLOW_REF',
                             'CI_IMAGE_OS', 'CI_IMAGE_VERSION')},
                    ciRunMetadataRecorded=True, productionAdmission=False,
                    wsl2Acceptance=False, providerAcceptance=False, rebootAcceptance=False)
    save(evidence, 'identity.json', identity)


def command(state, evidence, name, argv, env, seconds):
    prepared_source(state)  # Also between source-build and packager, before every target.
    need(0 < seconds <= 2000, 'COMMAND_TIME_BOUND')
    started = time.monotonic()
    result = subprocess.run([state['tools']['timeout'], '--signal=TERM', '--kill-after=10s',
                             str(seconds) + 's', *map(str, argv)],
                            cwd=SOURCE, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                            umask=0o022, check=False)
    save(evidence, name + '.json', {'schema': 1, 'command': name,
         'exitCode': result.returncode, 'seconds': time.monotonic() - started,
         'workLimitSeconds': seconds, 'rawOutputUploaded': False,
         'status': 'EXIT0' if result.returncode == 0 else 'HOLD'})
    need(result.returncode == 0, 'COMMAND_NONZERO_' + name)
    prepared_source(state)  # A successful child exit cannot mint authority for source changed during it.


def build(state_dir, evidence):
    state, root = context(state_dir, evidence)
    env = environment(root / 'build')
    # Artifact variable is deliberately absent: the real piweb source build runs.
    need('PI_AGENT_PIWEB_ARTIFACT' not in env, 'SOURCE_BUILD_REQUIRED')
    end = time.monotonic() + 1980
    command(state, evidence, 'build-command',
            ['/bin/bash', SOURCE / 'install.sh', 'node', 'fetch', 'piweb'], env, 1980)
    command(state, evidence, 'package-command',
            ['/bin/bash', SOURCE / 'scripts/build-piweb-artifact.sh', root / 'artifact'],
            env, end - time.monotonic())
    artifact = root / 'artifact' / ARTIFACT
    recorded = fingerprint(artifact, 512 * 1024 * 1024)
    sidecar = read(artifact.with_suffix('.gz.sha256'), 256)
    need(sidecar == (recorded['sha256'] + '  ' + ARTIFACT + '\n').encode(),
         'PACKAGER_CHECKSUM_MISMATCH')
    # Save once immediately after packaging; acceptance may not mint a new pin.
    save(state_dir, 'artifact.json', {'path': str(artifact), **recorded})
    save(evidence, 'artifact.sha256', sidecar)
    manifest = read(root / 'build/install/piweb/pi-agent-artifact.json', 16384)
    value = json.loads(manifest)
    need(set(value) == {'schema', 'version', 'os', 'arch', 'piWebVersion', 'piWebRef',
                        'adapterSha256', 'packages'}, 'ARTIFACT_MANIFEST_SHAPE')
    save(evidence, 'artifact-manifest.json', manifest)


def render_invocation(state, root, recorded):
    authority = state['sourceAuthority']
    invocation = authority['invocation']
    validate_invocation(invocation)
    need(hex_sha(state['runToken']) and hex_sha(authority['authoritySha256'])
         and hex_sha(recorded['sha256']), 'INVOCATION_CONTEXT')
    values = {'python': '/usr/bin/python3', 'driver': str(SOURCE / authority['roles']['driver'][0]),
              'custody_mode': invocation['custodyMode'], 'parent': str(root / 'acceptance'),
              'artifact': recorded['path'], 'artifact_sha256': recorded['sha256'],
              'run_token': state['runToken'], 'authority_sha256': authority['authoritySha256']}
    return [values[arg[1:-1]] if arg.startswith('{') else arg for arg in invocation['argv']]


def receipt_values(raw, authority):
    need(len(raw) <= 65536, 'RECEIPT_BOUND')
    receipt = strict_json(raw)
    need(type(receipt) is dict, 'RECEIPT_OBJECT')
    contract = authority['invocation']['receiptContract']
    values = {}
    for name, pointer in contract['fields'].items():
        current = receipt
        for part in pointer.split('/')[1:]:
            need(type(current) is dict and part in current, 'RECEIPT_BINDING_MISSING')
            current = current[part]
        values[name] = current
    return values


def bind_receipt(raw, state, artifact_sha):
    authority = state['sourceAuthority']
    validate_invocation(authority['invocation'])
    need(hex_sha(artifact_sha) and hex_sha(state['runToken'])
         and hex_sha(state['candidateCommit'], 40) and hex_sha(state['candidateTree'], 40)
         and authority['authoritySha256'] == sha(canonical(
             {k: v for k, v in authority.items() if k != 'authoritySha256'})), 'RECEIPT_CONTEXT')
    values = receipt_values(raw, authority)
    contract = authority['invocation']['receiptContract']
    need(type(values['schema']) is int and values['schema'] == contract['schemaValue']
         and values['scope'] == contract['scopeValue']
         and values['status'] in (contract['completedStatus'], 'HOLD'), 'RECEIPT_SCOPE')
    need(values['piwebArtifactSha256'] == artifact_sha
         and values['runToken'] == state['runToken']
         and values['sourceAuthoritySha256'] == authority['authoritySha256']
         and values['supervisor'] == authority['custodyMode']
         and values['baseSourceReference'] == BASE_COMMIT
         and values['sourceLockSha256'] == INSTALLER['sha256']
         and values['pluginSha256'] == '4763b1bc98eb64a7f8cba890a9c7fdf8907a3cab001eb5ccaa246cd45642a846', 'RECEIPT_IDENTITY')
    need(all(values[k] is False for k in ('realUbuntuAcceptance', 'realWSL2Acceptance',
                                        'providerAcceptance', 'rebootAcceptance'))
         and type(values['teardownVerified']) is bool
         and type(values['privateRootRetained']) is bool, 'RECEIPT_ADMISSION')
    runner = {key: state['runner'].get(key) for key in RUNNER_KEYS}
    need(type(runner.get('CI_REPOSITORY')) is str and len(runner['CI_REPOSITORY']) <= 128
         and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', runner['CI_REPOSITORY'])
         and all(type(runner.get(k)) is str and re.fullmatch('[0-9]{1,24}', runner[k])
                 for k in ('CI_RUN_ID', 'CI_RUN_ATTEMPT')), 'RECEIPT_RUN_BINDING')
    need(all(value is None or (type(value) is str and len(value) <= 512
                              and all(32 <= ord(c) < 127 for c in value))
             for value in runner.values()), 'RUNNER_METADATA_BOUND')
    need(all(runner[k] in (None, '') or hex_sha(runner[k], 40)
             for k in ('CI_EVENT_SHA', 'CI_WORKFLOW_SHA')), 'RUNNER_SHA')
    return {'schema': 'owned-ci-raw-receipt-binding/v1', 'classification': authority['classification'],
            'rawReceiptSha256': sha(raw), 'rawReceiptBytes': len(raw),
            'sourceAuthoritySha256': authority['authoritySha256'],
            'componentFreezeSha256': authority['freezeSha256'],
            'componentHandoffSha256': authority['handoffSha256'],
            'consumerLockSha256': authority['lockSha256'], 'sourceRowsSha256': authority['sourceRowsSha256'],
            'candidateCommit': state['candidateCommit'], 'candidateTree': state['candidateTree'],
            'runTokenSha256': sha(state['runToken'].encode()), 'runner': runner,
            'artifactSha256': artifact_sha, 'custodyMode': authority['custodyMode'],
            'receiptStatus': values['status'], 'teardownVerified': values['teardownVerified'],
            'privateRootRetained': values['privateRootRetained'],
            'bindingOutcome': ('SOURCE_BOUND_RECEIPT' if values['status'] == contract['completedStatus']
                               and values['teardownVerified'] and not values['privateRootRetained'] else 'HOLD'),
            'productionAdmission': False, 'wsl2Acceptance': False,
            'providerAcceptance': False, 'rebootAcceptance': False}


def raw_driver_receipt(root, authority):
    directory = root / 'acceptance'
    private(directory)
    pattern = authority['invocation']['receiptContract']['filePattern']
    found = []
    with os.scandir(directory) as entries:
        for count, entry in enumerate(entries, 1):
            need(count <= 128, 'DRIVER_RECEIPT_ENUMERATION_BOUND')
            if fnmatch.fnmatchcase(entry.name, pattern):
                found.append(directory / entry.name)
                need(len(found) <= 1, 'DRIVER_RECEIPT_MISSING_OR_AMBIGUOUS')
    need(len(found) == 1, 'DRIVER_RECEIPT_MISSING_OR_AMBIGUOUS')
    raw, observed = read_with_fingerprint(found[0])
    need(observed['mode'] == 0o600, 'DRIVER_RECEIPT_MODE')
    return raw


def collect_bound_receipt(state, root, evidence, artifact_sha):
    raw = raw_driver_receipt(root, state['sourceAuthority'])
    save(evidence, 'driver-receipt.json', raw)  # Preserve original, including a rejected binding.
    return {'sourceRunReceiptBinding': bind_receipt(raw, state, artifact_sha)}


def accept(state_dir, evidence):
    state, root = context(state_dir, evidence)
    recorded = strict_json(read(state_dir / 'artifact.json'))
    artifact = root / 'artifact' / ARTIFACT
    need(recorded['path'] == str(artifact)
         and fingerprint(artifact, 512 * 1024 * 1024) ==
         {k: recorded[k] for k in ('sha256', 'bytes', 'mode')}, 'RECORDED_ARTIFACT_CHANGED')
    command(state, evidence, 'acceptance-command',
            render_invocation(state, root, recorded),
            environment(root / 'controller'), 2000)
    proof = bind_receipt(raw_driver_receipt(root, state['sourceAuthority']), state, recorded['sha256'])
    need(proof['receiptStatus'] == state['sourceAuthority']['invocation']['receiptContract']['completedStatus']
         and proof['teardownVerified'] is True and proof['privateRootRetained'] is False, 'DRIVER_HOLD')


def collect(state_dir, evidence):
    state, root = context(state_dir, evidence)
    # Only the documented receipt sibling is read. Never copy a retained root,
    # config, identity/pairing state, raw logs, source archive or built artifact.
    recorded = strict_json(read(state_dir / 'artifact.json'))
    need(recorded['path'] == str(root / 'artifact' / ARTIFACT), 'RECORDED_ARTIFACT_PATH')
    return collect_bound_receipt(state, root, evidence, recorded['sha256'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'build', 'accept', 'collect'))
    parser.add_argument('state', type=Path)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    os.umask(0o022)
    try:
        result = globals()[args.phase](args.state, args.evidence)
        save(args.evidence, args.phase + '-result.json',
             {'schema': 1, 'phase': args.phase, 'status': 'EXIT0',
               'productionAdmission': False, **(result or {})})
        return 0
    except Exception as error:
        code = str(error) if isinstance(error, Hold) else type(error).__name__
        try:
            save(args.evidence, args.phase + '-result.json',
                 {'schema': 1, 'phase': args.phase, 'status': 'HOLD',
                  'code': code, 'productionAdmission': False})
        except (Hold, OSError):
            pass
        print('HOLD: ' + args.phase + ': ' + code, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
