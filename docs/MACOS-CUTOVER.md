# macOS: session home, and handing over a Mac's existing Omnigent host

`pi-agent-session-home` (docs/SESSION-HOME.md) was Linux/systemd only. On macOS it is
now `rootfs/bin/pi-agent-session-home-macos`, reached through the same command. It adds
one thing Linux did not need: **`cutover`**, which replaces the Omnigent host the Mac
already runs under launchd with this install's host **without losing a single
conversation**.

```
pi-agent-session-home enable | disable | status | restart [--in N]     same as Linux
pi-agent-session-home cutover [--dry-run] [--apply] [--force] [--allow-running ID[,ID]] [--in N]
pi-agent-session-home uncutover [--in N]
```

## Why a cutover, and why it keeps the conversations

A Mac that has used Omnigent for a while runs its host as the launchd job
`ai.omnigent.host`. Its conversations are *bound to that host on the server*: the host is
a row (`host_id`, `name`) and each conversation points at it. Starting this install's own
host next to it does not replace it; it adds a second host with the same machine name, and
the server then treats the two as one (it identifies a host by id **and**, per account, by
name). On every reconnect it deletes one row, re-creates it, and repoints the
conversations at whichever daemon connected last. That is exactly what happened on the
first Mac this was installed on (docs/OPERATIONS-GOTCHAS.md).

There are two ways to replace a host:

| | new id, old name | **adopt the old identity** (this) |
|---|---|---|
| what the server sees | a *different* host claims the name | the *same* host reconnects |
| server effect | `_rotate_host_id`: bound conversations set to none, old row deleted, new row inserted, conversations repointed | a plain update of the existing row |
| conversations | follow the rotation, if it goes right | never move |
| the plugin's resume check | `GET /v1/hosts/<id>` is **404** until the host has connected, and the plugin only starts the host *after* that check passes: a deadlock, seen here | the row exists, so the check passes |
| the same-name guard of the other lane | refuses unless told to take over | sees one host id for the name: nothing to refuse |
| evidence you can read afterwards | none that nothing was lost | host id, name and every binding, compared before and after |

So `cutover` writes the old `host_id` and `name` into this install's Omnigent
`config.yaml`, has the plugin re-save its connection receipt for that identity, retires
the old launchd job and lets this install's host come up as the same host.
`tests/session-home-macos.sh` includes a negative control that reproduces the rotation
with a new id under the old name (its last section) so the difference is not just an
argument.

## Before you start: the install must be new enough

The cutover relies on two things an update of the install provides, and the preflight
refuses to start without them (with the message that says what to do):

- `bin/pi-web-start.sh` that reads `session-home.state` (the macOS part of session home);
- the Omnigent plugin patched to start its host with the real `HOME`
  (`omnigent-plugin-session-home-patch.mjs`, applied by `pi-web-start.sh` at every service
  start, so: update the install, then restart the service once).

An install made by v0.2.1 or earlier has neither. Update first (the v0.2.2 package, or
`install.sh` again), restart the service, then dry-run.

## What it does, in order, and why

1. **Preflight** (also what `--dry-run` prints; read-only; reports every blocker):
   the old host's server row exists, is online, carries the name its config says, and
   belongs to this login; no conversation bound to it is busy (`--allow-running ID` for
   one you accept to cut off, `--force` for all); no Omnigent host is running that is
   neither the launchd job nor this install's; no other launchd job starts a host; this
   install's service is loaded and answering; the plugin's login is confirmed for the
   same server (its repair must not need a password); the install is new enough (above);
   enough disk; the two configs name the same server.
2. **Back up** the old config and tokens, the three launchd plists, this install's
   config, **the plugin's `connection.json` and `state.json`**, `~/.claude.json`,
   `~/.codex/config.toml` and the skill directories, with a checksum manifest, to
   `$PI_AGENT_HOME/backups/cutover-<time>/`.
