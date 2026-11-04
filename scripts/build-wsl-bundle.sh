#!/usr/bin/env bash
# Build the release bundle for the Windows (WSL2) installer.
#
#   scripts/build-wsl-bundle.sh OUTDIR VERSION [--tag TAG]    a release
#   scripts/build-wsl-bundle.sh OUTDIR dev                    what CI builds from a branch
#
# Writes to OUTDIR:
#   pi-agent-installer-<VERSION>.tar.gz (+ .sha256)   `git archive` of HEAD under one
#       directory. The Windows-side installer unpacks it inside the new distro and runs
#       install.sh from it. Same commit, same bytes: the sha256 published with a release
#       is worth something only if somebody else can rebuild it.
#   install-wsl.ps1   (release only) windows/install-wsl.ps1 with its @@PLACEHOLDERS@@
#       replaced by this release's version, URLs and the bundle's sha256, and a UTF-8 BOM
#       in front: Windows PowerShell 5.1 reads a file without one in the system code page
#       (950 on a Traditional Chinese Windows) and every Chinese message turns to mojibake.
#   Install-Pi-Agent.cmd   (release only) the file people double-click: downloads that
#       install-wsl.ps1 and runs it. CRLF, because cmd.exe can lose its place in a file with bare LF.
#
# Everything is built in a temporary directory and moved into OUTDIR only when all of it
# is right, so a mistake never leaves half a release behind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS_SRC="windows/install-wsl.ps1"
CMD_SRC="windows/install-pi-agent.cmd.in"
GUIDE="docs/WSL2.md"
PREFIX="woow-pi-agent-installer"
SLUG="${PA_REPO_SLUG:-WOOWTECH/Woow_native_os_pi_agent}"

die() { echo "build-wsl-bundle: $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
has_bom() { [ "$(head -c3 "$1" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; }

[ $# -ge 2 ] || die "usage: build-wsl-bundle.sh OUTDIR VERSION|dev [--tag TAG]"
out="$1"; ver="$2"; shift 2
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || die "--tag needs a value"; tag="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ "$ver" != dev ]; then
  printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' || die "'$ver' is not a version (1.2.3) or 'dev'"
fi
cd "$ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout"
# The bundle carries VERSION into the VM, where install.sh and the distro marker read it.
if [ "$ver" != dev ] && [ "$(tr -d '[:space:]' < VERSION)" != "$ver" ]; then
  die "the VERSION file says $(tr -d '[:space:]' < VERSION), not $ver: bump VERSION and commit before building a release"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/pa-wsl-bundle.XXXXXX")"
trap 'rm -rf "$work"' EXIT

name="pi-agent-installer-$ver.tar.gz"
# core.autocrlf=true (the Windows default) is applied by `git archive` too, and bash inside the VM stops
# at `set -euo pipefail\r`: found on the first hosted-runner run. .gitattributes pins LF for the scripts;
# this keeps any other file as committed as well.
git -c core.autocrlf=false -c core.eol=lf archive --format=tar.gz --prefix="$PREFIX/" -o "$work/$name" HEAD
sha="$(sha256 "$work/$name")"
printf '%s  %s\n' "$sha" "$name" > "$work/$name.sha256"

if [ "$ver" != dev ]; then
  # The guide's command is what people paste. `releases/latest` never resolves to a pre-release, so a
  # preview has to name itself; a release has to go back to latest, or it sends everybody to the old preview.
  case "$ver" in
    *-*) want="/releases/download/${tag:-v$ver}/install-wsl.ps1" ;;
    *)   want="/releases/latest/download/install-wsl.ps1" ;;
  esac
  cmd_url="$(git show "HEAD:$GUIDE" 2>/dev/null | sed -n "s/^\\\$u = '\(.*\)'.*/\1/p" | head -1 || true)"
  case "$cmd_url" in
    *"$want") ;;
    *) die "the install command in $GUIDE points at '${cmd_url:-nothing}', not ...$want" ;;
  esac

  # The script as committed -- what the bundle carries -- not the working copy.
  git show "HEAD:$PS_SRC" > "$work/ps.in" 2>/dev/null || die "$PS_SRC is not committed"
  pv="$(sed -n 's/^PIN_PI_WEB_VERSION=\([^ #]*\).*/\1/p' lib/pins.sh | head -1)"
  [ -n "$pv" ] || die "no PIN_PI_WEB_VERSION in lib/pins.sh"
  base="https://github.com/$SLUG/releases/download/${tag:-v$ver}"
  sed -e "s|@@VERSION@@|$ver|g" \
      -e "s|@@BUNDLE_URL@@|$base/$name|g" \
      -e "s|@@BUNDLE_SHA256@@|$sha|g" \
      -e "s|@@SCRIPT_URL@@|$base/install-wsl.ps1|g" \
      -e "s|@@PIWEB_URL_X64@@|$base/piweb-$pv-linux-x64.tar.gz|g" \
      -e "s|@@PIWEB_URL_ARM64@@|$base/piweb-$pv-linux-arm64.tar.gz|g" \
      "$work/ps.in" > "$work/ps.stamped"
  left="$(grep -Eo '@@[A-Z0-9_]+@@' "$work/ps.stamped" | head -1 || true)"
  [ -z "$left" ] || die "$PS_SRC has a placeholder this script does not know: $left"
  { has_bom "$work/ps.stamped" || printf '\357\273\277'; cat "$work/ps.stamped"; } > "$work/install-wsl.ps1"

  git show "HEAD:$CMD_SRC" > "$work/cmd.in" 2>/dev/null || die "$CMD_SRC is not committed"
  sed -e "s|@@SCRIPT_URL@@|$base/install-wsl.ps1|g" "$work/cmd.in" \
    | awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' > "$work/Install-Pi-Agent.cmd"
  left="$(grep -Eo '@@[A-Z0-9_]+@@' "$work/Install-Pi-Agent.cmd" | head -1 || true)"
  [ -z "$left" ] || die "$CMD_SRC has a placeholder this script does not know: $left"
fi

mkdir -p "$out"
cp "$work/$name" "$work/$name.sha256" "$out/"
if [ "$ver" != dev ]; then cp "$work/install-wsl.ps1" "$work/Install-Pi-Agent.cmd" "$out/"; fi
echo "built $out/$name"
echo "  sha256: $sha"
if [ "$ver" != dev ]; then echo "  stamped $out/install-wsl.ps1 and Install-Pi-Agent.cmd for ${tag:-v$ver}"; fi
