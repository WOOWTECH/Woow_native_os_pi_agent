#!/usr/bin/env bash
# Build a macOS .pkg that installs Pi Agent for the user who runs it.
#
#   scripts/build-macos-pkg.sh \
#       --artifact-url    https://github.com/.../piweb-<ver>-macos-arm64.tar.gz \
#       --artifact-sha256 <64 hex> \
#       [--tools <dir>]           default dist/tools-macos-<arch>  (scripts/build-macos-tmux.sh)
#       [--out <dir>]             default dist
#       [--sign-app "<Developer ID Application: ...>"]   codesign every Mach-O under tools/
#       [--sign "<Developer ID Installer: ...>"]         productsign the pkg
#       [--keychain <path>]                              for both, when the identity is not
#                                                        in the default search list
#       [--notary-key <AuthKey.p8> --notary-key-id <id> --notary-issuer <uuid>]
#                                                        notarize + staple (needs --sign)
#
# WHAT IS IN IT
#
# The installer (install.sh, lib/, rootfs/, vendor/, VERSION, docs), the bundled
# tools/ (tmux, built from source -- see build-macos-tmux.sh), and two one-line
# files pinning the prebuilt pi-web tree by URL and sha256. The tree itself is
# NOT embedded: postinstall downloads it, and install.sh verifies it against the
# pinned checksum. That keeps the pkg small, and it keeps the payload free of
# executable code apart from tools/bin/tmux -- the notary service inspects every
# binary in a package, and an embedded 140 MB tarball full of native modules is
# exactly what it would have to unpack. The build checks the result: tools/bin/
# tmux must be the only Mach-O anywhere in the expanded payload.
#
# WHY postinstall DROPS PRIVILEGES
#
# pkg postinstall runs as root, but this installs into the user's own
# ~/.local/share/pi-agent and must end up owned by them -- and Claude Code reads
# its credentials from the user's login Keychain, which root cannot see. So the
# script re-enters the console user's GUI session with `launchctl asuser`, as
# that user, with THEIR home: macOS's sudoers keeps the caller's HOME
# (env_keep += "HOME MAIL"), so plain `sudo -u` would run install.sh with root's
# home. `sudo -H` plus an explicit HOME prevents that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die()  { printf '[build-macos-pkg] ERROR: %s\n' "$*" >&2; exit 1; }
say()  { printf '[build-macos-pkg] %s\n' "$*"; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

ART_URL="" ART_SHA="" TOOLS="" OUT="$HERE/dist"
SIGN_APP="" SIGN_PKG="" KEYCHAIN=""
NOTARY_KEY="" NOTARY_KEY_ID="" NOTARY_ISSUER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact-url)    ART_URL="${2:-}"; shift 2 ;;
    --artifact-sha256) ART_SHA="${2:-}"; shift 2 ;;
    --tools)           TOOLS="${2:-}"; shift 2 ;;
    --out)             OUT="${2:-}"; shift 2 ;;
    --sign-app)        SIGN_APP="${2:-}"; shift 2 ;;
    --sign)            SIGN_PKG="${2:-}"; shift 2 ;;
    --keychain)        KEYCHAIN="${2:-}"; shift 2 ;;
    --notary-key)      NOTARY_KEY="${2:-}"; shift 2 ;;
    --notary-key-id)   NOTARY_KEY_ID="${2:-}"; shift 2 ;;
    --notary-issuer)   NOTARY_ISSUER="${2:-}"; shift 2 ;;
    -h|--help)         usage ;;
    *)                 die "unknown argument: $1 (see --help)" ;;
  esac
done

# --- validate inputs ----------------------------------------------------------
# The URL ends up in the payload and in install.sh's environment. Restrict it to
# a plain https path (no query string, no quotes, no spaces) naming a macOS
# artifact, and take the architecture from that name.
printf '%s' "$ART_URL" | grep -Eq '^https://[A-Za-z0-9._~/%+-]+-macos-(arm64|x64)\.tar\.gz$' \
  || die "--artifact-url must be an https URL ending in -macos-arm64.tar.gz or -macos-x64.tar.gz"
printf '%s' "$ART_SHA" | grep -Eq '^[0-9a-f]{64}$' \
  || die "--artifact-sha256 must be 64 lowercase hex characters"
case "$ART_URL" in
  *-macos-arm64.tar.gz) ARCH=arm64;  HOSTARCH=arm64  ;;
  *-macos-x64.tar.gz)   ARCH=x64;    HOSTARCH=x86_64 ;;
esac
if [ -n "$NOTARY_KEY$NOTARY_KEY_ID$NOTARY_ISSUER" ]; then
  [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ] \
    || die "notarization needs all of --notary-key, --notary-key-id and --notary-issuer"
  [ -f "$NOTARY_KEY" ] || die "no such notary key file: $NOTARY_KEY"
  [ -n "$SIGN_PKG" ] || die "notarization needs a signed pkg: pass --sign too"
