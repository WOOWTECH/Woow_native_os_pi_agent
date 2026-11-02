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
