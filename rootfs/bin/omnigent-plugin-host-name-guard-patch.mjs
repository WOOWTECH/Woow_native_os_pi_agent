#!/usr/bin/env node
/**
 * Make pi-omnigent-plugin refuse to start a host whose name another host of the
 * same Omnigent account already holds.
 *
 * What goes wrong without it. The Omnigent server keys a host by host_id AND, per
 * account, by name (host_store.upsert_on_connect: look up the host_id, else the
 * (workspace, user, name) triple). A daemon that connects under a taken name
 * makes the server NULL out the conversations bound to the old row, DELETE it,
 * INSERT a new one and reattach the conversations to that. Two live daemons with
 * one name undo each other on every tunnel reconnect, so the registration rows
 * -- and the conversations bound to them -- change hands back and forth. The
 * plugin starts `omnigent host` itself (src/omnigent.py, ensure_host) and never
 * looked. This patch adds the look, immediately before that spawn:
 *
 *   GET /v1/me and GET /v1/hosts; if ANY other host of this account (online or
 *   not -- an offline duplicate still owns bound conversations the server would
 *   move) has this host's name, raise HOST_NAME_COLLISION and spawn nothing.
 *
 * Intentional same-name takeover (replacing an old host and keeping its
 * conversations, docs/SESSION-HOME.md) is allowed, but only on purpose:
 * PI_AGENT_TAKEOVER_HOST_ID must hold the first 8 or more hex characters of the
 * id of the host being replaced, and EVERY colliding host's id must start with
 * it. "1" or "true" is not a host id, a typo does not match, and a lone prefix
 * cannot cover two different hosts -- all of those stay refused, and the refusal
 * prints the exact line to run with the id filled in. A takeover is also refused
 * while the old host is still online, because two live daemons are the problem
 * being prevented. The variable is dropped from the plugin's environment once it
 * has been honoured, so the host it starts does not inherit a standing override.
 *
 * Names are compared ignoring case and surrounding whitespace. The server's own
 * lookup is an exact match on (workspace, user, name) among rows that are not
 * deleted -- so this is stricter than it needs to be, on purpose: a false refusal
 * costs one rename, a missed collision costs the incident.
 *
 * Fail CLOSED. If the server cannot be asked (unreachable, 401/403/5xx, a reply
 * that is not the expected JSON), nothing is started and HOST_NAME_UNVERIFIABLE
 * says why. Failing open would let exactly the unanswerable moment -- a flaky
 * link, an expired login -- trigger the one thing that cannot be undone (a
 * deleted registration, conversations repointed). It costs nothing that was
 * possible before: connect and resume each need a successful server call just
 * before ensure_host (/v1/me, /v1/hosts/<id>), and connect polls /v1/hosts
 * afterwards, so a server that cannot answer this could not have finished
 * connecting anyway. There is deliberately no generic bypass variable.
 *
 * What a person sees. The refusal is an ordinary adapter error ({ code, message }),
 * which the plugin keeps in state.json and shows in three ways: `pi-omnigent
 * status` / `repair` print the message; the CLI's `connect` prints only the CODE
 * (by design: "errors print their code only"); and Settings -> Omnigent shows the
 * localized HINT that src/issues.mjs holds for the code -- the generic "something
 * needs attention" for a code it does not know. So the patch also gives the three
 * codes hints there (the plugin's own convention: every code has one). They point
 * at `pi-agent-host-name check`, which prints the last refusal from state.json as
 * readable text, with the exact command and the colliding id filled in.
 *
 * Scope. This guards the hosts the PLUGIN starts, and only when it is about to
 * spawn one; a host already running under the plugin is left alone. It does not
 * stop someone starting `omnigent host` by hand, or an Omnigent app, under a
 * taken name -- the default name this installer seeds (pi-agent-host-name) is what
 * keeps the common case apart.
 *
 * Same discipline as the other plugin patches: version-gated, exact anchors
 * (counted; a moved one leaves that file untouched rather than half patched),
 * idempotent, keeps a .orig of each file, never fails the caller. The guard itself
 * (src/omnigent.py, two anchors) is all-or-nothing and comes first; the hints
 * (src/issues.mjs, one anchor) are only added when the guard is in, and failing
 * to add them costs nothing but a more generic message in Settings. It does not share
 * an anchor with omnigent-plugin-session-home-patch.mjs, so the two apply in
 * either order. Skips are logged with a WARN: prefix, because a skipped safety
 * patch should not scroll by as routine.
 *
 *   omnigent-plugin-host-name-guard-patch.mjs <plugin root>
 */
