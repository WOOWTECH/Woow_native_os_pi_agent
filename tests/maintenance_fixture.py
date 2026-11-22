"""Explicit fake-SDK transport for native adapter tests ONLY.

The production require_maintenance_preservation method is executed unchanged.
Only its subprocess transport receives a labelled synthetic proof; this is not
SDK/source admission. Never installed by wire and never a production skip flag.
"""
from contextlib import contextmanager
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

@contextmanager
def guard_receipt_fixture(module, binary):
    calls = []
    def reply(argv, **options):
        assert argv[:3] == [sys.executable, '-I', '-B']
        assert Path(argv[3]).name == 'maintenance_preservation.py'
        assert argv[4:6] == ['--omnigent-bin', str(binary)]
        assert options['timeout'] == 30
        calls.append(argv)
        proof = dict(schema='plugin-native-maintenance-preservation/v2',ok=True,state='verified',
                     sourceSha256='68f4c2a3c0a3aa75436a15828e325bd279995435d83931d93b12516cca303962',
                     sdkImported=False,distribution='omnigent',coreVersion='0.16.0',
                     consoleEntryPoint='omnigent.cli:main',consoleScriptValidated=True,
                     pythonExecutable=sys.executable,consoleScript=str(Path(binary).resolve()),consoleScriptSha256='f'*64)
        return subprocess.CompletedProcess(argv,0,json.dumps(proof),'')
    with patch.object(module.subprocess,'run',reply):
        yield calls
