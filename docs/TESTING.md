# Testing / QA

## Linux — validated 2026-11-01 (on an internal Ubuntu 24.04 host)

A full QA pass on a clean machine. All green.

### Clean one-command install
`./install.sh` from a wiped `$PI_AGENT_HOME`, all 9 stages end to end:

```
preflight (skips apt when deps present) → node 22.23.4 → fetch (plugins +
settings-patch sha256 verified) → piweb (built from source, Omnigent/Paseo
routes compiled, CJK patch applied) → clis (claude 2.1.296 + codex 0.162.1) →
paseo (@getpaseo/cli 0.11.2) → omnigent (0.16.0 uv venv) → wire (settings.json
auto-registers both plugins) → service (systemd --user, enabled + started)
done: preflight node fetch piweb clis paseo omnigent wire service
```

### Smoke test (`tests/smoke-linux.sh`) — 24 passed, 0 failed
- **versions**: pi 1.4.0, claude 2.1.296, codex 0.162.1
- **service**: active + enabled (survives boot)
- **http**: `/`, `/api/home`, `/omnigent` all 200
- **plugin state**: `settings.json` registers both plugins; `/api/omnigent`
  reports `active:true`, 3 engines, version 0.3.31
- **skill sharing**: a skill under `data/skills/` is visible through
  `~/.claude/skills`, `~/.pi/agent/skills`, and `~/.agents/skills`
- **MCP sharing**: an http + a stdio server from `data/mcp.json` land in both
  `~/.claude.json` and `~/.codex/config.toml`; `claude mcp list` lists them;
  removing one prunes it from both (managed-marker tracking)
- **restart**: pi-web serves again after `systemctl --user restart`

Run it yourself:
```bash
bash tests/smoke-linux.sh    # exits non-zero on any failure
```

### Browser verification (real Chromium, over an SSH tunnel to localhost:30141)
- Settings dialog renders all 8 tabs: 一般 · 模型 · 技能 · 子代理 · 外掛 · MCP ·
  **Omnigent** · **Paseo**. UI is Traditional Chinese.
- The **Omnigent** tab is fully populated: connection form + the three detected
  engines (Claude Code 2.1.296, Codex 0.162.1, Pi Agent 1.4.0) + the
  conversation-verification panel. (Before the `settings.json` fix it showed
  "插件已停用".)