import fs from 'node:fs';
import path from 'node:path';

const EXPECTED_VERSIONS = ['0.3.31', '0.3.32'];
const MARKER = 'host-name-guard (Woow native installer)';

// 1. The method goes right above ensure_host.
const ANCHOR_DEF = '    def ensure_host(self, server: str) -> str:\n';
// 2. The call goes right above the line that opens host.log, i.e. after every
//    early return (kit, already-running) and before the Popen it protects.
const ANCHOR_CALL = '            descriptor = os.open(self.state_dir / "host.log", os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)\n';

// 3. src/issues.mjs: the plugin keeps one localized hint per code; ours go first in the table.
const ANCHOR_ISSUES = 'const ISSUES = Object.freeze({\n';
const HINTS = [
  `  // ${MARKER}: the codes src/omnigent.py raises instead of starting a host under a taken name.`,
  '  HOST_NAME_COLLISION: hint(null,',
  '    "Another host of this Omnigent account already has this host\'s name, so none was started (two hosts with one name take each other\'s registration and conversations). In a terminal run pi-agent-host-name check: it names the other host and the exact command to rename this one or to replace the other on purpose.",',
  '    "Omnigent 伺服器上已有另一台同名的 host，所以沒有啟動（兩台同名會互相搶走註冊與對話）。請在終端機執行 pi-agent-host-name check：會列出另一台 host，以及改名或刻意取代對方要執行的完整指令。",',
  '    "Omnigent 服务器上已有另一台同名的 host，所以没有启动（两台同名会互相抢走注册与对话）。请在终端执行 pi-agent-host-name check：会列出另一台 host，以及改名或有意取代对方要执行的完整命令。"),',
  '  HOST_NAME_UNVERIFIABLE: hint(null,',
  '    "Could not ask the Omnigent server whether this host\'s name is already taken, so no host was started (a duplicate name would delete the other host\'s registration and move its conversations). Check that the server is reachable and the sign-in is valid, then run pi-omnigent repair.",',
  '    "無法向 Omnigent 伺服器確認這台 host 的名稱有沒有和別台重複，所以沒有啟動（名稱重複會刪掉對方的註冊並搬走對話）。請確認伺服器連得上、登入仍有效，再執行 pi-omnigent repair。",',
  '    "无法向 Omnigent 服务器确认这台 host 的名称有没有和别台重复，所以没有启动（名称重复会删掉对方的注册并搬走对话）。请确认服务器可以连接、登录仍有效，再执行 pi-omnigent repair。"),',
  '  HOST_NAME_TAKEOVER_ONLINE: hint(null,',
  '    "The host being replaced is still online on the server. Stop it, wait until the server shows it offline, then run the same command again (pi-agent-host-name check shows it).",',
  '    "要取代的 host 在伺服器上仍然在線。請先停止它，等伺服器顯示離線後再執行同一行指令（pi-agent-host-name check 會列出）。",',
  '    "要取代的 host 在服务器上仍然在线。请先停止它，等服务器显示离线后再执行同一条命令（pi-agent-host-name check 会列出）。"),',
  '',
].join('\n');

const CALL = [
  `            # ${MARKER}: never start a host whose name is taken.`,
  '            self.guard_host_name(server)',
  '',
].join('\n');

