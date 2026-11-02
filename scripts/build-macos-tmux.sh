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
# tmux with libevent (core only), utf8proc and jemalloc linked statically, the
# system ncurses from /usr/lib, for arm64, minimum macOS 13.0.
#
# utf8proc is not optional: without it tmux takes character widths from the
# system wcwidth(), which gets East Asian widths wrong, and the people using
# this write Traditional Chinese. (tmux's own configure refuses to build on
# darwin without it for the same reason.)
#
# jemalloc is not optional either. On macOS, calloc(3) sometimes hands back a
# large allocation that is not zeroed (tmux issue 5385, seen on macOS 26 Apple
# silicon). A tmux on the system allocator then aborts now and then -- mostly
# on entering copy mode -- and every session on that server dies with it. The
# reports are "three aborts in 10 days" with history-limit 50000, which is what
# Omnigent sets. Upstream made jemalloc the macOS default in 3.7c; building
# without it is an explicit, discouraged opt-out.
#
# HOW JEMALLOC IS WIRED IN (and why not the way Homebrew does it)
#
# Homebrew builds jemalloc with an EMPTY prefix, so its dylib exports plain
# malloc/calloc/free and tmux's own calls bind to them by symbol while libc's
# internal allocations (strdup, asprintf, ...) still go through libc's
# allocator. tmux frees pointers libc allocated, so that split is a hazard,
# not a fix. Here jemalloc keeps its macOS default `je_` prefix and its zone
# allocator: a constructor (zone_register, src/zone.c) registers
# "jemalloc_zone" and promotes it to the DEFAULT malloc zone. From then on
# every malloc/calloc/realloc/free in the process -- tmux's and libc's alike --
# is dispatched to jemalloc by libc's own zone machinery, and pointers handed
# out before the promotion are still freed by the zone that owns them.
#
# Two things make that true, and the build checks both:
#   - the archive is linked with -force_load. Nothing references the object
#     file that holds the constructor, so a plain static link silently drops
#     it -- tmux links, runs, and keeps Apple's calloc;
#   - tmux's only call into jemalloc's own API, mallctl("version") in proc.c,
#     is mapped to je_mallctl. Nothing else is renamed.
#
# Every source tarball is pinned in lib/pins.sh by the sha256 Homebrew records
# for the same formula, and the build fails closed on a mismatch. It then checks
# its own output: only /usr/lib dependencies, minos 13.0, jemalloc serving the
# process's allocations through the default zone, and a private tmux server
# that round-trips Traditional Chinese with the right display widths.
#
#   scripts/build-macos-tmux.sh [outdir]      default: dist/tools-macos-arm64
#
# Output: <outdir>/bin/tmux, <outdir>/licenses/{tmux-COPYING,libevent-LICENSE,
# utf8proc-LICENSE.md,jemalloc-COPYING}, <outdir>/BUILDINFO
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
fetch_verify "$PIN_JEMALLOC_URL" "$PIN_JEMALLOC_SHA256" "$WORK/jemalloc.tar.bz2"
for t in tmux libevent utf8proc; do tar xzf "$WORK/$t.tar.gz" -C "$WORK/src"; done
tar xjf "$WORK/jemalloc.tar.bz2" -C "$WORK/src"

TMUX_SRC="$WORK/src/tmux-$PIN_TMUX_VERSION"
EVENT_SRC="$WORK/src/libevent-$PIN_LIBEVENT_VERSION"
UTF8_SRC="$WORK/src/utf8proc-$PIN_UTF8PROC_VERSION"
JEM_SRC="$WORK/src/jemalloc-$PIN_JEMALLOC_VERSION"

# The je_ prefix and the zone allocator are jemalloc's own macOS defaults;
# they are spelled out because the whole design depends on them (see header).
# --with-lg-page=14: every arm64 Mac uses 16 KiB pages, and pinning it keeps the
# build from depending on what the build host's configure probe happens to see.
# --disable-cxx: no operator new/delete, which -force_load would otherwise pull
# in together with a libc++ dependency tmux has no use for.
log "jemalloc $PIN_JEMALLOC_VERSION (static, je_ prefix, macOS zone allocator)"
( cd "$JEM_SRC"
  step jemalloc-configure ./configure --prefix="$DEPS" --with-jemalloc-prefix=je_ \
       --with-lg-page=14 --disable-cxx CFLAGS="$CFLAGS_ALL"
  step jemalloc-make make -j"$JOBS" build_lib_static
  step jemalloc-install make install_include install_lib_static )
JEM_DEFS="$JEM_SRC/include/jemalloc/internal/jemalloc_internal_defs.h"
grep -q '^#define JEMALLOC_ZONE' "$JEM_DEFS" \
  || die "jemalloc was configured without the macOS zone allocator"