fi
[ -z "$KEYCHAIN" ] || [ -f "$KEYCHAIN" ] || die "no such keychain: $KEYCHAIN"

TOOLS="${TOOLS:-$HERE/dist/tools-macos-$ARCH}"
[ -x "$TOOLS/bin/tmux" ] \
  || die "no bundled tmux at $TOOLS/bin/tmux -- run scripts/build-macos-tmux.sh (or pass --tools)"
file -b "$TOOLS/bin/tmux" | grep -q "Mach-O 64-bit executable $HOSTARCH" \
  || die "$TOOLS/bin/tmux is not a $HOSTARCH executable: $(file -b "$TOOLS/bin/tmux")"

# Version, in order of trust: explicit env, the VERSION file, then git. The
# payload is unpacked outside a git checkout when CI or a build host uses it, and
# silently stamping 0.0.0 produces a pkg that looks releasable and is not.
VERSION="${PI_AGENT_VERSION:-}"
[ -n "$VERSION" ] || VERSION="$(cat "$HERE/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="$(git -C "$HERE" describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$VERSION" ] || die "cannot determine version: set PI_AGENT_VERSION or add a VERSION file"
VERSION="${VERSION#v}"

# Expanded as ${KC_ARGS[@]+"${KC_ARGS[@]}"}: bash 3.2 (macOS /bin/bash) treats
# an empty array as unbound under set -u.
KC_ARGS=()
[ -n "$KEYCHAIN" ] && KC_ARGS=(--keychain "$KEYCHAIN")

ID="io.woowtech.pi-agent"
PAYLOAD="/usr/local/lib/woow-pi-agent"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pa-pkg.XXXXXX")"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT
ROOT="$WORK/root"; SCRIPTS="$WORK/scripts"
mkdir -p "$ROOT$PAYLOAD" "$SCRIPTS"

# --- payload ------------------------------------------------------------------
# The installer itself, not a copy of anyone's install. No 2>/dev/null: a
# missing entry must stop the build, not quietly ship without it (vendor/ was
# once left out this way, and the omnigent stage skipped itself).
tar cf - -C "$HERE" install.sh lib rootfs scripts tests docs README.md vendor VERSION \
  | tar xf - -C "$ROOT$PAYLOAD"
mkdir -p "$ROOT$PAYLOAD/tools"
cp -Rp "$TOOLS/." "$ROOT$PAYLOAD/tools/"
for f in install.sh lib/pins.sh vendor/omnigent-requirements.lock VERSION \
         rootfs/bin/flock rootfs/bin/pi-agent-env.sh tools/bin/tmux; do
  [ -e "$ROOT$PAYLOAD/$f" ] || die "payload is missing $f"
done
printf '%s\n' "$ART_URL" > "$ROOT$PAYLOAD/piweb-artifact-url"
printf '%s\n' "$ART_SHA" > "$ROOT$PAYLOAD/piweb-artifact-sha256"

if [ -n "$SIGN_APP" ]; then
  # Developer ID + hardened runtime + secure timestamp: what notarization asks of
  # every Mach-O in a package. Replaces the linker's ad-hoc signature.
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    say "codesign ${f#"$ROOT"}"
    codesign --force --options runtime --timestamp --sign "$SIGN_APP" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$f"
    codesign --verify --strict --verbose=2 "$f"
  done < <(find "$ROOT$PAYLOAD/tools" -type f -print0)
else
  say "tools/ keeps the linker's ad-hoc signature (pass --sign-app for distribution)"
fi

cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
# Runs as root. Hand the work to the console user inside their GUI session.
set -u
PAYLOAD=/usr/local/lib/woow-pi-agent
LOG=/var/log/woow-pi-agent-install.log
exec >>"$LOG" 2>&1
echo "=== $(date) pi-agent postinstall ==="

USER_NAME="$(stat -f%Su /dev/console)"
case "$USER_NAME" in
  ""|root|_mbsetupuser|loginwindow)
    echo "no console user ('$USER_NAME'); cannot install per-user. Run $PAYLOAD/install.sh as that user."
    exit 1 ;;
esac
USER_UID="$(id -u "$USER_NAME")" || exit 1
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "cannot resolve the home directory of $USER_NAME"; exit 1
fi

# Pinned when the pkg was built: the prebuilt pi-web tree for this architecture.
# Passed to install.sh through the environment, never through a shell string.
URL="$(head -n1 "$PAYLOAD/piweb-artifact-url")"
SHA="$(head -n1 "$PAYLOAD/piweb-artifact-sha256")"
case "$URL" in https://*) ;; *) echo "bad artifact URL in payload: $URL"; exit 1 ;; esac
printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{64}$' || { echo "bad artifact sha256 in payload"; exit 1; }
echo "installing for $USER_NAME (uid $USER_UID) in $USER_HOME"
echo "pi-web artifact: $URL  sha256 $SHA"

