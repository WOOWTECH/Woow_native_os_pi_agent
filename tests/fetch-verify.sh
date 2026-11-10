#!/bin/bash
# fetch_verify (lib/common.sh): install from copies fetched beforehand, and give a failing download more time.
#
# Why this exists. On 2026-11-09 GitHub answered HTTP 504 to all five tries for the pinned
# woowtech-pi-omnigent-plugin-0.3.31.tgz and the install stopped, on an H618 board. curl's own backoff between
# those tries (1, 2, 4, 8, 16 s) gave the 5xx about 30 s in all to clear, and there was no way to hand the
# installer the asset by other means.
#
#   A  PI_AGENT_ASSET_CACHE: a file named like the URL's last part (the asset's own name) or like DEST is copied and
#      nothing is downloaded; the sha256 check still runs and refuses a wrong copy; the cache is left as it was
#   B  without a cached copy curl runs as before, now with a delay between tries and a limit on the total time
#   C  install.sh's real fetch stage while every download fails: it installs both plugins from the cache
#
#   tests/fetch-verify.sh
#   PI_TEST_COMMON=/path/to/an/older/lib/common.sh tests/fetch-verify.sh     (expect failures: that is the check)
#
# Hermetic: a temp directory and a stand-in curl, first on PATH, that notes its arguments and then fails, or serves a
# file. C needs the pinned plugin tarballs: PA_TEST_PLUGIN_TGZ and PA_TEST_PASEO_TGZ, else the copies in
# PA_TEST_CACHE, else one download each -- refused unless its sha256 equals lib/pins.sh.
#
# Environment (all optional): PA_TEST_NODE, PA_TEST_PLUGIN_TGZ, PA_TEST_PASEO_TGZ, PA_TEST_CACHE (as the other suites)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="${PI_TEST_COMMON:-$HERE/lib/common.sh}"
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"
pass=0; fail=0; skipped=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; skipped=$((skipped + 1)); }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-fetch-verify.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fakebin" "$W/home" "$W/pa/tmp" "$W/cache" "$W/empty-cache"
CURL_LOG="$W/curl.log"
# The stand-in curl: notes its arguments; FAKE_CURL_SERVE=<file> copies that file to the -o target, else a 504.
cat > "$W/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CURL_LOG"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { out="\$2"; shift; }; shift; done
if [ -n "\${FAKE_CURL_SERVE:-}" ] && [ -n "\$out" ]; then cp "\$FAKE_CURL_SERVE" "\$out"; exit 0; fi
echo "curl: (22) The requested URL returned error: 504" >&2; exit 22
EOF
chmod 755 "$W/fakebin/curl"

URL="https://github.com/WOOWTECH/pi-omnigent-plugin/releases/download/v9.9.9/woowtech-pi-omnigent-plugin-9.9.9.tgz"
ASSET="woowtech-pi-omnigent-plugin-9.9.9.tgz"
printf 'the asset\n' > "$W/good"; GOOD_SHA="$(sha "$W/good")"
printf 'something else\n' > "$W/bad"
# fv DEST [VAR=value...]: fetch_verify "$URL" "$GOOD_SHA" DEST in a clean shell; prints what it said, then "rc=N"
fv() {
  local dest="$1"; shift
  : > "$CURL_LOG"; rm -f "$dest"
  env -i HOME="$W/home" PATH="$W/fakebin:/usr/bin:/bin" PI_AGENT_HOME="$W/pa" "$@" \
    bash -c '. "$1"; fetch_verify "$2" "$3" "$4"' _ "$COMMON" "$URL" "$GOOD_SHA" "$dest" 2>&1
  echo "rc=$?"
}
curl_ran() { [ -s "$CURL_LOG" ] && echo yes || echo no; }
DEST="$W/pa/tmp/omnigent-plugin.tgz"

echo "== A. PI_AGENT_ASSET_CACHE"
cp "$W/good" "$W/cache/$ASSET"
out="$(fv "$DEST" PI_AGENT_ASSET_CACHE="$W/cache")"
if case "$out" in *rc=0) true ;; *) false ;; esac && [ "$(curl_ran)" = no ] && [ "$(sha "$DEST")" = "$GOOD_SHA" ]; then
  ok "a copy named like the asset (the URL's last part) is used, and nothing is downloaded"
