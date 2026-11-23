# Owned native acceptance implementation plan

> Execute in this isolated worktree. The user authorized implementation and safety fixtures; no commit, push, CI, installer, SDK, provider or real acceptance execution is authorized.

**Goal:** A fail-closed Ubuntu/WSL2 acceptance driver that cannot reuse tenant state or the fixed native service.

**Architecture:** Standard-library Python owns a private descriptor-bound workspace and Linux child session. The acceptance CLI has fixed reviewed commands and source pins; tests exercise safety primitives and an explicitly synthetic composition using owned children only. Current shared-runtime MCP framing is exercised by a separate bounded stdio client when actual acceptance is authorized later.

**Tech stack:** Python 3.11+, Linux procfs, Bash installer (future acceptance only), JSON-RPC over stdio; no SDK imports in safety tests.

1. Create tests/test_owned_native_acceptance.py and tests/owned_native_acceptance.py: exclusive private roots, descriptor confinement, marker verification, environment allowlist. Red/green for collision, escape and symlink cases.
2. Add owned child process sessions, birth identity, bounded command output/deadline, listener ownership and conservative teardown. Test real local children/loopback servers and injected observations of identity replacement/teardown failure; no scanning tenant processes.
3. Implement exact source lock and platform/mode checks; explicit nonservice stages and preprovisioned prerequisite verification. Test source substitution, hostile environment and unsupported supervisor/platform refusal without executing the installer.
4. Implement current bridge contract, synthetic sentinel preservation and bounded stdio JSON-RPC. Tests use a plainly synthetic child protocol, never the real SDK, installer or bridge.
5. Compose fixed future acceptance stages and receipt limits; add interruption/failed-sync/failed-teardown regressions. A synthetic composition may only produce safety-fixture evidence.
6. Replace legacy smoke body with unconditional refusal; document the new seam and separate future Ubuntu/WSL2/provider/reboot evidence. Run only new safety fixtures and source/compiler checks, inspect final delta, then freeze source/evidence for root review. Do not commit or publish.

## V2 corrections in a separate worktree

Preserve the original v1 freeze. Bind and copy `VERSION` with the other immutable
installer inputs, and exercise the actual copied artifact-manifest helper.
Apply all exact pinned Linux static plugin overlays before validating the 37
post-overlay members or starting the web process. Exercise that ordering with
the actual package bytes and a selected pipeline fixture whose installer,
Pi Web and SDK boundaries remain explicitly synthetic. Resolve the complete
archive symlink graph before installation, preserving `..` traversal semantics
with shared time, component and hop limits and cycle detection. Cover chained
escapes, deeper/cyclic graphs and legitimate internal Node links.

Wire the owned safety suite unconditionally into the existing Python 3.12 /
Node 22 deployment job, preserve the existing maintenance suite, and parse the
real workflow in a focused no-skip wiring assertion. Run only the affected
safety suite under Python 3.12.14, source/compiler and workflow checks. Freeze
the new source and receipts for root review; actual Ubuntu, WSL2, provider,
reboot and CI acceptance remain false until separately observed.
