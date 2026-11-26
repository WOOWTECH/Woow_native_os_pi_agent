# Native release preparation

## 0.2.16-rc.4 preparation — paired Omnigent input pending

- Agent Connect `0.1.27-rc.4` immutable tuple received: source commit
  `a895f725aad645e7594c8405aac17aca409b3558`; candidate archive
  `phone-selected-release-rc4/artifacts/woowtech-pi-paseo-0.1.27-rc.4.tgz`,
  SHA-256 `3fe3f9e7bad463c6a007703a8db67c2de320b061e93ba7bc79339cae68fe937b`.
- Omnigent `0.3.42-rc.4` exact paired source and archive are pending from Dirac.
  Do not swap either package into `candidate-packages/`, refresh package pins,
  overlay guards, Linux member hashes, or owned-acceptance locks until that
  tuple arrives and the pair metadata is verified.
- Native `VERSION` is `0.2.16-rc.4`; only native-version assertions and this
  preparation documentation have advanced. The frozen packages and hash-bound
  controls intentionally still describe rc3, so this intermediate tree is not
  an rc4 build and must not be packaged or accepted as one.
- Once both tuples are present, follow
  [`docs/plans/2026-11-26-native-rc4-preparation.md`](plans/2026-11-26-native-rc4-preparation.md)
  and the non-circular source-authority procedure below before running final
  native checks.

## 0.2.16-rc.3 shortcut recording candidate

- Agent Connect 0.1.27-rc.3 includes the exact Smart `2b012f9f91377908c75b076c40a5917c712b66aa` builtin payload in `0.17.5-r3-8664f2c3f8f5`. Verified r2 and r1 control paths remain available; existing runtime directories are not overwritten.
- Omnigent 0.3.42-rc.3 requires this exact Agent Connect version. Pi Web source and combined adapter code remain unchanged.
- Shortcut recording needs both this builtin payload and the matching Smart Web keyboard guard. Installing the runtime alone does not fix an older Web client.
- Frozen archives, source commits, Linux overlay member hashes and acceptance authority are regenerated together. Isolated r2→r3→r2 and 0.17.4→r3→0.17.4 checks retain identities, pairing, workspaces, Tasks and configuration.
- Candidate only. aicoder acceptance uses the exact preview origins and separate evidence; this does not promote the Woowtech/Apporo production Web or update other hosts.

## 0.2.16-rc.2 preference persistence candidate

- Agent Connect 0.1.27-rc.2 ships exact Smart a61efefca builtin bytes in a separate 0.17.5-r2 runtime; keeps verified r1 for rollback.
- Omnigent 0.3.42-rc.2 pins this exact contributor. Combined Pi Web code and patch digest remain unchanged.
- The frozen archives, source commits, Linux overlay member hashes and acceptance authority are refreshed as one pair.
- Candidate only; aicoder real UI persistence and data preservation must be verified before describing it as accepted.

## 0.2.16-rc.1 coordinated candidate

- Agent Connect 0.1.27-rc.1 is paired with the Paseo 0.17.5 runtime at
  `0.17.5-r1-8664f2c3f8f5`; source commit
  `e4c568ce3214592574f11243acf5ed7db743d47e`, archive SHA256
  `f91b7daa16cc0d86907507fc21d5f87ec021c0ee0a9a93b47c7864debd10c52b`.
- Omnigent 0.3.42-rc.1 is paired to that Agent Connect source; commit
  `a79eb5cb891a7807f8aa665c6ef0b59b25fcc860`, archive SHA256
  `ada685198ba0a06d3a73e935c063857dfc7bbef5ab612d74c1a80d4bb41d4ede`.
  Its combined adapter bytes remain SHA256
  `13775483ce327a544b2604f4205db11ec0eec516e0765c44bebf72a133503dbb`.
- The four native Omnigent overlays accept only the exact new prerelease in
  addition to their reviewed versions. The three Linux overlays were regenerated
  against the paired archive and their installed member hashes are locked.
- Native artifact receipts now accept valid SemVer prerelease package filenames
  while retaining exact source, archive digest and receipt checks. Candidate
  archives have no stable release URL or stable-release status.
- The official CLI pin is 0.17.5. Pi Web remains pinned to source
  `6fcd7d44981ab51a21d6cd6eb06d361d0e3d3068`; the coordinated build is performed
  separately from this source change and must write its receipt against the
  final native candidate commit.

