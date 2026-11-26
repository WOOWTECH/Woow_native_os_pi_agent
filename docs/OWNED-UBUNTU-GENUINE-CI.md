# Owned Ubuntu CI source authority

The v2 consumer lock binds the reviewed custody runtime, controller and the native v0.2.14 candidate installer inputs. The pull-request job builds Pi Web and exercises installation and teardown on a disposable Ubuntu runner. Source composition alone is not a successful test result; only receipts from the exact candidate commit describe a run.

The baseline checkout is69963675d7c763ae5ef6e64090baae6aa4fcbd60. Its actual Linux and Mac successes and Ubuntu failed/HOLD attempt describe only that old source. V4 source authority remains historical and cannot authorize a replacement driver.

## Immutable installer authority

The 40 installer-input rows and expected post-overlay Linux plugin members are pinned for the native v0.2.14 candidate in `tests/owned-native-acceptance.lock.json`. They include the hard-link repair, Agent Connect 0.1.25 and Omnigent 0.3.40. The controller pins that exact lock hash, byte size and row count; it also pins the current packager. The historical base reference is provenance, not a requirement to restore obsolete package bytes. The legacy smoke refusal remains intact.

## Required final documents

The checked-in composition records these exact source documents:

- `tests/owned-acceptance-component-source.json`: `owned-component-source/v1`, classification, exact sorted source rows, roles and canonical sourceRowsSha256.
- `tests/owned-acceptance-component-handoff.json`: `owned-component-handoff/v1`, classification, raw freeze SHA, archive provenance, identical roles, exact closure and explicit invocation/receipt contracts.
- `scripts/owned-ubuntu-acceptance-ci.lock.json`: `owned-ubuntu-genuine-ci-inputs/v2`; immutable baseline plus exact raw F/H pins, source rows/count/digest, roles and archive provenance for this composition.

The source row shape is `{path,sha256,bytes,mode,gitMode,gitBlob}`. Rows must be unique, path-sorted, regular0644/0755 source files, below the checkout, at most128 rows,4MiB each and16MiB declared total. Metadata documents are at most64KiB. Raw JSON duplicate keys, type ambiguity, path aliases, links, self-pinning rows, original-asset overlap, missing/extra closure, different roles or raw metadata formatting drift all refuse. The source digest uses UTF8 JSON with sorted keys, compact comma/colon separators and no trailing newline. Git blob hashes are recomputed from source bytes; final Git tree/mode authority still requires independent root/API review.

Required roles cover the actual driver, supervisor, controller, workflows, safety suites, docs, legacy entry, and all final proc/custody helpers and fixtures. The handoff includes every custody helper and fixture used by this composition. The fixed existing role paths are compatibility requirements, not invented new helper paths.

The archive pin is provenance: runtime checks its agreement with F/H/rows, not a downloaded archive. Root must independently verify the actual frozen archive/member inventory. A self-consistent verifier/lock cannot authenticate its own review. Independent final integration pins and later commit/tree/API binding remain mandatory.

## Non-circular composition

Freeze final non-lock source leaves D first; these include the final controller, workflows, tests and component dependencies. F lists D only. Its source archive contains D only. H binds F/archive/roles. Neither D nor F/H may embed a dependent final consumer-lock hash or a final containing-commit hash. Copy raw F/H, then generate L from their exact rows. Only afterward freeze the full integration including L and metadata copies. Post-L tests/receipts belong in the final integration handoff, not an H that L hashes. Unresolved donor overlaps require a new reviewed composite freeze.

`REVIEWED_SOURCE_ONLY` metadata still denotes source review, not production admission. Test documents are explicitly `SYNTHETIC_FIXTURE`; the metadata verifier can inspect them, but the operational source gate rejects them before even the Git/head probe or a target spawn. The checked-in lock is composed from the reviewed source. Pending-authority refusal tests explicitly create pending temporary locks and never depend on the repository remaining pending.

## Phase and target binding

