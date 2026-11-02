#!/usr/bin/env bash
# Build the tmux that ships inside the macOS pkg.
#
# WHY IT IS BUNDLED
#
# Omnigent's native Pi harness runs the Pi TUI inside a private tmux server, so
# a Mac without tmux cannot run Pi sessions through Omnigent at all. Most users
# do not have it, and asking them to install Homebrew first is the wrong trade
# for an app-scoped install.
#
# WHY IT IS BUILT FROM SOURCE
#
# Homebrew's tmux cannot be redistributed. Its binary is built for the host it
# was poured on (minos 26.0 on the release host, so it will not even start on an
# older macOS) and it links four Homebrew dylibs -- utf8proc, ncursesw 6,
# libevent_core and jemalloc -- at /opt/homebrew paths that do not exist on a
# user's Mac.
#
# WHAT THIS BUILDS
#
# tmux with libevent (core only) and utf8proc linked statically, the system
# ncurses from /usr/lib, no jemalloc, for arm64, minimum macOS 13.0. utf8proc is
# not optional: without it tmux takes character widths from the system
# wcwidth(), which gets East Asian widths wrong, and the people using this
# write Traditional Chinese. (tmux's own configure refuses to build on darwin
# without it for the same reason.)
#
# Every source tarball is pinned in lib/pins.sh by the sha256 Homebrew records
# for the same formula, and the build fails closed on a mismatch. It then checks
# its own output: only /usr/lib dependencies, minos 13.0, and a private tmux
# server that round-trips Traditional Chinese with the right display widths.
#
#   scripts/build-macos-tmux.sh [outdir]      default: dist/tools-macos-arm64
#
# Output: <outdir>/bin/tmux, <outdir>/licenses/{tmux-COPYING,libevent-LICENSE,
# utf8proc-LICENSE.md}, <outdir>/BUILDINFO
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"

OUT="${1:-$HERE/dist/tools-macos-arm64}"
MIN="$PIN_TMUX_MACOS_MIN"

[ "$(uname -s)" = Darwin ] || die "build-macos-tmux.sh runs on macOS"
[ "$(uname -m)" = arm64 ]  || die "this builds the arm64 tmux; run it on an Apple-silicon Mac"
xcode-select -p >/dev/null 2>&1 || die "needs the Xcode Command Line Tools (clang, make, ar): xcode-select --install"

# A build that can see Homebrew links Homebrew: its pkg-config would hand tmux's
# configure ncursesw from /opt/homebrew. Build with the system toolchain only.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CPATH C_INCLUDE_PATH LIBRARY_PATH CPPFLAGS LDFLAGS CFLAGS \
      PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR 2>/dev/null || true
export MACOSX_DEPLOYMENT_TARGET="$MIN"
export CC=clang
CFLAGS_ALL="-arch arm64 -mmacosx-version-min=$MIN -O2"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pa-tmux-build.XXXXXX")"
# Remove the build tree on success; keep it on failure so the logs can be read.
cleanup() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  else echo "build tree kept for inspection: $WORK" >&2; fi
}
trap cleanup EXIT
DEPS="$WORK/deps"
mkdir -p "$WORK/src" "$DEPS/include" "$DEPS/lib"

# step <logname> <command...>: run quietly, show the log tail on failure.
step() {
  local name="$1"; shift
  if ! "$@" >"$WORK/$name.log" 2>&1; then
    tail -40 "$WORK/$name.log" >&2
    die "$name failed (log above)"
  fi
}

fetch_verify "$PIN_TMUX_URL"     "$PIN_TMUX_SHA256"     "$WORK/tmux.tar.gz"
fetch_verify "$PIN_LIBEVENT_URL" "$PIN_LIBEVENT_SHA256" "$WORK/libevent.tar.gz"
fetch_verify "$PIN_UTF8PROC_URL" "$PIN_UTF8PROC_SHA256" "$WORK/utf8proc.tar.gz"
for t in tmux libevent utf8proc; do tar xzf "$WORK/$t.tar.gz" -C "$WORK/src"; done

TMUX_SRC="$WORK/src/tmux-$PIN_TMUX_VERSION"
EVENT_SRC="$WORK/src/libevent-$PIN_LIBEVENT_VERSION"
UTF8_SRC="$WORK/src/utf8proc-$PIN_UTF8PROC_VERSION"

log "libevent $PIN_LIBEVENT_VERSION (static, core only, no openssl)"
( cd "$EVENT_SRC"
  step libevent-configure ./configure --prefix="$DEPS" --disable-shared --enable-static \
       --disable-openssl --disable-samples --disable-libevent-regress --disable-debug-mode \
       --disable-dependency-tracking CFLAGS="$CFLAGS_ALL"
  step libevent-make make -j"$JOBS"
  step libevent-install make install )
[ -f "$DEPS/lib/libevent_core.a" ] || die "libevent_core.a was not built"

log "utf8proc $PIN_UTF8PROC_VERSION (static)"
( cd "$UTF8_SRC"
  step utf8proc-make make libutf8proc.a CC=clang AR=ar CFLAGS="$CFLAGS_ALL" )