// String.raw: the Python below has backslashes and braces, no backticks, no dollar signs.
const METHOD = String.raw`    # ${MARKER}: do not start a host under a name that
    # another host of this account already holds. The server keys hosts by (account,
    # name) as well as by host_id: a daemon that connects under a taken name makes it
    # delete that host's registration, create a new one and repoint the conversations
    # bound to it, and two such daemons undo each other on every reconnect. Fail
    # CLOSED: if the server cannot be asked, no host is started (connect and resume
    # already need the server one call earlier, so this adds no new way to be stuck).
    # PI_AGENT_TAKEOVER_HOST_ID = id prefix of the host being replaced on purpose.
    def guard_host_name(self, server: str) -> None:
        import shlex
        import socket

        def key(value) -> str:
            # the server's own id normalisation: bare lowercase hex, no dashes, no legacy prefix
            text = value.strip().lower().replace("-", "") if isinstance(value, str) else ""
            return text.rpartition("_")[2] if "_" in text else text

        local = self.local_host()
        name = local.get("name") or socket.gethostname()
        mine = key(local.get("id"))
        try:
            client = self.client_factory(server, True)
            account = client.request("GET", "/v1/me").get("user_id")
            hosts = client.request("GET", "/v1/hosts").get("hosts")
            if not isinstance(hosts, list):
                raise PluginError("invalid_response", "Omnigent hosts 清單格式不正確。")
        except Exception as error:
            reason = error.code if isinstance(error, PluginError) else type(error).__name__
            raise PluginError("host_name_unverifiable", (
                f"無法向 Omnigent server 確認 host 名稱「{name}」有沒有和別台重複（{reason}），所以先不啟動 host。"
                "名稱重複時 server 會刪掉舊的註冊並搬走對話，事後無法復原；請確認 server 連得上、登入仍有效，再試一次。")) from None
        wanted = name.strip().casefold()
        others = [row for row in hosts
                  if isinstance(row, dict) and isinstance(row.get("name"), str) and row["name"].strip().casefold() == wanted
                  and not (mine and key(row.get("host_id")) == mine)
                  and not (isinstance(account, str) and isinstance(row.get("owner"), str) and row["owner"] != account)]
        if not others:
            return
        ids = [key(row.get("host_id")) for row in others]
        state = {"online": "目前在線", "offline": "目前離線"}
        described = "、".join(f"host_id {i[:8] or '?'}（{state.get(row.get('status'), '狀態不明')}）" for i, row in zip(ids, others))
        raw = os.environ.get("PI_AGENT_TAKEOVER_HOST_ID", "").strip()
        takeover = key(raw)
        if re.fullmatch(r"[0-9a-f]{8,32}", takeover) and all(i.startswith(takeover) for i in ids):
            online = [i for i, row in zip(ids, others) if row.get("status") == "online"]
            if online:
                shown = "、".join(f"host_id {i[:8] or '?'}" for i in online)
                raise PluginError("host_name_takeover_online", (
                    f"要取代的 host（{shown}）在 server 上仍然在線。請先停止它，等 server 顯示離線後再執行同一行指令；"
                    "兩台同名 host 同時在線，會一直互相搶走對方的註冊與對話。"))
            os.environ.pop("PI_AGENT_TAKEOVER_HOST_ID", None)
            return
        home = os.environ.get("PI_AGENT_HOME")
        def tool(command: str) -> str:
            return shlex.quote(f"{home}/bin/{command}") if home else command
        username = self.request.get("username")
        if isinstance(username, str) and username.strip():
            retry = f"{tool('pi-omnigent')} connect --server {shlex.quote(server)} --username {shlex.quote(username.strip())} --password-stdin"
        else:
            retry = f"{tool('pi-omnigent')} repair --server {shlex.quote(server)}"
        suffix = " (pi-agent)"
        suggestion = name[:-1] + " 2)" if name.endswith(suffix) else name + suffix
        lines = [
            f"這台 host 的名稱「{name}」已被 server 上另一台 host 使用：{described}。",
            "同一個帳號下兩台同名 host 會互相搶註冊：server 每次連線都會刪掉舊的註冊、改綁對話，兩台輪流重連就一直互相搬走對話，所以先不啟動。",
            "兩台並存（預設做法）：換一個不重複的名稱，再重試：",
            f"  {tool('pi-agent-host-name')} set {shlex.quote(suggestion)}",
            f"  {retry}",
        ]
        if len(others) == 1 and re.fullmatch(r"[0-9a-f]{8}", ids[0][:8]):
            lines += ["要取代那一台（刻意沿用同名、對話跟著搬過來）：先停止舊的 host，再執行：",
                      f"  PI_AGENT_TAKEOVER_HOST_ID={ids[0][:8]} {retry}"]
        else:
            lines.append("同名的 host 不只一台（或查不到 host_id）；取代只能指定一台，請先在 Omnigent 刪掉多餘的註冊，只剩要取代的那一台。")
        if raw:
            lines.append(f"目前的 PI_AGENT_TAKEOVER_HOST_ID（{raw[:40]}）沒有涵蓋上面全部的 host：它必須是要取代的那台 host_id 的前 8 碼以上（十六進位），不接受 1 或 true。")
        raise PluginError("host_name_collision", "\n".join(lines))

`;