grep -q '^#define LG_PAGE 14' "$JEM_DEFS" || die "jemalloc was not configured for 16 KiB pages"
[ -f "$DEPS/lib/libjemalloc.a" ] && [ -f "$DEPS/include/jemalloc/jemalloc.h" ] \
  || die "jemalloc's static library or header was not installed"

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
# JEMALLOC_CFLAGS maps tmux's single jemalloc API call (mallctl, proc.c) to the
# prefixed name and nothing else -- tmux's malloc/calloc/free stay libc's, which
# is what routes them through the default zone. JEMALLOC_LIBS force-loads the
# whole archive so the zone constructor is linked in (see header).
log "tmux $PIN_TMUX_VERSION (utf8proc, jemalloc zone, system ncurses, minos $MIN)"
( cd "$TMUX_SRC"
  step tmux-configure ./configure --prefix=/usr/local --disable-dependency-tracking \
       --enable-utf8proc --enable-jemalloc CFLAGS="$CFLAGS_ALL" \
       LIBEVENT_CORE_CFLAGS="-I$DEPS/include" LIBEVENT_CORE_LIBS="$DEPS/lib/libevent_core.a" \
       LIBUTF8PROC_CFLAGS="-I$DEPS/include" LIBUTF8PROC_LIBS="$DEPS/lib/libutf8proc.a" \
       JEMALLOC_CFLAGS="-I$DEPS/include -Dmallctl=je_mallctl" \
       JEMALLOC_LIBS="-Wl,-force_load,$DEPS/lib/libjemalloc.a"
  step tmux-make make -j"$JOBS" )
BIN="$TMUX_SRC/tmux"
[ -x "$BIN" ] || die "tmux was not built"
# Linked in, not merely detected: the static libraries' symbols must be in tmux.
# (Captured first: under pipefail, `nm | grep -q` fails whenever grep's early
# exit SIGPIPEs nm, which it does on a symbol table this size.)
syms="$(nm "$BIN" 2>/dev/null)"
grep -q '_utf8proc_charwidth' <<<"$syms" || die "tmux was built without utf8proc"
grep -q '_event_base_new'     <<<"$syms" || die "tmux was built without libevent"
grep -q ' _je_mallctl$'       <<<"$syms" || die "tmux was built without jemalloc"
grep -qE ' _(je_)?zone_register$' <<<"$syms" \
  || die "jemalloc's zone constructor is not in tmux (was -force_load lost?)"
# The opposite failure: an unprefixed jemalloc defining malloc & co in tmux
# itself, i.e. the override-by-symbol split this build exists to avoid.
if grep -qE ' T _(malloc|calloc|realloc|free)$' <<<"$syms"; then
  die "tmux defines malloc/calloc/realloc/free itself; jemalloc must not override by symbol"
fi

# ---- self-checks: refuse to emit a binary that would not work on a user's Mac.
log "checking the binary"
deps="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
bad="$(printf '%s\n' "$deps" | grep -v '^/usr/lib/' || true)"
[ -z "$bad" ] || die "tmux links outside /usr/lib: $bad"
minos="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos"{print $2; exit}')"
[ "$minos" = "$MIN" ] || die "tmux minos is '$minos', expected $MIN"
"$BIN" -V | grep -qx "tmux $PIN_TMUX_VERSION" || die "tmux -V does not report $PIN_TMUX_VERSION"

# jemalloc must be the DEFAULT malloc zone, not merely linked in. `tmux -V`
# never calls jemalloc's API, so jemalloc can only have served allocations --
# and print its statistics at exit -- if libc dispatched its own malloc to
# jemalloc's zone. (JE_MALLOC_CONF: the variable carries the je_ prefix.)
jstats="$(env -i JE_MALLOC_CONF=stats_print:true "$BIN" -V 2>&1 >/dev/null)"
jallocated="$(awk -F'[ ,]+' '/^Allocated:/{print $2; exit}' <<<"$jstats")"
[ "${jallocated:-0}" -gt 0 ] 2>/dev/null \
  || die "jemalloc is linked but is not the default malloc zone: no allocation reached it during tmux -V"

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
install -m 0644 "$JEM_SRC/COPYING"      "$OUT/licenses/jemalloc-COPYING"
{
  echo "tmux      $PIN_TMUX_VERSION      $PIN_TMUX_SHA256"
  echo "libevent  $PIN_LIBEVENT_VERSION  $PIN_LIBEVENT_SHA256  (static, core only)"
  echo "utf8proc  $PIN_UTF8PROC_VERSION  $PIN_UTF8PROC_SHA256  (static)"
  echo "jemalloc  $PIN_JEMALLOC_VERSION  $PIN_JEMALLOC_SHA256  (static, je_ prefix, default malloc zone)"
  echo "ncurses   system (/usr/lib)"
  echo "arch      arm64"
  echo "minos     $minos"
  echo "binary    sha256 $(sha256_of "$OUT/bin/tmux")"
} > "$OUT/BUILDINFO"

log "built $OUT/bin/tmux ($(du -h "$OUT/bin/tmux" | cut -f1), minos $minos)"
log "  sha256: $(sha256_of "$OUT/bin/tmux")"
log "  links:  $(printf '%s ' $deps)"
log "  CJK:    台灣報告 round-trips, cursor at column $cursor (2 columns each)"
log "  malloc: jemalloc is the default zone ($jallocated bytes served during tmux -V)"
