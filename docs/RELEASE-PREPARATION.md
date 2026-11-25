# Native release preparation

## 0.2.13

Changes from 0.2.12:

- Agent Connect 0.1.23 → 0.1.24 (pi-paseo-plugin #24, merged as `ee8f9b43`;
  `woowtech-pi-paseo-0.1.24.tgz`, sha256 `a8ffeda6…f831`). The managed Paseo
  daemon moves from 0.11.2 to **0.17.4** (runtime revision
  `0.17.4-r1-a651f42711da`), so the official app (app.paseo.sh 0.17.x) can use
  daemon features such as the "All changes" diff. The settings page and the
  three targets are unchanged.
  - **Restart to switch.** The first activation after the upgrade only
    installs 0.17.4 into a new release directory. A running 0.11.2 daemon keeps
    serving and the status reads `restart_required`; stop and start Agent
    Connect (Settings > Agent Connect, or `node bin/cli.mjs stop` then
    `start`) and the same `PASEO_HOME` runs under 0.17.4. Server ID, daemon key
    (the host identity in pairing links), settings and conversations are kept.
    `status.version` is the installed version, `status.daemon.version` the one
    serving.
  - **Config conversion.** Before the first 0.17.4 start the plugin loads
    `config.json` through 0.17.4's own reader and rewrites the voice settings
    it no longer accepts (`providers.openai` key and URL move into the OpenAI
    dictation/voice settings, `provider` defaults to `local`, fields `local`
    does not use are dropped). A setting 0.17.4 cannot load is reported as
    `CONFIG_INCOMPATIBLE` before anything is stopped; the old daemon keeps
    serving.
  - **Smart targets.** The Woowtech and Apporo Smart apps are 0.10.1 builds
    and only speak the older relay encryption, so Agent Connect sets
    `daemon.relay.requireProtectedSecurity` to false at every start for those
    two targets and refuses to hand out a pairing link that would require it
    (`PAIRING_SECURITY_UNSUPPORTED`). The Paseo target leaves the setting to
    its clients. Smart app compatibility with 0.17.4 has not been tested live.
  - **New 0.17.4 defaults.** `agents.idleRuntimeCleanup` is on: an agent idle
    for 60 minutes has its provider process closed and is reopened on the next
    message. `daemon.usage.enabled` is on: when an app asks for usage, the
    daemon reads this host's Claude/Codex login files and calls the providers'
    usage APIs. Both can be turned off in `config.json` without a restart.
  - **Terminals and `ps`.** 0.17.4 terminals are held by detached worker
    processes and cleaned up with `ps` (procps) on stop and start. The Linux
    installer already installs procps. Stop waits up to 45 seconds for the
    supervisor (the supervisor itself is bounded at 81 seconds) and never
    force-kills a process.
  - **Disk.** A runtime release directory is about 0.7 GB (0.11.2: about
    0.57 GB). After a healthy 0.17.4 start the plugin removes release
    directories it no longer needs, keeping the newest older one for rollback,
    and records the result in `state.json` (`lastPrune`).
  - **Rollback to 0.1.23** also needs a stop and start, and two changes 0.17.4
    makes to saved data are not undone: the OpenAI key moved out of
    `providers.openai` (0.11.2 then rejects the config as `CONFIG_INVALID`
    until it is moved back), and agent options saved in 0.17.4's new
    `controls` form, which 0.11.2 ignores, have to be set again.
- Omnigent plugin 0.3.38 → 0.3.39 (pi-omnigent-plugin #36, squash `b2c6d12c`;
  `woowtech-pi-omnigent-plugin-0.3.39.tgz`, sha256 `a5eb78fe…ff58`): only its
  combined Pi Web adapter, which now pairs with exactly Agent Connect 0.1.24.
  The combined patch (`PIN_OMNIGENT_UI_SHA256`) becomes `5e2c36b4…`; it differs
  from 0.3.38's in one file (a test that takes the Paseo version from the
  plugin instead of hardcoding it). Asset names are unchanged.
- The four plugin overlays accept 0.3.39 through the same reviewed
  maintenance-aware path as 0.3.35 to 0.3.38.
- `PIN_GETPASEO_CLI_VERSION` becomes 0.17.4 and the manifest's
  `runtimeRevision` for Agent Connect becomes `0.17.4-r1-a651f42711da`. The
  installer stages the runtime from the plugin's own lock, so these only feed
  the macOS installer test's checks.
- The 0.3.38 and Agent Connect 0.1.23 archives are dropped.

After upgrading, restart Pi Web (the macOS installer reloads it; on Linux
restart `pi-web.service`), then stop and start Agent Connect to move the
daemon to 0.17.4. The host identity in pairing links is unchanged. Do the stop
and start after the Pi Web restart: until then the running process still has
the 0.1.23 plugin loaded.

Shared runtime 0.1.6 and Pi Web 0.10.0 are unchanged.

## 0.2.12

Changes from 0.2.11:

