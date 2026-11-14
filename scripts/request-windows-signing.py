#!/usr/bin/env python3
"""Build via the existing signer, then verify in Pi Agent; never publish a release.

Requires Python 3 and a GitHub CLI login with Actions write access to both repos.
No signing credential is read, exported, or copied by this command.
"""
import datetime
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
SIGNER = 'WOOWTECH/woowtech-smart'
TARGET = 'WOOWTECH/Woow_native_os_pi_agent'


def gh(*args):
    return subprocess.check_output(['gh', *args], cwd=ROOT, text=True).strip()


def api(path):
    return json.loads(gh('api', path))


def dispatch(repo, workflow, ref, sha, fields):
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=2)
    args = ['workflow', 'run', workflow, '--repo', repo, '--ref', ref]
    for name, value in fields.items():
        args += ['-f', f'{name}={value}']
    gh(*args)
    for _ in range(40):
        runs = json.loads(gh('run', 'list', '--repo', repo, '--workflow', workflow,
                            '--branch', ref, '--event', 'workflow_dispatch', '--limit', '10',
                            '--json', 'databaseId,headSha,createdAt'))
        matches = [r for r in runs if r['headSha'] == sha and
                   datetime.datetime.fromisoformat(r['createdAt'].replace('Z', '+00:00')) >= since]
        if len(matches) > 1:
            raise RuntimeError('Concurrent dispatches; inspect run IDs before continuing')
        if matches:
            return matches[0]['databaseId']
        time.sleep(3)
    raise RuntimeError('Dispatched run did not appear; inspect Actions before retrying')


def wait(repo, run_id):
    print(f'https://github.com/{repo}/actions/runs/{run_id}', flush=True)
    deadline = time.monotonic() + 2400
    old = None
    while time.monotonic() < deadline:
        run = api(f'repos/{repo}/actions/runs/{run_id}')
        if run['status'] != old:
            print(f'{run_id}: {run["status"]}', flush=True)
            old = run['status']
        if run['status'] == 'completed':
            if run['conclusion'] != 'success':
                raise RuntimeError(f'Run {run_id}: {run["conclusion"]}; inspect its logs')
            return
        time.sleep(15)
    raise RuntimeError(f'Run {run_id} still pending; inspect Actions before retrying')


def main():
    config = json.loads((ROOT / 'scripts/windows-signer.json').read_text())
    version = (ROOT / 'VERSION').read_text().strip()
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    ref = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    if not ref or subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        raise RuntimeError('Use a clean, pushed branch checkout')
    if api(f'repos/{TARGET}/commits/{ref}')['sha'] != sha:
        raise RuntimeError('Push the current Pi Agent commit first')
    if api(f'repos/{SIGNER}/commits/{config["ref"]}')['sha'] != config['sha']:
        raise RuntimeError('Signer branch moved; review and update windows-signer.json first')
    workflow_path = f'repos/{SIGNER}/actions/workflows/desktop-release.yml'
    original = api(workflow_path)['state']
    if original not in ('active', 'disabled_manually'):
        raise RuntimeError(f'Signer workflow state needs investigation: {original}')
    try:
        if original != 'active':
            gh('api', workflow_path + '/enable', '--method', 'PUT')
        signing = dispatch(SIGNER, 'desktop-release.yml', config['ref'], config['sha'], {
            'tag': 'v' + version, 'platform': 'pi-agent', 'publish': 'false',
            'pi_agent_sha': sha, 'pi_agent_version': version,
        })
        wait(SIGNER, signing)
    finally:
        if original != 'active':
            gh('api', workflow_path + '/disable', '--method', 'PUT')
    print(f'Signing run: {signing}; source: {sha}', flush=True)
    verification = dispatch(TARGET, 'release.yml', ref, sha, {
        'version': version, 'windows_only': 'true', 'signed_run_id': str(signing),
    })
    wait(TARGET, verification)
    print(f'Verified artifact: https://github.com/{TARGET}/actions/runs/{verification}', flush=True)
    print('No release was published. For a separately approved tag of this exact commit, '
          f'set WINDOWS_SIGNED_RUN_ID={signing} before pushing the tag.', flush=True)


if __name__ == '__main__':
    main()
