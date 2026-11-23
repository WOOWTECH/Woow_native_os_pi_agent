"""AST-only actual packaged adapter seam; synthetic receipts, no SDK/host/network."""
import ast
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import types
from unittest.mock import patch

root, scenario = Path(sys.argv[1]), sys.argv[2]
tree = ast.parse((root / 'src/omnigent.py').read_text())
original = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Plugin')
methods = [n for n in original.body if isinstance(n, ast.FunctionDef) and n.name in
           ('require_maintenance_preservation', 'ensure_host', 'guard_host_name')]
error = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'PluginError')
with tempfile.TemporaryDirectory(prefix='native-adapter-owned-') as d:
    base = Path(d)
    binary = base / 'omnigent'
    binary.write_text('# owned marker only; never executed\n')
    binary.chmod(0o700)
    events, queries, spawned = [], [], []
    def run(argv, **options):
        assert argv[:3] == [sys.executable, '-I', '-B']
        assert argv[3] == str(root / 'src/maintenance_preservation.py')
        events.append('guard')
        proof = dict(schema='plugin-native-maintenance-preservation/v2', ok=True, state='verified',
                     sourceSha256='68f4c2a3c0a3aa75436a15828e325bd279995435d83931d93b12516cca303962',
                     sdkImported=False, distribution='omnigent', coreVersion='0.16.0',
                     consoleEntryPoint='omnigent.cli:main', consoleScriptValidated=True,
                     pythonExecutable=sys.executable, consoleScript=str(binary), consoleScriptSha256='a'*64)
        if scenario == 'identity-refusal':proof['consoleScript'] = '/foreign/omnigent'
        refuse = scenario == 'first-refusal' or (scenario == 'final-refusal' and len(events) == 2)
        return types.SimpleNamespace(returncode=1 if refuse else 0, stdout=json.dumps(proof))
    def popen(argv, **options):
        assert argv[:5] == [sys.executable, '-I', '-B', str(binary), 'host']
        assert not any(k in options['env'] for k in ('PYTHONPATH','PYTHONHOME','PYTHONPYCACHEPREFIX'))
        assert options['env']['OMNIGENT_CONFIG_HOME'] == str(base/'config')
        assert options['env']['OMNIGENT_DATA_DIR'] == str(base/'data')
        spawned.append(options['env']['HOME'])
        return types.SimpleNamespace(pid=1234)
    fake = types.SimpleNamespace(run=run,Popen=popen,DEVNULL=subprocess.DEVNULL,PIPE=subprocess.PIPE,
                                 TimeoutExpired=subprocess.TimeoutExpired)
    ns = dict(Path=Path,sys=sys,json=json,re=re,subprocess=fake,os=os,shutil=shutil,fcntl=fcntl,
              _SCRIPT_DIR=root/'src',atomic_json=lambda *a:None)
    program = ast.Module(body=[error,ast.ClassDef(name='Fixture',bases=[],keywords=[],body=methods,decorator_list=[])],type_ignores=[])
    exec(compile(ast.fix_missing_locations(program),'actual-adapter-fixture','exec'),ns)
    p = ns['Fixture']()
    p.request = dict(omnigentBin=str(binary),allowManagedHost=True)
    p.state_dir,p.workspace = base/'state',base
    p.local_host = lambda:dict(managerRunning=False,id='0'*32,name='fixture-name')
    p.managed_host_pid = lambda server:None
    p.process_identity = lambda pid:{}
    class Client:
        def request(self, method, route):
            queries.append(route)
            if scenario == 'name-unverifiable':raise ns['PluginError']('server_unreachable','fixture')
            if route=='/v1/me':return {'user_id':'fixture-owner'}
            rows=[]
            if scenario in ('collision','takeover-online'):
                rows=[dict(host_id='abcdefab'+'1'*24,name='fixture-name',owner='fixture-owner',status='online')]
            return {'hosts':rows}
    p.client_factory=lambda *a:Client()
    env=dict(HOME=str(base/'scoped'),OMNIGENT_CONFIG_HOME=str(base/'config'),OMNIGENT_DATA_DIR=str(base/'data'),PYTHONPATH='fixture',PYTHONHOME='fixture',PYTHONPYCACHEPREFIX='fixture')
    if scenario=='session-home':env['PI_AGENT_SESSION_HOME']=str(base/'real-home')
    if scenario=='takeover-online':env['PI_AGENT_TAKEOVER_HOST_ID']='abcdefab'
    code=None
    with patch.dict(os.environ,env,clear=True):
        try:p.ensure_host('https://fixture.invalid')
        except ns['PluginError'] as error:code=error.code
    expected={'identity-refusal':'MAINTENANCE_PRESERVATION_REQUIRED','first-refusal':'MAINTENANCE_PRESERVATION_REQUIRED','final-refusal':'MAINTENANCE_PRESERVATION_REQUIRED',
              'collision':'HOST_NAME_COLLISION','takeover-online':'HOST_NAME_TAKEOVER_ONLINE','name-unverifiable':'HOST_NAME_UNVERIFIABLE'}
    assert code==expected.get(scenario),(scenario,code)
    assert len(spawned)==(0 if code else 1)
    if scenario=='first-refusal':assert not queries and not p.state_dir.exists()
    if scenario=='final-refusal':assert len(events)==2 and queries
    if scenario=='session-home':assert spawned==[str(base/'real-home')]
    if scenario=='default-home':assert spawned==[str(base/'scoped')]
    if not code:assert events==['guard','guard']
    print(json.dumps(dict(scenario=scenario,error=code,guardCalls=len(events),spawns=len(spawned))))