# launchctl asuser: the user's GUI session, which is what gives the install their
# login Keychain (Claude Code) and lets the service stage load a LaunchAgent.
# sudo -H plus an explicit HOME: macOS's sudoers keeps the caller's HOME, so
# without them install.sh would run with root's home and install there.
launchctl asuser "$USER_UID" sudo -H -u "$USER_NAME" /usr/bin/env \
  HOME="$USER_HOME" \
  PI_AGENT_PIWEB_ARTIFACT="$URL" \
  PI_AGENT_PIWEB_ARTIFACT_SHA256="$SHA" \
  /bin/bash -lc 'cd "$HOME" && exec /usr/local/lib/woow-pi-agent/install.sh'
rc=$?
echo "install.sh exit=$rc"
exit $rc
POST
chmod 755 "$SCRIPTS/postinstall"

# --- build --------------------------------------------------------------------
mkdir -p "$OUT"
COMPONENT="$WORK/pi-agent-component.pkg"
DIST="$WORK/distribution.xml"
PKG="$OUT/WoowPiAgent-$VERSION-macos-$ARCH.pkg"

pkgbuild --root "$ROOT" --scripts "$SCRIPTS" \
         --identifier "$ID" --version "$VERSION" \
         --install-location / "$COMPONENT" >/dev/null

# The pinned pi-web tree is per-architecture, so install.sh would refuse it on
# the other one -- after the user had already clicked through. Let Installer
# refuse up front instead.
productbuild --synthesize --package "$COMPONENT" "$DIST" >/dev/null
if grep -q 'hostArchitectures=' "$DIST"; then
  sed -i '' -E "s/hostArchitectures=\"[^\"]*\"/hostArchitectures=\"$HOSTARCH\"/" "$DIST"
else
  sed -i '' -E "s/<options /<options hostArchitectures=\"$HOSTARCH\" /" "$DIST"
fi
grep -q "hostArchitectures=\"$HOSTARCH\"" "$DIST" || die "could not restrict the pkg to $HOSTARCH"
rm -f "$PKG"
productbuild --distribution "$DIST" --package-path "$WORK" "$PKG" >/dev/null

# --- verify what was actually built ---------------------------------------------
X="$WORK/expanded"
pkgutil --expand-full "$PKG" "$X" >/dev/null
P="$(find "$X" -type d -path "*/Payload$PAYLOAD" -print -quit)"
[ -n "$P" ] || die "expanded pkg has no $PAYLOAD"
machos=""
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' && machos="$machos${f#"$P"/}"$'\n'
done < <(find "$X" -type f -print0)
# Paths outside the payload would show up with their full expanded path, so
# anything other than exactly tools/bin/tmux fails here.
[ "$machos" = $'tools/bin/tmux\n' ] \
  || die "tools/bin/tmux must be the only Mach-O in the payload; found: $(printf '%s' "$machos" | tr '\n' ' ')"
[ "$(head -n1 "$P/piweb-artifact-url")" = "$ART_URL" ]    || die "artifact URL did not survive packaging"
[ "$(head -n1 "$P/piweb-artifact-sha256")" = "$ART_SHA" ] || die "artifact sha256 did not survive packaging"
[ -f "$P/vendor/omnigent-requirements.lock" ]             || die "vendor/ did not survive packaging"
say "payload verified: tools/bin/tmux is the only Mach-O; artifact pin and vendor/ present"

# --- sign and notarize --------------------------------------------------------
if [ -n "$SIGN_PKG" ]; then
  productsign --timestamp --sign "$SIGN_PKG" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$PKG" "$PKG.signed"
  mv "$PKG.signed" "$PKG"
  pkgutil --check-signature "$PKG"
  say "signed with: $SIGN_PKG"
else
  say "WARNING: the pkg is UNSIGNED -- Gatekeeper will refuse it on other Macs."
  say "For public download pass --sign-app and --sign (Developer ID), then notarize."
fi

if [ -n "$NOTARY_KEY" ]; then
  say "notarizing (this waits for Apple)"
  result="$(xcrun notarytool submit "$PKG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
              --issuer "$NOTARY_ISSUER" --wait --output-format json)"
  status="$(printf '%s' "$result" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
  sub_id="$(printf '%s' "$result" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    [ -n "$sub_id" ] && xcrun notarytool log "$sub_id" --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2 || true
    die "notarization status: ${status:-unknown} (submission ${sub_id:-?})"
  fi
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG"
  spctl -a -vv -t install "$PKG"
  say "notarized and stapled (submission $sub_id)"
fi

say "$PKG ($(du -h "$PKG" | cut -f1))"
