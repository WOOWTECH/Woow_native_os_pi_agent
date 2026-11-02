#!/usr/bin/env bash
# Package an already-built pi-web tree into a release asset.
#
# WHY THIS EXISTS
#
# The `piweb` install stage builds pi-web from source: git fetch a pinned ref,
# apply the Omnigent/Paseo settings patch, `npm ci --include=dev`, `npm run
# build`. That takes ~15 minutes and needs a full toolchain (Xcode CLT or
# build-essential). Fine for the engineer track; impossible to ask of someone
# double-clicking an installer.
#
# So CI runs the build once per platform and publishes the finished tree as a
# release asset. install.sh consumes it with PI_AGENT_PIWEB_ARTIFACT and skips
# the build entirely.
#
# The artifact is PLATFORM-SPECIFIC: node_modules carries native builds
# (node-pty above all), so a darwin-arm64 tree cannot be used on linux-x64.
# The name records that, and the installer checks it.
#
#   scripts/build-piweb-artifact.sh [outdir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"

OUT="${1:-$HERE/dist}"
OS="$(pa_os)"; ARCH="$(pa_arch)"
# WSL produces a linux tree; label it linux so the asset is reusable there.
[ "$OS" = wsl ] && OS=linux

TREE="$PA_PIWEB_DIR"
[ -d "$TREE/lib/node_modules/@agegr/pi-web/.next" ] || die "no built pi-web at $TREE — run ./install.sh piweb first"

# Refuse to ship a tree whose build cache was left in: it is ~600 MB of dead
# weight and the installer strips it, so its presence means a stale build.
CACHE="$TREE/lib/node_modules/@agegr/pi-web/.next/cache"
[ -d "$CACHE" ] && { log "stripping leftover .next/cache before packaging"; rm -rf "$CACHE"; }

NAME="piweb-${PIN_PI_WEB_VERSION}-${OS}-${ARCH}.tar.gz"
mkdir -p "$OUT"

log "packaging $TREE → $OUT/$NAME"
# Store paths relative to the piweb dir so the tree can be extracted under any
# PI_AGENT_HOME, whatever the installing user is called.
tar czf "$OUT/$NAME" -C "$TREE" .

( cd "$OUT" && sha256_of "$NAME" > "$NAME.sha256" && printf '%s  %s\n' "$(cat "$NAME.sha256")" "$NAME" > "$NAME.sha256" )

log "built $NAME ($(du -h "$OUT/$NAME" | cut -f1))"
log "  sha256: $(awk '{print $1}' "$OUT/$NAME.sha256")"
log "  pi-web ${PIN_PI_WEB_VERSION} @ ${PIN_PI_WEB_REF:0:12} for ${OS}-${ARCH}"
