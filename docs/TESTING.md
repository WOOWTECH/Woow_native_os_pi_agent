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
| macOS 26.4 arm64 · node 24.11 · Python 3.12 · omnigent 0.16.0 | **134 passed, 0 failed, 0 skipped** |
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

`tests/session-home-macos.sh`: **262 passed, 0 failed** (about 14 minutes). Real launchd jobs with
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

`tests/pi-wrapper-session-home.sh`: **9 passed, 0 failed**, hermetic (a temp directory and a fake
node that only reports its environment). It pins which HOME and which Pi data directory the
wrapper hands to pi with session home off and on, and it **fails against the previous
wrapper** (4 of the 9, the session-home cases): run it with `PI_TEST_WRAPPER=<older pi>` to see
the bug it guards. The bug was found on the first Mac cut over: Omnigent's own verification
of the Pi engine answered `MODELS_UNAVAILABLE` (claude verified fine), because the scoped pi
kept the user's HOME but read this install's empty data dir. See docs/SESSION-HOME.md.
