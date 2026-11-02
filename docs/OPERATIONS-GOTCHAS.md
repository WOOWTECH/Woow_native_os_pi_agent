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