## 0.2.15

Changes from 0.2.14:

- Agent Connect 0.1.26 (pi-paseo-plugin #27, merged as
  `23026e2442403ddee8df9f764ded6ea1a75b121e`) fixes the Start service feedback.
  A scheduled start remains tracked until ready, can still be stopped while
  preparing, and does not become a repeatable action after a failed status
  read. Unsaved or pending target changes require an explicit save and
  stop/start. Requests and startup tracking have finite deadlines; an unknown
  result is shown without automatically retrying a state-changing request.
  The verified release archive SHA256 is
  `87fcc99b371ef8acbb694884ae3b8654e50f9270651062ac55d37090734f3825`.
- Omnigent 0.3.41 (pi-omnigent-plugin #38, merged as
  `b481f9cd74e269a3f52a5cbf62713e252573c075`) contains the matching combined
  Pi Web adapter and requires Agent Connect 0.1.26. Its verified release
  archive SHA256 is
  `7de928d37def9feec4476674da82979c2bdb24adb3cd9413188959410120ad4e`;
  the combined adapter SHA256 is
  `13775483ce327a544b2604f4205db11ec0eec516e0765c44bebf72a133503dbb`.
- The four reviewed Omnigent overlays accept 0.3.41. The candidate manifest,
  installed Linux member inventory and owned acceptance authority are updated
  together, using the merged sources and byte-verified public release assets.

Paseo 0.17.4, runtime revision `0.17.4-r2-a651f42711da`, Better Paseo 1.7.0,
Pi Web 0.10.0, shared runtime 0.1.6 and managed Omnigent 0.16.0 stay unchanged.
The UI fix does not change saved authentication, pairing identities or data
formats. Reload Pi Web after installing to use the new settings component;
this UI-only update does not require restarting a healthy r2 daemon.

The Agent Connect and Omnigent PR checks passed, including 128 Agent Connect
host tests, 144 combined UI tests, TypeScript and production builds. Isolated
Chromium tests cover all three brands at desktop and 390px widths. These
results do not establish field acceptance or authorize interrupting a host
reserved for another test session. Existing moderate dependency advisories
remain outside this UI fix.

## 0.2.14

Changes from 0.2.13:

- Agent Connect 0.1.24 → 0.1.25 (pi-paseo-plugin #25, merged into main as
  `43cc7b0623c47afdbad6e35e0df7bd03dd5c72d3`); the frozen archive remains
  `woowtech-pi-paseo-0.1.25.tgz`, sha256
  `9717988c00a4c830a3fa458ab1ae778515c90257faaac0e68e695fefbf7cd8d1`.
  The source provenance pin uses the final merge commit. Official Paseo remains
  0.17.4; Agent Connect adds Better Paseo Tasks from runtime revision
  `0.17.4-r2-a651f42711da`. Tasks is enabled by default, while chat enhancement
  and automatic update checks are disabled by default. A normal stop/start
  switches the daemon to r2 while retaining the existing `PASEO_HOME`, including
  Tasks data, server identity, pairing key, conversations and settings. Rollback
  keeps that data directory and can reuse the retained r1 runtime.
- Omnigent plugin 0.3.40 (pi-omnigent-plugin #37, squash merge
  `a36f260d680d8334206e4b794a7c4bcd8dd2e99f`) is paired with Agent Connect
  0.1.25. The full PR CI passed; the frozen archive SHA256 is
  `4763b1bc98eb64a7f8cba890a9c7fdf8907a3cab001eb5ccaa246cd45642a846` and its
  combined Pi Web adapter SHA256 is `5e2c36b43f56e9ca8c3c2873d94102a86c75b74973cc23b278c34a2556e678a5`.
- The four Omnigent overlays extend their reviewed maintenance-aware version
  gates through 0.3.40. Host-name fixture output checks include the two-digit
  version 0.3.40.
- Pi Web 0.10.0, shared runtime 0.1.6, and managed Omnigent 0.16.0 stay
  unchanged. The official Paseo CLI stays 0.17.4; only the managed runtime
  revision changes to r2.

The frozen Omnigent archive, combined adapter digest, candidate manifest,
installed Linux member inventory, owned source lock, and installer-input lock
are pinned together to the merged source and the byte-verified release archive.

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