### Known-remaining (need external input, not installer bugs)
- **Live Omnigent connect** needs an Omnigent **server URL + account/password**.
- **Model availability** ("0 個模型") needs model auth: `claude auth login` /
  `codex login` (the user's own accounts) or an Omnigent server connection.
- **macOS** is gated on the plugin portability item — see `DESIGN.md` §6.
- **Windows (WSL2)** reuses this exact Linux path; pending a test target.

## Pi → LiteLLM gateway — validated 2026-11-01

Wired with `pi-agent-litellm set --base-url <gw>/v1 --key-stdin` against the
WOOWTECH PaaS LiteLLM release (a per-workspace `paas-ws-*` Helm release reached
over its public hostname). The key lands in `$PI_AGENT_HOME/litellm.env`
(mode 600) and `models.json` references it as `${LITELLM_API_KEY}`, so no
credential is stored in `models.json`.

Verified on the Linux host:
- `pi auth check --provider litellm --json` → `{"status":"ready","authType":"api_key"}`
- `pi --list-models` lists all **81** gateway models
- **Conversation + model switching**: four different models each returned their
  own distinct expected string —
  `apporo/gpt-6-astra`, `apporo/gpt-6-sol`, `chatgpt-pool/gpt-6-sol`,
  `qwen3-4b-cluster1` (a local GPU endpoint behind the gateway).
- Select with the provider prefix: `pi --model litellm/apporo/gpt-6-astra`.
  Ids keep their slashes because that is what goes on the wire.

### Findings worth knowing
1. **Most gateway models fail for upstream billing/quota reasons, not wiring.**
   Probing all 81: **24 answer**. The rest fail upstream —
   `woowtech/claude-*` and `anthropic/*`: Anthropic credit exhausted;
   `chatgpt/*`: `usage_limit_reached`; anything routed through OpenRouter
   (`deepseek/*`, `z-ai/*`, `openai/*` per `/model/info`): HTTP 402
   "upstream provider declined for a billing reason".
   Reliable groups observed: `apporo/gpt-*`, `chatgpt-pool/gpt-*`,
   `qwen3-4b-*` (local GPU), several `:free` models.
2. **`settings.json` `defaultModel` is ignored by `pi -p`** (pi 1.4.0). Print
   mode falls back to automatic selection, which takes the alphabetically first
   catalog entry — `anthropic/claude-fable-5.1` here, one of the no-credit ones.
   Pass `--model` explicitly, or keep no-credit models out of the gateway.
3. **Using Pi *through Omnigent* needs two files that `models.json` does not
   touch.** Omnigent enumerates a self-hosted Pi's models in
   `omnigent/harnesses/pi_native/credentials.py::pi_own_login_model_options`
   as the **intersection** of
   - `<agent-dir>/auth.json` — provider ids Pi has logged in to, and
   - `<agent-dir>/models-store.json` — Pi's catalog cache, which is
     **undocumented** (Pi's own configuration.md does not list it).

   It never reads `models.json`, which is the documented way to add a
   compatible endpoint. So a gateway wired the documented way is invisible to
   Omnigent: `pi auth check` says `ready`, `pi --list-models` shows every model
   and conversations work, while Omnigent reports `MODELS_UNAVAILABLE` and the
   mobile UI shows "Models unavailable".

   Note this is **not** a bug in `pi-omnigent-plugin`: its own
   `nativePiLoginFingerprint()` gate (also `auth.json`-based) is consistent
   with what the host requires. The gap is in the `omnigent` package itself
   (0.16.0, Databricks, Inc.) — a third-party dependency, not ours.

   **Resolution**: `rootfs/bin/omnigent-model-options-patch.py`, applied by
   `pi-web-start.sh` on every start (before the Omnigent host manager boots —
   the manager holds the module in memory for its whole life). It replaces
   `pi_own_login_model_options()` so that an empty file-pair result falls
   through to `pi --list-models`, which already knows the gateway's models.
   Idempotent, version-gated to omnigent 0.16.0, keeps a `.orig`, and never
   fails the start. Shared with `Woow_k3s_pi_agent_package`
   (`charts/pi-agent/files/`), where the same script runs from the chart's
   postStart hook. It reads only the rows under the `provider  model` header
   of that listing (with nothing configured Pi prints a "No models available"
   notice and exit code 0, which is not a model) and gives the CLI 12 seconds,
   because the Omnigent server stops waiting for the host after 15.

   **Verified on this host**: with `auth.json` and `models-store.json` BOTH
   empty — i.e. no credential stored anywhere outside `litellm.env` — a service
   restart applies the patch automatically and all three engines come up
   `ready=true verified=true` (claude 4, codex 8, pi 24) with the connection
   phase at **`ready`**; `verify --engine pi` passes on a real conversation.

   An earlier workaround seeded `auth.json` via an interactive `pi /login` plus
   a hand-written `models-store.json`. The patch makes both unnecessary, and
   removing the `auth.json` entry takes the gateway key back out of cleartext.

4. **Prune dead models, or every unqualified Pi run fails.** Pi's automatic
   selection takes the **first** entry in the provider's model list, and the
   gateway's alphabetically first model (`anthropic/claude-fable-5.1`) is one
   of the no-credit ones — so `pi -p`, and Omnigent's own verification, both
   died with `PROVIDER_PAYMENT_REQUIRED` while 23 working models sat further
   down the list. `pi-agent-litellm probe --apply` tests every model and keeps
   only the ones that answer (81 → 24 here), which makes the automatic default
   a working model and the Omnigent picker honest.

## macOS — validated 2026-11-01 (M2 MacBook Air, macOS 26.4.1, 8 GB RAM, arm64)

Clean host, no previous install, no Homebrew dependency. All nine stages ran,
then `tests/smoke.sh`: **24 passed, 0 failed** — the same suite and the same
score as Linux.

```
preflight (brew optional; found at /opt/homebrew, installed tmux)
node 22.23.4 darwin-arm64 (scoped; system Node untouched)
fetch (plugins + settings patch sha256 verified; darwin patch applied)
piweb   (built from source, 2 workers / 2560 MiB heap for an 8 GB host,
         both settings routes compiled, node-pty darwin-arm64 prebuild,
         CJK patch applied)
clis    claude 2.1.296 + codex 0.162.1, both darwin-arm64
paseo   @getpaseo/cli 0.11.2 with darwin-arm64 packages, 0 linux packages
omnigent 0.16.0 in a uv venv (uv's own CPython; system python3 is 3.9)
wire + service (launchd agent, RunAtLoad + KeepAlive)
```

`tests/darwin-premises.mjs` — 11 OS-level premises the plugin port rests on,
all passing, including that `O_EXLOCK` releases its lock when the holder is
SIGKILLed. It also **corrected a wrong premise**: `process.title` does take
effect on darwin, so an ownership check on `argv[0]` stays valid there. See
[`MACOS.md`](MACOS.md).

### Traps this run exposed

- **A leftover SSH tunnel nearly produced a false pass.** Port 30141 on the Mac
  was held by a `-L` forward left from an earlier session, so the first round of
  `/`, `/api/home` and `/omnigent` returned 200 **from the Linux box**, while the
  Mac's own pi-web was dying with `EADDRINUSE` under launchd. `/api/home` returns
  the agent's home path, which is what gave it away. Always confirm *which* host
  answered before calling a port test a pass.
- **`$HOME` is scoped on purpose.** `pi-agent-env.sh` repoints `HOME` into
  `$PI_AGENT_HOME/home`, so a test that looks for the launchd plist in
  `~/Library` finds nothing. The smoke test captures the real home before
  sourcing it.
- **A flaky assertion, not a product bug.** `claude mcp list` health-checks every
  account-level MCP server (a dozen claude.ai ones on the test hosts) and took
  >40s before reaching the fixture. `claude mcp get <name>` answers in ~1.5s and
  still proves claude read the shared config.

## Host-name suite — v0.2.2 (macOS and Linux)

```bash
bash tests/host-name.sh      # exits non-zero on any failure
```

Hermetic: temp directories and a stub Omnigent server on `127.0.0.1`. It never reads
or writes `~/.omnigent`, a running install or a real server, and starts nothing
(`tests/smoke.sh`, which restarts the service, is not involved). The one thing it
fetches is the pinned `pi-omnigent-plugin` tarball from its release URL — cached,
and refused unless its sha256 equals the one in `lib/pins.sh` (`PA_TEST_PLUGIN_TGZ`
supplies a local copy for offline runs, verified the same way). It needs `node`, and a
`python` that imports `httpx` and `yaml`; the driver uses the install's omnigent
python read-only, then `python3`, and otherwise builds a throwaway venv.

| suite | what it proves |
|---|---|
| **A** `pi-agent-host-name` | `seed` writes `<hostname> (pi-agent)` only when there is no name (idempotent, never overwrites, mode 600/700, every other line kept byte for byte, awkward shapes refused with a warning, never fails); a name equal to the plain hostname is warned about and **not** renamed; `set` takes any name — an old host's exact name included — and refuses malformed ones; the file is always the install's own (`OMNIGENT_CONFIG_HOME` and `HOME` are never followed); `check` reads the plugin's last refusal |
| **B** the plugin patch | applies once, second run is a byte-identical no-op, `.orig` stays pristine, a version it was not validated against or a moved anchor leaves the files alone with a `WARN:`, never fails, composes with the session-home patch in either order, valid Python for every interpreter present, and the new hints load |
| **C** `install.sh` | `wire` installs the three new files, patches and seeds (twice: no change), warns on a plain-hostname install, survives a skipped patch; the real `fetch` stage (from `file://` copies of the pinned tarballs) patches a fresh tree and again after the tree is replaced |
| **D** Node layer | `PI_AGENT_TAKEOVER_HOST_ID` reaches the Python adapter through the plugin's own `runtimeEnv`/`runJSON`; a refusal travels `initialize()` → `state.json` → `status()` (with the new hints) and `check`, while `connect` prints only the code |
| **E–H** the guard | the **real patched `omnigent.py`**, its own httpx client, against a stub serving `/v1/me` and `/v1/hosts`: no collision / empty list / own host_id (dashed, upper-case) start the host; a same-named host (online or offline, any case) is refused with the zh-TW message carrying the exact lines; another account's host is not a collision; every server failure (401/403/5xx, not JSON, no list, unreachable) is `HOST_NAME_UNVERIFIABLE` and starts nothing; `PI_AGENT_TAKEOVER_HOST_ID` works only as an 8–32 hex prefix covering **every** colliding host, never for `1`/`true`/a typo, never for an online host, and is spent once honoured; the guard only ever issues GETs, and sits at the spawn |
| **K** real omnigent | `load_or_create_host_identity` keeps the seeded name (ASCII, CJK, quotes, backslash) and generates only the `host_id`; skipped when no python has the `omnigent` package |

Recorded 2026-11-03 for v0.2.2:

| platform | result |
|---|---|
| macOS 26.4 arm64 · node 24.11 · Python 3.12 · omnigent 0.16.0 | **134 passed, 0 failed, 0 skipped** (v0.2.2); **138 passed, 0 failed, 0 skipped** with v0.2.3's four cutover-name cases (A19–A22) |
| Ubuntu 24.04 (Linux 7.0) · node 20.20 · Python 3.12.3, throwaway venv, isolated tree under `/tmp` | **128 passed, 0 failed, 1 skipped** (K: no `omnigent` package without using the machine's live install) |

Test strength was checked by hand with 26 deliberate regressions (guard fails open;
any non-empty takeover value accepted; offline duplicates ignored; takeover of an
online host allowed; own `host_id` treated as a collision; seed overwrites a name;
the tool follows `OMNIGENT_CONFIG_HOME`; the patch not idempotent; wire not seeding,
not patching, not installing the tools; config world-readable; the takeover variable
left in the started host's environment; no version gate; case-sensitive names;
other accounts' hosts counted; and so on). Every one makes the suite fail; the runner
is not part of the repository.

Not covered, and said so in `docs/RELEASE-0.2.2.md`: a live Omnigent server. The stub
is shaped from the plugin's own use of `/v1/me` and `/v1/hosts`.

## macOS session home + cutover — validated 2026-11-03 (M2 MacBook Air, macOS 26.4.1, 8 GB)

`tests/session-home-macos.sh`: **292 passed, 0 failed** (262 in v0.2.3; v0.2.4 adds 9 cases for the host's umask, 2 assertions that the started host has it, and 19 for a power cut after the repair) (about 7 minutes on a quiet machine, up to 14 under load). Real launchd jobs with
throw-away `io.woowtech.pa-shtest.<pid>.*` labels, fake hosts under a fake home, a stub of the
Omnigent server API on 127.0.0.1 (which reproduces the server's host rotation) and fakes of the
plugin's `pi-omnigent repair` and of pi-web's resume. It never touches `~/.omnigent`,
`ai.omnigent.*`, `io.woowtech.pi-agent` or a real server. See docs/MACOS-CUTOVER.md.

| section | passed | what it proves |
|---|---|---|
| 0 config merge | 15 | adopts host id + name; adds what is missing; never overwrites; added providers lose `default`; two servers refused; omnigent's own `load_providers` parses the result; `extend_path` |
| 1 baseline | 8 | fake old launchd host + fake install both connected, conversations bound as seeded |
| 2 refusals, dry run | 29 | `enable` refuses a live or loaded old host; a dry run changes nothing (whole-tree checksum) and never runs the plugin CLI; every blocker (busy conversation, foreign host, old host offline, login not confirmed, install too old, plugin unpatched) |
| 3 cutover | 61 | plists parked byte for byte and disabled; `~/.omnigent` parked + linked + hard-linked; identity adopted; the plugin's repair ran once, under `env -i` (a decoy variable did not leak), with the real home, **before** the service started; host runs with the real HOME and the old PATH appended; the **server** shows the same host online, same name, all 14 conversations bound, **no row rotated**; an unpinned host in this install's directory is not "ours" |
| 4 restart | 9 | a detached job survives its killed parent, replaces the host, removes its own plist |
| 5 uncutover | 20 | plists, parked directory, config, `connection.json` and `state.json` back byte for byte; journal archived; the old host online again with its conversations |
| 6 forced failures | 90 | six cycles (the server renames the host; the server drops the bindings; the host cannot start with session home; the repair fails; the repair "succeeds" without saving the receipt; the service does not come up), a worker killed half way and recovered at the next login, and a rollback that cannot confirm everything reporting INCOMPLETE until `uncutover` finishes it: each ends with everything as before, byte for byte |
| 7 / 7b / 7c enable, disable, restart | 23 | `enable`/`disable` leave the fake home byte for byte as it was; restart with session home alone moves the host to the real HOME and back; an unhealthy session home is reverted by the restart itself |
| 8 negative control | 2 | a new host id under the old name rotates the old row and repoints the conversations (what adoption avoids) |

Linux regression (Ubuntu 24.04, isolated `/tmp`): `bash -n` of `pi-agent-session-home`,
`pi-web-start.sh`, `pi-agent-env.sh`, `install.sh`; `pi-agent-session-home status` takes the unchanged
Linux path; the Darwin block of `pi-web-start.sh` is a no-op on Linux even with a state file present.

Not covered: the real `ai.omnigent.host` job's shutdown behaviour; the real plugin's `repair` (faked
from its source); the server's real reaction to a reused host id; Omnigent.app at run time; macOS
privacy prompts for the new host program; a real reboot mid-cutover; the woowtech MacBook.

## The `pi` wrapper under session home — validated 2026-11-03

`tests/pi-wrapper-session-home.sh`: **12 passed, 0 failed**, hermetic (a temp directory and a fake
node that only reports its environment). It pins which HOME and which Pi data directory the
wrapper hands to pi with session home off and on -- including that a user with **no** Pi
configuration of their own keeps the install's data dir -- and it **fails against the wrapper
published in v0.2.2** (4 of the 12, the cases where the user has a Pi of their own): run it
with `PI_TEST_WRAPPER=<older pi>` to see the bug it guards. The bug was found on the first Mac
cut over: Omnigent's own verification of the Pi engine answered `MODELS_UNAVAILABLE` (claude
verified fine), because the scoped pi kept the user's HOME but read this install's empty data
directory instead of the user's own `~/.pi/agent`. See docs/SESSION-HOME.md.

## Release 0.2.4 — the three suites added after the first real pkg install over a cut-over Mac

Run from a shell with a strict umask (077) on purpose: that is the condition that exposed all three.

| suite | what it pins | result | watched to fail before the fix |
|---|---|---|---|
| `tests/session-home-macos.sh` (nine new cases + two assertions) | the host a cutover starts gets the replaced job's umask (its plist's `Umask`, else 022), not the worker's strict one; a restart keeps it | 292 passed, 0 failed in all | yes: the host had 077 (1 failure) and the helper did not exist (9) |
| `tests/build-macos-pkg.sh` | an unsigned pkg built under umask 022 **and** 077 has a payload that other users can read and enter, with `install.sh` and the installed scripts executable for them | 8 passed, 0 failed | yes: under 077 the payload directory itself was 700 and every script lost its bits (3 failures); with the first two defences removed the build refuses on its own check (`PI_TEST_BUILDER=<mutant>`) |
| `tests/installer-rerun.sh` | the omnigent stage run twice over one install root, and over a half-made venv, exits 0; the stand-in uv refuses to create a venv over a non-empty directory, as uv 0.12 does; one check runs the real pinned uv | 7 passed, 0 failed | yes: the second run failed with uv's own message (3 failures) |

Measured on real Macs rather than in a sandbox (the commands are in OPERATIONS-GOTCHAS.md sections 17-20):

- a host's umask, through the host's own `mkdir` (the server's "create directory on a host" call):
  the cut-over host 700 (umask 077), the host restarted afterwards by pi-web 755 (022);
- macOS privacy consent for the install's `node`: one Mac *granted* for Desktop, Documents and
  Downloads (and `AllFiles` denied), the other *not decided* -- the preflight agrees with the
  unified log wherever the log has an answer;
- the v0.2.4 payload installed by `installer -pkg` over the cut-over MacBook: all nine stages, exit 0;
  config, receipt, state file, journal, the parked plists and the owner's `~/.pi/agent` byte-for-byte the
  same; the host process kept running (same pid); the server still showed the same host row and all
  16 conversations bound; Claude and Pi verified afterwards; memory never below 33% free, the two
  Apple review demos running throughout.

## Cut-over Apple silicon Macs, real runs — 2026-11-03 to 2026-11-06 (MacBook Air M1, macOS 26.7.1, 8 GB; MacBook Air M2, macOS 26.4.1, 8 GB)

The two Macs the cutover was first run on (docs/RELEASE-0.2.3.md) stayed the test beds for the releases after it. The notes of
v0.2.5, v0.2.6 and v0.2.7 say Apple silicon is "covered by tests with stand-ins, not by a run"; this section records the runs
that were made there since. Each was checked against the server, not against what the Mac said: the host row and, for every
conversation bound to that host, its id, status, host and `created_at`, listed before and after and compared line by line
(`GET /v1/hosts`, `GET /v1/sessions`); a host's umask through the server's "create directory on a host" call, which makes the
host's own `mkdir` (OPERATIONS-GOTCHAS section 17); the engines through `pi-omnigent verify`, each opening one test conversation
that was deleted afterwards by the id in its own result (404 on a later GET). On the M1 the free memory, the swap and the two
review demo containers were read every 30 seconds.

| when (+0800) | Mac | what ran | result |
|---|---|---|---|
| 11-03 17:42-17:50 | M1, 16 conversations | `uncutover`; then a `cutover` cut off after its repair step (the worker, its sleep and the adopted host `kill -9`, their launchd jobs booted out) and both plists bootstrapped in one call, a login with a leftover worker; then `cutover` again | `ROLLED BACK - uncutover requested` in 31 s. The cut-off run: `ROLLED BACK - an earlier run was interrupted`, 22 s after the "login", the old host back online. The last `cutover`: `OK` in 44 s, the host it started with umask 022. The server list (host row and 16 conversations) was identical to the one taken before, after every step; Claude and Pi answered. Memory never below 33% free, the demos running throughout |
| 11-05 15:23-15:25 | M1 | the published v0.2.5 arm64 pkg, `sudo installer`, over the cut-over install | exit 0, "The upgrade was successful", about 2 min; nine stages OK, no error line in the install log; the host kept its pid; the server list identical before, after, and after the engine checks; umask 022; Claude and Pi answered. The plugin's `state.json` read phase `error` right after the install (the false HOST_PROCESS_MISSING that v0.2.6 removes) and `needs-verification` again once the engines had been checked |
| 11-05 15:34 | M2, 37 conversations | `pi-agent-session-home restart`, started by a job that waited until no conversation was answering | `RESULT: OK`; the host's umask 077 to 022 (the directory it makes: mode 700 to 755), the v0.2.4 fix now measured on this Mac too; the 37 conversations still bound; Claude and Pi answered |
| 11-06 07:13-07:16 | M1 | the published v0.2.7 arm64 pkg (sha256 `c07f5ace39f6...ab6ac8`), `sudo installer`, over the cut-over install | exit 0 in 2 min 14 s, "The upgrade was successful", nine stages OK, 0 error lines in 272 log lines. The host kept its pid (up 2 days 13 hours); host row and 16 conversations identical before, after, and after the engine checks; umask 022; Claude and Pi answered, and the host offers Pi's models (61). Config, receipt, session-home state, journal, the service's plist and the parked plists byte for byte the same; only `state.json` (the plugin rewrites it at each start), the scripts the release changed and the payload version differ |
| 11-06 07:27-07:30 | M2, 37 conversations, two of them in status `running` | the payload of that same pkg: `install.sh` run as the pkg's postinstall runs it (same environment variables, a login shell, the pinned pi-web URL and sha256) but as the user, without `sudo`: no pkg receipt, no `/usr/local/lib/woow-pi-agent` | exit 0 in 179 s, nine stages, 0 error lines. The 11 processes listed before (the host, tmux servers, claude) all still running, the host with the same pid; both `running` conversations still were afterwards, one of them the session that had scheduled the upgrade, which kept answering throughout; 37 conversations before and after, none missing (one idle conversation started a turn on its own, the only status change); umask 022; the installed scripts equal the payload's; the service's plist unchanged; Claude and Pi answered |

What v0.2.6 changed, as the plugin records it. `data/omnigent-plugin/boot.json`, `resumption`, read before and after the
upgrade of 11-06 on both Macs:

| | before (v0.2.5 and earlier) | after (v0.2.7) |
|---|---|---|
| M1 and M2 | `ok: false`, `error.code: HOST_PROCESS_MISSING` | `ok: true`, `resumed: true`, `host.connected: true` |

`state.json` stayed at `needs-verification` (`INCOMPLETE_CHAT_VERIFICATION`: not every installed engine has had a real reply
verified on that account), where v0.2.5 passed through `error`. The cost PR #3 names, a Mac no longer reporting a host that died
while the server still shows it online, was not exercised.

Not run: a real reboot (both Macs have FileVault on and no automatic login, so it needs someone at the keyboard); a wiped Mac;
Installer.app by hand; the pkg route on the M2 (its v0.2.7 went in through `install.sh`, as above); Codex in these engine checks
(Claude and Pi were verified); a host that dies while the server shows it online.

## Intel Macs — validated 2026-11-04 (13" MacBook Pro 2017, i5-7360U, macOS 13.7.8; MacBook Air 2020, i3-1000NG4, macOS 15.4.1; 8 GB each)

| suite | what it pins | result | watched to fail before the fix |
|---|---|---|---|
| `tests/intel-mac.sh` (new) | **A** the lock pins cryptography and argon2-cffi-bindings twice under complementary Intel / non-Intel markers, marks nothing else, hashes every pin · **B** the darwin patch adds `--constraints "$PI_OMNIGENT_UV_CONSTRAINTS"` to the plugin's own `uv tool install`, and on x64 only one run of the new omnigent with a 120 s limit before the 5 s probe (the real `installDependencies()`, a stand-in uv; idempotent) · **C** `pi-agent-env.sh` sets the variable on an Intel Mac that has the kept lock, and not before the omnigent stage, on Apple silicon or on Linux · **D** (pinned uv) a dry run on this machine picks the right pins, 94 packages; the Intel blocks equal uv's own answer to the command in the lock's header; a fresh Intel resolution still picks the wheel-less releases · **E** (Intel Mac) the venv, a constrained `uv tool install` and the patched plugin's own `installDependencies()` all succeed with source builds forbidden | 28 passed, 0 failed on each Intel Mac; on Linux x86_64 24 passed, 0 failed, E skipped | yes, each piece taken back to main in turn (on Linux): the lock 5 failures, the patch without the constraints edit 4, without the first-launch edit 3, `pi-agent-env.sh` 1 |
| `tests/installer-rerun.sh` (one new check) | the omnigent stage keeps the requirements it installed from, at `$PI_AGENT_HOME/omnigent/requirements.lock` | 8 passed, 0 failed (Linux and both Macs) | yes: `install.sh` as on main, 1 failure |

Measured on the two Macs:

- `scripts/build-macos-tmux.sh` on x86_64: tmux 3.8, 2.4 MB, `Mach-O 64-bit executable x86_64`, minos
  13.0, linking only `/usr/lib/libncurses.5.4.dylib`, `libSystem.B.dylib` and `libresolv.9.dylib`;
  台灣報告 round-trips with the cursor at column 8; jemalloc is the default zone (614,176 and 646,944
  bytes served during `tmux -V`). sha256 `477f49fc…` on the MacBook Pro, `ef81e38d…` on the MacBook Air:
  each Mac built with its own Command Line Tools, and the binaries differ.
- `tests/tmux-stress.sh` on those x86_64 builds, 300 s each: **0 aborts**, no crash reports -- 590 iterations
  on the MacBook Pro (533 copy-mode entries, 537 full captures), 449 on the MacBook Air (413, 407);
  footprint at the end 123 MB and 139 MB.
- an end-to-end install in the pkg's layout -- `tools/bin/tmux`, the macos-x64 pi-web tree as a local
  `PI_AGENT_PIWEB_ARTIFACT`, `UV_NO_BUILD=1`, its own `PI_AGENT_HOME`, every stage but `service`: exit 0
  on both. Then the plugin's own `pi-omnigent install-dependencies`, from an empty state directory, three
  times on each Mac: `ok: true`, `issues: []`, omnigent 0.16.0 every time (6.0 to 9.5 s).
- the same end-to-end before the first-launch edit ended in "uv finished, but the managed Omnigent
  executable is unavailable" on both Macs, although uv had installed everything. The first
  `omnigent --version` after a fresh install took 4.1 and 6.1 s on the i3, 4.0 and 4.3 s on the i5
  (0.5 to 0.65 s on every later run), and the plugin's probe allows 5 s. With `--compile-bytecode` it
  was 2.6 to 3.1 s: under the limit, but not by enough while pi-web is still starting.
- no native node module is compiled on an Intel Mac: the installed MacBook Pro has none under
  `build/Release`, and 16 prebuilt `.node` files in pi-web, 10 in the Paseo runtime.
- the release workflow, dispatched on the branch before the v0.2.5 tag (run 41826891068): all three
  legs green. On the `macos-15-intel` runner pi-web built and packed (146 MB artifact) and the tmux
  build passed every self-check (CJK at two columns a character, jemalloc the default zone, links
  only `/usr/lib`).
- not tried then: a Mac without the Command Line Tools (both had them by then). Tried later, with them moved away: see "The published v0.2.6 pkg on Intel Macs" below.

## Pi's models on a fresh install, and resume without /proc — validated 2026-11-05 (the 2017 MacBook Pro above, macOS 13.7.8, with another session running a JDK and Chrome on it; the 2020 MacBook Air above, macOS 15.4.1; Linux x86_64)

| suite | what it pins | result | watched to fail before the fix |
|---|---|---|---|
| `tests/model-options-hook.sh` (new) | **A** `omnigent-plugin-model-options-hook-patch.mjs` applies, is idempotent, version-gated, leaves a moved anchor alone · **B** it composes with the darwin patch in either order · **C** the real `installDependencies()` with stand-ins for uv and the tool's python: the patch runs after the install and before the plugin looks at the result, on install and on update, not otherwise, and no failure of it fails the install · **D** `wire` and the real `fetch` stage · **E** `pi-web-start.sh`, including a re-extracted plugin tree | 26 passed, 0 failed on the Mac and on Linux | yes, on Linux, each piece broken in turn: no run in the hook 6 failures, placed after the probe 3, errors escaping 2, `install.sh` without the calls 4, `wire` without the file 1, the start script without it 2 |
| `tests/resume-no-proc.sh` + `resume_no_proc_test.py` (new) | the darwin patch's edit: applies, composes with the guard and session-home patches in either order · the REAL `src/omnigent.py` through `resume()` against a stub server, with a stand-in `omnigent` that exits at once as the real one does when a host is running: unpatched `HOST_PROCESS_MISSING`, patched connected, also when the host comes back after a moment; a host that never comes back is still `HOST_CONNECT_TIMEOUT`; with a real `/proc` nothing changes | 11 passed, 0 failed on the Mac, where `/proc` really is absent (the real-`/proc` case skipped); 12 passed, 0 failed on Linux, `/proc` hidden from the module | yes, on Linux: the edit not applied 5 failures, the condition unchanged 4, the check removed everywhere 2 |

Unchanged suites over this tree: `host-name.sh` 138/0, `installer-rerun.sh` 8/0, `pi-wrapper-session-home.sh` 12/0 on both; `intel-mac.sh` 28/0 on the Mac, 24/0 on Linux; `build-macos-pkg.sh` 8/0 on the Mac.

Measured, `list-models` matches in the omnigent the plugin had just installed (0 unpatched, 4 patched):

| | v0.2.5 | with the hook |
|---|---|---|
| MacBook Pro: `pi-omnigent install-dependencies`, nothing else started | 0 | 4 |
| MacBook Pro: a real first service start, from an empty plugin directory | 0 | 4 |
| MacBook Air: a real first service start, after a full install | not run | 4 |
| Linux: `pi-omnigent install-dependencies`, nothing else started | not run | 4 |

- The plugin had its omnigent 39, 46 and 76 s after those first starts (10, 40 and 63 s in earlier runs). In none of them had
  the start script's own step run: there was nothing to patch yet.
- A real pi-web restart (`launchctl kickstart -k`) with a connected host, on the MacBook Air, control then fix. v0.2.5's
  plugin: phase `error`, `HOST_PROCESS_MISSING`, from the first look at 15 s to the last at 120 s, with `connected=true`
  and the same host pid. With the edit: phase `needs-verification`, no issue, at every look for those 2 minutes, the same
  pid, and the catalog unchanged (claude 4, codex 3, pi 85). Each restart left one more `A host daemon is already running
  for this server` in `data/omnigent-plugin/host.log`: the duplicate host omnigent refuses (OPERATIONS-GOTCHAS section 6).
  No session was bound to that host, so a session running through such a restart was not measured here. It was later, through a whole upgrade: see "The published v0.2.6 pkg on Intel Macs" below.
- One more first start, at a load average near 50: `prepare()` threw, `boot.json` said `"phase": "error"`, and omnigent
  was not installed 6 minutes later. At load 7 the same install worked. See OPERATIONS-GOTCHAS section 21; the exception
  is swallowed, so the cause is suspected, not proven.
- Not run: `tests/session-home-macos.sh` and `tests/smoke.sh`, which use real launchd jobs or restart the service, on a
  Mac that was in use; the suites in the table on the MacBook Air; Apple silicon.

## The published v0.2.6 pkg on Intel Macs, and a Mac without the Command Line Tools — validated 2026-11-05 (the 2020 MacBook Air, macOS 15.4.1; the 2017 MacBook Pro, macOS 13.7.8)

| suite | what it pins | result | watched to fail |
|---|---|---|---|
| `tests/installer-rerun.sh` (5 new checks) | on a simulated Mac with no tools the omnigent stage exits 0, uv's `install_name_tool` call never reaches the stub, and the stand-in is gone afterwards; with the tools it reaches the real tool as before | 13/0 on the MacBook Air, 12/0 on Linux, where the real-uv check is skipped | the stand-in never put on `PATH`; the stand-in used even with the tools |
| `tests/claude-no-tools.sh` (new) | which git Claude Code finds through the `claude` wrapper. No tools: the stand-in, which exits 127, says how to get the tools, is not added twice, and runs the real git with its arguments intact once the tools are there. With the tools, with another git first on `PATH`, and on Linux: nothing changes | 9/0 on the MacBook Air and on Linux | the old wrapper; the stand-in on every Mac; no Darwin check; no check of which git is first |
| `tests/build-macos-pkg.sh` (2 new checks) | `installer -pkginfo` shows the pkg's name, at each umask | 10/0 on the MacBook Air | the title edit removed: 2 fail. The published v0.2.6 pkg prints nothing |

The published x64 pkg, `sudo installer`, downloaded with quarantine set (Gatekeeper: accepted, Notarized Developer ID):

| run | on | result |
|---|---|---|
| over an install | MacBook Air | exit 0 in 223 s. Payload root-owned, receipt 0.2.6, installed files owned by the user |
| over an install, a session's tmux and claude running | MacBook Pro | exit 0 in 165 s. Those and the host kept their pids; no issue at any look for 60 s |
| over an install, Claude's Bash tool writing a heartbeat every second | MacBook Air | exit 0 in 283 s. Heartbeat 420 beats, longest gap 2 s, the reply arrived; host, tmux and claude kept their pids |
| from zero, no tools | MacBook Air | exit 0 in 227 s, 0 compile lines, dependencies ok, phase `needs-login`. The dialog came up once |

No tools, on the MacBook Air. `/Library/Developer/CommandLineTools` renamed and put back on any exit; `xcode-select -p` fails; each run ends with a control, `/usr/bin/git`, which answers "No developer tools were found, requesting install" and opens the dialog, so a run with no dialog means something. **This is not a wiped Mac**, and Installer.app's windows were not walked through.

Before the fixes:

| what ran | dialog | stubs reached |
|---|---|---|
| every stage in turn, logging stand-ins for the stubs first on `PATH` | yes, in `omnigent` | 1: uv's `install_name_tool -id` on libpython |
| a logged-in install: the service idle for 60 s, between the host's timers | no | |
| `pi-omnigent status`, `pi-omnigent catalog`, `codex exec`, `pi -p` | no | |
| real sessions: Pi, Codex | no | |
| `claude --version`, `claude auth status` | no | 0 |
| `claude -p` | **yes** | 3: `git`, starting with `git -c core.hooksPath=/dev/null ... ls-files --error-unmatch -- :(icase).claude/settings.local.json` |
| a real Claude session | **yes**, 2 s after it was created | not logged: the host's `PATH` has no stand-ins |
| the same `claude -p`, stand-ins that exit 127 first on its `PATH` | no | 3, all to the stand-in for `git` |

With the fixes:

| what ran | dialog | stubs reached |
|---|---|---|
| the published payload with the fixed `install.sh`, in one go, then its first boot to the end (`boot.json`) | **no** | 0. Exit 0 in 162 s. The Pi patch on the plugin's omnigent: 4 matches |
| the final `omnigent` stage alone, real uv and real downloads, a scratch home | no | not logged; exit 0 in 41 s, the stand-in gone |
| the published, signed v0.2.7 x64 pkg through `sudo installer`, from zero, then its first boot to the end | **no** | not logged (the postinstall sets its own `PATH`). Exit 0 in 158 s, `Package name is Woow Pi Agent`, 0 compile lines, the Pi patch: 4 matches |
| a logged-in install with the `git` stand-in, the host connected, for 241 s: the host starting `bin/claude` by itself (19:25:22, 19:27:22) and a real Claude session | **no** | `/usr/bin/git` in the exec trace: none |

- The agent's own `git` in that Claude session, tools away: `command -v git` names the stand-in, `git --version` says `git: this Mac has no Command Line Tools. To install them: xcode-select --install`, exit 127. Tools back, the same session, not restarted: `git version 2.39.5 (Apple Git-154)`, exit 0, through the stand-in. A new session with the tools: `/usr/bin/git`, and the stand-in not on `PATH`.
- Before the fixes, real sessions with all three engines each ran one command through their own tool and replied, in 14 to 28 s. The dialog did not hold anything up: the stub fails at once.
- An exec trace (`fs_usage -w -f exec -e fs_usage`) shows the host's python running `bin/claude` twice about every 3 minutes (18:48:22, 18:51:22, and 19:27:22 in a later run; once also at 19:25:22, right after a session had ended), with the dialog up within a second of each before the fix. What it runs them for was not identified. It takes a running host: the from-zero install has none, and no dialog in its first boot.
- `claude -p` on that Mac answers "Your organization has disabled Claude subscription access for Claude Code" with or without the tools, so it never did a turn. Its `git` calls come before that. The Claude sessions, which run the TUI, are not affected.
- As shipped, libpython's install name is `@rpath/libpython3.12.dylib`. uv renames it to the full path; the stand-in leaves it. The interpreter links `@rpath/libpython3.12.dylib` and finds it through its own rpath, so it runs either way (`import ssl` on one never renamed).

What misled these measurements, for the next person:

- The dialog ignores SIGTERM. `pkill` leaves it on the screen, and the next run sees it and blames its first stage. Use SIGKILL; launchd may still bring it back about 10 s later, once.
- A logged-in install that was made with the tools has no `python3` link, since `wire` only makes one on a Mac without them. Take the tools away afterwards and every discovery runs the `python3` stub, which a real tools-less install never does. Make the link for the test.
- `pgrep -f` on the dialog's name matches the shell running a command that contains that name. Keep the pattern out of the command line.
- `fs_usage` leaves out `sh` and others unless given `-e`, and for `posix_spawn` it can print a file action's path instead of the program: Claude's `git` shows up as its working directory.
- Taking the first boot's `list-models` count before `boot.json` exists reads 0: the hook runs after the first launch.
- A multi-line prompt reaches a Claude session as pasted text, and Claude may ask whether you meant it rather than run it. Send one line.

Over the tree released as v0.2.7, on the MacBook Air with no session on it: `session-home-macos.sh` 292/0 and `smoke.sh` 24/0, neither run for v0.2.6; `model-options-hook.sh` 26/0, `resume-no-proc.sh` 11/0, `intel-mac.sh` 28/0, `host-name.sh` 138/0, `pi-wrapper-session-home.sh` 12/0.

Not run: a wiped Mac; Installer.app by hand; `pi-omnigent connect` from the empty state, which would leave a permanent host row on the server; a `git` run by an agent under Codex or Pi, which has no stand-in.
