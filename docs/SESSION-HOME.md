# Session home: Omnigent sessions with the user's own HOME

By default this install scopes `HOME` to `$PI_AGENT_HOME/home` for everything it
starts, the Omnigent sessions included. `pi-agent-session-home enable` switches
the sessions — and only them — to the user's real home.

## When you need it

Scoping is right for a **test** install that must not touch the machine owner's
setup (the macOS case in `MACOS.md`: the owner had their own live Omnigent).

It is wrong once the install **replaces** the owner's previous pi-agent. Their
conversations then resume with nothing from their real home. Measured on a
workstation cut over from an older native install whose Omnigent host ran with
`HOME=/home/<user>`:

| | before the cutover | after, scoped HOME |
|---|---|---|
| MCP servers (`~/.claude.json`) | 15 | 0 |
| Claude Code plugins | 3 (incl. the user's main workflow plugin) | 0 |
| `git commit` | works | `Author identity unknown` |
| gh, `~/.ssh`, `~/.git-credentials` | present | `not logged into any GitHub hosts` |
| `~/.espressif`, `~/.nvm`, `.bashrc` | present | invisible |

PATH was unaffected (its entries are absolute), and so was kubectl
(`KUBECONFIG` is an absolute path). Everything keyed on `$HOME` was not.

## Why the host, not the wrappers

The obvious fix — set `HOME` in the `claude`/`codex` wrappers — breaks Omnigent.
Its claude harness resolves Claude's files from `Path.home()` **inside the
runner process**, not the harness:

```
harnesses/claude_native/status_file.py   Path.home()/.claude            (status files)
harnesses/claude_native/bridge.py:215    Path.home()/.claude/settings.json   import-time constant
harnesses/claude_native/bridge.py:1787   Path.home()/.claude.json
harnesses/claude_native/main.py:269      Path.home()/.claude/projects        import-time constant
```

So the runner and the harness must agree on one `HOME`, and runners are forked
from the host. The plugin starts the host itself (`src/omnigent.py`, a copy of
its own environment), so `omnigent-plugin-session-home-patch.mjs` makes it set
`HOME` from `PI_AGENT_SESSION_HOME` when that is present. pi-web and the plugin
keep the scoped `HOME`: their launcher shims and state stay inside the install.

### The wrappers must not rely on an environment variable

The first version had the wrappers restore `HOME` from `PI_AGENT_SESSION_HOME`.
It never arrived: omnigent starts harnesses with an allowlisted environment
(`inner/os_env.py`), so the variable set on pi-web was dropped on the way —
measured, 0 occurrences in the harness's tmux and in claude. The wrappers then
re-sourced `pi-agent-env.sh` and put claude back on the scoped `HOME`, while the
host itself ran with the real one and the restart's health check passed.

The wrappers now key off `$PI_AGENT_HOME/session-home.state` and keep the `HOME`
they were called with. That is the right value for every caller: the runner
(the real home, once the host has it), each codex session (omnigent gives it a
private `HOME`, which the old forced value used to overwrite), and pi-web's own
terminal (scoped, as before). Measured with the fixed wrapper: called with the
real home, `claude plugin list` shows the user's plugins; called with the scoped
home, none.

## Why `~/.omnigent` becomes a link

omnigent hardcodes `Path.home()/.omnigent` in about twenty places. The
identity-bearing ones go through `config.global_config_path()` and honour
`OMNIGENT_CONFIG_HOME`, which the plugin pins — so the host never reads the
wrong identity. The rest do not: `runner/identity.py` (runner id),
`codex_native/bridge.py` (codex bridges and rollouts), the model-catalog cache,
logs, the install ledger. With a real `HOME` those would write into whatever
`~/.omnigent` already holds — on a cut-over machine, the previous install's
directory — so two installs' state would mix and deleting the old one later
would delete part of the new one.

`enable` therefore parks an existing `~/.omnigent` (renamed, never deleted) and
replaces it with a link to this install's Omnigent directory. Every path, env
var or not, then lands in one place.

The parked directory's **session state** is hard-linked in: `codex-native`
(Codex keeps a conversation's real context in its rollouts there — without it an
old codex thread opens but Codex has lost its own memory of it), `pi-native`,
`attachments`. Hard links cost no space and leave the parked copy complete for a
rollback.

## The user's own files in the real home

`pi-agent-share-state.mjs` (shared skills/MCP) was written for the container,
where `HOME` is the data volume and moving a real directory into the shared tree
is a migration. In a user's own home the same move would carry their existing
skills into this install's data dir, where an uninstall deletes them. So when
`HOME` is outside `$PI_AGENT_HOME` it:

- never moves, replaces or relinks an existing file, directory or link — only
  creates a link where nothing exists;
- does not create `~/workspace` (a container convenience);
- rewrites `~/.claude.json` only when the managed MCP map changed (Claude Code
  rewrites that file constantly; an unconditional rewrite races those writes),
  and `~/.codex/config.toml` only when its content changed — never an empty one.

### Pi is the one engine whose data is not under `HOME`

Claude and Codex keep their login and settings under `HOME`, so keeping the caller's
HOME is enough. Pi keeps its models, login and settings in a single directory chosen by
`PI_CODING_AGENT_DIR`, and `pi-agent-env.sh` points that at this install's data dir. A
scoped `pi` that kept the user's HOME but that directory found **no models at all**
(Omnigent: `MODELS_UNAVAILABLE`) although the user's own `~/.pi/agent` had them — found
on the first Mac cut over, where Claude verified fine and Pi did not.

So while session home is on, the `pi` wrapper points `PI_CODING_AGENT_DIR` at the
caller's own `~/.pi/agent` when two things hold: the caller runs with the user's own HOME
(which is what the Omnigent host hands to its sessions), **and that directory holds a Pi
configuration — a `models.json` or an `auth.json`**. A user with no Pi of their own keeps
this install's data dir, where `pi-agent-litellm` put the gateway; redirecting them would
leave Pi without models. A caller with this install's HOME (pi-web's own terminal) keeps
the install's data dir too, and a directory the caller chose itself is honoured unless it
is just the inherited scoped default. `tests/pi-wrapper-session-home.sh` pins all of
this, and fails against the wrapper published in v0.2.2.