const log = (m) => console.log(`[omnigent-plugin-host-name-guard-patch] ${m}`);

// Write target atomically, keeping the pristine file as .orig the first time.
function writeAtomic(target, text) {
  const backup = `${target}.orig`;
  if (!fs.existsSync(backup)) { fs.copyFileSync(target, backup); log(`kept the pristine file as ${path.basename(backup)}`); }
  const tmp = `${target}.patch-tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, target);
}

// The localized hints. Returns quietly in every case: the guard does not depend on them.
function addHints(root, version) {
  const target = path.join(root, 'src', 'issues.mjs');
  let source;
  try { source = fs.readFileSync(target, 'utf8'); }
  catch (error) { log(`WARN: cannot read ${target} (${error.code ?? error.message}) — the guard is in, but Settings will show its generic hint for the new codes`); return; }
  if (source.includes(MARKER)) { log('issues.mjs: hints already patched — no change'); return; }
  const hits = source.split(ANCHOR_ISSUES).length - 1;
  if (hits !== 1) { log(`WARN: expected exactly 1 ISSUES table in issues.mjs, found ${hits} — the guard is in, but Settings will show its generic hint for the new codes`); return; }
  try { writeAtomic(target, source.replace(ANCHOR_ISSUES, () => ANCHOR_ISSUES + HINTS)); }
  catch (error) { log(`WARN: cannot write beside ${target} (${error.code ?? error.message}) — the guard is in, but Settings will show its generic hint for the new codes`); return; }
  log(`patched ${target} (plugin ${version})`);
}

function main() {
  const root = process.argv[2];
  if (!root) { console.error('usage: omnigent-plugin-host-name-guard-patch.mjs <plugin root>'); return 2; }

  let version;
  try { version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version; }
  catch (error) { log(`cannot read the plugin's package.json (${error.code ?? error.message}) — skipping`); return 0; }

  const target = path.join(root, 'src', 'omnigent.py');
  let source;
  try { source = fs.readFileSync(target, 'utf8'); }
  catch (error) { log(`cannot read ${target} (${error.code ?? error.message}) — skipping`); return 0; }

  if (source.includes(MARKER)) { log('omnigent.py: already patched — no change'); addHints(root, version); return 0; }
  if (!EXPECTED_VERSIONS.includes(version)) {
    log(`WARN: plugin ${version} is installed but this patch was validated against ${EXPECTED_VERSIONS.join(', ')} — SKIPPING. Two same-named hosts can take each other's registration until the patch is re-checked.`);
    return 0;
  }

  // Counted, exact anchors: a moved or re-indented spawn must be re-inspected
  // rather than half-patched into a Python file that no longer parses.
  const defHits = source.split(ANCHOR_DEF).length - 1;
  const callHits = source.split(ANCHOR_CALL).length - 1;
  if (defHits !== 1 || callHits !== 1) {
    log(`WARN: expected exactly 1 ensure_host definition and 1 host.log open, found ${defHits} and ${callHits} — leaving the plugin alone. Two same-named hosts can take each other's registration until the patch is re-checked.`);
    return 0;
  }

  try {
    writeAtomic(target, source
      .replace(ANCHOR_CALL, () => CALL + ANCHOR_CALL)
      .replace(ANCHOR_DEF, () => METHOD + ANCHOR_DEF));
  } catch (error) {
    log(`WARN: cannot write beside ${target} (${error.code ?? error.message}) — read-only install, patch it at build time`);
    return 0;
  }
  log(`patched ${target} (plugin ${version})`);
  addHints(root, version);
  return 0;
}

process.exit(main());
