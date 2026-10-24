# Update asset signing (Windows and Linux)

The macOS archives carry a Sparkle EdDSA signature. The Windows executable
(`ErgoptiPlus.exe`) and the Linux bundle (`ergopti-plus-linux.tar.gz`) are signed
the same way in spirit: each release publishes a detached `<asset>.sig` and both
updaters verify it before installing. The policy is
`static/ergopti_plus/_shared/modules/updater/asset_signing.json`.

## What is signed

A canonical record, not the file: the header `ergopti-update-asset-v1`, the asset
name, its size and its lowercase SHA-256, each followed by a line feed. The
signature (ECDSA P-256, SHA-256, raw 64-byte `r||s`, base64 on one line) therefore
binds the name, the size and the content, and the updater verifies it from the
digest it already computed over the exact bytes it installs.

P-256 and not the Sparkle Ed25519 key: the Windows CNG provider only gained
Ed25519 recently and the driver supports Windows 10; CNG and OpenSSL both verify
P-256. Windows 10 and later, and OpenSSL 3, are the verifiers; no extra binary.

## Code in the repository

| Part                          | File                                                                 |
| ----------------------------- | -------------------------------------------------------------------- |
| Policy                        | `_shared/modules/updater/asset_signing.json`                         |
| Signer and reference verifier | `tools/build/update-asset-signature.cjs`                             |
| Shared vectors                | `_shared/tests/corpus/updater/asset_signature_vectors.json`          |
| Linux verifier                | `linux/infra/asset_signature.lua` (OpenSSL)                          |
| Windows verifier              | `windows/modules/updater/asset_signature.ahk` (CNG)                  |
| CI signing                    | `Sign the update asset` steps in `ci-windows.yml` and `ci-linux.yml` |
| CI presence gate              | `ci-release.yml`, "Refuse to publish an incomplete..."               |

## Maintainer setup (nothing here can be done from the repository)

1. Generate the key pair once, on a trusted machine:
   `node tools/build/update-asset-signature.cjs keygen`.
2. Store the printed private PEM as the repository secret `UPDATE_SIGNING_KEY`
   (GitHub, Settings, Secrets and variables, Actions). Keep an offline copy; a
   lost key means every installed copy needs a manual update.
3. Put the printed public key (base64 SubjectPublicKeyInfo) into
   `public_key_spki_base64` of `asset_signing.json`.
4. Cut one release with `enforcement` still `"off"`. The release lanes sign and
   publish the `.sig` files; the updaters verify them and log the result.
   Check that both `ErgoptiPlus.exe.sig` and `ergopti-plus-linux.tar.gz.sig` are
   attached and that the update log says `verified`.
5. Set `enforcement` to `"required"` in a following commit. From then on a release
   without the signatures fails in CI, and an updater refuses an asset whose
   signature is missing or wrong.

While `enforcement` is `"off"` the updaters log on every update that the signature
was not enforced; this is a stated, reversible interim state and not a fallback.

## Verifying by hand

`node tools/build/update-asset-signature.cjs verify <public-key-base64> <asset>`
with the `.sig` next to the asset.