Two consequences to know:

- **One Pi directory, one set of models.** A user whose `~/.pi/agent` has its own
  `models.json` sees only those providers in Omnigent sessions; a gateway that lives only
  in this install's data dir is not offered. Add it to the user's file (the `litellm`
  provider block of `<install>/data/models.json`; the key stays an `${LITELLM_API_KEY}`
  reference). Done on the first Mac and tested first on a copy with the Pi that wrote the
  file and the newer one: both list the old and the added models, and without the key the
  gateway's models are simply not shown.
- **The scoped `pi` can be newer** than the one that wrote the user's directory (1.4.0
  over 0.85.0 on that Mac) and writes there. Measured: after a session, the only changes
  under `~/.pi/agent` were `settings.json`'s `lastChangelogVersion` and a clean-up
  time-stamp. `enable` and `cutover` back `~/.pi/agent` up first (`pi-agent-dir.tgz` in
  the backup directory).

## Use

```
pi-agent-session-home enable     # backups, park + link ~/.omnigent, systemd drop-in
pi-agent-session-home restart    # detached; health-checks; auto-disables on failure
pi-agent-session-home status
pi-agent-session-home disable    # removes the drop-in, restores the parked ~/.omnigent
```

`enable` refuses while another Omnigent host serves the real `~/.omnigent` —
that is someone's live integration, not this install's to move.

`restart` runs in its own transient systemd unit, because restarting the host
ends every session it serves, including one that may have run the command. It
waits for pi-web to answer, for this install's host to be running with the
expected `HOME`, and for the plugin to report it connected; if that does not
happen it runs `disable` and restarts again. Its log is
`$PI_AGENT_HOME/logs/session-home.log`.

Backups of what sessions will now write to (`~/.claude.json`,
`~/.codex/config.toml`, the user's own skill directories) go to
`$PI_AGENT_HOME/backups/session-home-<timestamp>/`.

## macOS

`pi-agent-session-home` hands over to `pi-agent-session-home-macos` on Darwin: same
commands, with launchd where Linux has systemd.

- There is no drop-in. `enable` writes `$PI_AGENT_HOME/session-home.state`;
  `pi-web-start.sh` reads `REAL_HOME=` from it and exports `PI_AGENT_SESSION_HOME`, and the
  wrappers already key off the same file. (Darwin only; Linux keeps its drop-in.)
- Processes are read with `ps eww` instead of `/proc`. That shows the environment of
  same-user processes that are not Apple system binaries, which covers the python Omnigent
  hosts. A host whose environment cannot be read is treated as *unknown*, never as fine.
- `restart` runs as a one-shot LaunchAgent that removes its own plist, and checks health the
  same way (pi-web answers, our host runs with the expected `HOME`, the plugin reports it
  connected), reverting on failure.
- A Mac that already runs its own Omnigent host under launchd is the usual case, and `enable`
  refuses it. **`cutover`** replaces that host and keeps its conversations by taking over its
  host id and name; see docs/MACOS-CUTOVER.md.
