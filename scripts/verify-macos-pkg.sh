#!/bin/bash
# Read-only distribution gate; needs macOS and Apple's trust services, no keys.
set -euo pipefail
[ "$#" = 1 ] && [ -f "$1" ] || { echo 'usage: verify-macos-pkg.sh artifact.pkg' >&2; exit 64; }
[ "$(uname -s)" = Darwin ] || { echo 'macOS is required for signature/trust validation' >&2; exit 1; }
PKG="$1"
SIG="$(pkgutil --check-signature "$PKG")"
printf '%s\n' "$SIG"
printf '%s\n' "$SIG" | grep -q 'Developer ID Installer:'
xcrun stapler validate "$PKG"
spctl --assess --verbose=2 --type install "$PKG"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pa-pkgverify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pkgutil --expand-full "$PKG" "$WORK/expanded"
TMUX="$(find "$WORK/expanded" -type f -path '*/Payload/usr/local/lib/woow-pi-agent/tools/bin/tmux' -print -quit)"
[ -n "$TMUX" ]
codesign --verify --strict --verbose=2 "$TMUX"
DETAIL="$(codesign --display --verbose=4 "$TMUX" 2>&1)"
printf '%s\n' "$DETAIL"
printf '%s\n' "$DETAIL" | grep -q 'Authority=Developer ID Application:'
printf '%s\n' "$DETAIL" | grep -q 'flags=.*runtime'
printf '%s\n' "$DETAIL" | grep -q '^Timestamp='
echo 'PASS: Installer identity, staple, Gatekeeper, tmux Developer ID/runtime/timestamp'
