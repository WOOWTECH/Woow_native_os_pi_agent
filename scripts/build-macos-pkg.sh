#!/usr/bin/env bash
# Build a macOS .pkg that installs Pi Agent for the user who runs it.
#
#   scripts/build-macos-pkg.sh \
#       --artifact-url    https://github.com/.../piweb-<ver>-macos-arm64.tar.gz \
#       --artifact-sha256 <64 hex> \
#       OR --artifact-file /path/piweb-<ver>-macos-<arch>.tar.gz
#       [--arch arm64|x64]        assert artifact target (default: derive from filename)
#       [--release]               require Developer ID signing + accepted notarization
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
# tools/ (tmux), and a pinned pi-web source. URL mode keeps the tree external;
# --artifact-file embeds the exact tarball and checks its explicit SHA both here
# and in the per-user setup helper. Only tmux is an unpacked Mach-O; the embedded
# archive contains native modules and is NOT covered by that inventory assertion.
# Apple notarization must accept the complete package in either mode.
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
# The payload is installed owned by root, and the postinstall then hands the work to the console user, who must
# be able to read and run it. `tar xf -` and `mkdir` apply the builder's umask, so a builder running under a strict
# one produced a pkg whose install.sh was 700: "Permission denied", exit 126, nothing installed (v0.2.3, built from
# a shell whose umask a cutover had left at 077). Fixed here, not left to whoever runs the build.
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die()  { printf '[build-macos-pkg] ERROR: %s\n' "$*" >&2; exit 1; }
say()  { printf '[build-macos-pkg] %s\n' "$*"; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

ART_URL="" ART_FILE="" ART_NAME="" TARGET_ARCH="" ART_SHA="" TOOLS="" OUT="$HERE/dist"
SIGN_APP="" SIGN_PKG="" KEYCHAIN="" RELEASE=0
NOTARY_KEY="" NOTARY_KEY_ID="" NOTARY_ISSUER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release)         RELEASE=1; shift ;;
    --artifact-file)   ART_FILE="${2:-}"; shift 2 ;;
    --arch)            TARGET_ARCH="${2:-}"; shift 2 ;;
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

# Fail closed before using tools, signing identities or network.
if [ "$RELEASE" = 1 ]; then
  case "$SIGN_APP" in 'Developer ID Application: '*) ;; *) die '--release needs --sign-app Developer ID Application identity' ;; esac
  case "$SIGN_PKG" in 'Developer ID Installer: '*) ;; *) die '--release needs --sign Developer ID Installer identity' ;; esac
  [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ] \
    || die '--release needs all three notarization parameters'
fi

# --- validate inputs ----------------------------------------------------------
[ -z "$ART_URL" ] || [ -z "$ART_FILE" ] || die 'choose exactly one of --artifact-url or --artifact-file'
[ -n "$ART_URL$ART_FILE" ] || die 'one of --artifact-url or --artifact-file is required'
[ "${#ART_SHA}" = 64 ] || die '--artifact-sha256 must be 64 lowercase hex characters'
printf '%s' "$ART_SHA" | grep -Eq '^[0-9a-f]{64}$' \
  || die "--artifact-sha256 must be 64 lowercase hex characters"
if [ -n "$ART_FILE" ]; then
  ART_NAME="$(basename "$ART_FILE")"
  case "$ART_NAME" in *[!A-Za-z0-9._+-]*) die 'invalid --artifact-file filename characters' ;; esac
  printf '%s' "$ART_NAME" | grep -Eq '^piweb-[A-Za-z0-9._+-]+-macos-(arm64|x64)\.tar\.gz$' \
    || die '--artifact-file filename must be piweb-<version>-macos-arm64.tar.gz or piweb-<version>-macos-x64.tar.gz'
  SOURCE_NAME="$ART_NAME"
else
  printf '%s' "$ART_URL" | grep -Eq '^https://[A-Za-z0-9._~/%+-]+-macos-(arm64|x64)\.tar\.gz$' \
    || die "--artifact-url must be an https URL ending in -macos-arm64.tar.gz or -macos-x64.tar.gz"
  SOURCE_NAME="$ART_URL"
fi
case "$SOURCE_NAME" in
  *-macos-arm64.tar.gz) ARCH=arm64; HOSTARCH=arm64 ;;
  *-macos-x64.tar.gz) ARCH=x64; HOSTARCH=x86_64 ;;