cp "$UTF8_SRC/utf8proc.h" "$DEPS/include/"
cp "$UTF8_SRC/libutf8proc.a" "$DEPS/lib/"

# tmux's configure takes these variables in place of pkg-config, and with no
# pkg-config on PATH ncurses falls through to the system -lncurses.
#
# --disable-jemalloc is a deliberate, owner-decided choice, and upstream
# disagrees with it: since 3.7c tmux's configure REQUIRES an explicit choice on
# darwin and recommends jemalloc, "to avoid what appears to be a bug in calloc"
# (tmux issue 5385, CHANGES 3.7b -> 3.7c). If that bug shows up as corrupt panes
# or crashes, the fix is a static jemalloc built here the same way as libevent,
# which keeps the binary's dependencies inside /usr/lib.
log "tmux $PIN_TMUX_VERSION (utf8proc, system ncurses, no jemalloc, minos $MIN)"
( cd "$TMUX_SRC"
  step tmux-configure ./configure --prefix=/usr/local --disable-dependency-tracking \
       --enable-utf8proc --disable-jemalloc CFLAGS="$CFLAGS_ALL" \
       LIBEVENT_CORE_CFLAGS="-I$DEPS/include" LIBEVENT_CORE_LIBS="$DEPS/lib/libevent_core.a" \
       LIBUTF8PROC_CFLAGS="-I$DEPS/include" LIBUTF8PROC_LIBS="$DEPS/lib/libutf8proc.a"
  step tmux-make make -j"$JOBS" )
BIN="$TMUX_SRC/tmux"
[ -x "$BIN" ] || die "tmux was not built"
# Linked in, not merely detected: the static library's symbols must be in tmux.
# (Captured first: under pipefail, `nm | grep -q` fails whenever grep's early
# exit SIGPIPEs nm, which it does on a symbol table this size.)
syms="$(nm "$BIN" 2>/dev/null)"
grep -q '_utf8proc_charwidth' <<<"$syms" || die "tmux was built without utf8proc"
grep -q '_event_base_new'     <<<"$syms" || die "tmux was built without libevent"

# ---- self-checks: refuse to emit a binary that would not work on a user's Mac.
log "checking the binary"
deps="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
bad="$(printf '%s\n' "$deps" | grep -v '^/usr/lib/' || true)"
[ -z "$bad" ] || die "tmux links outside /usr/lib: $bad"
minos="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos"{print $2; exit}')"
[ "$minos" = "$MIN" ] || die "tmux minos is '$minos', expected $MIN"
"$BIN" -V | grep -qx "tmux $PIN_TMUX_VERSION" || die "tmux -V does not report $PIN_TMUX_VERSION"

# A private server, configured the way Omnigent runs it: own socket, no config
# file, C.UTF-8 (Omnigent forces that when the environment has no UTF-8 locale).
SOCK="$WORK/check.sock"
T() { env -i HOME="$WORK" PATH=/usr/bin:/bin TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "$BIN" -S "$SOCK" -f /dev/null "$@"; }
T new-session -d -s check -x 60 -y 6 /bin/cat
T send-keys -t check -l '台灣報告'
sleep 0.5
# The tty echoes the four characters; each is two columns wide, so the cursor
# must sit at column 8. A system-wcwidth tmux gets this wrong.
cursor="$(T display-message -p -t check '#{cursor_x}')"
T send-keys -t check Enter
sleep 0.5
pane="$(T capture-pane -p -t check)"
T kill-server 2>/dev/null || true
[ "$cursor" = 8 ] || die "CJK width check failed: cursor at column $cursor after 台灣報告 (expected 8)"
hits="$(printf '%s\n' "$pane" | grep -c '台灣報告' || true)"
[ "$hits" -ge 2 ] || die "CJK round trip failed: capture-pane returned: $pane"

mkdir -p "$OUT/bin" "$OUT/licenses"
install -m 0755 "$BIN" "$OUT/bin/tmux"
install -m 0644 "$TMUX_SRC/COPYING"     "$OUT/licenses/tmux-COPYING"
install -m 0644 "$EVENT_SRC/LICENSE"    "$OUT/licenses/libevent-LICENSE"
install -m 0644 "$UTF8_SRC/LICENSE.md"  "$OUT/licenses/utf8proc-LICENSE.md"
{
  echo "tmux      $PIN_TMUX_VERSION      $PIN_TMUX_SHA256"
  echo "libevent  $PIN_LIBEVENT_VERSION  $PIN_LIBEVENT_SHA256  (static, core only)"
  echo "utf8proc  $PIN_UTF8PROC_VERSION  $PIN_UTF8PROC_SHA256  (static)"
  echo "ncurses   system (/usr/lib)"
  echo "arch      arm64"
  echo "minos     $minos"
  echo "binary    sha256 $(sha256_of "$OUT/bin/tmux")"
} > "$OUT/BUILDINFO"

log "built $OUT/bin/tmux ($(du -h "$OUT/bin/tmux" | cut -f1), minos $minos)"
log "  sha256: $(sha256_of "$OUT/bin/tmux")"
log "  links:  $(printf '%s ' $deps)"
log "  CJK:    台灣報告 round-trips, cursor at column $cursor (2 columns each)"