Preparation verifies composed source authority before platform prerequisites or target execution, then binds the exact PR head/tree, raw F/H/L hashes, all source rows/roles and an unpredictable controller run token into exclusive private control state. Each later phase and every target command (before spawn and after a successful exit) rechecks the same prepared authority; it does not mint new expected pins from a changed checkout. The existing private roots, allowlisted environments, timeouts, artifact checks and real build -> original packager -> recorded SHA order remain.

The handoff must explicitly provide `owned-driver-invocation/v1`: custodyMode, argv template and receiptContract. The only argv substitutions are `{python}`, `{driver}`, `{custody_mode}`, `{parent}`, `{artifact}`, `{artifact_sha256}`, `{run_token}`, `{authority_sha256}`, each once. Executable and driver role are fixed; only the optional Python -B prefix is supported. The scenario must explicitly remain --mode acceptance and --platform ubuntu. No shell/eval/env template is accepted. All remaining CLI literals come from the final reviewed handoff. There is no guessed mode, old owned-pgid fallback, source-plan or fixture substitute. Unsupported/missing final transport requires HOLD and a reviewed adapter revision.

The provisional receipt adapter is `owned-driver-receipt-contract/v1`: explicit schemaValue, owned-platform scope, completed status, bounded receipt filename pattern and unique JSON pointers (up to4 object levels). It binds actual schema/scope/status, artifact SHA, controller run token, runtime source-authority digest, selected custody mode, immutable installer baseline/lock/plugin, teardown/private-root flags and all false broad-admission flags. The handoff declares the driver flags `--run-token` and `--source-authority-sha256`, with direct receipt field pointers. Synthetic tests alone use clearly named fixture argv literals. If final custody exposes a different supported identity/transport contract, do not manufacture values: review a narrow adapter revision before composition.

The run token and source digest are required semantic bindings to prevent stale receipt relabeling. The controller passes them only through the handoff's explicit argv contract. The actual driver must support that final declared interface.

## Eleven-artifact evidence boundary

The existing upload allowlist is unchanged: identity, prepare-result, build-command, package-command, build-result, artifact checksum, artifact manifest, acceptance-command, accept-result, raw driver-receipt, collect-result. No twelfth file, retained root, configs, raw runtime logs or private artifact is uploaded.

Collection reads one bounded regular0600 receipt matching the declared owned filename pattern; missing, ambiguous, linked, oversized or unreadable receipts refuse. It preserves `driver-receipt.json` byte-for-byte, including rejected identity or a valid HOLD. A rejected binding leaves a HOLD collect-result and never creates a success envelope. A valid binding is nested under `collect-result.json.sourceRunReceiptBinding`: raw receipt hash/size, validated F/H/L/row digests, actual candidate commit/tree, allowlisted run metadata, hashed nonce, artifact SHA, selected mode, raw status and cleanup flags. Unknown control-state fields are not forwarded. Event/workflow SHA/ref remain distinct from the checked-out PR head.

`collect-result.status: EXIT0` means collection succeeded, not scenario success. A raw HOLD, unverified teardown or retained private root has envelope bindingOutcome HOLD. The failed accept step remains failed; always-run collect/upload cannot promote it. All broad Ubuntu/WSL2/provider/reboot/production admission flags remain false.

## Focused verification

`tests/test_owned_ci_authority.py` uses actual controller functions and owned temporary files containing synthetic metadata, original immutable input bytes and an in-memory synthetic source tar. It never imports or invokes a native SDK, installer, provider or daemon. It covers pending/old authority refusal, exact source closure and metadata mutation, prepared-state drift, raw byte preservation, stale run/source/artifact rejection, uncertainty retention and workflow wiring. Provisioned-tool checks include Node22 --version; the pending-target regression proves a harmless local child is not started.

Deployment CI runs the authority suite and custody/lifecycle regressions under Python3.12/Node22 while retaining the existing owned-native and maintenance commands. Process-control suites execute only on disposable CI runners. The genuine job independently records its actual candidate head and artifact hash. Provider, WSL2, reboot, user-host and production acceptance remain outside this job; broad-admission receipt flags stay false even when the owned Ubuntu scenario completes.