esac
case "$TARGET_ARCH" in ''|arm64|x64) ;; *) die '--arch must be arm64 or x64' ;; esac
[ -z "$TARGET_ARCH" ] || [ "$ARCH" = "$TARGET_ARCH" ] || die "artifact architecture $ARCH does not match --arch $TARGET_ARCH"
if [ -n "$ART_FILE" ]; then
  [ -f "$ART_FILE" ] || die "no such artifact file: $ART_FILE"
  ART_FILE="$(cd "$(dirname "$ART_FILE")" && pwd)/$ART_NAME"
  [ "$(shasum -a 256 "$ART_FILE" | awk '{print $1}')" = "$ART_SHA" ] || die 'local artifact sha256 mismatch'
fi
if [ -n "$NOTARY_KEY$NOTARY_KEY_ID$NOTARY_ISSUER" ]; then
  [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ] \
    || die "notarization needs all of --notary-key, --notary-key-id and --notary-issuer"
  [ -f "$NOTARY_KEY" ] || die "no such notary key file: $NOTARY_KEY"
  [ -n "$SIGN_PKG" ] || die "notarization needs a signed pkg: pass --sign too"
fi
[ -z "$KEYCHAIN" ] || [ -f "$KEYCHAIN" ] || die "no such keychain: $KEYCHAIN"

# Version, in order of trust: explicit env, the VERSION file, then git. The
# payload is unpacked outside a git checkout when CI or a build host uses it, and
# silently stamping 0.0.0 produces a pkg that looks releasable and is not.
VERSION="${PI_AGENT_VERSION:-}"
[ -n "$VERSION" ] || VERSION="$(cat "$HERE/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="$(git -C "$HERE" describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$VERSION" ] || die "cannot determine version: set PI_AGENT_VERSION or add a VERSION file"
VERSION="${VERSION#v}"
# Package versions support SemVer core + prerelease, without build metadata.
# Reject path/XML characters and numeric identifiers with leading zeroes.
case "$VERSION" in *[!0-9A-Za-z.-]*) die 'version must be SemVer major.minor.patch[-prerelease], without build metadata' ;; esac
NUM='(0|[1-9][0-9]*)'
PRE="($NUM|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
printf '%s' "$VERSION" | grep -Eq "^$NUM\.$NUM\.$NUM(-$PRE(\.$PRE)*)?$" \
  || die 'version must be SemVer major.minor.patch[-prerelease], without build metadata'

TOOLS="${TOOLS:-$HERE/dist/tools-macos-$ARCH}"
[ -x "$TOOLS/bin/tmux" ] \
  || die "no bundled tmux at $TOOLS/bin/tmux -- run scripts/build-macos-tmux.sh (or pass --tools)"
file -b "$TOOLS/bin/tmux" | grep -q "Mach-O 64-bit executable $HOSTARCH" \
  || die "$TOOLS/bin/tmux is not a $HOSTARCH executable: $(file -b "$TOOLS/bin/tmux")"

# Expanded as ${KC_ARGS[@]+"${KC_ARGS[@]}"}: bash 3.2 (macOS /bin/bash) treats
# an empty array as unbound under set -u.
KC_ARGS=()
[ -n "$KEYCHAIN" ] && KC_ARGS=(--keychain "$KEYCHAIN")

ID="io.woowtech.pi-agent"
TITLE="Woow Pi Agent"
PAYLOAD="/usr/local/lib/woow-pi-agent"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pa-pkg.XXXXXX")"

# codesign finds an identity in a separate keychain only when that keychain is
# on the user's search list, even with --keychain (docs/OPERATIONS-GOTCHAS.md
# §11). And under a scoped $HOME -- which this project sets -- it finds nothing
# whichever list was edited. Measured on the build Mac, three ways:
#   list edited in scoped home, codesign with scoped HOME  -> no identity found
#   list edited in REAL home,   codesign with scoped HOME  -> no identity found
#   list edited in REAL home,   codesign with REAL HOME    -> signs
# So every keychain-facing tool here runs with the account's real home, and the
# search list is restored on exit, including on failure. Assumes keychain paths
# without spaces (true for ~/Library/Keychains and electron-builder's cache).
REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
as_real_home() { HOME="${REAL_HOME:-$HOME}" "$@"; }
real_home_security() { as_real_home security "$@"; }
ORIG_SEARCH_LIST=""