- Agent Connect 0.1.22 → 0.1.23 (pi-paseo-plugin #23, merged as `152e1c3a`;
  `woowtech-pi-paseo-0.1.23.tgz`, sha256 `0e4f3c99…0265`). The Paseo target
  opens and pairs at the official `https://app.paseo.sh`, like the two Smart
  targets open their own sites. The bundled `/paseo-web` client (patched
  Paseo Web 0.13.0-woow.1, about 11 MB downloaded per host) and its Pi Web
  route are removed. Activation removes the copy 0.1.9–0.1.22 left in the
  Agent Connect state directory: only the entries those versions created,
  never through a symlink, and a failure never blocks activation. Browsers
  paired through `/paseo-web` pair once more on app.paseo.sh; daemon
  identity, logins and conversations are unchanged. The bundled build
  carried two display fixes that upstream has not merged yet
  (getpaseo/paseo#7908); until upstream ships them, the official site may
  still show them. The backend conversation is unaffected.
- Omnigent plugin 0.3.37 → 0.3.38 (pi-omnigent-plugin #35, squash `a447f30d`;
  `woowtech-pi-omnigent-plugin-0.3.38.tgz`, sha256 `2ed6aef9…5cde`): only its
  combined Pi Web adapter, which now pairs with exactly Agent Connect 0.1.23.
  The combined patch (`PIN_OMNIGENT_UI_SHA256`) becomes `a5f5e6eb…`, so the
  prebuilt Pi Web trees are rebuilt; asset names are unchanged.
- The four plugin overlays accept 0.3.38 through the same reviewed
  maintenance-aware path as 0.3.35 to 0.3.37.
- `PA_PASEO_WEB_DIR` (lib/common.sh) and `PI_PASEO_WEB_ARCHIVE`
  (rootfs/bin/pi-agent-env.sh) are removed. Nothing ever read them.

After upgrading, restart Pi Web (the macOS installer reloads it; on Linux
restart `pi-web.service`). Until then the old process keeps the 0.1.22
runtime in memory and cannot make a Paseo pairing link.

Shared runtime 0.1.6 and Pi Web 0.10.0 are unchanged.

## 0.2.11

Changes from 0.2.10:

- Agent Connect 0.1.21 → 0.1.22 (pi-paseo-plugin #22, merged as `3c3a94cb`;
  `woowtech-pi-paseo-0.1.22.tgz`, sha256 `98cdf9d4…00fcf`). Settings > Agent
  Connect gains 「允許代理彼此協作」, **off by default**. When on, agents get
  Paseo's own MCP tools through `daemon.mcp.injectIntoAgents`: agents,
  terminals and schedules, plus messaging, mode changes and permission
  approvals for any agent on the host. Paseo 0.11.2 leaves that setting off,
  so Agent Connect agents could not hand work to each other through the tools.
  The switch shows the daemon config value, which a Paseo client can also
  change. The page states the risk (terminals run commands without permission
  prompts). It also states that turning the switch off reaches only newly
  opened conversations.
- Omnigent plugin 0.3.36 → 0.3.37 (pi-omnigent-plugin #34, squash `effc5984`;
  `woowtech-pi-omnigent-plugin-0.3.37.tgz`, sha256 `2b05b25c…44f8`): only its combined
  Pi Web adapter, which now pairs with exactly Agent Connect 0.1.22. The
  combined patch (`PIN_OMNIGENT_UI_SHA256`) becomes `178236c5…`, so the
  prebuilt Pi Web trees are rebuilt; asset names are unchanged.
- The four plugin overlays accept 0.3.37 through the same reviewed
  maintenance-aware path as 0.3.35 and 0.3.36.

Shared runtime 0.1.6 and Pi Web 0.10.0 are unchanged.

## 0.2.10

Changes from 0.2.9:

- Omnigent plugin 0.3.35 → 0.3.36 (pi-omnigent-plugin #33, frozen as
  `woowtech-pi-omnigent-plugin-0.3.36.tgz`, sha256 `223d1464…11f6`). When the
  maintenance preservation guard refuses the SDK, status and the installer
  issue now name the cause as a fixed token. For example, `unsafe-source-file`
  means hard-linked files, and the issue says to run
  `pi-omnigent repair --update`. Before, it showed only "dependencies missing".
- Agent Connect 0.1.20 → 0.1.21 (`woowtech-pi-paseo-0.1.21.tgz`, sha256
  `538ce608…a39f`, source `d382779f`). Upstream Paseo writes `paseo.pid`
  without a mode, so under Ubuntu's umask 002 it is 0664. 0.1.20 refused that
  file on every retry, so Agent Connect never started. 0.1.21 accepts it
  inside the private home. The Pi Web adapter patch is byte-identical, so the
  combined patch (`f5c909b3…`) and the prebuilt Pi Web asset names are
  unchanged.
- Linux/WSL2 recovery: `woow-native-connection.service` now also resumes an
  authorized host on an HTTPS server. It waits until the server accepts a TCP
  connection, then runs the same plugin boot lifecycle. Pi Web's own boot
  worker tries only once, so a network that came up after Pi Web left the host
  offline until someone opened Settings.
- The four plugin overlays accept 0.3.36 through the same reviewed
  maintenance-aware path as 0.3.35. Every anchor they check is unchanged.

Shared runtime 0.1.6 and Pi Web 0.10.0 are unchanged.

## 0.2.9

Changes from 0.2.8 (PR #16):

- Omnigent plugin 0.3.34 → 0.3.35, frozen as
  `woowtech-pi-omnigent-plugin-0.3.35.tgz` (sha256 `9ac751b3…db2b` in
  `candidate-packages/manifest.json`). 0.3.35 checks the managed Omnigent before
  maintenance and refuses files that have more than one hard link.
- On Linux and WSL2, a plugin-managed Omnigent installed by plugin 0.3.34 or
  earlier shares its files with the uv cache, so the upgrade left hosts offline
  with `DEPENDENCIES_MISSING`. `install.sh` now runs
  `rootfs/bin/pi-agent-unshare-omnigent.py` before it unpacks the plugin and
  gives those files their own copies. If it cannot, it stops with the old plugin
  and Pi Web still in place. See `docs/OPERATIONS-GOTCHAS.md` section 22.
- Agent Connect stays 0.1.20 and the shared runtime stays 0.1.6. Agent Connect
  0.1.21 fixes the Ubuntu pid-file mode, but Omnigent plugin 0.3.35's combined
  adapter accepts only 0.1.20. 0.1.21 waits for the next plugin release.
- Pi Web stays 0.10.0, so the asset names are unchanged apart from the tag.

Existing 0.2.8 assets and the separate 0.3.0-rc Windows channel remain
immutable. The release route below is unchanged since 0.2.8.

## Release route (prepared for 0.2.8)

The normal Ubuntu/WSL2 instructions use tag `v0.2.8` and its Linux x64 Pi Web
artifact. Mac downloads use the matching arm64/x64 pkg URLs. These paths become
available only after publication. The source and pkg contain all three exact
archives from `candidate-packages/manifest.json`; their npm names are unchanged.
No registry installation of these packages and no plugin release download is
needed. Upstream Node, managed Paseo, provider CLI and Python dependencies still
use the existing pinned network downloads.

`release.yml` validates VERSION against the requested version/tag, builds the
three platform trees, verifies installed shared-runtime gates, and packages
unsigned Mac candidates on manual dispatch. Frozen tgz files are copied unchanged,
never rebuilt with `npm pack`. Its aggregate Actions artifact includes SHA256s,
source commit/tree and run identity. Manual dispatch has read-only repository
permission and does not publish anything.

An explicitly pushed version tag retains the existing source/prebuilt install
release route: all three platform trees, checksums, frozen tgz files and the
exact tag-build receipt are attached to the GitHub Release. Only this conditional
job has contents:write. It excludes unsigned `.pkg` files and does not wait for
maintainer Mac signing. Authorizing the tag is the public-promotion boundary.
The tag build records its actual commit and Git tree, not the earlier PR head.
A merge commit may differ from the reviewed head while retaining the same tree;
compare both identities, and review any tree change before authorizing the tag.

The tree receipt binds the native version, OS/architecture, pinned Pi Web source,
combined patch and all frozen package hashes. Packaging cannot restamp an older
tree. Installing an older/mismatched tree fails before replacing an existing
installation. Full Mac CI exercises both source install and this artifact path,
including credential-free lifecycle and identity retention. Package expansion
compares all three archives byte for byte.

Public Mac packages still require Developer ID Application and Developer ID
Installer signatures, accepted notarization and staple verification. Existing
`build-macos-pkg.sh --release` enforces those gates. For embedded Pi Web use the
existing `sign-macos-piweb-artifact.sh` first; that produces a separately reviewed
signed tree without modifying the three frozen archives. Never label the CI
unsigned pkg as a signed ordinary-user release.

The existing automatic Pi Agent signer in `WOOWTECH/woowtech-smart` serves the
separate Windows EXE preview route, not Mac pkg. Its secret names are
`ESIGNER_STOREPASS`, `ESIGNER_CREDENTIAL_ID`, `ESIGNER_TOTP_SECRET`. The current
WSL2 route runs the Linux installer inside Ubuntu and needs none of them.
No native Mac signing secrets or native self-hosted runner were visible in the
2026-11-21 repository metadata check. Secret presence is not a credential test;
organization-level access was not established. No secrets were read or copied.

After exact artifact review, release owners may authorize the matching source/tag
and prebuilt assets independently, then verify anonymous normal-install URLs.
Signed `.pkg` preparation and signature verification remain separate. This task
does not grant publication. CI does not establish actual user Mac provider,
Windows host, or HA Supervisor upgrade acceptance.
