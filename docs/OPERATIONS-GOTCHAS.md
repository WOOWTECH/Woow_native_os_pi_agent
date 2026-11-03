# Operational gotchas on this Mac

Written 2026-11-02 by the lane that built the installer, for whoever works on
the signing/notarization track next. These are measurement and process traps,
not code bugs — every one of them cost real time here. `docs/MACOS.md` covers
the code-level findings (keychain path, flock); this file covers the rest.

## 1. Any keychain or certificate check over SSH is a FALSE NEGATIVE

A plain `ssh` session cannot reach the login Keychain:

```
security show-keychain-info  →  User interaction is not allowed.   (exit 36)
security find-identity -v    →  (prints nothing, or misses identities)
claude auth status           →  loggedIn: false   ← even when it IS logged in
```

This produced a wrong conclusion here twice. The owner's own `claude`, with the
owner's own HOME, reports `loggedIn: false` over SSH while their Omnigent is
demonstrably working.

**Always measure in the GUI session:**

```bash
echo "$PASS" | sudo -S -p '' launchctl asuser "$(id -u)" sudo -n -u "$(whoami)" <command>
```

Same applies to `security find-identity`, `notarytool`, `productsign`, and
anything that touches the keychain. A cert that "isn't there" over SSH may be.

## 2. The sudo timestamp expires mid-operation

The pattern above primes a sudo timestamp, then relies on `sudo -n` inside. The
timestamp expires in ~5 minutes. During a long step (a 136 MB download took 6.5
minutes here) the inner `sudo -n` then fails with `a password is required`, and
whatever came after it silently does not run.

That cost a bogus `16 passed, 8 failed` smoke result: `launchctl bootout` had
run, the matching `bootstrap` had not, so pi-web simply was not up. Nothing was
actually broken.

**Re-prime sudo immediately before each privileged call**, or run the whole
sequence inside one `launchctl asuser ... bash -c '...'`.

## 3. `</dev/null` kills the password you piped into sudo

```bash
g(){ echo "$PASS" | sudo -S -p '' launchctl asuser ... "$@" </dev/null; }   # BROKEN
```

The redirect applies to the whole pipeline and replaces the piped password:
`sudo: no password was provided`. Prime sudo separately instead.

## 4. After sourcing `pi-agent-env.sh`, `~` is the SCOPED home

`pi-agent-env.sh` sets `HOME=$PI_AGENT_HOME/home`. Any later `~/...` in that
same shell resolves there, not to `/Users/<user>`.

This went wrong when the owner was asked to run two commands: the first sourced
the env, the second used `~`, and the symlink landed at
`…/pi-agent/home/.local/share/pi-agent/home/Library/Keychains` — a nested path
that does nothing.

**Use absolute paths in anything handed to the owner to run**, and note that
`$SCOPED/home/.local/bin/` holds the real `pi-web` / `pi-omnigent-web` Omnigent
launcher shims — do not `rm -rf` that `.local` while cleaning up a mistake.

## 5. The Omnigent host caches engine readiness — restarting pi-web is NOT enough

After fixing anything an engine depends on (credentials, gateway, keychain), the
plugin keeps reporting the old state. `launchctl kickstart` on pi-web does not
clear it: the running host is reused.

```bash
HOME="$A/home" OMNIGENT_CONFIG_HOME="$A/home/.omnigent" \
  "$A/data/omnigent-plugin/uv/tools/omnigent/bin/omnigent" host stop
# then restart pi-web; it relaunches the host through the shim
```

Only after that did `claude` go from `needs-auth` to `ready=True` with models.

## 6. `managerRunning=false` and `HOST_PROCESS_MISSING` are cosmetic on macOS

The plugin confirms its host process by reading `/proc/<pid>`, which macOS does
not have, so it always fails to confirm. The host is fine and the engines work.
Linux shows the same `false` with everything verified. Do not chase it.

## 7. Port 30141 answering 200 does not prove the LOCAL pi-web answered

