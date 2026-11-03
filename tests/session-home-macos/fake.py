#!/usr/bin/env python3
"""Fakes for tests/session-home-macos.sh. Nothing here talks to anything but 127.0.0.1.

One file, several roles, picked by argv[1]; the test copies it into a sandbox under the
names the real programs have, because the code under test finds hosts by command line:

  omnigent host --server URL ...      a fake Omnigent host (what the plugin starts)
  omnigent host stop                  stops the host named by the daemon registry
  python -m omnigent.host.service_entry --server URL
                                      the same host as the old launchd daemon runs it
                                      (a stub package on PYTHONPATH calls run_host)
  pi-web                              a fake pi-web + the part of the Omnigent plugin
                                      that matters here: the resume gate and ensure_host
  api                                 a stub of the Omnigent server API (+ test controls)

The host and the fake pi-web are plain python (not an Apple system binary) so that
`ps eww` shows their environment, as it does for the real python hosts.
"""
import hashlib
import http.server
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlparse

NOW = lambda: int(time.time())


def jreq(method, url, body=None, token=None, timeout=5):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "Mozilla/5.0 (fake)")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except Exception:
            return e.code, None
    except Exception:
        return 0, None


def read_cfg(path):
    import yaml
    with open(path) as f:
        return yaml.safe_load(f) or {}


# ------------------------------------------------------------------------ host ---
def registry_dir():
    data = os.environ.get("OMNIGENT_DATA_DIR") or os.path.join(os.path.expanduser("~"), ".omnigent")
    return os.path.join(data, "daemons")


