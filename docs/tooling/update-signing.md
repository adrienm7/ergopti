# Update asset signing (Windows and Linux)

The macOS archives carry a Sparkle EdDSA signature. The Windows executable
(`ErgoptiPlus.exe`) and the Linux bundle (`ergopti-plus-linux.tar.gz`) are signed
the same way in spirit: each release publishes a detached `<asset>.sig` and both
updaters verify it before installing. The policy is
`static/ergopti_plus/_shared/updater/data/asset_signing.json`.

## What is signed

A canonical record, not the file: the header `ergopti-update-asset-v1`, the asset
name, its size and its lowercase SHA-256, each followed by a line feed. The
signature (ECDSA P-256, SHA-256, raw 64-byte `r||s`, base64 on one line) therefore
binds the name, the size and the content, and the updater verifies it from the
digest it already computed over the exact bytes it installs.

P-256 and not the Sparkle Ed25519 key: the Windows CNG provider only gained
Ed25519 recently and the driver supports Windows 10; CNG and OpenSSL both verify
P-256. Windows 10 and later, and OpenSSL 3, are the verifiers; no extra binary.

## How the Linux updater applies it

`linux/modules/updater/signature_gate.lua` is the only caller of
`linux/infra/asset_signature.lua`. The transfer fetches `ergopti-plus-linux.tar.gz.sig`
next to the checksum, on the checksum phase deadline, and asks the gate once the
archive is adopted, with the sealed size and the verified SHA-256. A refusal retires
the adopted archive through the normal failure path, so nothing is installed.

| `enforcement` | good signature            | bad, missing or undownloadable signature     |
| ------------- | ------------------------- | -------------------------------------------- |
| `"off"`       | installs, logs `verified` | installs, logs the reason in words (warning) |
| `"required"`  | installs, logs `verified` | refused with the reason in words (error)     |

There is no separate `"warn"` value: with `"off"` and a key provisioned a bad
signature is already reported without blocking, and a new value would not be
admitted by the Windows verifier, which reads the same policy file. A policy that
cannot be read or admitted refuses the update instead of skipping the check.

## How the Windows updater applies it

`Updater_DownloadAndInstall` is the one path of the tray's update, the update
prompt and the release installer. It asks `AssetSignature_AllowsInstall`
(`windows/modules/updater/asset_signature.ahk`) before its transaction starts,
with the size and digest GitHub's release API authenticated; the staging worker
then enforces that same digest on the downloaded bytes. The table above applies,
with one difference: no key means nothing is fetched. Step 4 below is also the
first real download of the `.sig` asset through the managed transport, so an
`"off"` log saying the signature could not be downloaded must be resolved before
step 5.

## Installing from the public feed (Windows and Linux)

When the GitHub API gives the Versions window no list, the window reads the
public Atom feed, which names no assets and no digests. Decided 2026-11-06 (as
macOS hands that release to Sparkle): only the newest release of the channel on
screen, when the shared offer rule offers it, may install from it, and only
through its signature, which is then required whatever `enforcement` says:

- Windows: `AssetSignature_AuthenticateFeedAsset` downloads `ErgoptiPlus.exe`
  and `ErgoptiPlus.exe.sig` under their conventional release path, computes the
  size and SHA-256 of the downloaded bytes, verifies the rebuilt record and
  hands that size and digest to the staging worker, which downloads the asset
  again and enforces them as it does an API digest.
- Linux: `manager.feed_release_record` names the bundle, its `.sha256` and its
  `.sig` under their conventional names, marked `signature_required`; the
  transfer verifies the archive against the checksum, then the gate requires
  the signature over the sealed size and that digest.

With no key provisioned every feed row keeps the no-details refusal; an older
row is refused with `install_error_feed_not_newest`, and a signature that does
not verify with `install_error_feed_signature`. The update check's own feed
fallback still only announces a release (check-only). Tests use the throwaway
key of `_shared/tests/corpus/updater/feed_install_vectors.json` and local fake
feeds.

macOS needs nothing more: Sparkle verifies the EdDSA signature of the appcast
download, and the in-app release installer checks the GitHub API digest and the
code-signature requirement of the staged app.

## Code in the repository

| Part                          | File                                                                 |
| ----------------------------- | -------------------------------------------------------------------- |
| Policy                        | `_shared/updater/data/asset_signing.json`                            |
| Signer and reference verifier | `tools/build/update-asset-signature.cjs`                             |
| Shared vectors                | `_shared/tests/corpus/updater/asset_signature_vectors.json`          |
| Linux verifier                | `linux/infra/asset_signature.lua` (OpenSSL)                          |
| Linux updater gate            | `linux/modules/updater/signature_gate.lua`                           |
| Windows verifier and gate     | `windows/modules/updater/asset_signature.ahk` (CNG)                  |
| CI signing                    | `Sign the update asset` steps in `ci-windows.yml` and `ci-linux.yml` |
| CI presence gate              | `ci-release.yml`, "Refuse to publish an incomplete..."               |

## Maintainer setup (nothing here can be done from the repository)

1. Generate the key pair once, on a trusted machine:
   `node tools/build/update-asset-signature.cjs keygen`.
2. Store the printed private PEM as the repository secret `UPDATE_SIGNING_KEY`
   (GitHub, Settings, Secrets and variables, Actions). Keep an offline copy; a
   lost key means every installed copy needs a manual update. `ci.yml` passes it
   to the Windows and Linux lanes on release runs only, and both declare it.
3. Put the printed public key (base64 SubjectPublicKeyInfo) into
   `public_key_spki_base64` of `asset_signing.json`.
4. Cut one release with `enforcement` still `"off"`. The release lanes sign and
   publish the `.sig` files; the updaters verify them and log the result.
   Check that both `ErgoptiPlus.exe.sig` and `ergopti-plus-linux.tar.gz.sig` are
   attached and that the update log says `verified`. Then, with the API
   blocked (for example after the 60-request limit), install that release from
   the Versions window's feed list on Windows and on Linux: the log must say
   `Feed release ... authenticated` (Windows) or `Update signature verified.`
   after the feed row was chosen (Linux), and an older feed row must be refused.
5. Set `enforcement` to `"required"` in a following commit that changes only that
   field. From then on a release without the signatures fails in CI, and an
   updater refuses an asset whose signature is missing or wrong. The flip is
   refused while `public_key_spki_base64` is empty, by the release tool, the
   Windows verifier and the Linux gate alike, since it would refuse every
   update (`tools/test/test-update-asset-signature.cjs`).

## What the release lanes do

`node tools/build/update-asset-signature.cjs release-sign <asset>` is the whole
CI decision, tested by `tools/test/test-update-asset-signature.cjs` with
throwaway keys:

- the policy names a key, or `enforcement` is `"required"`: a missing
  `UPDATE_SIGNING_KEY` fails the lane, and a secret whose signatures do not
  verify against `public_key_spki_base64` fails it too (nothing is written);
- the policy names no key yet: a missing secret only warns, and the release is
  published without `.sig` files.

`ci-release.yml` asks `expects-signatures` and refuses to publish a release
whose `.sig` assets are missing once the answer is `yes`.

While `enforcement` is `"off"` the updaters log on every update that the signature
was not enforced; this is a stated, reversible interim state and not a fallback.

## Verifying by hand

`node tools/build/update-asset-signature.cjs verify <public-key-base64> <asset>`
with the `.sig` next to the asset.
