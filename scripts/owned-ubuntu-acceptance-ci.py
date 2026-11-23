#!/usr/bin/env python3
"""Direct disposable Ubuntu CI route. No fixture, SDK import or release publisher.

Only a later authorized workflow invokes these phases. Never run this helper as
a source check. Raw build/runtime output is discarded; private roots are retained
on failure until runner disposal. Uploaded evidence is an explicit allowlist.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
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


def fingerprint(path, maximum):
    need(path.resolve(strict=True) == path, 'LINKED_PATH')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
             and before.st_size <= maximum, 'FILE_TYPE_OR_BOUND')
        h = hashlib.sha256()
        size = 0
        while True:
            block = os.read(fd, 65536)
            if not block:
                break
            size += len(block)
            need(size <= maximum, 'FILE_BOUND')
            h.update(block)
        after = os.fstat(fd)
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns,
                            s.st_ctime_ns, s.st_mode, s.st_nlink)
        need(fields(before) == fields(after) == fields(path.lstat())
             and size == before.st_size, 'FILE_CHANGED')
        return {'sha256': h.hexdigest(), 'bytes': size,
                'mode': stat.S_IMODE(before.st_mode)}
    finally:
        os.close(fd)


def read(path, maximum=65536):
    before = fingerprint(path, maximum)
    raw = path.read_bytes()
    need(len(raw) == before['bytes']
         and hashlib.sha256(raw).hexdigest() == before['sha256'], 'READ_CHANGED')
    return raw


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


def git(*args):
    result = subprocess.run(['/usr/bin/git', '-C', str(SOURCE), *args],
                            env=MINIMAL, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=10, check=False)
    need(result.returncode == 0 and len(result.stdout) <= 4096, 'GIT_IDENTITY')
    return result.stdout.decode().strip()


def source_identity(expected_head):
    need(re.fullmatch('[a-f0-9]{40}', expected_head or ''), 'EXPECTED_PR_HEAD')
    need(git('rev-parse', 'HEAD') == expected_head, 'CHECKOUT_NOT_PR_HEAD')
    need(not git('status', '--porcelain', '--untracked-files=normal'), 'DIRTY_CHECKOUT')
    pins = json.loads(read(SOURCE / LOCK))
    input_pin = pins['installerInputLock']
    need(fingerprint(SOURCE / input_pin['path'], 65536)['sha256'] == input_pin['sha256'],
         'INSTALLER_LOCK_DRIFT')
    installer = json.loads(read(SOURCE / input_pin['path']))
    need(installer['baseCommit'] == pins['baseCommit']
         and installer['baseTree'] == pins['baseTree']
         and len(installer['files']) == input_pin['count'] == 40, 'BASE_IDENTITY')
    for row in [pins['packager'], *installer['files'], *pins['candidateSource']['files']]:
        actual = fingerprint(SOURCE / row['path'], 4 * 1024 * 1024)
        need(all(actual[k] == row[k] for k in ('sha256', 'bytes', 'mode')),
             'SOURCE_PIN_DRIFT')
    return {'candidateCommit': expected_head, 'candidateTree': git('rev-parse', 'HEAD^{tree}'),
            'baseReference': pins['baseCommit'], 'baseTreeReference': pins['baseTree'],
            'installerInputLock': input_pin, 'installerInputs': installer['files'],
            'originalPackager': pins['packager'], 'candidateSource': pins['candidateSource'],
            'routeFiles': {p: fingerprint(SOURCE / p, 131072) for p in ROUTE_FILES}}


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
    state = json.loads(read(state_dir / 'state.json'))
    root = Path(state['root'])
    private(root)
    need(root.parent == Path('/tmp') and root.name.startswith('own-ub-'), 'ROOT_BINDING')
    for name in ('build', 'controller', 'artifact', 'acceptance'):
        private(root / name)
    source_identity(state['candidateCommit'])
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
    state = {'root': str(root), 'candidateCommit': identity['candidateCommit'], 'tools': tools}
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


def driver_receipt(root):
    found = list((root / 'acceptance').glob('native-acceptance-*.receipt.json'))
    need(len(found) == 1, 'DRIVER_RECEIPT_MISSING_OR_AMBIGUOUS')
    need(fingerprint(found[0], 65536)['mode'] == 0o600, 'DRIVER_RECEIPT_MODE')
    raw = read(found[0])
    receipt = json.loads(raw)
    need(receipt['schema'] == 1 and receipt['scope'] == 'owned-platform-scenario'
         and receipt['baseSourceReference'] == '172522c8a4065f80e813d6d4710b26b13b6094c7'
         and all(receipt[k] is False for k in ('realUbuntuAcceptance', 'realWSL2Acceptance',
                                               'providerAcceptance', 'rebootAcceptance')),
         'DRIVER_RECEIPT_BINDING')
    return raw, receipt


def accept(state_dir, evidence):
    state, root = context(state_dir, evidence)
    recorded = json.loads(read(state_dir / 'artifact.json'))
    artifact = root / 'artifact' / ARTIFACT
    need(recorded['path'] == str(artifact)
         and fingerprint(artifact, 512 * 1024 * 1024) ==
         {k: recorded[k] for k in ('sha256', 'bytes', 'mode')}, 'RECORDED_ARTIFACT_CHANGED')
    command(state, evidence, 'acceptance-command',
            ['/usr/bin/python3', '-B', SOURCE / 'tests/owned_native_acceptance.py',
             '--mode', 'acceptance', '--platform', 'ubuntu', '--supervisor', 'owned-pgid',
             '--parent', root / 'acceptance', '--piweb-artifact', recorded['path'],
             '--piweb-artifact-sha256', recorded['sha256'], '--deadline-seconds', '1800'],
            environment(root / 'controller'), 2000)
    _, receipt = driver_receipt(root)
    need(receipt['status'] == 'OWNED_SCENARIO_COMPLETED'
         and receipt['teardownVerified'] is True
         and receipt['privateRootRetained'] is False
         and receipt['piwebArtifactSha256'] == recorded['sha256'], 'DRIVER_HOLD')


def collect(state_dir, evidence):
    state, root = context(state_dir, evidence)
    # Only the documented receipt sibling is read. Never copy a retained root,
    # config, identity/pairing state, raw logs, source archive or built artifact.
    try:
        raw, _ = driver_receipt(root)
    except (Hold, OSError, ValueError, KeyError):
        return
    save(evidence, 'driver-receipt.json', raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'build', 'accept', 'collect'))
    parser.add_argument('state', type=Path)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    os.umask(0o022)
    try:
        globals()[args.phase](args.state, args.evidence)
        save(args.evidence, args.phase + '-result.json',
             {'schema': 1, 'phase': args.phase, 'status': 'EXIT0',
              'productionAdmission': False})
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