cleanup() {
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  if [ -n "$ORIG_SEARCH_LIST" ]; then
    # shellcheck disable=SC2086  # whitespace-separated keychain paths
    real_home_security list-keychains -d user -s $ORIG_SEARCH_LIST || true
  fi
}
trap cleanup EXIT
ROOT="$WORK/root"; SCRIPTS="$WORK/scripts"
mkdir -p "$ROOT$PAYLOAD" "$SCRIPTS"

# --- payload ------------------------------------------------------------------
# The installer itself, not a copy of anyone's install. No 2>/dev/null: a
# missing entry must stop the build, not quietly ship without it (vendor/ was
# once left out this way, and the omnigent stage skipped itself).
tar cf - -C "$HERE" install.sh lib rootfs scripts tests docs README.md vendor VERSION \
  | tar xf - -C "$ROOT$PAYLOAD"
# The resolved package version is authoritative inside the installed payload too.
printf '%s\n' "$VERSION" > "$ROOT$PAYLOAD/VERSION"
mkdir -p "$ROOT$PAYLOAD/tools"
cp -Rp "$TOOLS/." "$ROOT$PAYLOAD/tools/"
for f in install.sh lib/pins.sh vendor/omnigent-requirements.lock VERSION \
         rootfs/bin/flock rootfs/bin/pi-agent-env.sh tools/bin/tmux; do
  [ -e "$ROOT$PAYLOAD/$f" ] || die "payload is missing $f"
done
mkdir -p "$ROOT/Applications" "$WORK/resources"
cp "$HERE/scripts/macos/Pi-Agent.command" "$ROOT/Applications/Pi Agent.command"
cp "$HERE/scripts/macos/Pi-Agent.command" "$ROOT/Applications/Pi Agent Repair.command"
chmod 755 "$ROOT/Applications/"*.command
cat > "$WORK/resources/conclusion.html" <<'HTML'
<html><body><h1>Pi Agent</h1>
<p>Open Applications → Pi Agent.command to start Pi Agent in your browser.
Terminal shows startup progress. Internet is required for first setup.</p>
<p>If setup failed, open Pi Agent Repair.command to retry while keeping your data.
Setup logs: ~/.local/share/pi-agent/logs/macos-setup.log (or your existing custom install directory).
Installer log: /var/log/woow-pi-agent-install.log.</p></body></html>
HTML
# Write both selectors, including the empty one, so a mode switch overwrites
# stale manifests from an earlier installed package.
printf '%s\n' "$ART_NAME" > "$ROOT$PAYLOAD/piweb-artifact-file"
if [ -n "$ART_FILE" ]; then
  mkdir -p "$ROOT$PAYLOAD/artifacts"
  cp "$ART_FILE" "$ROOT$PAYLOAD/artifacts/$ART_NAME"
  [ "$(shasum -a 256 "$ROOT$PAYLOAD/artifacts/$ART_NAME" | awk '{print $1}')" = "$ART_SHA" ] || die 'staged artifact sha256 mismatch'
fi
printf '%s\n' "$ART_URL" > "$ROOT$PAYLOAD/piweb-artifact-url"
printf '%s\n' "$ART_SHA" > "$ROOT$PAYLOAD/piweb-artifact-sha256"
# Explicit, whatever the umask was (a second line of defence; the check after expansion is the third): owner
# read/write, everyone else read, and execute wherever the file or directory already has an execute bit.
# Includes the parent directories (/usr/local/lib ...), which a Mac without them would get from this payload.
chmod -R u+rwX,go+rX "$ROOT"

if [ -n "$SIGN_APP" ]; then
  if [ -n "$KEYCHAIN" ]; then
    ORIG_SEARCH_LIST="$(real_home_security list-keychains -d user | tr -d '"' | xargs)"
    # shellcheck disable=SC2086
    real_home_security list-keychains -d user -s "$KEYCHAIN" $ORIG_SEARCH_LIST
    say "signing keychain added to the search list for codesign (restored on exit)"
  fi
  # Developer ID + hardened runtime + secure timestamp: what notarization asks of
  # every Mach-O in a package. Replaces the linker's ad-hoc signature.
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    say "codesign ${f#"$ROOT"}"
    as_real_home codesign --force --options runtime --timestamp --sign "$SIGN_APP" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$f"
    as_real_home codesign --verify --strict --verbose=2 "$f"
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
    echo "no console user ('$USER_NAME'); cannot install per-user. Log in and open /Applications/Pi Agent.command to finish setup."
    exit 1 ;;
