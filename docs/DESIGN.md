# Woow Native Pi Agent — Design

Status: **draft / in build** · Started 2026-11-01 · Owner: WOOWTECH

A 4th deployment target for the WOOWTECH "Pi Agent" stack: install it **natively on
a developer/user machine** (macOS / Linux / Windows), alongside the existing
PaaS (k8s), HA add-on, and k3s root image.

## 1. Locked decisions (from brainstorming with the owner, 2026-11-01)

| # | Decision | Choice |
|---|---|---|
| Q1 | Scope | **A — full Pi Agent natively**: pi-web settings page + Claude Code + Codex + Omnigent + Paseo + skill/MCP sharing. Not just "install the CLIs". |
| Q2 | Audience | **C — both**: internal engineers first, architected so it can grow to a customer product. |
| Q3 | Windows | **C — WSL2 for v1**, true-native Windows deferred to a later phase. |
| Q4 | Distribution | **A + C — both tracks**: (A) one-line bootstrap for engineers; (C) downloadable signed native installers (.pkg/.dmg, .deb, .msi) for general users. Both call the **same core installer**. |
| Arch | Reuse strategy | **① thin assembler**: install pinned upstream pieces, copy `pi-agent-share-state.mjs` verbatim, replace only the container plumbing (s6/bashio/ingress/nginx) with per-OS service management. No forking of pi-web. (Patching WOOWTECH's *own* plugins for macOS/Windows is allowed — see §6.) |

## 2. What the stack actually is (from reverse-engineering the reference repos)

Primary blueprint = **`Woow_k3s_pi_agent_package`** Dockerfile — it is already the
"de-HA'd" assembly (plain `debian:bookworm-slim`, no s6/bashio/ingress, settings
tabs compiled as **native pi-web routes** via `combined.adapter.patch`).

Runtime components (all Node/Python, no separate agent daemon):
- **pi-web** (`@agegr/pi-web`, Next.js, Node 22) — main UI + browser terminal (node-pty).
  In-process `require`s `@earendil-works/pi-coding-agent` (= `pi`). Listens on a port.
- **Claude Code** `@anthropic-ai/claude-code` **2.1.296**, **Codex** `@openai/codex` **0.162.1** (npm).
- **Omnigent host** — Omnigent CLI **0.16.0** in a **uv + Python 3.12** venv; connects to a remote Omnigent server.
- **Paseo** — `pi-paseo` plugin 0.1.16 + managed `@getpaseo/cli` **0.11.2** runtime; daemon on `127.0.0.1:6769`; pairs via `https://app.paseo.sh` relay.
- **Settings tabs** — `general/models/skills/agents/plugins/mcp` are pi-web native; **Omnigent/Paseo** added by applying `combined.adapter.patch` to a pinned pi-web source commit (`PI_WEB_REF=6fcd7d44…`, `PI_WEB_VERSION=0.10.0`) then `npm run build`.

Pins (single source `cli-runtime/versions.json` + Dockerfile ARGs):
- pi-web `0.10.0` @ ref `6fcd7d44981ab51a21d6cd6eb06d361d0e3d3068`
- omnigent-plugin `0.3.32` (sha256 `00c555a2…`), UI patch sha256 `b204fcae…`
- paseo-plugin `0.1.16` (sha256 `c5705564…`), getpaseo/cli `0.11.2`
- shared-runtime `@woowtech/pi-agent-shared-runtime` @ `e648882638fa0674f83ec274d58d5fcd7e703a7b`
- omnigent `0.16.0`, claude `2.1.296`, codex `0.162.1`, node `22.x`

### Skill / MCP sharing — the mechanism we reuse
`rootfs/usr/local/bin/pi-agent-share-state.mjs` (HA add-on, **139 lines, pure Node, zero
container assumptions**). Reads `PI_AGENT_DATA_DIR`/`PI_CODING_AGENT_DIR` + `HOME`:
- **Skills**: symlinks `$data/skills` → `~/.pi/agent/skills`, `~/.claude/skills`, `~/.agents/skills` (one shared tree).
- **MCP**: reads `$data/mcp.json`, merges into Claude `~/.claude.json` (`mcpServers`) and writes Codex `~/.codex/config.toml` `[mcp_servers."name"]` inside `# BEGIN/END pi-agent shared MCP (managed)` markers; tracks managed names in `.shared-mcp-managed.json` to prune removed ones.
- Runs **before every `claude`/`codex` launch** via thin wrappers.
→ Copied **verbatim** into `rootfs/bin/`. (k3s root uses a heavier `@woowtech/pi-agent-shared-runtime` bundle driven by pi-web; the add-on's share-state is simpler and sufficient for native — decide which during build.)

## 3. Native runtime layout

Everything under a user-writable dir (replacing the container's `/data/pi-agent`):
```
$PI_AGENT_HOME            = ~/.local/share/pi-agent   (macOS: ~/Library/Application Support/pi-agent or same)
  data/                   PI_CODING_AGENT_DIR  (skills/, mcp.json, sessions/, models.json[plaintext key!], auth.json, settings.json)
  home/                   HOME for pi/claude/codex subprocesses
  node/                   scoped pinned Node 22 (do NOT touch system node)
  clis/{claude,codex}/    npm prefixes
  piweb/                  built + patched pi-web tree
  omnigent/venv/          uv Python 3.12 venv w/ omnigent 0.16.0
  paseo-runtime/          getpaseo/cli 0.11.2
  bin/                    wrappers: pi, claude, codex, pi-omnigent, pi-paseo, pi-agent-share-state.mjs
  logs/
```
Run as the **normal user** (never root). pi-web bound to `127.0.0.1:<port>`.

### Trust guard (no nginx)
pi-web's `isApiRequestAllowed()` rejects non-loopback Host / mismatched Origin. The
k8s build used an nginx Host/Origin rewrite only because the tunnel injected a public
hostname. **Native localhost access satisfies the guard on its own** (Host=`localhost`,
same-origin). nginx is dropped. For optional LAN/mobile access: bind `0.0.0.0` +
`extra_allowed_hosts` + set `PI_WEB_PASSWORD` (built-in login), opt-in with a warning.

## 4. Service management (replaces s6)
Unified control CLI `pi-agent {start|stop|restart|status|open|logs|update}` over:
- **macOS**: launchd user agent `~/Library/LaunchAgents/io.woowtech.pi-agent.plist` (`RunAtLoad`+`KeepAlive`).
- **Linux / WSL2**: systemd `--user` unit, `Restart=on-failure`, `enable-linger`; fallback nohup launcher + login hook if no systemd.

## 5. Install flow (shared core, per-OS prereqs)
1. preflight: detect OS/arch; install prereqs (scoped Node 22, Python 3.12, uv, git, build tools, util-linux/flock on Linux, jq) via Homebrew / apt-dnf / (WSL)apt.
2. assemble pinned pieces (see §2): fetch+verify plugins (sha256); build pi-web from source + apply `combined.adapter.patch` (**v1**; **later**: ship a prebuilt patched tree as a release asset so users need no toolchain — required for the .pkg/.deb/.msi track); Paseo runtime (+musl cleanup); shared-runtime; Omnigent uv venv; claude+codex npm.
3. lay down `$PI_AGENT_HOME`, wrappers, `pi-agent-share-state.mjs`; apply CJK path patch (`fix-unicode-space-paths.mjs`).
4. register + start the service; open browser to `localhost:<port>`.

Skip for v1 (YAGNI): ttyd (pi-web has its own terminal), the ~720 MB video pipeline (ffmpeg/playwright/chromium), cloudflared/helm/NetworkPolicy.

## 6. ⚠️ Portability finding — plugins are Linux-coupled
WOOWTECH's **own** plugins hard-code Linux:
- `pi-omnigent-plugin/src/common.mjs`: requires `/usr/bin/flock`|`/bin/flock` (throws `LOCK_UNAVAILABLE`), reads `/proc/<pid>/stat`, `/proc/sys/kernel/random/boot_id`.
- `src/ui-retention.mjs`, `pi-paseo-plugin/src/{state,daemon-identity,runtime,supervisor,pid-transition}.mjs`: many `if (process.platform !== 'linux') throw/return` (e.g. `DAEMON_IDENTITY_UNVERIFIABLE`, `LOCK_GUARD_UNSUPPORTED`).
- `omnigent.py` uses `fcntl.flock` (POSIX, OK on macOS) but also `/proc/<pid>/cmdline|stat` (Linux-only).

**Consequence**: **Linux + WSL2 work as-is**. **Native macOS and native Windows break**
(Omnigent "login & connect" and Paseo daemon identity fail). Full "一致對齊" on macOS
needs adding darwin support to these two WOOWTECH plugins (cross-platform file lock;
replace `/proc` identity with `ps`/`sysctl` + a boot-session id). Bounded, upstreamable.

> **Measured 2026-11-01 — this section's prediction was too pessimistic.** The
> plugins largely work on darwin: the locks and `/proc` identity code are not on
> the install/status/activate paths, and the only real blocker was one
> platform allow-list. macOS now passes the same 24/24 smoke suite as Linux.
> See [`MACOS.md`](MACOS.md) for what was actually measured; keep the analysis
> below only as the map of what *would* matter if the Paseo daemon-recovery and
> Omnigent host-adoption paths are needed.

**macOS options (superseded — M1 turned out to be far smaller than estimated):**
- **M1** Port the plugins to darwin (true native, full alignment; real work on WOOWTECH's own repos).
- **M2** Run the Linux stack under a lightweight VM (Lima/Colima) on macOS — fast, but a VM (not "原生"; not a container either).
- **M3** Ship macOS without the Omnigent/Paseo Linux-bound features for v1 (agent + skill/MCP sharing work; tabs degraded) until M1 lands.

## 7. Phasing
- **Phase 1 (now)**: Linux installer (engineer bootstrap), **real-tested on an internal LAN Ubuntu host**. Full functional alignment on Linux.
- **Phase 2**: Windows via WSL2 (reuses Linux path); macOS per the §6 decision.
- **Phase 3 (customer track)**: prebuilt patched pi-web artifact in CI; signed native installers (.pkg/.dmg notarized, .deb, .msi); plaintext-API-key hardening; auth defaults.

## 8. Success criteria (functional alignment bar, mirrors the reference)
After install on a target OS: (a) `claude` + `codex` run and **share skills + MCP** with pi (pi-web); (b) pi-web settings page opens in a browser with working **Omnigent + Paseo** tabs; (c) a real-browser smoke test passes (desktop; later mobile/after-restart).

## 9. Open items / need from owner
- GitHub: new repo under WOOWTECH + push access (gh not logged in on the build Mac).
- Omnigent **server URL + account/password** for the live "login & connect" test.
- macOS strategy decision (§6).
- Repo name (proposal: `Woow_native_pi_agent` or `Woow_pi_agent_native_installer`).
