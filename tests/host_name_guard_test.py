#!/usr/bin/env python3
"""Behavioural test of the v0.2.2 host-name guard (the Python half of tests/host-name.sh).

It runs the REAL patched src/omnigent.py of the pinned pi-omnigent-plugin -- the
file omnigent-plugin-host-name-guard-patch.mjs produces from the pristine plugin
-- through Plugin.ensure_host(), with the plugin's own httpx Client, against a
stub Omnigent server on 127.0.0.1 that serves /v1/me and /v1/hosts and records
every request. The `omnigent` binary the plugin would start is a stub script that
writes a marker file, so "was a host started?" is observed rather than inferred.

Nothing here touches ~/.omnigent, a running install or a real server.

usage: python -I -B host_name_guard_test.py <pristine plugin dir> <node> <patch script>
"""
import http.server
import importlib.util
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PRISTINE, NODE, PATCH = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
WORK = Path(tempfile.mkdtemp(prefix="pa-hn-guard-"))
# The environment every scenario starts from: nothing of the machine's own Omnigent or
# pi-agent setup (this suite may well be run from inside an Omnigent session), and no
# proxy between the plugin's httpx client and the stub server on 127.0.0.1.
BASE_ENV = {k: v for k, v in os.environ.items()
            if not k.upper().startswith(("OMNIGENT", "OG_", "PI_AGENT", "RUNNER_")) and not k.lower().endswith("_proxy")}
BASE_ENV["NO_PROXY"] = BASE_ENV["no_proxy"] = "127.0.0.1,localhost"

# ids: OLD is the host being collided with (or replaced); MINE this install's own
OLD = "2b8a18bc000000000000000000000000"
OLD2 = "9f3c7d21aabbccddeeff001122334455"
SIBLING = "2b8a18bc111111111111111111111111"      # shares OLD's first 8 characters
MINE = "0123456789abcdef0123456789abcdef"
NAME = "ElmodeMacBook-Air.local"

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


# ------------------------------------------------------------- the plugin ---
PLUGIN = WORK / "plugin"
(PLUGIN / "src").mkdir(parents=True)
shutil.copy(PRISTINE / "package.json", PLUGIN / "package.json")
shutil.copy(PRISTINE / "src" / "omnigent.py", PLUGIN / "src" / "omnigent.py")
done = subprocess.run([NODE, PATCH, str(PLUGIN)], capture_output=True, text=True)
assert done.returncode == 0 and "patched" in done.stdout, done.stdout + done.stderr
spec = importlib.util.spec_from_file_location("omnigent_plugin_under_test", PLUGIN / "src" / "omnigent.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
PluginError = mod.PluginError


class FakeAuth:
    def token(self, server, refresh=True):
        return "stub-token"


# ------------------------------------------------------------- the server ---
STATE = {"log": []}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, status, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        STATE["log"].append((self.command, self.path, self.headers.get("Authorization")))
        route = {"/v1/me": "me", "/v1/hosts": "hosts"}.get(self.path)
        if route is None:
            return self._reply(404, {"detail": "not found"})
        status, body = STATE[route]
        return self._reply(status, body)

    def _anything_else(self):
        STATE["log"].append((self.command, self.path, None))
        self._reply(405, {"detail": "the guard only reads"})

    do_POST = do_PUT = do_DELETE = do_PATCH = _anything_else


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}"


def host(host_id, name=NAME, status="online", owner="u_me"):
    row = {"host_id": host_id, "name": name, "status": status}
    if owner is not None:
        row["owner"] = owner
    return row


class Outcome:
    def __init__(self, result, error, marker, log):
        self.result, self.error, self.marker, self.log = result, error, marker, log

    @property
    def spawned(self):
        return self.marker is not None

    @property
    def code(self):
        return self.error.code if self.error else None

    @property
    def message(self):
        return self.error.message if self.error else ""