esac
USER_UID="$(id -u "$USER_NAME")" || exit 1
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "cannot resolve the home directory of $USER_NAME"; exit 1
fi

# The user helper validates the selected URL/local artifact and checksum.
echo "installing for $USER_NAME (uid $USER_UID) in $USER_HOME"

# launchctl asuser: the user's GUI session, which is what gives the install their
# login Keychain (Claude Code) and lets the service stage load a LaunchAgent.
# sudo -H plus an explicit HOME: macOS's sudoers keeps the caller's HOME, so
# without them install.sh would run with root's home and install there.
launchctl asuser "$USER_UID" sudo -H -u "$USER_NAME" /usr/bin/env \
  HOME="$USER_HOME" \
  /bin/bash "$PAYLOAD/scripts/macos/pi-agent-launch.sh" --install
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
# The synthesized distribution has no <title>, so Installer has no name to show:
# `installer: Package name is ` with nothing after it.
sed -i '' -E "s#(<installer-gui-script[^>]*>)#\\1<title>$TITLE</title>#" "$DIST"
grep -q "<title>$TITLE</title>" "$DIST" || die "could not give the pkg its title"
sed -i '' -E 's#</installer-gui-script>#<conclusion file="conclusion.html"/></installer-gui-script>#' "$DIST"
rm -f "$PKG"
productbuild --resources "$WORK/resources" --distribution "$DIST" --package-path "$WORK" "$PKG" >/dev/null

# --- verify what was actually built ---------------------------------------------
X="$WORK/expanded"
pkgutil --expand-full "$PKG" "$X" >/dev/null
P="$(find "$X" -type d -path "*/Payload$PAYLOAD" -print -quit)"
[ -n "$P" ] || die "expanded pkg has no $PAYLOAD"
[ "$(cat "$P/VERSION")" = "$VERSION" ] || die 'payload VERSION differs from package version'
# Read back Apple's parsed component metadata, not just our filename.
PACKAGE_INFO="${P%/Payload*}/PackageInfo"
[ -f "$PACKAGE_INFO" ] || die 'expanded component has no PackageInfo'
RECORDED_VERSION="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@version)' "$PACKAGE_INFO")"
[ "$RECORDED_VERSION" = "$VERSION" ] || die "pkgutil component version differs: $RECORDED_VERSION"
for entry in 'Pi Agent.command' 'Pi Agent Repair.command'; do
  launcher="${P%"$PAYLOAD"}/Applications/$entry"
  [ -n "$(find "$launcher" -perm -o+rx -print)" ] || die "launcher is missing or unreadable: $entry"
done
unreadable="$(find "$P" ! -perm -o+r -print | head -3 | sed "s#^$P/##" | tr '\n' ' ')"
[ -z "$unreadable" ] || die "payload entries are not readable by the user the postinstall hands the install to (builder umask $(umask)): $unreadable"
[ -n "$(find "$P/install.sh" -perm -o+x -print)" ] || die "payload install.sh is not executable by the user the postinstall hands the install to"
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
[ "$(head -n1 "$P/piweb-artifact-file")" = "$ART_NAME" ] || die 'artifact filename did not survive packaging'
if [ -n "$ART_FILE" ]; then
  [ "$(shasum -a 256 "$P/artifacts/$ART_NAME" | awk '{print $1}')" = "$ART_SHA" ] || die 'packaged artifact sha256 mismatch'
fi
[ -f "$P/vendor/omnigent-requirements.lock" ]             || die "vendor/ did not survive packaging"
say "payload verified: tools/bin/tmux is the only unpacked Mach-O; artifact pin and vendor/ present"

# --- sign and notarize --------------------------------------------------------
if [ -n "$SIGN_PKG" ]; then
  as_real_home productsign --timestamp --sign "$SIGN_PKG" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$PKG" "$PKG.signed"
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

if [ "$RELEASE" = 1 ]; then
  "$HERE/scripts/verify-macos-pkg.sh" "$PKG"
  say 'release gate passed (publication is a separate approval)'
fi

say "$PKG ($(du -h "$PKG" | cut -f1))"