An SSH tunnel left open from another machine can hold that port, so `/`,
`/api/home` and `/omnigent` all return 200 while the Mac's own pi-web is in an
`EADDRINUSE` restart loop. Confirm the responder:

```bash
curl -s localhost:30141/api/home | python3 -c 'import sys,json;print(json.load(sys.stdin).get("home"))'
```

It must print this machine's scoped home.

## 8. Do not restart or stop the owner's Omnigent daemon

`pid 59067` (`~/.omnigent`, `ai.omnigent.host`) is the owner's own live
integration, with running sessions and ~1.6 GB of state. It is separate from
this install's host. Stopping the scoped host (§5) does not touch it — check it
survived afterwards:

```bash
ps -p 59067 -o pid=
```

## 9. `tr` does not understand `\xNN`

`tr -d "\"\x27\n"` silently deletes the characters `x`, `2`, `7` as well. Used
on an API key, it produced a corrupted key and a confusing `401` that looked
like a credentials problem. Extract with `sed -n 's/^KEY=//p' | head -1`.

## 10. The auto-mode classifier blocks some legitimate steps

Reading a k8s secret, creating a link inside `~/Library/Keychains`, and even
printing the *lengths* of lines in a credential file were all refused here. If
you hit this, hand the exact command to the owner rather than working around it.

## 11. A signing identity can exist only as a `.p12` — not in any keychain

Even measured correctly in the GUI session, `security find-identity -v` lists
only `Apple Development` and `Apple Distribution` on this Mac. That does **not**
mean the team has no Developer ID. The *Developer ID Application* certificate
(G2, serial `470409E7…`, expires 2027-12-02) lives as files in
`/Users/elmolin/.local/share/woowtech-smart/signing/` — key, `.cer`, and a
`.p12` whose password is in the same-named `.password` — and is deliberately
kept out of the login keychain: electron-builder imports it into a throwaway
keychain via `CSC_LINK` at build time.

Reading `find-identity` as "no certificate" led to a wrong correction here and a
false request for the owner to go create one. Check the team's signing
directories (and the memory notes that record them) before concluding a
certificate is missing.

Also from that track: `codesign` does not find an identity that lives only in a
temporary keychain unless that keychain is on the user search list
(`security list-keychains -d user -s <kc> <existing list>`), even with
`--keychain`. Restore the original list in a `trap`.

## 12. In a scoped-HOME session, the search-list fix silently does nothing

Sessions that run inside this install (anything launched by its Omnigent host)
have `HOME=$PI_AGENT_HOME/home`. There, `security list-keychains -d user`
reads and writes the **scoped** home's preferences — it even shows a different
list from the real one (here: only `login.keychain-db`, without the
`electron-builder-root-certs.keychain` the real list has). And `codesign` run
under that HOME does not find the signing keychain's identity **whichever list
was edited** — while `find-identity` on that keychain lists it as valid.
Measured on this Mac:

| search list edited in | `codesign` ran with | result |
|---|---|---|
| scoped home | scoped `HOME` | `no identity found` |
| real home | scoped `HOME` | `no identity found` |
| real home | real `HOME` | signs |

An earlier version of this section said `codesign` "searches the real user's
list". The second row disproves that: what matters is that `codesign` itself
runs with the real home. `scripts/build-macos-pkg.sh` handles this on its own
(`as_real_home` wraps `security`, `codesign` and `productsign`), so it can be
run from a scoped session. By hand, run the whole signing sequence with the real
home:

```bash
env HOME=/Users/<user> bash -c '
  orig=$(security list-keychains -d user | tr -d "\"" | xargs)
  trap "security list-keychains -d user -s $orig" EXIT
  security list-keychains -d user -s "$KC" $orig
  codesign --force --options runtime --timestamp --keychain "$KC" --sign "$IDENT" "$BIN"
'
```

A related trap in testing this: a script that pipes `codesign` into `sed`
without `pipefail` reports success when signing failed, and a following
`codesign --verify` on a copied system binary then "passes" against **Apple's
original signature**. Check `Authority=` in `codesign -dv`, not just that
verification passed.

