#!/usr/bin/env bash
# Hermetic tests for the WSL2 support (docs/WSL2-PLAN.md), Linux side.
#
#   bash tests/wsl.sh                 # every section
#   bash tests/wsl.sh win env         # only those
#
# Sections (the seams agreed for this work):
#   win        rootfs/bin/pi-agent-win        how an agent reaches Windows programs
#   ctl        rootfs/bin/pi-agent            open / doctor / systemd environment on WSL
#   env        rootfs/bin/pi-agent-env.sh     PATH and BROWSER on WSL, nothing elsewhere
#   install    install.sh                     the WSL preflight and service stage
#   rootsetup  scripts/wsl-root-setup.sh      what runs as root inside the new distro
#   bundle     scripts/build-wsl-bundle.sh    the release bundle and the stamped installer
# The Windows-side installer (windows/install-wsl.ps1) has its own Pester suite.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=wsl/lib.sh
. "$HERE/wsl/lib.sh"

[ $# -gt 0 ] || set -- win ctl env install
for s in "$@"; do
  [ -f "$HERE/wsl/$s.sh" ] || { echo "no such section: $s" >&2; exit 2; }
  echo "## $s"
  # shellcheck source=/dev/null
  . "$HERE/wsl/$s.sh"
done

echo
echo "# RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