else no "a copy named like the asset (the URL's last part) is used, and nothing is downloaded" "curl ran: $(curl_ran); $out"; fi
case "$out" in *"from $W/cache/$ASSET"*) ok "...and the log says where it came from" ;; *) no "...and the log says where it came from" "$out" ;; esac
[ -f "$W/cache/$ASSET" ] && [ "$(sha "$W/cache/$ASSET")" = "$GOOD_SHA" ] && [ -f "$DEST" ] && [ ! -L "$DEST" ] && [ "$(inode "$DEST")" != "$(inode "$W/cache/$ASSET")" ] \
  && ok "...copied: the cache keeps its file, and DEST is a file of its own" || no "...copied: the cache keeps its file, and DEST is a file of its own"
rm -f "$W/cache/$ASSET"; cp "$W/good" "$W/cache/omnigent-plugin.tgz"
out="$(fv "$DEST" PI_AGENT_ASSET_CACHE="$W/cache")"
case "$out" in *rc=0) [ "$(curl_ran)" = no ] && ok "a copy named like DEST is used too" || no "a copy named like DEST is used too" "curl ran" ;; *) no "a copy named like DEST is used too" "$out" ;; esac
cp "$W/good" "$W/cache/$ASSET"; cp "$W/bad" "$W/cache/omnigent-plugin.tgz"
out="$(fv "$DEST" PI_AGENT_ASSET_CACHE="$W/cache")"
case "$out" in *rc=0) ok "both there: the asset's own name comes first" ;; *) no "both there: the asset's own name comes first" "$out" ;; esac
rm -f "$W/cache/$ASSET"
out="$(fv "$DEST" PI_AGENT_ASSET_CACHE="$W/cache")"
case "$out" in
  *"sha256 mismatch"*"copied from $W/cache/omnigent-plugin.tgz"*rc=[1-9]*) [ "$(curl_ran)" = no ] && ok "a wrong copy is refused by the sha256 check, naming the file it came from" || no "a wrong copy is refused by the sha256 check" "curl ran" ;;
  *) no "a wrong copy is refused by the sha256 check, naming the file it came from" "$out" ;;
esac
out="$(fv "$DEST" PI_AGENT_ASSET_CACHE="$W/empty-cache" FAKE_CURL_SERVE="$W/good")"
case "$out" in *rc=0) [ "$(curl_ran)" = yes ] && ok "a cache without that file: it downloads, as before" || no "a cache without that file: it downloads, as before" "curl did not run" ;; *) no "a cache without that file: it downloads, as before" "$out" ;; esac

echo "== B. the download"
out="$(fv "$DEST" FAKE_CURL_SERVE="$W/good")"
args="$(cat "$CURL_LOG")"
case "$out" in *rc=0) ok "no cache: one curl, and the sha256 check passes" ;; *) no "no cache: one curl, and the sha256 check passes" "$out" ;; esac
delay="$(printf '%s\n' "$args" | sed -n 's/.*--retry-delay \([0-9][0-9]*\).*/\1/p')"
maxt="$(printf '%s\n' "$args" | sed -n 's/.*--retry-max-time \([0-9][0-9]*\).*/\1/p')"
tries="$(printf '%s\n' "$args" | sed -n 's/.*--retry \([0-9][0-9]*\).*/\1/p')"
if [ -n "$delay" ] && [ "$delay" -ge 5 ] && [ -n "$maxt" ] && [ -n "$tries" ] && [ $((tries * delay)) -ge 60 ]; then
  ok "curl waits ${delay} s between tries, up to $tries tries within ${maxt} s (was 5 tries, about 30 s)"
else no "curl waits between tries, with a limit on the total time" "$args"; fi
case "$args" in *--retry-all-errors*) ok "...on any error, as before (a reset connection is not 'transient' to curl)" ;; *) no "...on any error, as before" "$args" ;; esac
out="$(fv "$DEST")"
case "$out" in
  *"download failed"*"$ASSET"*"PI_AGENT_ASSET_CACHE"*rc=[1-9]*) ok "a download that keeps failing stops the install and says how to use a copy" ;;
  *) no "a download that keeps failing stops the install and says how to use a copy" "$out" ;;