def scenario(hosts=(), *, name=NAME, my_id=None, me=(200, {"user_id": "u_me"}), hosts_reply=None,
             takeover=None, username=None, agent_home=None, url=None, managed=True, config_text=None):
    """One ensure_host() call with a fresh state/config directory and a fresh environment."""
    work = Path(tempfile.mkdtemp(dir=WORK))
    config_home, workspace = work / "omni", work / "ws"
    config_home.mkdir()
    workspace.mkdir()
    if config_text is not None:
        (config_home / "config.yaml").write_text(config_text)
    elif name is not None:
        lines = ["host:"] + ([f"  host_id: {my_id}"] if my_id else []) + [f"  name: {json.dumps(name)}"]
        (config_home / "config.yaml").write_text("\n".join(lines) + "\n")
    marker, binary = work / "spawned.txt", work / "omnigent"
    binary.write_text(f'#!/bin/sh\necho "spawned $*" > "{marker}"\n'
                      f'echo "takeover=${{PI_AGENT_TAKEOVER_HOST_ID-unset}}" >> "{marker}"\n')
    binary.chmod(0o755)
    STATE["log"] = []
    STATE["me"] = me
    STATE["hosts"] = hosts_reply if hosts_reply is not None else (200, {"hosts": list(hosts)})
    server_url = url or URL
    request = {"configHome": str(config_home), "dataDir": str(config_home), "stateDir": str(work / "state"),
               "workspace": str(workspace), "omnigentBin": str(binary), "server": server_url}
    if managed:
        request["allowManagedHost"] = True
    if username:
        request["username"] = username
    os.environ.clear()
    os.environ.update(BASE_ENV)
    for key in ("PI_AGENT_TAKEOVER_HOST_ID", "PI_AGENT_HOME", "OG_HOST_ENABLED", "OG_STATUS_FILE"):
        os.environ.pop(key, None)
    if takeover is not None:
        os.environ["PI_AGENT_TAKEOVER_HOST_ID"] = takeover
    if agent_home is not None:
        os.environ["PI_AGENT_HOME"] = agent_home
    plugin = mod.Plugin(request, auth=FakeAuth())
    result = error = None
    try:
        result = plugin.ensure_host(server_url)
    except PluginError as caught:
        error = caught
    finally:
        plugin.close()
    text = None
    if result == "plugin":
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not marker.exists():
            time.sleep(0.02)
        time.sleep(0.05)
        text = marker.read_text() if marker.exists() else None
    elif error is not None:
        time.sleep(0.15)
        text = marker.read_text() if marker.exists() else None
    out = Outcome(result, error, text, list(STATE["log"]))
    out.env_takeover_after = os.environ.get("PI_AGENT_TAKEOVER_HOST_ID")
    os.environ.clear()
    os.environ.update(BASE_ENV)
    return out


def read_only(out):
    return all(m == "GET" and p in ("/v1/me", "/v1/hosts") for m, p, _ in out.log)


def started(label, out):
    check(label, out.result == "plugin" and out.spawned and out.error is None,
          f"result={out.result!r} error={out.code} {out.message!r} marker={out.marker!r}")


def refused(label, out, code):
    check(label, out.code == code and not out.spawned and out.result is None,
          f"result={out.result!r} code={out.code} spawned={out.spawned} {out.message!r}")


# --------------------------------------------------------------- scenarios ---
print("== E. the guard, against the real patched omnigent.py and a stub server ==")

out = scenario([host(OLD, "some other machine")], my_id=MINE)
started("E1 no other host has this name -> the host is started", out)
check("E1b ...and the guard only read: GET /v1/me, GET /v1/hosts, with the bearer token", read_only(out) and
      [(m, p) for m, p, _ in out.log] == [("GET", "/v1/me"), ("GET", "/v1/hosts")] and out.log[0][2] == "Bearer stub-token", str(out.log))

started("E2 an empty host list (first host of a fresh server) -> started", scenario([], my_id=None))
started("E3 the only same-named row is this install's own host_id -> started (a restart is not a collision)",
        scenario([host(MINE, status="online")], my_id=MINE))
started("E3b ...even when the server spells the id dashed and upper-case",
        scenario([host("01234567-89AB-CDEF-0123-456789ABCDEF")], my_id=MINE))
started("E3c ...and when this install has no host_id yet but the name is unused",
        scenario([host(OLD, "elsewhere")], my_id=None))

out = scenario([host(OLD)], my_id=MINE, username="woow", agent_home="/tmp/x y/pa")
refused("E4 another host holds the name (online) -> HOST_NAME_COLLISION, nothing started", out, "HOST_NAME_COLLISION")
m = out.message
check("E4b the message is in zh-TW and names the other host: name, id8, online", "已被" in m and NAME in m and "host_id 2b8a18bc（目前在線）" in m, m)
bindir = shlex.quote("/tmp/x y/pa/bin/pi-omnigent")
check("E4c ...and carries the exact takeover line, id filled in, quoted for the path with a space",
      f"  PI_AGENT_TAKEOVER_HOST_ID=2b8a18bc {bindir} connect --server {URL} --username woow --password-stdin" in m, m)
check("E4d ...and the exact rename line (suggested unique name, quoted)",
      f"  {shlex.quote('/tmp/x y/pa/bin/pi-agent-host-name')} set {shlex.quote(NAME + ' (pi-agent)')}" in m, m)
