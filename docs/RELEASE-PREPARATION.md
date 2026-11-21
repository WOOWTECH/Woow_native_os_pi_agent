# Native 0.2.8 release preparation

This is a source candidate, not a published release. Existing 0.2.7 assets and
the separate 0.3.0-rc Windows channel remain immutable.

The normal Ubuntu/WSL2 instructions use tag `v0.2.8` and its Linux x64 Pi Web
artifact. Mac downloads use the matching arm64/x64 pkg URLs. These paths become
available only after publication. The source and pkg contain all three exact
archives from `candidate-packages/manifest.json`; their npm names are unchanged.
No registry installation of these packages and no plugin release download is
needed. Upstream Node, managed Paseo, provider CLI and Python dependencies still
use the existing pinned network downloads.

`release.yml` validates VERSION against the requested version/tag, builds the
three platform trees, verifies installed shared-runtime gates, and packages
unsigned Mac candidates on manual dispatch. Frozen tgz files are copied unchanged,
never rebuilt with `npm pack`. Its aggregate Actions artifact includes SHA256s,
source commit/tree and run identity. Manual dispatch has read-only repository
permission and does not publish anything.

An explicitly pushed version tag retains the existing source/prebuilt install
release route: all three platform trees, checksums, frozen tgz files and the
exact tag-build receipt are attached to the GitHub Release. Only this conditional
job has contents:write. It excludes unsigned `.pkg` files and does not wait for
maintainer Mac signing. Authorizing the tag is the public-promotion boundary.
The tag build records its actual commit and Git tree, not the earlier PR head.
A merge commit may differ from the reviewed head while retaining the same tree;
compare both identities, and review any tree change before authorizing the tag.

The tree receipt binds the native version, OS/architecture, pinned Pi Web source,
combined patch and all frozen package hashes. Packaging cannot restamp an older
tree. Installing an older/mismatched tree fails before replacing an existing
installation. Full Mac CI exercises both source install and this artifact path,
including credential-free lifecycle and identity retention. Package expansion
compares all three archives byte for byte.

Public Mac packages still require Developer ID Application and Developer ID
Installer signatures, accepted notarization and staple verification. Existing
`build-macos-pkg.sh --release` enforces those gates. For embedded Pi Web use the
existing `sign-macos-piweb-artifact.sh` first; that produces a separately reviewed
signed tree without modifying the three frozen archives. Never label the CI
unsigned pkg as a signed ordinary-user release.

The existing automatic Pi Agent signer in `WOOWTECH/woowtech-smart` serves the
separate Windows EXE preview route, not Mac pkg. Its secret names are
`ESIGNER_STOREPASS`, `ESIGNER_CREDENTIAL_ID`, `ESIGNER_TOTP_SECRET`. The current
WSL2 route runs the Linux installer inside Ubuntu and needs none of them.
No native Mac signing secrets or native self-hosted runner were visible in the
2026-11-21 repository metadata check. Secret presence is not a credential test;
organization-level access was not established. No secrets were read or copied.

After exact artifact review, release owners may authorize the matching source/tag
and prebuilt assets independently, then verify anonymous normal-install URLs.
Signed `.pkg` preparation and signature verification remain separate. This task
does not grant publication. CI does not establish actual user Mac provider,
Windows host, or HA Supervisor upgrade acceptance.
