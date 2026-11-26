"""Verified frozen v4 npm package + owned transport fixtures; no SDK/host."""
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "candidate-packages/woowtech-pi-omnigent-plugin-0.3.42-rc.4.tgz"
ARCHIVE_SHA = "fc0d51131e21efc1d9e94ef5f3b5b7bbf7c811691e46769763dcde667a74bcc8"
NODE = shutil.which("node")
PATCHES = ("darwin", "session-home", "host-name-guard", "model-options-hook")

class Consumers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-consumer-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def fixture(self, name="plugin", version="0.3.42-rc.4"):
        p = self.base / name
        archive = ARCHIVE if version != "0.3.34" else ROOT / "candidate-packages/woowtech-pi-omnigent-plugin-0.3.34.tgz"
        expected = ARCHIVE_SHA if version != "0.3.34" else "e9e80783881f8a036cbf922d2f50fad860dac3bd23e170dda768ab3c56107945"
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), expected)
        p.mkdir()
        with tarfile.open(archive, "r:gz") as archive:
            for member in archive.getmembers():
                self.assertTrue(member.isfile() and member.name.startswith("package/"))
                rel = Path(member.name.removeprefix("package/"))
                self.assertFalse(rel.is_absolute() or ".." in rel.parts)
                target = p / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())
                target.chmod(member.mode)
        value = json.loads((p / "package.json").read_text())
        if value["version"] != version:  # unknown-version negative only
            value["version"] = version
            (p / "package.json").write_text(json.dumps(value))
        return p

    def apply(self, p, patch):
        r = subprocess.run([NODE, str(ROOT / "rootfs/bin" / ("omnigent-plugin-" + patch + "-patch.mjs")), str(p)], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_new_shape_composes_in_both_orders_and_is_idempotent(self):
        for index, order in enumerate((PATCHES, tuple(reversed(PATCHES)))):
            with self.subTest(order=order):
                p = self.fixture(str(index))
                for patch in order:self.apply(p, patch)
                installer = (p / "src/installer.mjs").read_text()
                adapter = (p / "src/omnigent.py").read_text()
                common = (p / "src/common.mjs").read_text()
                self.assertIn("model-options-hook (Woow native installer)", installer)
                self.assertIn("uv-constraints (Woow native installer)", installer)
                self.assertNotIn("first-launch (Woow native installer)", installer)
                self.assertIn("session-home (Woow native installer)", adapter)
                self.assertIn("self.guard_host_name(server)", adapter)
                self.assertIn("no-proc-no-verdict (Woow native installer)", adapter)
                self.assertIn("flock-path-fallback (Woow native installer)", common)
                before = {x: (p / "src" / x).read_bytes() for x in ("installer.mjs", "omnigent.py", "common.mjs", "issues.mjs")}
                for patch in reversed(order):self.apply(p, patch)
                self.assertEqual(before, {x: (p / "src" / x).read_bytes() for x in before})
                compile(adapter, "fixture-adapter", "exec")
                for file in ("installer.mjs", "common.mjs", "issues.mjs"):
                    r = subprocess.run([NODE, "--check", str(p / "src" / file)], capture_output=True, text=True)
                    self.assertEqual(r.returncode, 0, r.stderr)

    def test_unknown_version_is_unchanged(self):
        for which in PATCHES:
            p = self.fixture(which, version="9.9.9")
            before = {x.name:x.read_bytes() for x in (p / "src").iterdir() if x.is_file()}
            self.assertIn("SKIPPING", self.apply(p, which))
            self.assertEqual(before,{x.name:x.read_bytes() for x in (p / "src").iterdir() if x.is_file()})

    def test_modern_shape_drift_is_refused(self):
        for which in PATCHES:
            p = self.fixture(which)
            target=p / "src" / ("installer.mjs" if which=="model-options-hook" else "omnigent.py")
            source=target.read_text().replace("maintenancePreservation = await maintenance", "maintenancePreservation = await other") if which=="model-options-hook" else target.read_text().replace("launch = self.require_maintenance_preservation()", "launch = other()")
            target.write_text(source)
            before={x.name:x.read_bytes() for x in (p / "src").iterdir() if x.is_file()}
            self.assertIn("SKIPPING",self.apply(p,which))
            self.assertEqual(before,{x.name:x.read_bytes() for x in (p / "src").iterdir() if x.is_file()})

    def test_legacy_warmup_remains(self):
        p=self.fixture(version="0.3.34")
        baseline=self.fixture("legacy-baseline",version="0.3.34")
        for which in PATCHES:
            self.apply(p,which)
            name="omnigent-plugin-"+which+"-patch.mjs"
            script=self.base/name
            script.write_bytes(subprocess.check_output(['git','show','a1149879db6644c193625472bf647af5871d6ffa:rootfs/bin/'+name],cwd=ROOT))
            result=subprocess.run([NODE,str(script),str(baseline)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        def snapshot(path):
            return {str(f.relative_to(path)):(f.read_bytes(),f.stat().st_mode & 0o777)
                    for f in (path/'src').rglob('*') if f.is_file()}
        self.assertEqual(snapshot(p),snapshot(baseline))
        self.assertIn("first-launch (Woow native installer)",(p/"src/installer.mjs").read_text())

    def test_guard_auth_identity_signal_methods_unchanged(self):
        p=self.fixture()
        original=ast.parse((p/"src/omnigent.py").read_text())
        for which in PATCHES:self.apply(p,which)
        after=ast.parse((p/"src/omnigent.py").read_text())
        def methods(tree):
            return {x.name:ast.dump(x,include_attributes=False) for c in tree.body if isinstance(c,ast.ClassDef) and c.name=="Plugin" for x in c.body if isinstance(x,ast.FunctionDef)}
        before,now=methods(original),methods(after)
        self.assertEqual(set(now),set(before)|{"guard_host_name"})
        for name in before:
            if name not in ("ensure_host","resume"):self.assertEqual(before[name],now[name],name)
        # Remove only the reviewed additions; every original statement, guard,
        # lock and spawn must then have its original AST in these two methods.
        class NativeAdditions(ast.NodeTransformer):
            def __init__(self):self.home=self.name=self.proc=0
            def visit_If(self,node):
                if ast.unparse(node.test)=='os.environ.get(\'PI_AGENT_SESSION_HOME\')':
                    self.home+=1
                    return None
                return self.generic_visit(node)
            def visit_Expr(self,node):
                if ast.unparse(node.value)=='self.guard_host_name(server)':
                    self.name+=1
                    return None
                return self.generic_visit(node)
            def visit_BoolOp(self,node):
                node=self.generic_visit(node)
                kept=[v for v in node.values if ast.unparse(v)!="Path('/proc/self').exists()"]
                self.proc+=len(node.values)-len(kept)
                node.values=kept
                return node
        remove=NativeAdditions()
        normalized=methods(remove.visit(after))
        self.assertEqual((remove.home,remove.name,remove.proc),(1,1,1))
        for name in ('ensure_host','resume'):self.assertEqual(before[name],normalized[name],name)
        with tarfile.open(ARCHIVE,"r:gz") as tf:
            self.assertEqual((p/"src/maintenance_preservation.py").read_bytes(),tf.extractfile("package/src/maintenance_preservation.py").read())

    def test_real_installer_transport_order_and_refusal(self):
        p=self.fixture()
        self.apply(p,"darwin");self.apply(p,"model-options-hook")
        state=self.base/"state"; (state/"bin").mkdir(parents=True)
        (state/"bin/omnigent-model-options-patch.py").write_text("# marker never executed")
        for mode in ("fresh","force"):
            for ambient in ('hardlink','clone','copy','unset'):
                for scenario in ("ok","model-fails","model-throws","guard-fails","guard-throws"):
                    with self.subTest(mode=mode,ambient=ambient,scenario=scenario):
                        r=subprocess.run([NODE,str(ROOT/"tests/native-maintenance-install-driver.mjs"),str(p),str(state),mode,scenario,ambient],capture_output=True,text=True,timeout=10)
                        self.assertEqual(r.returncode,0,r.stderr)
                        value=json.loads(r.stdout)
                        self.assertEqual(value['events'],['discover','uv','model','discover','maintenance'])
                        self.assertEqual('--force' in value['installs'][0],mode=='force')
                        self.assertIn('--constraints',value['installs'][0])
                        self.assertEqual(value['installLinkModes'],['copy'])
                        self.assertEqual(value['ambientLinkMode'],None if ambient=='unset' else ambient)
                        self.assertTrue(value['callerEnvUnchanged'])
                        self.assertEqual(value['ok'],not scenario.startswith('guard-'))
                        self.assertEqual(value['maintenance']['ok'],not scenario.startswith('guard-'))
        # An owned mutation of the new package proves that copy-mode assertions
        # fail independently of an otherwise successful synthetic guard receipt.
        installer=p/'src/installer.mjs';text=installer.read_text()
        self.assertEqual(text.count("UV_LINK_MODE: 'copy'"),1)
        installer.write_text(text.replace("UV_LINK_MODE: 'copy'","UV_LINK_MODE: 'hardlink'"))
        r=subprocess.run([NODE,str(ROOT/'tests/native-maintenance-install-driver.mjs'),str(p),str(state),'fresh','ok','hardlink'],capture_output=True,text=True,timeout=10)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('AssertionError',r.stderr)

    def test_real_adapter_ast_seams(self):
        p=self.fixture()
        for which in PATCHES:self.apply(p,which)
        for scenario in ('default-home','session-home','collision','takeover-online','name-unverifiable','first-refusal','final-refusal','identity-refusal'):
            with self.subTest(scenario=scenario):
                r=subprocess.run([sys.executable,'-B',str(ROOT/'tests/native-maintenance-adapter-fixture.py'),str(p),scenario],capture_output=True,text=True,timeout=10)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                self.assertEqual(json.loads(r.stdout)['scenario'],scenario)

if __name__ == "__main__":unittest.main(verbosity=2)