check("E4e ...and the guard made no write request", read_only(out), str(out.log))

out = scenario([host(OLD)], my_id=MINE)
check("E4f without a username the retry is `repair`, and with no PI_AGENT_HOME the tools are bare names",
      f"  PI_AGENT_TAKEOVER_HOST_ID=2b8a18bc pi-omnigent repair --server {URL}" in out.message
      and f"  pi-agent-host-name set {shlex.quote(NAME + ' (pi-agent)')}" in out.message, out.message)

out = scenario([host(OLD, status="offline")], my_id=MINE)
refused("E5 an OFFLINE duplicate counts too (the server would still move its bound conversations)", out, "HOST_NAME_COLLISION")
check("E5b ...and the message says it is offline", "host_id 2b8a18bc（目前離線）" in out.message, out.message)

out = scenario([host(OLD, name="elmodemacbook-air.LOCAL")], my_id=MINE)
refused("E6 names are compared ignoring case and surrounding spaces", out, "HOST_NAME_COLLISION")

out = scenario([host(OLD, name="  " + NAME + " ")], my_id=MINE)
refused("E6b ...and surrounding spaces", out, "HOST_NAME_COLLISION")

started("E7 a same-named host of ANOTHER account is not a collision (the server scopes names per account)",
        scenario([host(OLD, owner="u_someone_else")], my_id=MINE))
refused("E7b ...but a row of the same account is", scenario([host(OLD, owner="u_me")], my_id=MINE), "HOST_NAME_COLLISION")
refused("E7c ...and with no account id to compare, every same-named row counts (conservative)",
        scenario([host(OLD, owner="u_someone_else")], my_id=MINE, me=(200, {})), "HOST_NAME_COLLISION")
refused("E7d ...as does a row with no owner field at all", scenario([host(OLD, owner=None)], my_id=MINE), "HOST_NAME_COLLISION")

out = scenario([host(MINE), host(OLD2, status="offline")], my_id=MINE)
refused("E8 own row + a stale offline duplicate -> refused, and only the duplicate is named", out, "HOST_NAME_COLLISION")
check("E8b ...", "9f3c7d21" in out.message and "01234567" not in out.message, out.message)

hn = socket.gethostname()
out = scenario([host(OLD, hn)], name=None)
refused("E9 a config with no name falls back to the machine's hostname, which omnigent would use", out, "HOST_NAME_COLLISION")
check("E9b ...", hn in out.message, out.message)

out = scenario([host(OLD, "box (pi-agent)")], name="box (pi-agent)", my_id=MINE)
check("E10 a name that already ends in (pi-agent) is suggested as `(pi-agent 2)`",
      shlex.quote("box (pi-agent 2)") in out.message, out.message)

# ---- fail closed -----------------------------------------------------------
print("== F. fail closed: the server cannot answer ==")
cases = [
    ("F1 /v1/hosts -> 500", dict(hosts_reply=(500, {"detail": "boom"})), "HTTP_500"),
    ("F2 /v1/hosts -> 401", dict(hosts_reply=(401, {"detail": "no"})), "NEEDS_LOGIN"),
    ("F3 /v1/hosts -> 403", dict(hosts_reply=(403, {"detail": "no"})), "FORBIDDEN"),
    ("F4 /v1/hosts -> not JSON", dict(hosts_reply=(200, b"<html>captive portal</html>")), "INVALID_RESPONSE"),
    ("F5 /v1/hosts -> JSON without a list", dict(hosts_reply=(200, {"hosts": {"a": 1}})), "INVALID_RESPONSE"),
    ("F6 /v1/hosts -> JSON that is not an object", dict(hosts_reply=(200, b"[1,2,3]")), "INVALID_RESPONSE"),
    ("F7 /v1/me -> 500", dict(me=(500, {"detail": "boom"})), "HTTP_500"),
    ("F8 /v1/me -> 401", dict(me=(401, {})), "NEEDS_LOGIN"),
]
for label, kwargs, reason in cases:
    out = scenario([host(OLD, "unrelated")], my_id=MINE, **kwargs)
    refused(f"{label} -> HOST_NAME_UNVERIFIABLE, nothing started", out, "HOST_NAME_UNVERIFIABLE")
    check(f"{label}: the message says why ({reason}) and that nothing was started", reason in out.message and "先不啟動" in out.message, out.message)

