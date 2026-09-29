# Local branch final audit

Committed dev: 2d065e7c808fb3006fa23dfa3e2584e1747d3b9e
Committed main: 3b8811be72745d158bc24dfb41580bb695005081

| Branch                         | Merge base                               |   + |   - |
| ------------------------------ | ---------------------------------------- | --: | --: |
| feat/ovh2-console              | ab7412933a69c79669142b48614c35c83c1224da |   1 |   2 |
| feat/ovh2-diag-integration     | 51563a9ad3d8e615fbfbf51bc6d6c44101b0755b |   6 |  37 |
| feat/ovh2-linux-harness        | ab7412933a69c79669142b48614c35c83c1224da |   0 |   1 |
| feat/ovh2-neutral-config       | 437f490243c7a63d32e25a6920ce60c0e958ad82 |   2 |   1 |
| feat/ovh2-shortcut-refusals    | d409787a526c46298ab5370b89988c40b3a5e618 |   0 |   1 |
| feat/ovh2-state-refusals       | d409787a526c46298ab5370b89988c40b3a5e618 |   0 |   1 |
| feat/ovh2-windows-master-state | e77324b6785ca29627d1b8c1e0ef689fa69fdabe |   1 |   0 |
| worktree-wf_f8423464-54e-1     | f31e85e1154b912ddea286280331d82f7fe2fa0a |  14 |   0 |
| worktree-wf_f8423464-54e-2     | f31e85e1154b912ddea286280331d82f7fe2fa0a |  14 |   0 |

## Interpretation

- Read-only committed-history audit against pinned dev. Dirty root integration is excluded.
- Minus proves patch equivalence. Plus alone does not prove missing functionality. Adapted integrations use an exact cherry-pick footer or matching unique subject/body and prior integration evidence; retain originals because patch IDs differ.
- The two worktree-wf branches have the same HEAD. Thirteen of their fourteen plus commits are already reachable from main. Only c4f5973 is outside both dev and main.
- f35930ec2 adds macOS infra/extension_packs.lua and its tests/unit/lib/test_extension_packs.lua; both files are absent in dev. This L4 owner remains unintegrated.
- e58cadf95 adds historical hotstring binding metadata to the shared scanner; that implementation is absent in dev. Preserve scanner/test original for coordinated L4 integration.
- c4f5973 is SvelteKit dependency update #83. Preserve once and review against current package versions; do not blindly reapply.
- No patches exported, branches deleted, source/index changed, commits or pushes performed by this audit.

## All distinct plus commits

- a96a9e84e18fb3d81637435365686bd9878b3568 — feat(console): center native debug windows at a shared minimum size. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: 503f6cb5e1d2c11067a711aa53d3cfb74c8b767b.
  Preserve original: `git format-patch -1 --stdout a96a9e84e18fb3d81637435365686bd9878b3568` (redirect to a dedicated patch; not executed).
- ecacf79938b74817e48ddf9915902b32de8ca1fe — feat(layouts): add the shared layout manager window on three drivers. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: dcfbe6051f3b0e33a2ff36030e7575b3cb5367f1.
  Preserve original: `git format-patch -1 --stdout ecacf79938b74817e48ddf9915902b32de8ca1fe` (redirect to a dedicated patch; not executed).
- 5bfa29e5f4e6fcc4f91bf792f85bb46f782f2130 — refactor(macos): host the layout manager window in ui/layout_manager. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: 9da35250472e7a12d34cf86eb1515502f307e071.
  Preserve original: `git format-patch -1 --stdout 5bfa29e5f4e6fcc4f91bf792f85bb46f782f2130` (redirect to a dedicated patch; not executed).
- f77494627af86efc87bf8df5191a20a1dfb43b85 — feat(layouts): publish verified extension generations atomically. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: 129e02f61498a6545c8cca12ea8fcfbd95396f18.
  Preserve original: `git format-patch -1 --stdout f77494627af86efc87bf8df5191a20a1dfb43b85` (redirect to a dedicated patch; not executed).
- 703d10c88ae4f98be283357afc2116be636efb29 — feat(layouts): discover committed extension packs on Linux. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: 50dff8281d6daf8256d3363922bd7c3323bccaf5.
  Preserve original: `git format-patch -1 --stdout 703d10c88ae4f98be283357afc2116be636efb29` (redirect to a dedicated patch; not executed).