3. **Retire** `ai.omnigent.host` and `ai.omnigent.og016watch`: `launchctl bootout`,
   `launchctl disable`, and *move* (never delete) the plists to
   `~/Library/LaunchAgents/.pre-pi-agent/`. Once `~/.omnigent` is a link, the old job's
   script (`~/.omnigent/bin/host-service.sh`) is gone and `KeepAlive` would retry it
   forever, so this step is not optional.
4. **Wait for the server** to show the old host offline. Two daemons with one id on the
   tunnel at once is the thing to avoid.
5. **Stop this install's service and host.** The service first, so nothing relaunches the
   host while we change its identity; then `omnigent host stop`, because on macOS the
   plugin cannot see a running host (it looks in `/proc`) and would start a second one.
6. **Park `~/.omnigent`** (renamed to `~/.omnigent.pre-pi-agent`, never deleted), link it
   to this install's directory, hard-link `codex-native`, `pi-native` and `attachments`
   across (same as Linux `enable`).
7. **Adopt the identity in `config.yaml`**: `host.host_id` and `host.name` from the old
   config go into this install's config; anything the old config has and this one lacks
   (the `runner` block, providers such as `pi-original`) is added; nothing this install
   already has is overwritten. A provider added this way loses its `default` marker,
   because two defaults for one family would be ambiguous.
8. **Write the state file** (replaces the systemd drop-in): `REAL_HOME=` makes
   `pi-web-start.sh` export `PI_AGENT_SESSION_HOME`, which the plugin patch hands to the
   host as its `HOME`; `HOST_PATH=` (the PATH the old job ran with) is appended *after*
   this install's own directories, so the user's tools are found by sessions and the
   wrappers still win.
9. **Let the plugin refresh its own receipt: `pi-omnigent repair --server <server>`,
   with the service still down.** The plugin refuses to resume a host whose id differs
   from the one in `connection.json`, checked before it starts the host, and that file
   still names this install's old identity: the next service start would end in
   `connection_identity_mismatch` and no host at all. (Its wait loop would also poll the
   old `(pi-agent)` row, which must stay as it is.) `repair` is the plugin's
   `initialize` -> `connect`, which has no such check: it starts the host from the config
   written above, waits until the server shows it online and saves the receipt itself.
   It runs under `env -i` -- an Omnigent runner's `OMNIGENT_RUNNER_*` variables must not
   leak into the host it starts -- with only `PATH`, `PI_AGENT_HOME`, the real home as
   `PI_AGENT_SESSION_HOME`, and `USER`/`LOGNAME`/`LANG`/`TMPDIR`. It needs no password
   because the plugin's login is confirmed (preflight). Then, before going on, the
   cutover checks that `connection.json` names the adopted host, that a host of this
   install is running with the real `HOME`, and that the **server** shows the adopted
   host online.
10. **Start the service.** Its plugin resumes: the config and the receipt agree, the row
    exists, and the host is already running (the plugin starts another one anyway, since
    it cannot see the first on macOS; the registry refuses it and the first stays).
11. **Verify on the server**, not just locally: the old host id is online, under the old
    name, and every conversation that was bound to it still is.

Any failure from step 2 on runs the rollback. It also restores `connection.json` and
`state.json` byte for byte (what the repair rewrote is kept under `after-cutover/` in the
backup). `uncutover` runs the same rollback later, and so does the next login if the
machine dies half way: the worker's own plist is still there, sees a run that never
finished, and rolls back instead of continuing. Everything is journalled in
`$PI_AGENT_HOME/cutover.journal`.

One deliberate difference from the order first sketched: the scoped host is stopped
*before* `config.yaml` is written, not after, so a running host never sees its identity
change under it. The invariants are the same: the old host is offline on the server, the
scoped host is gone, and the identity is in the config, all before the repair runs; and
the repair runs before the service is started.