dead = socket.socket()
dead.bind(("127.0.0.1", 0))
dead_url = f"http://127.0.0.1:{dead.getsockname()[1]}"
dead.close()
out = scenario([], my_id=MINE, url=dead_url)
refused("F9 the server is unreachable -> HOST_NAME_UNVERIFIABLE", out, "HOST_NAME_UNVERIFIABLE")
check("F9b ...with SERVER_UNREACHABLE as the reason", "SERVER_UNREACHABLE" in out.message, out.message)

out = scenario([host(OLD)], my_id=MINE, hosts_reply=(500, {}), takeover="2b8a18bc")
refused("F10 a takeover id does not bypass an unanswerable question", out, "HOST_NAME_UNVERIFIABLE")

# ---- the override ----------------------------------------------------------
print("== G. PI_AGENT_TAKEOVER_HOST_ID ==")
for value in ["2b8a18bc", "2B8A18BC", "2b8a18bc0000", OLD, "2b8a18bc-0000-0000-0000-000000000000", " 2b8a18bc "]:
    out = scenario([host(OLD, status="offline")], my_id=MINE, takeover=value)
    started(f"G1 a prefix of the old host's id ({value!r}), old host offline -> started", out)
    check(f"G1b ...the variable was spent: the started host does not inherit it ({value!r})",
          out.marker is not None and "takeover=unset" in out.marker and out.env_takeover_after is None, str(out.marker))

for value in ["1", "true", "yes", "TRUE", "", "   ", "all", "*", "2b8a18b", "zzzzzzzz", "2b8a18bd", "2b8a18bc" + "0" * 25]:
    out = scenario([host(OLD, status="offline")], my_id=MINE, takeover=value)
    refused(f"G2 {value!r} does NOT take over (generic flag, typo, too short, not hex, too long)", out, "HOST_NAME_COLLISION")
    if value.strip():
        check(f"G2b ...and the refusal explains the variable ({value!r})", "沒有涵蓋" in out.message and "不接受 1 或 true" in out.message, out.message)

out = scenario([host(OLD, status="offline"), host(OLD2, status="offline")], my_id=MINE, takeover="2b8a18bc")
refused("G3 two same-named hosts: a prefix naming only one of them is refused", out, "HOST_NAME_COLLISION")
check("G3b ...and the message says takeover can only name one host (and offers no takeover line)",
      "不只一台" in out.message and "  PI_AGENT_TAKEOVER_HOST_ID=" not in out.message, out.message)

started("G4 two same-named hosts that BOTH start with the prefix are covered by it",
        scenario([host(OLD, status="offline"), host(SIBLING, status="offline")], my_id=MINE, takeover="2b8a18bc"))
refused("G4b ...but a longer prefix that fits only one of them is not enough",
        scenario([host(OLD, status="offline"), host(SIBLING, status="offline")], my_id=MINE, takeover="2b8a18bc0000"), "HOST_NAME_COLLISION")

out = scenario([host(OLD, status="online")], my_id=MINE, takeover="2b8a18bc")
refused("G5 taking over a host that is still ONLINE is refused (two live daemons are the problem)", out, "HOST_NAME_TAKEOVER_ONLINE")
check("G5b ...and says to stop it first", "仍然在線" in out.message and "請先停止" in out.message, out.message)
check("G5c ...naming the host plainly (no nested parentheses)", "要取代的 host（host_id 2b8a18bc）在 server 上仍然在線" in out.message, out.message)

started("G6 the server may spell the old id dashed, upper-case or legacy-prefixed",
        scenario([host("2B8A18BC-0000-0000-0000-000000000000", status="offline")], my_id=MINE, takeover="2b8a18bc"))
started("G6b ...legacy-prefixed", scenario([host("ag_" + OLD, status="offline")], my_id=MINE, takeover="2b8a18bc"))

started("G7 a takeover id set when nothing collides is simply not needed",
        scenario([host(OLD, "unrelated")], my_id=MINE, takeover="1"))
refused("G8 a row with no usable host_id can never be taken over",
        scenario([{"name": NAME, "status": "offline", "owner": "u_me"}], my_id=MINE, takeover="2b8a18bc"), "HOST_NAME_COLLISION")

# ---- ordering --------------------------------------------------------------
print("== H. the guard sits at the spawn, nowhere else ==")
out = scenario([host(OLD)], my_id=MINE, managed=False)
check("H1 without allowManagedHost the old error comes first and the server is never asked",
      out.code == "HOST_NOT_MANAGED" and out.log == [], f"{out.code} {out.log}")

shutil.rmtree(WORK, ignore_errors=True)
server.shutdown()
print(f"SUMMARY passed={passed} failed={failed} skipped=0")
sys.exit(1 if failed else 0)
