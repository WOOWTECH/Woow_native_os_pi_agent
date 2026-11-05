#!/usr/bin/env python3
"""resume() where there is no /proc: the Python half of tests/resume-no-proc.sh.

It runs the REAL src/omnigent.py of the pinned pi-omnigent-plugin through Plugin.resume(), with the plugin's own
httpx client, against a stub Omnigent server on 127.0.0.1. The `omnigent` binary the plugin starts is a stand-in
that records the call and exits at once, as the real one does when a host is already running ("A host daemon is
already running for this server"). So the situation is the one after a pi-web restart on a Mac: a host is connected,
the plugin cannot see it, and the process it just started is gone.

Without /proc means what it says on a Mac. On Linux it is simulated by giving the module a Path that finds nothing
under /proc, which is exactly what managed_host_pid() and the edit look at; section B then also runs with the real
/proc, to show that nothing changes where /proc exists. Nothing here touches ~/.omnigent, a running install or a
real server.

usage: python -I -B resume_no_proc_test.py <pristine plugin dir> <node> <darwin patch script>
"""
import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PRISTINE, NODE, PATCH = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
WORK = Path(tempfile.mkdtemp(prefix="pa-resume-"))
BASE_ENV = {k: v for k, v in os.environ.items()
            if not k.upper().startswith(("OMNIGENT", "OG_", "PI_AGENT", "RUNNER_")) and not k.lower().endswith("_proxy")}
BASE_ENV["NO_PROXY"] = BASE_ENV["no_proxy"] = "127.0.0.1,localhost"
HOST_ID = "0123456789abcdef0123456789abcdef"
REAL_PROC = Path("/proc/self").exists()
MARKER = "no-proc-no-verdict (Woow native installer)"

passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  PASS  {label}")
    else:
        failed += 1
        print(f"  FAIL  {label}")
        if detail:
            print("        " + str(detail).replace("\n", "\n        "))


def load(name, patched):
    """Import a private copy of the plugin's omnigent.py, through the darwin patch or not."""
    plugin = WORK / name
    (plugin / "src").mkdir(parents=True)
    shutil.copy(PRISTINE / "package.json", plugin / "package.json")
    shutil.copy(PRISTINE / "src" / "omnigent.py", plugin / "src" / "omnigent.py")
    if patched:
        (plugin / "src" / "installer.mjs").write_text("")   # the patch's other files: absent anchors only log
        (plugin / "src" / "common.mjs").write_text("")
        done = subprocess.run([NODE, PATCH, str(plugin)], capture_output=True, text=True)
        assert done.returncode == 0, done.stdout + done.stderr
        assert MARKER in (plugin / "src" / "omnigent.py").read_text(), done.stdout
    spec = importlib.util.spec_from_file_location(f"omnigent_plugin_{name}", plugin / "src" / "omnigent.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def hide_proc(mod):
    """Give the module a Path that finds nothing under /proc (a no-op where there is no /proc anyway)."""
    real = Path

    def no_proc_path(*args):
        first = os.fspath(args[0]) if args else ""
        if first == "/proc" or first.startswith("/proc/"):
            return real("/nonexistent-proc-for-this-test" + first[len("/proc"):])
        return real(*args)

    no_proc_path.home = real.home
    mod.Path = no_proc_path


class FakeAuth:
    def token(self, server, refresh=True):
        return "stub-token"


# ------------------------------------------------------------- the server ---
STATE = {"statuses": [], "log": []}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        STATE["log"].append(self.path)
        if self.path == "/v1/me":
            return self._reply(200, {"user_id": "u_me"})
        if self.path == f"/v1/hosts/{HOST_ID}":
            statuses = STATE["statuses"]
            status = statuses.pop(0) if len(statuses) > 1 else statuses[0]
            return self._reply(200, {"host_id": HOST_ID, "owner": "u_me", "name": "testbox (pi-agent)", "status": status})
        return self._reply(404, {"detail": "not found"})


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}"


def resume(mod, statuses, timeout=8):
    """One resume() with a fresh config; returns (result, error code, whether a host process was started)."""
    work = Path(tempfile.mkdtemp(dir=WORK))
    config, workspace = work / "omni", work / "ws"
    config.mkdir()
    workspace.mkdir()
    (config / "config.yaml").write_text(f"server: {URL}\nhost:\n  host_id: {HOST_ID}\n  name: testbox (pi-agent)\n")
    started, binary = work / "started.txt", work / "omnigent"
    binary.write_text(f'#!/bin/sh\necho "$*" > "{started}"\nexit 1\n')   # the real one refuses a duplicate like this
    binary.chmod(0o755)
    STATE["statuses"], STATE["log"] = list(statuses), []
    os.environ.clear()
    os.environ.update(BASE_ENV)
    plugin = mod.Plugin({"configHome": str(config), "dataDir": str(config), "stateDir": str(work / "state"),
                         "workspace": str(workspace), "omnigentBin": str(binary), "server": URL, "action": "resume",
                         "resumeHostId": HOST_ID, "allowManagedHost": True, "timeoutSeconds": timeout}, auth=FakeAuth())
    result = code = None
    try:
        result = plugin.resume()
    except mod.PluginError as caught:
        code = caught.code
    finally:
        plugin.close()
    for _ in range(100):
        if started.exists():
            break
        time.sleep(0.02)
    return result, code, started.exists()


patched, pristine = load("patched", True), load("pristine", False)
hide_proc(patched)
hide_proc(pristine)
where = "this Mac has no /proc" if not REAL_PROC else "/proc hidden from the module"

print(f"== A. without /proc ({where}): a connected host after a pi-web restart ==")
result, code, started = resume(pristine, ["online"])
check("the unpatched plugin reports the connected host as gone: HOST_PROCESS_MISSING (the bug)",
      code == "HOST_PROCESS_MISSING" and result is None, f"result={result} code={code}")
result, code, started = resume(patched, ["online"])
check("patched: resume succeeds, with the id and server the plugin's receipt check compares",
      code is None and result == {"server": URL, "host": {"id": HOST_ID, "connected": True, "manager": "plugin"}},
      f"result={result} code={code}")
check("...and the plugin still tried to start a host, as it does when it cannot see one", started)
result, code, _ = resume(patched, ["offline", "offline", "online"])
check("a host that comes back after a moment: still connected", code is None and result and result["host"]["connected"],
      f"result={result} code={code}")
result, code, _ = resume(patched, ["offline"], timeout=3)
check("a host that never comes back is still an error: HOST_CONNECT_TIMEOUT, not a false success",
      code == "HOST_CONNECT_TIMEOUT" and result is None, f"result={result} code={code}")

print("== B. with /proc: nothing changes ==")
if not REAL_PROC:
    print("  SKIP  this machine has no /proc")
else:
    real = load("patched_real_proc", True)
    result, code, started = resume(real, ["online"])
    check("patched, real /proc: a host that exited is still HOST_PROCESS_MISSING",
          code == "HOST_PROCESS_MISSING" and result is None and started, f"result={result} code={code}")

server.shutdown()
shutil.rmtree(WORK, ignore_errors=True)
print()
print(f"SUMMARY passed={passed} failed={failed}")
sys.exit(1 if failed else 0)
