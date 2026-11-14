#!/bin/bash
# Sign/repack a SHA-pinned pi-web archive, or verify it without changing it.
# Requires macOS build tools and Python 3.9+ (not an end-user dependency).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "${PI_AGENT_BUILD_PYTHON:-/usr/bin/python3}" -I "$HERE/macos/piweb-artifact-signing.py" "$@"