esac

echo "== C. install.sh fetch, every download failing"
NODE="${PA_TEST_NODE:-$(command -v node || true)}"
CACHE_DIR="${PA_TEST_CACHE:-${TMPDIR:-/tmp}/pi-agent-test-cache}"; mkdir -p "$CACHE_DIR"
# pinned NAME URL SHA OVERRIDE -> the verified tarball's path, or nothing
pinned() {
  local name="$1" url="$2" want="$3" f="${4:-$CACHE_DIR/$1}"
  if [ ! -f "$f" ] || [ "$(sha "$f")" != "$want" ]; then
    [ -z "${4:-}" ] || return 1
    curl -fsSL --retry 3 -o "$f.part" "$url" 2>/dev/null && [ "$(sha "$f.part")" = "$want" ] || { rm -f "$f.part"; return 1; }
    mv "$f.part" "$f"
  fi
  printf '%s' "$f"
}
OMNI_NAME="${PIN_OMNIGENT_PLUGIN_TGZ##*/}"; PASEO_NAME="${PIN_PASEO_PLUGIN_TGZ##*/}"
OMNI="$(pinned "$OMNI_NAME" "$PIN_OMNIGENT_PLUGIN_TGZ" "$PIN_OMNIGENT_PLUGIN_SHA256" "${PA_TEST_PLUGIN_TGZ:-}")" || OMNI=""
PASEO="$(pinned "$PASEO_NAME" "$PIN_PASEO_PLUGIN_TGZ" "$PIN_PASEO_PLUGIN_SHA256" "${PA_TEST_PASEO_TGZ:-}")" || PASEO=""
if [ -z "$NODE" ] || [ ! -x "$NODE" ] || [ -z "$OMNI" ] || [ -z "$PASEO" ] || [ -n "${PI_TEST_COMMON:-}" ]; then
  skip "C* -- needs node and the pinned plugin tarballs (PA_TEST_PLUGIN_TGZ, PA_TEST_PASEO_TGZ); not run with PI_TEST_COMMON"
else
  mkdir -p "$W/assets"; cp "$OMNI" "$W/assets/$OMNI_NAME"; cp "$PASEO" "$W/assets/$PASEO_NAME"
  # stage F: a fresh install root with only the scoped node, as model-options-hook.sh does
  stage() {
    rm -rf "$W/f"; mkdir -p "$W/f/node/bin"; ln -s "$NODE" "$W/f/node/bin/node"; : > "$CURL_LOG"
    env -i HOME="$W/home" PATH="$W/fakebin:/usr/bin:/bin" PI_AGENT_HOME="$W/f" "$@" bash "$HERE/install.sh" fetch > "$W/fetch.log" 2>&1
  }
  stage PI_AGENT_ASSET_CACHE="$W/assets"; rc=$?
  if [ "$rc" = 0 ] && [ "$(curl_ran)" = no ] \
     && [ "$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$W/f/plugins/pi-omnigent-plugin/package.json" | head -1)" = "$PIN_OMNIGENT_PLUGIN_VERSION" ] \
     && [ -f "$W/f/plugins/pi-paseo-plugin/package.json" ]; then
    ok "with the two pinned tarballs in PI_AGENT_ASSET_CACHE, fetch installs both plugins and downloads nothing"
  else no "with the two pinned tarballs in PI_AGENT_ASSET_CACHE, fetch installs both plugins and downloads nothing" "rc=$rc curl ran: $(curl_ran); $(tail -3 "$W/fetch.log" | tr '\n' ' ' | cut -c1-300)"; fi
  stage; rc=$?
  if [ "$rc" != 0 ] && grep -q "download failed" "$W/fetch.log"; then ok "(control) without it the same fetch stops: download failed"
  else no "(control) without it the same fetch stops: download failed" "rc=$rc $(tail -2 "$W/fetch.log" | tr '\n' ' ' | cut -c1-300)"; fi
fi

echo
printf 'fetch_verify: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" = 0 ]