def run_host(argv):
    server = argv[argv.index("--server") + 1] if "--server" in argv else ""
    state = os.environ.get("FAKE_STATE", "")
    if state and os.path.exists(os.path.join(state, "fail-start")):
        sys.stderr.write("fake host: fail-start marker present\n")
        sys.exit(1)
    if state and os.environ.get("PI_AGENT_SESSION_HOME") and os.path.exists(os.path.join(state, "fail-session-home")):
        sys.stderr.write("fake host: fails while session home is on\n")
        sys.exit(1)
    cfg_home = os.environ.get("OMNIGENT_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".omnigent")
    cfg = read_cfg(os.path.join(cfg_home, "config.yaml"))
    hid, name = cfg["host"]["host_id"], cfg["host"]["name"]
    reg = registry_dir()
    os.makedirs(reg, exist_ok=True)
    rec_path = os.path.join(reg, hashlib.sha1(server.encode()).hexdigest()[:16] + ".json")
    if os.path.exists(rec_path):
        try:
            pid = json.load(open(rec_path)).get("pid")
            if isinstance(pid, int) and pid != os.getpid():
                os.kill(pid, 0)
                sys.stderr.write("A host daemon is already running (pid %d)\n" % pid)
                sys.exit(1)
        except (OSError, ValueError):
            pass
    rec = {"pid": os.getpid(), "host_id": hid, "target": server, "server_url": server,
           "resolved_server_url": None, "mode": "server", "started_at": NOW(), "log_path": None,
           "config_sig": "fake"}
    with open(rec_path, "w") as f:
        json.dump(rec, f)
    if state:
        with open(os.path.join(state, "host-%d.json" % os.getpid()), "w") as f:
            json.dump({"pid": os.getpid(), "home": os.environ.get("HOME"), "cfg_home": cfg_home,
                       "path": os.environ.get("PATH"), "host_id": hid, "name": name,
                       "session_home": os.environ.get("PI_AGENT_SESSION_HOME")}, f)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    jreq("POST", server + "/_test/connect", {"host_id": hid, "name": name, "pid": os.getpid()})
    while not stop.is_set():
        time.sleep(0.2)
    jreq("POST", server + "/_test/offline", {"host_id": hid})
    try:
        if json.load(open(rec_path)).get("pid") == os.getpid():
            os.unlink(rec_path)
    except (OSError, ValueError):
        pass
    sys.exit(0)


def host_stop():
    reg = registry_dir()
    for fn in sorted(os.listdir(reg)) if os.path.isdir(reg) else []:
        p = os.path.join(reg, fn)
        try:
            pid = json.load(open(p)).get("pid")
        except (OSError, ValueError):
            os.unlink(p)
            continue
        if isinstance(pid, int):
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
            for _ in range(100):
                try:
                    os.kill(pid, 0)
                except OSError:
                    break
                time.sleep(0.1)
        if os.path.exists(p):
            os.unlink(p)
    print("stopped")


# ---------------------------------------------------------------------- pi-web ---
def run_piweb():
    state = os.environ.get("FAKE_STATE", "")
    if state and ((os.environ.get("PI_AGENT_SESSION_HOME") and os.path.exists(os.path.join(state, "fail-piweb")))
                  or os.path.exists(os.path.join(state, "fail-piweb-always"))):
        sys.stderr.write("fake pi-web: told to fail\n")     # -piweb: only with session home on; -always: any start
        sys.exit(1)
    home = os.environ["HOME"]                    # scoped: pi-web-start.sh sourced pi-agent-env.sh
    pa = os.environ["PI_AGENT_HOME"]
    port = int(os.environ.get("PI_WEB_PORT", os.environ.get("PORT", "30141")))
    omni = os.path.join(home, ".omnigent")
    cfg = read_cfg(os.path.join(omni, "config.yaml"))
    hid, server = cfg["host"]["host_id"], cfg["server"]
    plug = os.path.join(pa, "data", "omnigent-plugin")
    tok = json.load(open(os.path.join(omni, "auth_tokens.json")))[server]["token"]
    err = {"why": None}

    # --- what resumeAuthorizedHost + python resume() check before they start a host
    try:
        conn = json.load(open(os.path.join(plug, "connection.json")))
        if conn["host"]["id"] != hid:
            err["why"] = "connection_identity_mismatch (receipt %s, config %s)" % (conn["host"]["id"][:8], hid[:8])
    except (OSError, ValueError, KeyError):
        err["why"] = "no usable connection receipt"
    if not err["why"]:
        code, me = jreq("GET", server + "/v1/me", token=tok)
        code2, own = jreq("GET", server + "/v1/hosts/" + hid, token=tok)
        if code != 200 or code2 != 200 or own.get("owner") != me.get("user_id"):
            err["why"] = "own_host precheck failed (HTTP %s/%s)" % (code, code2)
    # --- ensure_host. On macOS the plugin cannot see a running host (it looks in /proc), so it
    # always starts one; when one is already registered the new process exits ("already
    # running") and the old one stays -- exactly what the real plugin does after a repair.
    if not err["why"]:
        env = dict(os.environ)
        env["OMNIGENT_CONFIG_HOME"] = omni
        env["OMNIGENT_DATA_DIR"] = omni
        if os.environ.get("PI_AGENT_SESSION_HOME"):          # the plugin patch
            env["HOME"] = os.environ["PI_AGENT_SESSION_HOME"]
        binary = os.path.join(pa, "bin", "omnigent")
        with open(os.path.join(pa, "logs", "fake-host.log"), "ab") as log:
            p = subprocess.Popen([binary, "host", "--server", server, "--non-interactive", "--no-open"],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env,
                                 start_new_session=True)
        os.makedirs(plug, exist_ok=True)
        with open(os.path.join(plug, "host-process.json"), "w") as f:
            json.dump({"pid": p.pid, "server": server}, f)

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path.startswith("/api/home"):
                return self._send(200, {"ok": True, "resume_error": err["why"]})
            if self.path.startswith("/api/omnigent"):
                c = hid_now()
                code, row = jreq("GET", server + "/v1/hosts/" + c, token=tok)
                ok = (not err["why"]) and code == 200 and row.get("status") == "online"
                return self._send(200, {"host": {"id": c, "connected": bool(ok)}})
            self._send(404, {})

    def hid_now():
        return hid

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown).start())
    srv.serve_forever()
    sys.exit(0)


