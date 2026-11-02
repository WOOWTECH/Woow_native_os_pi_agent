#!/usr/bin/env bash
# Build a macOS .pkg that installs Pi Agent for the user who runs it.
#
# WHAT IS IN IT
#
# The installer payload is the repo plus a prebuilt pi-web tree (~145 MB). That
# is the piece that otherwise costs ~15 minutes and a full toolchain, so
# bundling it is what makes this usable by someone who just downloaded a file.
# The remaining stages (scoped Node, the Claude/Codex CLIs, the Paseo runtime,
# the Omnigent venv) are ordinary downloads and still need a network.
#
# WHY postinstall DROPS PRIVILEGES
#
# pkg postinstall runs as root, but this installs into the user's own
# ~/.local/share/pi-agent and must end up owned by them -- and Claude Code reads
# its credentials from the user's login Keychain, which root cannot see. So the
# script re-enters the console user's GUI session with `launchctl asuser`.
# Installing as root would produce a tree the user cannot write and an engine
# that reports "Not logged in".
#
#   scripts/build-macos-pkg.sh <prebuilt-piweb.tar.gz> [outdir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${1:?usage: build-macos-pkg.sh <prebuilt-piweb.tar.gz> [outdir]}"
OUT="${2:-$HERE/dist}"
[ -f "$ART" ] || { echo "no such artifact: $ART" >&2; exit 1; }

# Version, in order of trust: explicit env, a VERSION file shipped with the
# payload, then git. The payload is unpacked outside a git checkout when CI or a
# build host uses it, and silently stamping 0.0.0 there produces a pkg that
# looks releasable and is not.
VERSION="${PI_AGENT_VERSION:-}"
[ -n "$VERSION" ] || VERSION="$(cat "$HERE/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="$(git -C "$HERE" describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "cannot determine version: set PI_AGENT_VERSION or add a VERSION file" >&2; exit 1; }
VERSION="${VERSION#v}"
ID="io.woowtech.pi-agent"
ROOT="$(mktemp -d)/root"
SCRIPTS="$(mktemp -d)/scripts"
PAYLOAD="/usr/local/lib/woow-pi-agent"
trap 'rm -rf "$(dirname "$ROOT")" "$(dirname "$SCRIPTS")"' EXIT

mkdir -p "$ROOT$PAYLOAD" "$SCRIPTS"
# Ship the installer itself, not a copy of the user's install.
tar cf - -C "$HERE" install.sh lib rootfs scripts tests docs README.md 2>/dev/null \
  | tar xf - -C "$ROOT$PAYLOAD"
cp "$ART" "$ROOT$PAYLOAD/piweb-prebuilt.tar.gz"

cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
# Runs as root. Hand the work to the console user inside their GUI session.
set -u
PAYLOAD=/usr/local/lib/woow-pi-agent
LOG=/var/log/woow-pi-agent-install.log
exec >>"$LOG" 2>&1
echo "=== $(date) pi-agent postinstall ==="

USER_NAME="$(stat -f%Su /dev/console)"
USER_UID="$(id -u "$USER_NAME")"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = root ]; then
  echo "no console user; cannot install per-user. Run install.sh manually." >&2
  exit 1
fi
echo "installing for $USER_NAME ($USER_UID)"

# launchctl asuser puts us in that user's GUI session, which is what gives the
# install access to their login Keychain (Claude Code) and their Homebrew.
launchctl asuser "$USER_UID" sudo -u "$USER_NAME" \
  /bin/bash -lc "PI_AGENT_PIWEB_ARTIFACT='$PAYLOAD/piweb-prebuilt.tar.gz' '$PAYLOAD/install.sh'"
rc=$?
echo "install.sh exit=$rc"
exit $rc
POST
chmod +x "$SCRIPTS/postinstall"

mkdir -p "$OUT"
RAW="$OUT/.pi-agent-component.pkg"
PKG="$OUT/WoowPiAgent-$VERSION.pkg"

pkgbuild --root "$ROOT" --scripts "$SCRIPTS" \
         --identifier "$ID" --version "$VERSION" \
         --install-location / "$RAW" >/dev/null

productbuild --package "$RAW" "$PKG" >/dev/null
rm -f "$RAW"

# Sign only if a Developer ID Installer identity is present. Without one the pkg
# still installs, but Gatekeeper warns the user it is from an unidentified
# developer -- fine for internal use, not for public download.
IDENTITY="$(security find-identity -v 2>/dev/null | grep -m1 "Developer ID Installer" | sed 's/.*"\(.*\)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  productsign --sign "$IDENTITY" "$PKG" "$PKG.signed" && mv "$PKG.signed" "$PKG"
  echo "[build-macos-pkg] signed with: $IDENTITY"
  echo "[build-macos-pkg] next: xcrun notarytool submit '$PKG' --keychain-profile <profile> --wait && xcrun stapler staple '$PKG'"
else
  echo "[build-macos-pkg] WARNING: no 'Developer ID Installer' identity — the pkg is UNSIGNED."
  echo "[build-macos-pkg] Gatekeeper will refuse it on other Macs. For public download you need a"
  echo "[build-macos-pkg] Developer ID Installer certificate and notarization."
fi

echo "[build-macos-pkg] $PKG ($(du -h "$PKG" | cut -f1))"
