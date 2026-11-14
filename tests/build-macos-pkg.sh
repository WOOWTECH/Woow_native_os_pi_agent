#!/bin/bash
# The macOS pkg builder must produce a payload the INSTALLING user can read and run, whatever umask the
# builder happens to run under.
#
# Why this exists. v0.2.3's pkg was built from a shell whose umask was 077 -- inherited from an Omnigent host
# that a cutover had started with the cutover worker's strict umask. `tar xf -` as a normal user applies the
# umask, so every payload file came out 600/700, owned by root after install: the postinstall hands the work to
# the console user, who could not read install.sh ("Permission denied", exit 126), and the install never began.
#
#   tests/build-macos-pkg.sh
#   PI_TEST_BUILDER=/path/to/an/older/build-macos-pkg.sh tests/build-macos-pkg.sh    (expect failures: that is the check)
#
# Hermetic: builds UNSIGNED into a temp directory, with a stand-in for the bundled tmux (a copy of /usr/bin/true,
# which is a Mach-O like the real thing). It needs no signing key, no network and no Apple service.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER="${PI_TEST_BUILDER:-$HERE/scripts/build-macos-pkg.sh}"
TEST_VERSION=0.3.0-rc.8
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

[ "$(uname -s)" = Darwin ] || { echo "SKIP: macOS only (pkgbuild)"; exit 0; }
for t in pkgbuild productbuild pkgutil; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: no $t"; exit 0; }; done

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-pkgmodes.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tools/bin" "$W/out"
cp /usr/bin/true "$W/tools/bin/tmux"
case "$(uname -m)" in arm64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) exit 1 ;; esac
SHA="$(printf '0%.0s' $(seq 1 64))"

# build_under UMASK: build in a fresh subshell with that umask; leaves the pkg in $W/out/<umask>/
build_under() {
  mkdir -p "$W/out/$1"
  ( umask "$1"; PI_AGENT_VERSION="$TEST_VERSION" "$BUILDER" --artifact-url "https://example.invalid/piweb-0.0.0-macos-$ARCH.tar.gz" --artifact-sha256 "$SHA" \
      --tools "$W/tools" --out "$W/out/$1" ) > "$W/build-$1.log" 2>&1
}
# payload_of UMASK: expands the built pkg (under a normal umask, so the expansion itself cannot mask anything)
payload_of() {
  rm -rf "$W/x-$1"
  ( umask 022; pkgutil --expand-full "$W/out/$1"/WoowPiAgent-*.pkg "$W/x-$1" >/dev/null 2>&1 )
  find "$W/x-$1" -type d -path '*/Payload/usr/local/lib/woow-pi-agent' -print -quit
}

for U in 022 077; do
  echo "== built under umask $U"
  if build_under "$U"; then ok "the build succeeds under umask $U"; else
    # a builder that refuses to build a pkg the user could not read is also a pass for the 077 case
    if [ "$U" = 077 ] && grep -q 'not readable' "$W/build-$U.log"; then ok "the build refuses under umask $U, saying the payload would be unreadable"; continue; fi
    no "the build succeeds under umask $U" "$(tail -3 "$W/build-$U.log")"; continue
  fi
  # the name Installer shows: the synthesized distribution has none unless the builder gives it one
  name="$(installer -pkginfo -pkg "$W/out/$U"/WoowPiAgent-*.pkg 2>/dev/null | head -1)"
  if [ "$name" = "Woow Pi Agent" ]; then ok "installer shows the pkg's name (umask $U)"; else no "installer shows the pkg's name (umask $U)" "it prints '$name'"; fi
  P="$(payload_of "$U")"
  if [ -z "$P" ] || [ ! -d "$P" ]; then no "the pkg has the payload directory" "not found under $W/x-$U"; continue; fi
  if [ -f "$W/out/$U/WoowPiAgent-$TEST_VERSION-macos-$ARCH.pkg" ] && [ "$(cat "$P/VERSION")" = "$TEST_VERSION" ]; then
    ok "version override reaches filename and payload (umask $U)"
  else no "version override reaches filename and payload (umask $U)"; fi
  component="${P%/Payload*}/PackageInfo"
  actual="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@version)' "$component" 2>/dev/null)"
  if [ "$actual" = "$TEST_VERSION" ]; then ok "pkgutil expands the exact prerelease component version (umask $U)"
  else no "pkgutil expands the exact prerelease component version (umask $U)" "got: $actual"; fi
  for entry in 'Pi Agent.command' 'Pi Agent Repair.command'; do
    launcher="${P%/usr/local/lib/woow-pi-agent}/Applications/$entry"
    if [ -f "$launcher" ] && [ -n "$(find "$launcher" -perm -o+rx -print)" ]; then
      ok "$entry is readable and executable under umask $U"
    else no "$entry is readable and executable under umask $U"; fi
  done
  if [ -f "$P/scripts/macos/pi-agent-launch.sh" ]; then ok 'shared first-run helper is packaged'; else no 'shared first-run helper is packaged'; fi
  unreadable="$(find "$P" ! -perm -o+r -print | sed "s#^$P/##" | head -4 | tr '\n' ' ')"
  if [ -z "$unreadable" ]; then ok "every payload file and directory is readable by other users (umask $U)"; else no "every payload file and directory is readable by other users (umask $U)" "e.g. $unreadable"; fi
  untraversable="$(find "$P" -type d ! -perm -o+x -print | sed "s#^$P/##" | head -4 | tr '\n' ' ')"
  if [ -z "$untraversable" ]; then ok "every payload directory can be entered by other users (umask $U)"; else no "every payload directory can be entered by other users (umask $U)" "e.g. $untraversable"; fi
  # what the source tree runs, the installed copy must run -- for the installing user, not only for root
  lost=""
  for f in install.sh rootfs/bin/pi rootfs/bin/claude rootfs/bin/no-dev-tools/git rootfs/bin/pi-web-start.sh rootfs/bin/pi-agent-session-home rootfs/bin/pi-agent-session-home-macos; do
    [ -x "$HERE/$f" ] && [ ! -x "$P/$f" -o -z "$(find "$P/$f" -perm -o+x -print 2>/dev/null)" ] && lost="$lost $f"
  done
  if [ -z "$lost" ]; then ok "install.sh and the scripts it installs stay executable for other users (umask $U)"; else no "install.sh and the scripts it installs stay executable for other users (umask $U)" "lost:$lost"; fi
done

echo
printf 'macOS pkg builder, payload permissions: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