## 13. Two Omnigent hosts with one name take each other's registration away

Sections 13–16 were added with v0.2.2, after the host-name incident on this Mac
(2026-11-02/03): this install's scoped host and the owner's own Omnigent host were
both named `ElmodeMacBook-Air.local`, under one account. `docs/MACOS.md` used to
call that cosmetic ("a second host with the same display name … nothing
functional depends on it"). **That was wrong.**

The server (`omnigent` 0.16.0, `host_store.upsert_on_connect`, read in the package
this installer pins) finds a connecting host by `host_id` and, failing that, by
the (workspace, user, **name**) triple. A new `host_id` arriving under a taken
name is treated as the same machine coming back with a new identity, and
`_rotate_host_id` runs: the conversations bound to the old row get `host_id =
NULL`, the old row is **deleted**, a new one is inserted (it keeps the old
`created_at`), and the conversations are bound to the new row. Two live daemons
with one name therefore do this to each other on every tunnel reconnect. What it
looks like:

- one entry in the host picker flipping between online and offline;
- `GET /v1/hosts/<id>` answering 404 for an id that was valid a minute ago (§14
  is what that does to a restart);
- conversations that open on the *other* daemon (§15).

What v0.2.2 does about it:

| | |
|---|---|
| unique by construction | `wire` writes `host: {name: "<hostname> (pi-agent)"}` into this install's own `home/.omnigent/config.yaml` when it has no name. omnigent keeps a name it finds and generates only the `host_id`. |
| refused when taken | a plugin patch checks `GET /v1/hosts` just before the plugin starts a host. Any other host of the account with the same name — online **or offline**, an offline duplicate still owns bound conversations — and nothing is started: `HOST_NAME_COLLISION`, whose message names the other host and gives the exact line to proceed. |
| fail closed | if the server cannot be asked (unreachable, 401/403/5xx, not the expected JSON) nothing is started either: `HOST_NAME_UNVERIFIABLE`. Connect and resume already need the server one call earlier, so this blocks nothing that could have worked, and failing open would let a flaky link trigger the one thing that cannot be undone. There is no generic bypass variable. |
| intentional takeover | `PI_AGENT_TAKEOVER_HOST_ID=<first 8+ hex characters of the host being replaced>`; every colliding host's id must start with it, and that host must be offline. `1`, `true` or a typo do not work. |
| tooling | `pi-agent-host-name check` / `set NAME` / `seed`. |

**Where a person sees a refusal** (measured through the plugin's own Node layer by
`tests/host-name.test.mjs` D2, not assumed):
the plugin stores it in `data/omnigent-plugin/state.json` as `{code, message}`.
`pi-omnigent connect` prints **only the code** — the plugin prints codes only, by
design. `pi-omnigent status` and `repair` print the whole message, as JSON. Settings →
Omnigent shows the localized *hint* the plugin keeps per code, not the message, so
the patch adds hints for the three new codes (without them Settings would say only
"something needs attention"). All of them lead to `pi-agent-host-name check`, which
prints the last refusal as written — real newlines, the other host's id, the exact
commands — and exits 1 while one is pending.

An install that already has a name — including one equal to the plain hostname —
is **not** renamed (it may be registered and in use): `wire` prints a warning and
`pi-agent-host-name check` says so. To fix it: `pi-agent-host-name set "<hostname>
(pi-agent)"`, then `pi-agent restart` — a running host keeps the name it started
with.

The seeded name is unique against hosts that are *not* pi-agent installs. Two
pi-agent installs on one machine (a second one on another `PI_WEB_PORT`) would
seed the same `<hostname> (pi-agent)`; the second to connect is refused by the
guard and told to `set` a name of its own.

Limits, stated plainly: the guard covers hosts *the plugin starts*, at the moment
it is about to start one. It does not stop someone running `omnigent host` by
hand, or an Omnigent app, under a taken name — the seeded default is what keeps
the common case apart. And nothing in the rotation moves conversations *back*, so
after a collision check which host each conversation is bound to.

The two ways to run a second host — side by side, or replacing one on purpose —
are laid out in `docs/MACOS.md` ("Host names must differ") and, for the
replacement, `docs/SESSION-HOME.md`.

## 14. A deleted registration deadlocks the restart — recover with `repair`, under `env -i`

Once the `host_id` in this install's config has no registration row — rotated out
by §13, deleted in the UI, or replaced by `omnigent host reset-id`, which mints an
id nothing has registered yet — restarting pi-web does not bring the host back.
The plugin's `resume()` asks `GET /v1/hosts/<host_id>` **before** it calls
`ensure_host()`; the answer is 404 (`HTTP_404`), `resume()` raises, and the host
is never started — so it can never register again. The restart reports the error
every time and heals nothing.

`connect()` has no such pre-check, and reuses the stored login when it is given no
credentials. The plugin CLI's `repair` goes through it when `state.json` has
`loginConfirmed: true` for the same server:

```bash
env -i "$HOME/.local/share/pi-agent/bin/pi-omnigent" repair --server https://omnigent.woowtech.io
```

(your `PI_AGENT_HOME` instead of the default path if you moved it). If it answers
`FRESH_LOGIN_REQUIRED`, there is no confirmed login to reuse: use `connect --server
… --username … --password-stdin`.

Why `env -i`: `ensure_host()` scrubs only six variables from the environment of the
host it spawns (`OMNIGENT_HOST_ID`, `OMNIGENT_HOST_NAME`, `RUNNER_SERVER_URL`,
`RUNNER_AUTH_TOKEN`, `OMNIGENT_RUNNER_AUTH_TOKEN`, `OMNIGENT_HOST_BINDING_TOKEN`).
Typed in a shell that belongs to an Omnigent session — a conversation's terminal,
a coding agent's shell — the rest (`OMNIGENT_RUNNER_*` and friends) come along
into a daemon that is supposed to be this install's own. `env -i` clears them; the
wrapper re-establishes `PATH`, `HOME` and the install's variables itself, which is
why the command uses the absolute path. To take over a host on purpose, add the
variable after `-i`: `env -i PI_AGENT_TAKEOVER_HOST_ID=2b8a18bc …/pi-omnigent
repair …`.

## 15. A conversation follows its host binding — and the daemon behind it may have another HOME

A conversation is bound to a `host_id`; whichever daemon currently holds that
registration serves it. After a rotation (§13) or a takeover, that can be a daemon
with a different `HOME`, working directory, MCP servers and plugins than the one
the conversation started on — here, the scoped install (`HOME=$PI_AGENT_HOME/home`)
versus the owner's own host (their real home).

Measured on this Mac: the work on this track ran in a conversation served by the
owner's live daemon — the real `HOME` — while its working directory was the scoped
home. `~` is the real home there, until a script sources `pi-agent-env.sh`, after
which it is the scoped one (§4); a relative path means the scoped home either way.
Use **absolute paths** in anything run from such a conversation, and check which
daemon serves it before trusting `~` or the working directory. Never run
`omnigent`, `pi-omnigent connect` or `repair` from there without knowing whose
config it will resolve.

## 16. Read the RESULT line of a script's result file, not whether the script finished

The host-rename script on this Mac ran to the end and exited 0 — and its result
file ended `RESULT: UNVERIFIED`. The rename had gone through but the check that
proves it could not run, because of §14. "Finished" told nothing; the last line
did, and reading only the first would have reported success.

For any script whose job is to change something and prove it: make the last line of
its result file exactly one of `RESULT: OK`, `RESULT: FAILED <why>` or `RESULT:
UNVERIFIED <why>`; read *that* line (`grep '^RESULT' file | tail -1`), not the exit
status, the presence of the file or the word "done"; and treat a missing RESULT
line as a failure, not as a pass.