The work runs in a **one-shot LaunchAgent that removes its own plist** (the same pattern
as the host rename that preceded this). It has to: stopping the old host ends every
session it serves, including the one that may have typed the command. The command returns
at once; `--in N` (default 10 s) is the grace period.

## Runbook

From a terminal in the logged-in session (launchd's GUI domain is not reachable over ssh):

```sh
P=$HOME/.local/share/pi-agent/bin/pi-agent-session-home
# once: update the install (v0.2.2 or later) and restart its service, see "Before you start"
$P cutover --dry-run                     # read-only. Blockers, then the plan. Run it as often as you like.
# quit Omnigent.app if it is open; note which conversations are busy
$P cutover --apply --in 30               # add --allow-running <id> for a conversation you accept to cut off
tail -f ~/.local/share/pi-agent/logs/session-home.log
tail -1 ~/.local/share/pi-agent/session-home.result     # RESULT: OK ... / ROLLED BACK ... / NOT STARTED ...
$P status
# go back, any time, including after a successful cutover:
$P uncutover
```

Run from inside an Omnigent conversation served by the host being replaced, the busy
conversation is that very one: give its id to `--allow-running`, and expect to reopen it
afterwards (it is bound to the same host, so it comes back).

### What the owner will notice

- Every session the old host served ends; they resume on reopening. Their transcripts
  are untouched (Claude's under `~/.claude/projects`, Codex's under `codex-native`).
- macOS may ask again for access to Desktop, Documents or Downloads, because the new host
  is a *different python* (this install's, not the old `uv` tool) and privacy consent is
  per program. This was not testable here.
- The plugin's repair may register the engines' agents on the server for the adopted
  host, as it did for the old `(pi-agent)` host; if they exist already it reuses them.
- A second row, `<hostname> (pi-agent)`, stays on the server, offline. It is this
  install's old identity; it is harmless and is deliberately not deleted.
- `launchctl print-disabled gui/$(id -u)` lists the two old labels as disabled until
  `uncutover` (which enables them again).
- macOS may show a "background item added" notice for the one-shot job the cutover (and
  `restart`, `uncutover`) schedules; it removes its own plist when it finishes.

## Omnigent.app (the desktop app)

Read-only look at `/Applications/Omnigent.app` (0.18.1, Electron, `app.asar`):

- It **installs no service**. There is no `LaunchAgents`, `launchctl` or plist handling
  anywhere in the bundle. `ai.omnigent.host` came from someone's setup script, so the
  app will not bring it back.
- When it connects it runs `ensureHostConnected`: if a live daemon for that server is in
  the registry (`<state dir>/daemons/*.json`: live pid and an online tunnel) it **adopts**
  it ("ownedByDesktop: false", never kills it); otherwise it **spawns** `omnigent host
  --server URL --non-interactive` itself and kills that child when the app quits.
- So: before the cutover it adopts the old daemon; after it, `~/.omnigent` is the link,
  the registry it reads is this install's, and it adopts *this* host rather than starting
  a second one. The link is also what makes a second host impossible (the registry
  refuses a second daemon for one server).
- The risk is the gap between the old host dying and the new one starting: an app that is
  open could decide to start its own host. Such a host reaches this install's directory
  only through the `~/.omnigent` link, with no `OMNIGENT_CONFIG_HOME`, whereas every host
  the plugin starts is pinned to it. The classification therefore never counts it as this
  install's: preflight and the post-stop check refuse it, and the local verification --
  which looks for a host of this install, running with the real `HOME` -- fails and rolls
  the cutover back instead of passing on the strength of a host the plugin did not start
  and will not bring back. Quitting the app for the few minutes avoids the question.

## The same-name guard (v0.2.2)

The guard that refuses to start a host when *another* host id of the account holds its
name (`omnigent-plugin-host-name-guard-patch.mjs`, docs/OPERATIONS-GOTCHAS.md §13)
excludes rows whose `host_id` equals the local identity, so after the config carries the
old id **and the exact old name** (as the cutover writes it) it has nothing to refuse.
Both halves are tested where they live: the cutover sandbox asserts the pass condition
(exactly one row holds the name, and it is the id in the config), and
`tests/host_name_guard_test.py` case E3 runs the real patched `ensure_host` against a stub
server whose only same-named row is the host's own id, and expects the host to start (E3b:
also when the server spells the id dashed and upper-case). The cutover's `repair` step
therefore passes the guard; and because the stale `<hostname> (pi-agent)` row has a
different name, it is never a collision either.

## Test hooks

`rootfs/bin/pi-agent-session-home-macos` reads `PI_SH_*` variables for the tests, and
nothing in production sets them: `PI_SH_REAL_HOME`, `PI_SH_PYTHON`, `PI_SH_OMNIGENT`,
`PI_SH_SERVER`, `PI_SH_SERVICE_LABEL`, `PI_SH_OLD_HOST_LABEL`, `PI_SH_OLD_AUX_LABELS`,
`PI_SH_WORKER_PREFIX`, `PI_SH_HOST_FILTER` (only host processes whose command line
contains this text count, so a test cannot see the real daemons), the waits
(`PI_SH_POLL`, `PI_SH_HEALTH_TRIES`, `PI_SH_OFFLINE_TRIES`, `PI_SH_ONLINE_TRIES`,
`PI_SH_EXIT_TRIES`, `PI_SH_REPAIR_SECS`, `PI_SH_MIN_FREE_MB`) and `PI_SH_STEP_PAUSE` (a
sleep after each step, to interrupt the worker). `schedule` copies them into the worker's
plist; the plugin's `repair` does not get them (`env -i`).

## Tests

`tests/session-home-macos.sh` -- real launchd jobs (labels `io.woowtech.pa-shtest.<pid>.*`)
and fake hosts under a throw-away fake home, against a stub of the server API on
127.0.0.1 that also reproduces the server's host rotation. A fake `pi-omnigent` records
how it was called and does what `repair` does; a fake pi-web does what the plugin's
resume does on macOS (the identity gate, then always start a host). It never touches
`~/.omnigent`, `ai.omnigent.*`, `io.woowtech.pi-agent` or a real server.
See docs/TESTING.md for the counts. Covered: the config merge (adopts, never overwrites,
strips `default`, refuses two servers, parses with omnigent's own `load_providers`);
`enable` refusing a live old host; a dry run that changes nothing (whole-tree checksum
before and after) and never runs the plugin CLI; each blocker, including a login that is
not confirmed and an install that is not new enough; the cutover and everything it should
leave behind; the plugin's repair run once, under `env -i` (a decoy variable did not
leak), with the real home handed over, before the service was started, in that order in
the journal; server-side evidence including that no row was rotated; the classification
of a host that is not pinned; `restart` and a detached job that outlives its killed
parent; `uncutover` restoring every plist, the parked directory, the config and the
plugin's `connection.json` and `state.json` byte for byte; six forced failures (the
server renames the host, the server drops the bindings, the host cannot start with
session home, the repair fails, the repair "succeeds" without saving the receipt, the
service does not come up) each rolling back completely; a rollback that cannot confirm
everything saying so and `uncutover` finishing it; a worker killed half way and recovered
by the next login; `enable`/`disable`
byte for byte; the same-name rotation as a negative control.

**Not covered** (and why): the real `ai.omnigent.host` job's SIGTERM behaviour; the real
plugin's `repair` (the fake does what the plugin's source says it does -- read, not run:
running it would touch the live install, though it did work when used earlier to recover
the host rename); the server's real reaction to a reused host id (only the stub, built
from the server source read earlier; the cutover's own server check is what protects
against a surprise); Omnigent.app at run time (static analysis only); macOS privacy
prompts; a reboot in the middle (the logic is tested with a killed worker, not a real
reboot); Windows; the woowtech MacBook, which was deliberately not touched.
