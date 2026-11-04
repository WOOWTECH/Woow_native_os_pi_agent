#!/bin/bash
# Re-running the installer over an existing install must converge, not fail.
#
# Why this exists. docs say "to update, install the pkg again" (or run ./install.sh again). On a Mac that was
# already installed -- found on the second Mac, a cut-over one -- the omnigent stage stopped with
#
#   error: A virtual environment already exists at `.../omnigent/venv`. Use the `--clear` flag or set
#   UV_VENV_CLEAR=1 to replace the existing virtual environment      (install.sh exit=2)
#
# because uv (0.12.x, the pinned one) refuses to create a venv over a non-empty directory unless told to. By then
# the earlier stages had already replaced the plugin tree and the pi-web tree, so the machine was left half
# updated: the wire and service stages, which put the scripts and the patches back, never ran.
#
#   tests/installer-rerun.sh
#
# Hermetic: a temp install root and a stand-in `uv` that behaves like the pinned one where it matters (it refuses
# to create a venv over a non-empty directory without --clear / --allow-existing, and says so the way uv does).
# Nothing is downloaded and nothing outside the temp directory is touched. A final check runs the REAL pinned uv
# on a scratch directory when one is at hand, so the stand-in cannot drift from the real thing unnoticed.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
# shellcheck source=../lib/pins.sh
. "$HERE/lib/pins.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-rerun.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
PA="$W/pa"; mkdir -p "$PA/bin" "$W/home"

cat > "$PA/bin/uv" <<EOF
#!/bin/bash
# stand-in for the pinned uv ($PIN_UV_VERSION): only what the omnigent stage calls
case "\${1:-}" in
  --version) echo "uv $PIN_UV_VERSION (stand-in)"; exit 0 ;;
  python)    exit 0 ;;                                    # uv python install --no-bin <ver>
  venv)
    shift; clear=0; allow=0; target=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --clear|-c) clear=1 ;;
        --allow-existing) allow=1 ;;
        --python) shift ;;
        -*) ;;
        *) target="\$1" ;;
      esac; shift
    done
    if [ -e "\$target" ] && [ -n "\$(ls -A "\$target" 2>/dev/null)" ] && [ "\$clear" = 0 ] && [ "\$allow" = 0 ]; then
      echo "error: A virtual environment already exists at \\\`\$target\\\`. Use the \\\`--clear\\\` flag or set UV_VENV_CLEAR=1 to replace the existing virtual environment" >&2
      exit 2
    fi
    [ "\$clear" = 1 ] && rm -rf "\$target"
    mkdir -p "\$target/bin"
    printf '#!/bin/bash\\nexit 0\\n' > "\$target/bin/python"; chmod 755 "\$target/bin/python"
    echo made > "\$target/pyvenv.cfg"
    exit 0 ;;
  pip)       # uv pip sync --python <venv python> --require-hashes <lock>
    [ -x "\$(echo "\$*" | sed -n 's/.*--python \\([^ ]*\\).*/\\1/p')" ] || { echo "stand-in uv: the venv python is missing" >&2; exit 3; }
    exit 0 ;;
esac
echo "stand-in uv: unexpected call: \$*" >&2; exit 4
EOF
chmod 755 "$PA/bin/uv"

run_stage() {   # run_stage LABEL  -> exit status of `install.sh omnigent` over $PA
  env -i HOME="$W/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin PI_AGENT_HOME="$PA" /bin/bash "$HERE/install.sh" omnigent > "$W/$1.log" 2>&1
}

echo "== the omnigent stage, over a fresh install root, then over the install it just made"
if run_stage first; then ok "first run (nothing installed yet): exit 0"; else no "first run (nothing installed yet): exit 0" "$(tail -3 "$W/first.log")"; fi
[ -x "$PA/omnigent/venv/bin/python" ] && ok "...and it left a working venv" || no "...and it left a working venv" "no $PA/omnigent/venv/bin/python"
cmp -s "$HERE/vendor/omnigent-requirements.lock" "$PA/omnigent/requirements.lock" \
  && ok "...and kept the requirements it installed from (an Intel Mac's plugin install resolves against them)" \
  || no "...and kept the requirements it installed from (an Intel Mac's plugin install resolves against them)" "no identical $PA/omnigent/requirements.lock"
if run_stage second; then ok "second run, over the existing install: exit 0 (it converges instead of stopping)"; else no "second run, over the existing install: exit 0 (it converges instead of stopping)" "$(grep -i -m1 'error' "$W/second.log" | cut -c1-200)"; fi
[ -x "$PA/omnigent/venv/bin/python" ] && ok "...and the venv is still there and working" || no "...and the venv is still there and working" "no $PA/omnigent/venv/bin/python"

echo "== a half-made venv left by an interrupted earlier run"
rm -rf "$PA/omnigent/venv"; mkdir -p "$PA/omnigent/venv/lib"; echo junk > "$PA/omnigent/venv/lib/stale"
if run_stage third; then ok "a non-empty leftover directory is replaced, exit 0"; else no "a non-empty leftover directory is replaced, exit 0" "$(grep -i -m1 'error' "$W/third.log" | cut -c1-200)"; fi
[ ! -e "$PA/omnigent/venv/lib/stale" ] && ok "...the stale file is gone (the venv was recreated, not reused)" || no "...the stale file is gone (the venv was recreated, not reused)" "still there"

echo "== the stand-in matches the real pinned uv (only when one is at hand)"
REALUV=""
for c in "${PI_TEST_UV:-}" "${PI_AGENT_HOME:-$HOME/.local/share/pi-agent}/bin/uv"; do
  [ -n "$c" ] && [ -x "$c" ] && [ "$("$c" --version 2>/dev/null | awk '{print $2}')" = "$PIN_UV_VERSION" ] && { REALUV="$c"; break; }
done
RPY="$(command -v python3 || true)"
if [ -z "$REALUV" ] || [ -z "$RPY" ] || ! "$RPY" -c 'import sys' 2>/dev/null; then
  echo "  SKIP  no uv $PIN_UV_VERSION (set PI_TEST_UV) or no python3 here"
else
  export UV_CACHE_DIR="$W/uvcache" UV_PYTHON_PREFERENCE=only-system
  "$REALUV" venv --python "$RPY" "$W/real" >/dev/null 2>&1
  "$REALUV" venv --python "$RPY" "$W/real" >/dev/null 2>&1; r1=$?
  "$REALUV" venv --clear --python "$RPY" "$W/real" >/dev/null 2>&1; r2=$?
  if [ "$r1" != 0 ] && [ "$r2" = 0 ]; then ok "real uv $PIN_UV_VERSION: a second venv without a flag fails (exit $r1), with --clear it succeeds"; else no "real uv $PIN_UV_VERSION: a second venv without a flag fails, with --clear it succeeds" "without flag exit $r1, with --clear exit $r2"; fi
fi

echo
printf 'installer re-run: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