- f35930ec2fedd889c4ffc4fff7dfbd1101626783 — feat(layouts): discover committed extension packs on macOS. no_integration_proven_preserve_patch.
  Preserve original: `git format-patch -1 --stdout f35930ec2fedd889c4ffc4fff7dfbd1101626783` (redirect to a dedicated patch; not executed).
- e58cadf956fac2bf18adf652cd3031f4198278b6 — feat(layouts): declare historical hotstring source bindings. no_integration_proven_preserve_patch.
  Preserve original: `git format-patch -1 --stdout e58cadf956fac2bf18adf652cd3031f4198278b6` (redirect to a dedicated patch; not executed).
- 8ad07a053c904c69869172f343ebe8fd4877dcf5 — feat(config): start neutral and persist only explicit overrides. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: ae047500fe4a6cef4f0497cde3840cfa17b06444.
  Preserve original: `git format-patch -1 --stdout 8ad07a053c904c69869172f343ebe8fd4877dcf5` (redirect to a dedicated patch; not executed).
- 7bbae9394ea55b247d2f2d6e16d8c5ce24e7cf27 — feat(config): retain rollback debt for scoped transactions. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: dc4f2618159deb0574da7b896a6ab5e1c645f022.
  Preserve original: `git format-patch -1 --stdout 7bbae9394ea55b247d2f2d6e16d8c5ce24e7cf27` (redirect to a dedicated patch; not executed).
- 335e06aa1f2b868e225da798269b03edcdf7dcae — fix(windows): preserve desired features behind category masters. adapted_integration_identified_not_patch_equivalent.
  Identified adapted counterpart: 8549080ada96a5df1958e1a09eddb388c51a2445.
  Preserve original: `git format-patch -1 --stdout 335e06aa1f2b868e225da798269b03edcdf7dcae` (redirect to a dedicated patch; not executed).
- 7a3b86196e52067d02d219fae23e1e92502f2bd3 — Bump devalue in the npm_and_yarn group across 1 directory (#38). reachable_from_main_not_dev.
- 7ea5f77607238568f9389eda492cdb40edc223fa — Create CNAME. reachable_from_main_not_dev.
- d97701f1ed4545028fab2314eb8b79f621b6814f — Bump picomatch in the npm_and_yarn group across 1 directory (#51). reachable_from_main_not_dev.
- 8a51c7cc5cdd8e7b9c6f338b798bfff5fe7f1758 — Bump vite in the npm_and_yarn group across 1 directory (#52). reachable_from_main_not_dev.
- 5f4d709232812ecc42095d852e9685e8d394760c — Bump lodash in the npm_and_yarn group across 1 directory (#53). reachable_from_main_not_dev.
- fdbad76028652a21cb12eb11b4ac67bc31ee09a9 — Bump basic-ftp in the npm_and_yarn group across 1 directory (#54). reachable_from_main_not_dev.
- 2f7149d636dafcb09b224a979952308dd4e06b6e — Bump basic-ftp in the npm_and_yarn group across 1 directory (#56). reachable_from_main_not_dev.
- 3f5218a1e2f3889486cb3189114cfbf2230570a5 — chore(ci): add release build workflow with workflow_dispatch. reachable_from_main_not_dev.
- cbd7328b52299ba987eb7f0c06cb298597ebe151 — Bump lxml from 6.0.2 to 6.1.0 in the uv group across 1 directory (#77). reachable_from_main_not_dev.
- 967519de6071bccad732f88a0dee968c4ef09310 — Bump svelte in the npm_and_yarn group across 1 directory (#76). reachable_from_main_not_dev.
- c23e22f823fc0769630979fbb53b310553b13f4e — Bump the npm_and_yarn group across 1 directory with 2 updates (#78). reachable_from_main_not_dev.
- d2213d10c9ad21ffb75a0d7a62ef851e40f16fd1 — chore(ci): remove obsolete deployTocPanel workflow. reachable_from_main_not_dev.
- 3b8811be72745d158bc24dfb41580bb695005081 — Bump esbuild in the npm_and_yarn group across 1 directory (#81). reachable_from_main_not_dev.
- c4f59734352ab442daad6309f5ec57854f4511a3 — Bump @sveltejs/kit in the npm_and_yarn group across 1 directory (#83). no_integration_proven_preserve_patch.
  Preserve original: `git format-patch -1 --stdout c4f59734352ab442daad6309f5ec57854f4511a3` (redirect to a dedicated patch; not executed).

Three lane branches have zero plus commits: linux-harness, shortcut-refusals, state-refusals. Their changes are patch-equivalent in committed dev. Before retirement, preserve any unrelated worktree state separately.
