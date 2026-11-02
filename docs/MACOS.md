# macOS (native, non-container)

Status as of 2026-11-01, verified on an **M2 MacBook Air, macOS 26.4.1, 8 GB RAM**
(`arm64`), from a clean state — no previous pi-agent install.

## What works natively today

| Piece | State |
|---|---|
| Installer stages `preflight node fetch clis piweb` | ✅ verified on-device |
| Scoped Node 22 (`darwin-arm64`) | ✅ installed under `$PI_AGENT_HOME`, system Node untouched |
| Claude Code 2.1.296 + Codex 0.162.1 | ✅ run natively (`claude-code-darwin-arm64`, `codex-darwin-arm64`) |
| pi-web built from source + Omnigent/Paseo settings patch | ✅ both settings routes compile; `node-pty` uses the `darwin-arm64` prebuild |
| CJK path patch | ✅ applied |
| Skill / MCP sharing (`pi-agent-share-state.mjs`) | pure Node, no platform assumptions |
| launchd user agent | installer writes `~/Library/LaunchAgents/io.woowtech.pi-agent.plist` |
| Omnigent / Paseo **plugin** runtime | ⛔ blocked — see [Phase B](#phase-b-the-plugin-darwin-port) |

## Host requirements

**Neither Homebrew nor the Command Line Tools is required for the `.pkg`
install** (the prebuilt pi-web path). What runs is part of macOS itself —
`curl`, `bsdtar` (which reads `.tar.xz` through libarchive, so no `xz` binary is
needed) and `/usr/bin/perl` — or is installed scoped under `$PI_AGENT_HOME`:
its own Node, the pinned **uv** binary, uv's own CPython for the Omnigent venv,
a `flock` shim and the bundled `tmux`.

Be careful what "part of macOS" means here: `/usr/bin/git` and
`/usr/bin/python3` exist on every Mac, but without the Command Line Tools they
are **installer stubs** that open a dialog and fail. So `command -v python3`
proves nothing. The installer and the service avoid both:

- **uv** is the pinned standalone binary from astral-sh/uv releases, verified per
  target triple against `lib/pins.sh`, and installed to `$PI_AGENT_HOME/bin/uv`.
  It used to be bootstrapped with `python3 -m venv` + pip. Being on `PATH` also
  matters for the Omnigent plugin: when it finds no `uv`, it bootstraps one with
  `python3 -m pip` itself (`src/installer.mjs`), which on a stub-only Mac blocks
  the Omnigent tab.
- **`pi-web-start.sh`** runs the model-options patch under the omnigent tool's
  own interpreter rather than `python3`.
- **Building pi-web from source** (the git-clone track) does need git and a
  compiler, and says so up front instead of tripping the stub.

`tmux` is **bundled in the `.pkg`**: Omnigent's native Pi harness runs the Pi
TUI inside a private tmux server, and Omnigent finds it with
`shutil.which("tmux")` — plain `PATH` order, where `$PI_AGENT_HOME/bin` comes
first. See [Bundled tmux](#bundled-tmux). A git-clone install has no bundled
tmux and falls back to Homebrew when present.

Note that a non-login shell (ssh, launchd) does **not** have Homebrew on `PATH`
even when it is installed, so the installer looks in `/opt/homebrew` and
`/usr/local` rather than trusting `PATH`.

**One leftover touch of the stub.** The plugin's dependency discovery still
probes `python3 --version` on every refresh, and a failed probe is not cached
(`src/installer.mjs`, `probe()`). On a Mac without the Command Line Tools that
probe runs the stub. Nothing depends on the result once `uv` is on `PATH`, but
it may surface the "install command line developer tools?" dialog. Fixing it
means shadowing `python3`, which would also change the `python3` that agent
sessions see — so it is left for the plugin to fix upstream.

## Bundled tmux

`scripts/build-macos-tmux.sh` builds the tmux that ships in the `.pkg`, into
`dist/tools-macos-arm64/` (`bin/tmux`, `licenses/`, `BUILDINFO`). The pkg
builder takes that directory as `tools/`, and the wire stage installs
`tools/bin/tmux` to `$PI_AGENT_HOME/bin/tmux`.

**Why not Homebrew's.** It cannot be redistributed: its binary is built for the
host it was poured on (minos 26.0 on the release host, so it will not start on
an older macOS), and it links four Homebrew dylibs — utf8proc, ncursesw 6,
libevent_core and jemalloc — at `/opt/homebrew` paths that do not exist on a
user's Mac.

**What is built.** tmux 3.8 with libevent 2.1.13-stable (core only, no OpenSSL)
and utf8proc 2.12.0 linked **statically**, the system ncurses from `/usr/lib`,
for arm64, `MACOSX_DEPLOYMENT_TARGET=13.0`. Every source tarball is pinned in
`lib/pins.sh` by the sha256 Homebrew records for the same formula. The build
runs with `PATH=/usr/bin:/bin`, so Homebrew's pkg-config cannot hand configure
its ncursesw.

**utf8proc is not optional.** Without it tmux takes character widths from the
system `wcwidth()`, which gets East Asian widths wrong — and the people using
this write Traditional Chinese. The build checks it rather than trusting
configure: the utf8proc symbols must be in the binary, and a private server
must echo `台灣報告` with the cursor at column 8 (four characters, two columns
each), then return it intact from `capture-pane`.

**jemalloc: left out, against upstream's advice.** Since 3.7c, tmux's configure
refuses to choose on darwin by itself and recommends `--enable-jemalloc` "to
avoid what appears to be a bug in calloc" (tmux issue 5385). This build passes
`--disable-jemalloc`, by decision. If that bug ever shows up as corrupt panes or
crashes, link jemalloc statically the same way as libevent; the binary's
dependencies would stay inside `/usr/lib`.

**The resulting binary** (2026-11-02): 1,749,960 bytes, `Mach-O 64-bit
executable arm64`, minos 13.0, linker-signed ad hoc; it links only
`/usr/lib/libncurses.5.4.dylib`, `/usr/lib/libSystem.B.dylib` and
`/usr/lib/libresolv.9.dylib`. `scripts/build-macos-pkg.sh --sign-app` replaces
the ad-hoc signature with Developer ID + hardened runtime + a secure timestamp.
And the pkg build refuses any payload where `tools/bin/tmux` is not the only
Mach-O.

## Portability bugs this found

All four were invisible on Linux and only appeared by running on the Mac:

1. **`mapfile` is bash ≥ 4; macOS ships 3.2.57.** The CJK-patch step died.
   Replaced with `find -print0 | xargs`.
2. **`tar -xJf`** asks GNU tar to shell out to an `xz` binary macOS does not
   have. `-xf` works on both — GNU tar and bsdtar each detect xz themselves.
3. **`stat -c %a` is GNU-only**; BSD stat needs `-f %Lp`.
4. **npm lifecycle scripts need `node` on `PATH`, not just a Node to run npm
   with.** `@anthropic-ai/claude-code`'s `install.cjs` runs through `sh -c` and
   calls a bare `node`; with only a scoped Node the install failed with
   `sh: node: command not found`. On any host that happens to have a system Node
   this works by accident, which is why Linux never showed it.

## Build sizing on small machines

The Next.js build is the only memory-hungry step, and its defaults are tuned for
CI machines: one worker per core, heap sized from total RAM. On an 8 GB laptop
with the owner's own work open that swaps the machine to a standstill. The
installer now derives both from the host (`lib/common.sh`):

| RAM | Workers (`CIRCLE_NODE_TOTAL`) | Heap cap |
|---|---|---|
| < 6 GB | 1 | 1536 MiB |
| 6–12 GB | 2 | 2560 MiB |
| > 12 GB | 3 | 4096 MiB |

On the 8 GB Mac the build completed at 2 workers / 2560 MiB. Swap grew to
4.9 GB of 6.1 GB and the machine stayed responsive. Budget ~**1.2 GB** for the
built pi-web tree and ~**560 MB** for the two CLIs.

## What the plugins actually needed (measured, not predicted)

The earlier design note in `DESIGN.md` §6 predicted that both plugins would
break on darwin — `flock` is absent, `/proc` does not exist, and several
`process.platform !== 'linux'` gates throw. Running it on the Mac showed that
prediction was **substantially too pessimistic**, and the difference matters
because it is the gap between "two days of security-sensitive porting" and one
allow-list:

| Predicted to break | Measured on macOS 26.4 / M2 |
|---|---|
| `locked()` → `LOCK_UNAVAILABLE` on every operation | **Never hit.** `status`, `doctor`, `install-host` and `activate` all succeed. `install-host` takes the non-Linux token-lock path by design; the flock helper is not on these paths. |
| Process identity from `/proc` | **Not on these paths either.** It gates host *adoption* and Paseo daemon *recovery*, which need a login first. |
| Omnigent settings tab unusable | **Tab is live**: `active=true`, `phase=new`, all three engines detected with versions, `issue=null`. |
| Paseo runtime linux-only | **Installs and verifies**: `@getpaseo/cli` 0.11.2 with the `darwin-arm64` packages, zero linux packages pulled. |

The **one** real blocker was `src/installer.mjs`:

```js
if (platform !== 'linux' || !['x64', 'arm64'].includes(arch)) {
  issues.push(`This plugin requires a Linux x64 or arm64 container ...`);
  return result();      // <- before any discovery
}
```

That `return` fires before discovery, so every dependency reports missing —
omnigent, uv, python, node and all three engines — and the tab is stuck on
`DEPENDENCIES_MISSING`. Widening that allow-list to include `darwin` is enough
for the plugin to bootstrap its own uv + omnigent and find everything:
`ok: true`, `issues: []`.

Two findings fell out of that:

- **`tmux` was already installed** (Homebrew, 3.8) but invisible, because
  Homebrew is not on `PATH` in a non-login shell or a launchd job. Fixed in
  `pi-agent-env.sh`, which now appends `/opt/homebrew/bin` on darwin — appended,
  so the scoped Node and wrappers still win. Omnigent's native Pi harness
  spawns `tmux` from there too.
- The **bubblewrap warning is noise on macOS**: `bwrap` is a Linux namespace
  tool that cannot exist there, and the advice ("add it to the container image")
  makes no sense on a laptop. Suppressed on darwin.

Both edits live in `rootfs/bin/omnigent-plugin-darwin-patch.mjs`, applied by the
`fetch` stage: version-gated to plugin 0.3.31, exact-anchor (a moved gate is
reported, never half-patched), idempotent, keeps a `.orig`, and never fails the
install — a Mac without it has a degraded Omnigent tab, not a broken agent.
**They belong upstream in `WOOWTECH/pi-omnigent-plugin`**; the patch exists only
until a release carries them, at which point the version gate skips it.

## Still open

- **`LOGIN_REQUIRED`** — the Omnigent server URL and credentials. Exactly where
  Linux sat before they were supplied; not a macOS matter.
- **Paseo is installed but not enabled** (`phase: not_installed`). Enabling it
  exercises the daemon paths, which is where `daemon-identity.mjs` and its
  `/proc` reads finally do matter. Those are the genuinely security-sensitive
  parts (they gate proving which process owns a daemon), and the honest options
  are in the section below. Nothing on the tested path depends on them.

## If the daemon paths are needed later

`/proc/<pid>/environ` is how both plugins prove a daemon inherited *our*
`PASEO_HOME` / Omnigent config rather than merely being a same-uid process of
the right name. There is no darwin equivalent — confirmed, `ps -Eww` yields
nothing useful — and approximating it would be a silent dependency on the target
not being hardened. The options, in order:

1. **Replace the evidence, keep the invariant.** Have the process we spawn hold
   a kernel lock inside the 0700 state dir (darwin's `O_EXLOCK` is ideal and was
   measured to release on SIGKILL), and treat *holding it* as the proof. A lock
   in a directory only we can write is a stronger claim than env equality, and
   it is portable — worth adopting on Linux too.
2. **Fail closed on darwin** for the "adopt an orphan from a previous run" path.
   The user reconnects; nothing is signalled on a guess.

What must not happen is emulating `environ` and calling it equivalent.

Cost to sign off on explicitly if that work starts: `ps -o lstart=` has
**1-second** resolution where Linux reads clock ticks, so a PID recycled within
the same second with the same uid compares equal. macOS pids reach 99998 before
wrapping, so this needs ~100k process creations in one second — infeasible in
practice, but a real reduction in the PID-reuse defence, and `comm` (a full path
on darwin) is the extra evidence that narrows it.

## Testing on a workstation that already uses Omnigent

A laptop is not a container: the Mac used for this already had **its own live
Omnigent integration** — `Omnigent.app` running, a registered host
(`ElmodeMacBook-Air.local`, its own `host_id`), 1.6 GB of session state under
`~/.omnigent` (`codex-native` 1.0 GB, `pi-native` 512 MB, `attachments` 14 MB),
and Claude Code sessions driven through it. None of that may be disturbed by
installing or testing this.

### The install is isolated, and that is verifiable

`pi-agent-env.sh` scopes `HOME` to `$PI_AGENT_HOME/home`, and both plugin halves
resolve the Omnigent config from `$HOME`:

- `src/common.mjs` → `locations()`: `omniDir: env.OMNIGENT_CONFIG_HOME || path.join(home, '.omnigent')`, `home = env.HOME || os.homedir()`
- `src/omnigent.py` → `Plugin.__init__`: `self.home = Path(os.environ.get("HOME", str(Path.home())))`, and it exports `OMNIGENT_CONFIG_HOME` to its children

So the service's view is its own, and it is empty until someone connects it:

```
$ pi-omnigent status        # with the install's env, which is how pi-web runs it
  host.id=null  server=null  phase=new
```

Measured against the owner's live integration: their `host_id`, server and
credentials are **not** visible to it, and a full checksum comparison of
`config.yaml`, `auth_tokens.json`, `install_ledger.backfill.json`,
`telemetry.json` and `.update_check.json` before and after the whole install and
test run came back identical, 6/6.

### The footgun this exposed, and the fix

`pi-omnigent` and `pi-paseo` used to be **symlinks** straight to the plugins'
`cli.mjs`. A symlink runs with the *caller's* `HOME`, so the same command typed
in an ordinary shell resolves `~/.omnigent` to the real account — which is
exactly how the owner's `host_id` first showed up in a `status` probe during
this work. `status` only reads, but `connect` or `initialize` would have written
the owner's live host.

They are now wrapper scripts that source `pi-agent-env.sh` before exec'ing the
CLI, so the plugin can only reach this install's state no matter which shell it
is started from. Verified from a plain shell with the real `HOME`:

```
$ ~/.local/share/pi-agent/bin/pi-omnigent status
  host.id=null  server=null       # isolated
```

An older install's symlinks are removed by the `wire` stage.

### Back up before testing on someone's machine

`~/omnigent-backups/<timestamp>/` holds:

| | |
|---|---|
| `critical/` + `critical.sha256` | identity and credentials, copied and checksum-verified — this is what a restore actually turns back on |
| `omnigent-full.tar.gz` | the whole `~/.omnigent` tree (688 MB compressed from 1.6 GB, 16,635 entries), minus lock files |
| `RESTORE.md` | the host id, and the exact commands for restoring either just the identity or everything |

The owner's Omnigent daemon is **not** stopped for the snapshot — that would
interrupt their running sessions — so the large session trees are a live
best-effort copy while the small identity files are verified byte-for-byte
(`tar` reported zero warnings on this run, and the critical files were checked
again *inside* the archive).

### One real near-miss, and the guard added because of it

Running the model-options patch **without `--tool-dir`** during this work applied
it to `~/.local/share/uv/tools/omnigent` — the machine owner's **own live
Omnigent install** (python3.13), not the scoped one (python3.12). `DEFAULT_ROOTS`
contains that path because inside the container it *is* the right target (HOME is
the data volume there); on a workstation it is somebody's running Omnigent.

It restored cleanly from the `.orig` the patch keeps — 0 residue, upstream
function back, syntax valid, `import` returning 9 models, `Omnigent.app` never
interrupted — but the right answer is for that to be impossible. The patch now
refuses any root outside `PI_AGENT_HOME` when that variable is set, and says so:

```
skipping ~/.local/share/uv/tools/omnigent: outside PI_AGENT_HOME
  (~/.local/share/pi-agent) — refusing to patch another install
found omnigent under ~/.local/share/pi-agent/data/omnigent-plugin/uv/tools/omnigent
```

Container behaviour is unchanged: nothing sets `PI_AGENT_HOME` there, so the
search works as before (verified — the Linux host still resolves the same path).

## Connecting to Omnigent on macOS

`pi-omnigent connect` failed on macOS with `LOCK_UNAVAILABLE` long before any
`/proc` code was reached. The cause is one line in the plugin's `src/common.mjs`:

```js
const executable = ['/usr/bin/flock', '/bin/flock'].find(candidate => fs.existsSync(candidate));
if (!executable) throw Object.assign(new Error('Linux util-linux flock is required.'), { code: 'LOCK_UNAVAILABLE' });
```

macOS ships no `flock(1)` at all, and `/usr/bin` is SIP-protected, so one cannot
be linked into either path. Upstream `main` (after PR #28) still has this line —
that PR fixed the installer's platform gate, not the lock.

### Why this is one line and not the M1 port

Reading the whole of `locked()` matters here, because the obvious conclusion is
wrong. The lock also calls `processIdentity()`, which reads `/proc/<pid>/stat`
and `/proc/sys/kernel/random/boot_id` — so it looks like connecting needs the
full `/proc` port. It does not:

- `processIdentity()` is **already wrapped in `try { … } catch { return {} }`**, so
  on darwin it yields `{}` and the owner record is written as `{ pid }` alone.
- `legacyLockAlive()` degrades to a 60-second mtime window on any throw.

Both are upstream behaviour on any platform where `/proc` is absent. So **no
ownership check is weakened or skipped by this patch** — the only thing missing
was the binary.

The fix adds a PATH fallback for `flock(1)`. That keeps `locked()` the *kernel*
lock its own comment promises, rather than downgrading it to an advisory file.

What it finds is `rootfs/bin/flock`, a `/usr/bin/perl` stand-in that the wire
stage installs into `$PI_AGENT_HOME/bin` on macOS only. On Linux it would shadow
util-linux's real flock for every agent shell. It implements exactly the form
the plugin uses — `flock [-n] [-x] [-E code] [--] <file> <command...>` with
flock(2) `LOCK_EX|LOCK_NB` — and refuses anything else with exit 64. Homebrew's
`discoteq/flock` honours the same contract, but requiring Homebrew for an
app-scoped install is the wrong trade, and every Mac has `/usr/bin/perl`. One
deliberate difference: Perl marks descriptors close-on-exec, so the command does
not inherit the lock. This process holds it until the command exits, which is
util-linux's `-o` behaviour. The plugin's helper exits when its stdin closes, so
the two agree on every path the plugin uses.

The `-n -E 75` contract that `locked()` depends on is asserted by
`tests/darwin-premises.mjs` (§6), not assumed. It resolves flock the way the
plugin will (its two hard-coded paths, then `PATH` with `$PI_AGENT_HOME/bin`
first) and asserts three things: that the shim is the one picked, ahead of any
Homebrew flock; that the holder prints `LOCKED`; and that a contender exits 75
without running, with the lock released when the holder exits. A change that
broke either flag would otherwise break `connect` silently.

### Result

```
$ pi-omnigent connect --server https://omnigent.woowtech.io --username … --password-stdin
{ "ok": true, "phase": "needs-verification",
  "host": { "id": "655a7a82…", "name": "ElmodeMacBook-Air.local", "connected": true } }
```

A **separate** host: the machine owner's own registration (`2b8a18bc…`) is
untouched, and their five identity/credential files still match the pre-connect
snapshot byte-for-byte.

Two things remain before the three engines are usable through Omnigent on a Mac,
neither caused by the installer:

1. **Each engine still needs its own login** on that machine (`claude auth login`,
   `codex login --device-auth`, `pi` → `/login`) — Omnigent registers these
   providers as `kind: subscription`, so connecting the host grants no models.
2. **`managerRunning` stays false.** The host manager's ownership checks in
   `src/omnigent.py` do read `/proc` (4 sites) with no try/catch fallback, and
   that is still the M1 port.

### A naming wrinkle

`connect` takes no host name, and the plugin only honours a `hostName` field
coming from an `initialize` request, which the CLI does not expose. The name is
the machine's, so a scoped install on a machine that already has its own host
registers a **second host with the same display name** — distinguishable only by
host id. Rename it in the Omnigent UI if that matters; nothing functional
depends on it.

## Adopting the user's existing engine logins

A workstation usually already has these engines logged in — and the scoped HOME
that keeps this install out of the owner's files is exactly what hides those
logins from it. `pi-agent-adopt-logins` closes the gap where it safely can.

**First, a measurement trap.** Over SSH every engine looks logged out:

```
$ claude auth status          # over ssh, the user's own binary and HOME
  loggedIn: false
$ security show-keychain-info ~/Library/Keychains/login.keychain-db
  User interaction is not allowed.
```

The login Keychain is locked for a non-GUI session, so that `false` is a **false
negative** — the same command in the GUI session (`launchctl asuser <uid>`)
returns `true`. Any claim about engine auth that was measured over SSH is void.
`codex` is worse: its shebang needs a `node` that an SSH PATH does not have, so
it fails for a third unrelated reason.

**What can be adopted, measured in the GUI session:**

| Engine | Where the credential lives | Adoptable? |
|---|---|---|
| codex | `~/.codex/auth.json` | **Yes** — symlinked; verified `Logged in using ChatGPT` |
| pi | `~/.pi/agent/auth.json` | **Yes** — symlinked |
| claude | login Keychain (per-user) | **Yes** — but not by copying anything; see below |

They are **symlinked, not copied**: these tokens refresh, and a copy silently
pins an old one.

**Claude Code needed one link, not a login — and the search for it went wrong
in an instructive way.** Every "adopt the credential" theory was disproved by
measurement in the GUI session:

| Theory | Test | Result |
|---|---|---|
| The Keychain is per-HOME | same binary, real HOME | `true` — the Keychain is reachable |
| A different binary breaks the Keychain ACL | scoped binary, real HOME | `true` — the binary is irrelevant |
| The account block in `.claude.json` is the gate | clean HOME + full copy of the real `.claude.json` | `false` |
| `machineID` binds the credential | scoped HOME with the real `machineID` | `false` |
| The whole `~/.claude` directory is the gate | clean HOME + full copy of `~/.claude` too | `false` |
| An env var can redirect it | `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_HOME` → real | `false` |

Every row varied something inside Claude Code while holding one variable fixed
without noticing it: **`$HOME` is also where macOS looks for the Keychain
itself.** `/usr/bin/security` says so directly:

```
HOME=<scoped>  security default-keychain → "A default keychain could not be found."
HOME=<real>    security default-keychain → /Users/<user>/Library/Keychains/login.keychain-db
```

and `securityd` logs `MacOS error: -25307` (`errSecNoDefaultKeychain`) for each
attempt. The scoped home has no `Library/Keychains`, so **no** keychain
operation from this install can work — reads included. That is the whole bug:

- "Not logged in" was a **failed read**, not an absent credential.
- `claude auth login` failing with *"Couldn't save your login. If your Mac's
  keychain is locked, unlock it and log in again"* was a **failed write**. The
  keychain was neither locked nor ACL-restricted; the message sends you to the
  wrong place, and it cost a long detour through ACL and launchd-session
  theories before `security` was asked the plain question.

The fix is one symlink, created by the `wire` stage:

```
$PI_AGENT_HOME/home/Library/Keychains -> ~/Library/Keychains
```

After it, with **no login at all**, the scoped install reports
`loggedIn: true, authMethod: claude.ai` — the credential was always there. Only
this one directory is shared; the data dir, sessions, `.omnigent` host identity
and the shared skills/MCP tree stay scoped. `tests/darwin-premises.mjs` §7
asserts it, because the failure mode impersonates a login problem.

One caveat worth knowing: the Omnigent host process caches engine readiness, so
after linking it still reported `needs-auth` until it was restarted
(`omnigent host stop`, then pi-web through its launcher shim). Measured after
that: `claude ready=True` with `opus, fable, sonnet, haiku`, and
`verify --engine claude` → `ok=True` on `claude-opus-5-5`.

`pi-agent-adopt-logins --undo` reverses everything it did, and it never writes
to the real home — verified: the owner's Omnigent files stayed 6/6 after the run.
