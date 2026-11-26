# Native 0.2.16-rc.4 preparation

This worktree starts at native rc3 HEAD `82d004fbd358439fc38f3c38c1de875cf278313f`.
The intended candidate is native `0.2.16-rc.4`, pairing Agent Connect
`0.1.27-rc.4` (Gauss) with Omnigent `0.3.42-rc.4` (Dirac). Gauss supplied the
immutable Agent Connect tuple: source commit
`a895f725aad645e7594c8405aac17aca409b3558`, archive
`phone-selected-release-rc4/artifacts/woowtech-pi-paseo-0.1.27-rc.4.tgz`,
SHA-256 `3fe3f9e7bad463c6a007703a8db67c2de320b061e93ba7bc79339cae68fe937b`.
Dirac's exact paired source and archive are pending. `VERSION` and native-version
assertions now say rc4; package pins, manifests, archive bytes, source authority
and member hashes deliberately remain rc3 until both exact inputs are available.
Do not infer or copy rc3 hashes for rc4. The Pi Web source and combined adapter
must be checked against Dirac's exact archive before deciding whether their pins
need to move.

## Update sequence after both handoffs

1. Verify each source commit and archive bytes independently; inspect package
   version, Agent Connect runtime revision and Smart Tasks chunk, Omnigent's
   exact Agent Connect compatibility metadata, and combined adapter metadata.
   Record supplied commits and computed archive SHA-256 values. Keep the shared
   runtime at 0.1.6 unless the handoff explicitly changes that component.
2. Replace the two candidate archives and update `candidate-packages/manifest.json`
   and `lib/pins.sh` as one pair. Update the native version to `0.2.16-rc.4`.
   Preserve unpublished-candidate status and do not add release URLs.
3. Update all four Omnigent overlay version guards in `rootfs/bin/` only after
   confirming the rc4 archive retains the reviewed maintenance contract. Apply
   the paired archive to the pinned Pi Web source only if its exact combined
   adapter requires it; regenerate any dependent prebuilt-artifact metadata.
4. Regenerate `tests/owned-native-acceptance.lock.json` from the final source
   and actual plugin archive. Check both its 40 installer-input rows and every
   installed Linux plugin-member hash. Do not hand-edit expected hashes from
   rc3 or omit changed files.
5. Recompose the owned acceptance authority in dependency order: finalize
   non-lock source leaves; regenerate `tests/owned-acceptance-component-source.json`
   source rows/archive digest; bind it in
   `tests/owned-acceptance-component-handoff.json`; then regenerate
   `scripts/owned-ubuntu-acceptance-ci.lock.json` and its pinned lock digest,
   byte size and row count in `scripts/owned-ubuntu-acceptance-ci.py`.
   Refresh exact-version assertions in tests and the matching acceptance docs.
   Follow `docs/OWNED-UBUNTU-GENUINE-CI.md`'s non-circular D → F → H → L order;
   final integration and CI receipts are recorded after those locks settle.
6. Run focused artifact-manifest, overlay, package-member, native installer,
   Linux acceptance-authority and deployment CI checks on this exact local
   commit. Keep host/provider acceptance separate; do not access aicoder or
   treat source/fixture results as host acceptance. Commit locally with the
   requested Claude Sonnet co-author footer; do not push.

Until those inputs arrive, this document is the only rc4-specific preparation.
The branch remains deliberately unbuildable as rc4 rather than carrying
partially updated package identity or invented provenance.