# ----------------------------------------------------------------- pi-omnigent ---
def atomic_json(path, obj, mode=0o600):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def run_pi_omnigent(argv):
    """The `pi-omnigent` wrapper plus the plugin's `repair` (initialize -> connect).

    It records how it was called -- the test asserts `env -i` and the order -- and then does
    what repair does: start the host from the CONFIG's identity (detached, with the real HOME
    when PI_AGENT_SESSION_HOME is set), wait until the server shows it online, and rewrite
    the connection receipt and the plugin state. It has no resume-identity check, like connect().
    """
    pa = os.environ["PI_AGENT_HOME"]
    fake = json.load(open(os.path.join(pa, ".fake.json")))      # the environment is empty by design
    state = fake["state"]
    launchctl = subprocess.run(["/bin/launchctl", "print", "gui/%d/%s" % (os.getuid(), fake["svc_label"])],
                               capture_output=True)
    dump = {"argv": argv, "env": dict(os.environ), "svc_loaded": launchctl.returncode == 0,
            "pid": os.getpid(), "at": time.time()}
    with open(os.path.join(state, "pi-omnigent-%d.json" % time.time_ns()), "w") as f:
        json.dump(dump, f)
    # what the wrapper's pi-agent-env.sh does to the environment
    home = os.path.join(pa, "home")
    omni = os.path.join(home, ".omnigent")
    path = os.environ.get("PATH", "")
    path = "%s:%s:%s" % (os.path.join(pa, "bin"), os.path.join(pa, "node", "bin"), path)
    for d in ("/opt/homebrew/bin", "/usr/local/bin"):
        if os.path.isdir(d) and (":" + d + ":") not in (":" + path + ":"):
            path += ":" + d
    if os.path.exists(os.path.join(state, "fail-repair")):
        print(json.dumps({"ok": False, "phase": "error", "error": {"code": "ADAPTER_FAILED"}}))
        sys.exit(1)
    plug = os.path.join(pa, "data", "omnigent-plugin")
    st = json.load(open(os.path.join(plug, "state.json")))
    server = argv[argv.index("--server") + 1] if "--server" in argv else st.get("server")
    if st.get("loginConfirmed") is not True or server != st.get("server"):
        print(json.dumps({"ok": False, "phase": "needs-login", "error": {"code": "FRESH_LOGIN_REQUIRED"}}))
        sys.exit(1)
    cfg = read_cfg(os.path.join(omni, "config.yaml"))
    hid, name = cfg["host"]["host_id"], cfg["host"]["name"]
    tok = json.load(open(os.path.join(omni, "auth_tokens.json")))[server]["token"]
    # ensure_host
    env = dict(os.environ)
    env.update({"PATH": path, "HOME": home, "OMNIGENT_CONFIG_HOME": omni, "OMNIGENT_DATA_DIR": omni,
                "FAKE_STATE": state})
    if os.environ.get("PI_AGENT_SESSION_HOME"):                  # the plugin patch
        env["HOME"] = os.environ["PI_AGENT_SESSION_HOME"]
    with open(os.path.join(pa, "logs", "fake-host.log"), "ab") as log:
        p = subprocess.Popen([os.path.join(pa, "bin", "omnigent"), "host", "--server", server,
                              "--non-interactive", "--no-open"],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env, start_new_session=True)
    atomic_json(os.path.join(plug, "host-process.json"), {"pid": p.pid, "server": server})
    for _ in range(80):                                          # the catalog poll, up to 40 s
        code, row = jreq("GET", server + "/v1/hosts/" + hid, token=tok)
        if code == 200 and row.get("status") == "online":
            break
        if p.poll() is not None:
            print(json.dumps({"ok": False, "phase": "error", "error": {"code": "HOST_EXITED"}}))
            sys.exit(1)
        time.sleep(0.5)
    else:
        print(json.dumps({"ok": False, "phase": "error", "error": {"code": "HOST_CONNECT_TIMEOUT"}}))
        sys.exit(1)
    if not os.path.exists(os.path.join(state, "repair-noop")):   # a repair that forgot to save the receipt
        conn = json.load(open(os.path.join(plug, "connection.json")))
        conn["server"] = server
        conn["host"].update({"id": hid, "name": name, "connected": True})
        atomic_json(os.path.join(plug, "connection.json"), conn)
        st.update({"phase": "needs-verification", "loginConfirmed": True, "issue": None,
                   "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        atomic_json(os.path.join(plug, "state.json"), st)
    print(json.dumps({"ok": True, "phase": "needs-verification", "server": server,
                      "connection": {"host": {"id": hid, "name": name, "connected": True}}}, indent=2))
    sys.exit(0)


# ------------------------------------------------------------------------- api ---
class State:
    def __init__(self, seed):
        self.lock = threading.Lock()
        self.hosts = {h["host_id"]: dict(h) for h in seed["hosts"]}
        self.sessions = [dict(s) for s in seed["sessions"]]
        self.max_page = int(seed.get("max_page", 5))
        self.token = seed.get("token", "test-token")
        self.user = seed.get("user", "woow")
        self.never_online = set()
        self.chaos = []                      # one-shot actions on the next connect of a host
        self.rotations = 0
        self.requests = []

    def connect(self, hid, name):
        chaos = [c for c in self.chaos if c["host_id"] == hid]
        for c in chaos:
            self.chaos.remove(c)
            if c.get("rename"):
                name = c["rename"]
        self._connect(hid, name)
        for c in chaos:
            if c.get("unbind"):
                for s in self.sessions:
                    if s["host_id"] == hid:
                        s["host_id"] = None

    def _connect(self, hid, name):
        h = self.hosts.get(hid)
        if h is not None:
            h["status"], h["name"], h["last_seen"] = "online", name, NOW()
            return
        clash = [x for x in self.hosts.values() if x["name"] == name]
        if clash:
            old = clash[0]
            bound = [s for s in self.sessions if s["host_id"] == old["host_id"]]
            for s in bound:
                s["host_id"] = None
            created = old["created_at"]
            del self.hosts[old["host_id"]]
            self.hosts[hid] = {"host_id": hid, "name": name, "owner": self.user, "status": "online",
                               "created_at": created, "last_seen": NOW()}
            for s in bound:
                s["host_id"] = hid
            self.rotations += 1
        else:
            self.hosts[hid] = {"host_id": hid, "name": name, "owner": self.user, "status": "online",
                               "created_at": NOW(), "last_seen": NOW()}

    def view(self, h):
        h = dict(h)
        if h["host_id"] in self.never_online:
            h["status"] = "offline"
        return h


def run_api(seed_path, port_path):
    st = State(json.load(open(seed_path)))

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, obj, raw=None):
            b = raw if raw is not None else json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}") if n else {}

        def do_POST(self):
            path = urlparse(self.path).path
            with st.lock:
                b = self._body()
                if path == "/_test/connect":
                    st.connect(b["host_id"], b["name"])
                elif path == "/_test/offline":
                    if b["host_id"] in st.hosts:
                        st.hosts[b["host_id"]]["status"] = "offline"
                elif path == "/_test/mode":
                    st.never_online = set(b.get("never_online", []))
                elif path == "/_test/chaos":
                    st.chaos.append(b["on_connect"])
                elif path == "/_test/session":
                    for s in st.sessions:
                        if s["id"] == b["id"]:
                            s.update({k: v for k, v in b.items() if k != "id"})
                else:
                    return self._send(404, {"detail": "no such test control"})
            self._send(200, {"ok": True})

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            with st.lock:
                st.requests.append(u.path)
                if u.path == "/_test/state":
                    return self._send(200, {"hosts": {k: st.view(v) for k, v in st.hosts.items()},
                                            "sessions": st.sessions, "rotations": st.rotations,
                                            "requests": len(st.requests)})
                ua = self.headers.get("User-Agent", "")
                if ua.startswith("Python-urllib") or not ua:
                    return self._send(403, None, raw=b"error code: 1010")
                if self.headers.get("Authorization") != "Bearer " + st.token:
                    return self._send(401, {"detail": "unauthorized"})
                if u.path == "/v1/me":
                    return self._send(200, {"user_id": st.user, "is_admin": True})
                if u.path == "/v1/hosts":
                    return self._send(200, {"hosts": [st.view(h) for h in st.hosts.values()]})
                if u.path.startswith("/v1/hosts/"):
                    h = st.hosts.get(u.path.rsplit("/", 1)[1])
                    return self._send(200, st.view(h)) if h else self._send(404, {"detail": "not found"})
                if u.path == "/v1/sessions":
                    lim = min(int((q.get("limit") or ["20"])[0]), st.max_page)
                    rows = st.sessions
                    after = (q.get("after") or [None])[0]
                    if after:
                        ids = [s["id"] for s in rows]
                        rows = rows[ids.index(after) + 1:] if after in ids else []
                    page = rows[:lim]
                    return self._send(200, {"object": "list", "data": page,
                                            "first_id": page[0]["id"] if page else None,
                                            "last_id": page[-1]["id"] if page else None,
                                            "has_more": len(rows) > lim})
                self._send(404, {"detail": "not found"})

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(port_path + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(port_path + ".tmp", port_path)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown).start())
    srv.serve_forever()


def main():
    role = sys.argv[1] if len(sys.argv) > 1 else ""
    if role == "host" and len(sys.argv) > 2 and sys.argv[2] == "stop":
        return host_stop()
    if role == "host":
        return run_host(sys.argv[2:])
    if role == "-m":                                   # python -m omnigent.host.service_entry --server URL
        return run_host(sys.argv[3:])
    if role == "pi-web":
        return run_piweb()
    if role == "pi-omnigent":
        return run_pi_omnigent(sys.argv[2:])
    if role == "api":
        return run_api(sys.argv[2], sys.argv[3])
    sys.stderr.write("fake.py: unknown role %r\n" % role)
    sys.exit(2)


if __name__ == "__main__":
    # Invoked as `pi-web` (the launcher shim pi-web-start.sh execs) or as `pi-omnigent` (the plugin
    # CLI wrapper): the file name picks the role, the arguments are the program's own.
    base = os.path.basename(sys.argv[0])
    if base == "pi-web" and len(sys.argv) == 1:
        sys.argv.append("pi-web")
    elif base == "pi-omnigent":
        sys.argv.insert(1, "pi-omnigent")
    main()
