# macOS PKG candidate handoff — 2026-11-14

Base: `origin/main` at `f01b6a1`, **not** the divergent `v0.3.0-rc.7` tag
(`f1ce4ad`). Keep main's Intel constraints, no-dev-tools and model-options-hook
fixes. Feature branch: `feat/installer-macos-20261114`. Candidate version is
passed as `PI_AGENT_VERSION=0.3.0-rc.8`; no VERSION change, tag, release workflow
or public upload is part of this work.

## Build on each native architecture

The tmux builder runs its output, so use a native arm64 Mac for arm64 and an
Intel Mac for x64. These are **separate packages**, not universal binaries.
The repository has both build paths; neither new candidate has been built or
accepted on a Mac by this Linux implementation task. macOS 13.0 is tmux's
configured deployment target, not evidence that the entire product works on
every macOS version. Test the intended minimum OS separately.

Use a separate checkout/worktree of the feature branch on the Mac. A build
host needs Xcode Command Line Tools, Git and network access. End users on the
prebuilt PKG path should need neither CLT nor Homebrew.

Build the pi-web artifact using an isolated directory (no service stage):

```bash
case "$(uname -m)" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *) exit 1 ;;
esac
BUILD_HOME="$(mktemp -d "$HOME/pi-agent-pkg-build.XXXXXX")"
PI_AGENT_HOME="$BUILD_HOME" ./install.sh node fetch piweb
PI_AGENT_HOME="$BUILD_HOME" scripts/build-piweb-artifact.sh "$PWD/dist"
scripts/build-macos-tmux.sh "$PWD/dist/tools-macos-$ARCH"
bash tests/build-macos-pkg.sh
```

The pi-web filename uses **PIN_PI_WEB_VERSION**, not the candidate PKG version.
Obtain the exact filename and SHA from `dist/piweb-*-macos-$ARCH.tar.gz.sha256`.
Arrange a team-only HTTPS staging URL reachable by the test Mac for that exact
file; this is a required handoff input, **not permission for public publication**.
The URL must end in `-macos-arm64.tar.gz` or `-macos-x64.tar.gz`, with no query,
spaces or authentication requirement. The payload downloads this URL at install
time and verifies its SHA. A cross-architecture or stale artifact is not valid.

An unsigned, private engineering build:

```bash
# Set ARTIFACT_URL to the staged URL and ARTIFACT_SHA256 to its 64 lowercase hex SHA.
: "${ARTIFACT_URL:?set exact staged artifact URL}"
: "${ARTIFACT_SHA256:?set exact artifact SHA256}"
PI_AGENT_VERSION=0.3.0-rc.8 scripts/build-macos-pkg.sh \
  --artifact-url "$ARTIFACT_URL" --artifact-sha256 "$ARTIFACT_SHA256" \
  --tools "$PWD/dist/tools-macos-$ARCH" --out "$PWD/dist/private-unsigned"
```

Unsigned output is for engineering inspection/installation only and cannot
satisfy the ordinary downloaded-file Gatekeeper acceptance. Do not remove
quarantine or disable Gatekeeper as a substitute for formal acceptance.

## Formal build gate (authorized signing lane only)

No signing material was accessed by the Linux implementation task. The signing
lane supplies existing identities and notary parameters using its established
credential handling. These are parameters, not credentials to paste into a report:

