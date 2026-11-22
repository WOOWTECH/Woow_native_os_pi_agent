# Genuine disposable Ubuntu CI route

This separate pull-request workflow is source only until reviewed and explicitly
submitted for execution. No build, installer, SDK, provider, network or CI run was
performed to author it. The worktree starts at original base
172522c8a4065f80e813d6d4710b26b13b6094c7; the new route and driver are uncommitted
additions to that reference, not files claimed to exist at the base.

The ten copied driver files now match frozen V4 f221a00d… / handoff 0b40b939….
Only the safety-suite file was refreshed from V3, to a40c4919…. The other nine
retain their exact V3/V4 bytes. Root reported V4 accepted and locally submitted
as ec0a52a20958d7ca8ad779a5b5d2391b52248892, tree
982e0f89ace1acf2cd8753f9a6434d829ce1ee13, parent 172522c8…. This addon
binds that accepted source, but remains subject to independent review. Integrate
only its five new files atop ec0a52a; do not replace the accepted ten-file delta.
The genuine job does not run that synthetic suite; existing deployment CI remains
unchanged relative to accepted V4.

The route follows Bacon's owned-ubuntu-genuine-ci-route-audit/AUDIT.md:
one GitHub-hosted Ubuntu 24.04 x64 nonroot job, contents-read permission, no
supplied secrets, and checkout credential persistence disabled. An automatic
pull_request trigger checks out the exact PR head SHA. Preparation verifies that
the clean checkout's actual HEAD equals that SHA; identity records the actual
candidate commit/tree separately from the original base/tree and accepted V4
submission. Run metadata also distinguishes the event SHA and workflow SHA/ref
from the actual checked-out PR head.

The route's source lock separately binds:

- The original 39-input installer lock, including VERSION and candidate packages.
- The original scripts/build-piweb-artifact.sh bytes/mode (outside that input lock).
- All ten copied frozen V4 driver/workflow/documentation/test inputs.
- The new route files are recorded by actual bytes/modes under the candidate
  commit; their independent review authority is the new source freeze/commit.

Preparation checks actual UID, Ubuntu version, architecture, kernel, system
Python 3.11+, procfs, pidfds and subreaper capability. Bash, curl, Git, GPG, jq,
SSH, xz, flock, tmux, tar/gzip, GNU utilities, timeout, make and C/C++ compilers
must already be executable in /usr/bin:/bin; OS CA roots must exist. Missing
prerequisites produce HOLD. No image inventory was consulted as execution
evidence, and no apt, sudo, installer preflight or custom host setup is used.

Each step enters through env -i and umask022. A new short unpredictable mode0700
/tmp/own-ub-* root holds separate build/account/install/TMPDIR/XDG/npm/uv
directories, a controller account, an empty artifact output and a fresh
acceptance parent. No runner HOME, login state, secrets, proxy variables, SSH
agent, Python/Node hooks or external application configuration is adopted.

The helper invokes these genuine boundaries, with no mock or fixture substitute:

1. /bin/bash install.sh node fetch piweb with the isolated build prefix and no
   PI_AGENT_PIWEB_ARTIFACT variable. The pinned real source/adapter is fetched,
   development dependencies installed, Next built, development packages pruned,
   source-build manifest written and postbuild checks applied.
2. /bin/bash scripts/build-piweb-artifact.sh <private-output> with exactly the
   same build environment/prefix. The original packager revalidates the manifest.
3. Immediately hash the regular singly-linked local archive, compare its exact
   packager sidecar, and exclusively record its path/SHA/size/mode. Rechecking
   those bytes before acceptance never creates a replacement trusted pin.
4. /usr/bin/python3 -B tests/owned_native_acceptance.py --mode acceptance
   --platform ubuntu --supervisor owned-pgid --parent <fresh-private-parent>
   --piweb-artifact <recorded-local-archive> --piweb-artifact-sha256 <recorded-SHA>
   --deadline-seconds 1800. The sibling-import driver CLI remains unchanged.

The driver therefore executes all eight genuine private installation stages,
static overlays/package bindings, owned HTTP, sharing helper/SDK bridge,
credential-free synthetic echo/skill/config data, removal and owned restart.
No provider conversation, connect/login/takeover, tenant state, fixed service,
persistent boot setting or release publisher is selected.

Build/package share a 1980-second command budget; acceptance has a 2000-second
outer timeout around the driver's unchanged 1800-second work budget and bounded
teardown. GNU timeout allows ten seconds after TERM before KILL. Workflow steps
are bounded to 5/35/35/2/3 minutes after checkout, inside a 90-minute job. There
are no continue-on-error, retry, alternate-listener or synthetic success paths.
A nonzero command/HOLD stays a failed job even when collection/upload succeeds.

Only explicit nonsecret evidence filenames are uploaded: source/run/tool/OS
identity, phase/command status and timings, original driver receipt, artifact
manifest and checksum. The archive, control state, raw stdout/stderr, entire
private root, generated configs, identity/pairing state and credential-bearing
files are never uploaded. Raw process output is discarded rather than logged;
this limits failed-build diagnostics to status, timings and source identity.
Driver failure receipts/roots are retained privately until runner disposal.
Cancellation may leave only partial status evidence, which cannot be promoted
to success; always-run collection/upload is an attempt, not a durability promise.

A successful command must also have the driver's OWNED_SCENARIO_COMPLETED,
verified teardown, removed private run root and matching artifact SHA. The
receipt's realUbuntuAcceptance, realWSL2Acceptance, providerAcceptance and
rebootAcceptance fields remain false. External review must bind any observed
hosted Ubuntu scenario assessment to that actual PR-head CI run and receipt.
There is no WSL2, provider, reboot, tenant-upgrade, restore or lost-history claim.

Same-run build provenance is not reproducible-dependency-byte provenance.
Node's scoped download has the existing version check, not an independent
archive hash. Existing artifact manifest checks are authoritative; node-pty
loading remains warning-only. Driver file/output/archive/cleanup bounds are
unchanged: a real install/artifact exceeding them must HOLD. No local fixture
result establishes that this route fits those limits.

Pi3 HOLD, Pi4 NOAPPLY, Pi1 paused and Muji untouched remain unchanged.
