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

**Homebrew is not required.** Everything is either part of macOS and the Xcode
Command Line Tools (`git`, `curl`, `python3`, `bsdtar` — which reads `.tar.xz`
through libarchive, so no `xz` binary is needed, and `cc`, which `node-pty`
needs) or installed scoped under `$PI_AGENT_HOME`: its own Node, and uv's own
CPython for the Omnigent venv. Asking someone to install a system-wide package
manager for an app-scoped install is the wrong trade.

`tmux` is the one optional extra: Omnigent's native Pi harness runs the Pi TUI
inside its own tmux server. The installer installs it when Homebrew happens to
be present and warns otherwise; nothing else needs it.

Note that a non-login shell (ssh, launchd) does **not** have Homebrew on `PATH`
even when it is installed, so the installer looks in `/opt/homebrew` and
`/usr/local` rather than trusting `PATH`.

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