```bash
: "${SIGN_APP:?Developer ID Application: Name (TEAMID)}"
: "${SIGN_INSTALLER:?Developer ID Installer: Name (TEAMID)}"
: "${NOTARY_KEY_FILE:?existing AuthKey file path}"
: "${NOTARY_KEY_ID:?existing key ID}"
: "${NOTARY_ISSUER:?issuer UUID}"
PI_AGENT_VERSION=0.3.0-rc.8 scripts/build-macos-pkg.sh --release \
  --artifact-url "$ARTIFACT_URL" --artifact-sha256 "$ARTIFACT_SHA256" \
  --tools "$PWD/dist/tools-macos-$ARCH" --out "$PWD/dist/private-signed" \
  --sign-app "$SIGN_APP" --sign "$SIGN_INSTALLER" \
  --notary-key "$NOTARY_KEY_FILE" --notary-key-id "$NOTARY_KEY_ID" \
  --notary-issuer "$NOTARY_ISSUER"
# Optional existing non-default signing keychain: add --keychain /path/to/keychain.
scripts/verify-macos-pkg.sh \
  "$PWD/dist/private-signed/WoowPiAgent-0.3.0-rc.8-macos-$ARCH.pkg"
```

`--release` fails before build if either Developer ID identity or any notary
parameter is missing. It then requires accepted notarization and a valid staple.
The independent verifier checks package Installer identity, staple, Gatekeeper,
and bundled tmux's strict signature, Developer ID Application authority,
hardened runtime and timestamp. Nonzero means **do not hand off as releasable**;
a failed build may leave a diagnostic PKG on disk. This gate validates the PKG
and its bundled tmux, not the separately downloaded runtime tree. Record the
artifact SHA and runtime acceptance independently. A gate pass grants no public
release authorization.

## Acceptance evidence required from the Mac agent

1. Record branch commit, `sw_vers`, native CPU, artifact URL/SHA, package SHA and
   full builder/verifier exit status. Run the package permissions test above
   under its built-in 022 and 077 cases. Verify both Applications entries exist
   and are readable/executable by a normal user, and the conclusion page displays.
2. On a clean test account without CLT/Homebrew, download the signed package
   through a browser so quarantine is present. Double-click it with normal
   Gatekeeper enabled. Confirm trusted Installer UI, real stage logs, successful
   online install and no developer-tools prompts. Open **Pi Agent.command** from
   Finder; Terminal must show progress, then browser UI loads and an actual agent
   session works. Record which engines were authenticated; UI HTTP readiness alone
   does not prove engine readiness.
3. Run `launchctl print "gui/$(id -u)/io.woowtech.pi-agent"` in the actual GUI
   user's session. Confirm the job belongs to that user and its environment points
   to their scoped installation. Reopen and double-click twice while installing;
   no second setup should run concurrently. Log out/in and reopen the entry.
4. Interrupt networking during setup. Installer must report failure; helper log
   must retain the stage/error. Restore networking and use the normal entry to
   retry the incomplete setup. Test **Pi Agent Repair.command** too. Break service
   readiness separately; it must report launchd failure or an approximately
   120-second HTTP timeout, with log/repair directions and no premature browser.
5. In an existing test account, record (without copying secrets into reports)
   launchd label/location, saved port, scoped identity and real-home Omnigent/
   engine identity file checksums. Exercise upgrade/repair, including a custom
   location with spaces and nondefault saved port. These identities, location
   and port must remain unchanged; the existing installer may update binaries
   and rewrite the same plist. A conflicting explicit PI_AGENT_HOME must fail.
   Repair restarts this product's service; don't run it over a live work session.
6. Verify wrong-architecture rejection before downloads. Test arm64 and Intel
   separately; publish only the architecture/OS combinations actually accepted.
   The original plugins and authentication paths still need the existing Mac
   runtime suites; this change is not a new claim of all-engine support.

Attach sanitized setup logs, builder/verifier logs and Finder/Installer evidence
to the coordinator. Keep user credentials, notary keys and complete user logs
out of commits. Public publication remains a separate user confirmation.

## Linux implementation checks

`python3 tests/macos-launch.py`: 12 hermetic tests, including command-stub trust
failure cases. `bash -n` on the changed shell scripts and `git diff --check`.
`bash tests/build-macos-pkg.sh` explicitly skips on Linux; it is not a native
build pass. Native Apple verification, Finder behavior, CLT-free fresh installs,
architecture/OS acceptance and real engine sessions remain Mac-lane dependencies.
