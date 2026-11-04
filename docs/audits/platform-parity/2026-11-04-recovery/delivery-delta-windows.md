# Windows migration delivery delta

Audited baseline: `3a680d9f530a9af686fccc16d3f7611ec7fb034c`.
Reviewed immutable delivery commit: `6d3c8ac5e2993a36c4ee0a1a67dfa3b207318edf`.
Read-only Git blob/function comparison. No proof replay, live module, test or generator executed. Baseline report/findings remain immutable.

**All four WFM findings remain applicable by source comparison.** No source file was renamed. Added header text shifts existing migration helper references by one line; main run-body runtime loop adds another four lines before locator rewrite.

| Finding | Current contexts at delivery SHA                                                                                                                                   | Assessment                                                                                                                                                                               |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WFM-001 | `windows/infra/legacy_folder_migration.ahk:244` run, moves :257–268, static rules :269–272, unchecked rewrite/report :273–275; `LegacyFolderRewritePathsFile` :212 | Locator/config move ordering, no admission on kept results, in-place FSWrite and boot continuation are unchanged. Extra managed-runtime moves do not add transaction/recovery ownership. |
| WFM-002 | Whole legacy config move :261; exact rule :270; exact normalized compare :185                                                                                      | Selected descendants still move with their ancestor and fail exact-only locator rebasing.                                                                                                |
| WFM-003 | Rewrite regex :176; semantic `ReadPathsToml` owner unchanged                                                                                                       | Quoted valid TOML keys are still ignored by migration while accepted by the reader.                                                                                                      |
| WFM-004 | Exact old locator move :257; unchanged `boot.ahk:66–70` and `ConfigTransitionWalPath` / inspect owner                                                              | Old Roaming locator WAL/artifacts are still neither recovered nor migrated before new-locator recovery. New runtime loop does not discover them.                                         |

These conclusions retain original evidence limits: source-derived Windows integration, real shared-core POSIX fixture corroboration at baseline, no native Windows execution. No new delivery runtime receipt is implied.

## Changed managed-runtime ownership

`AppFoldersManagedOllamaRoot()` now returns `AppFoldersRoot() + "ollama"`: `%LOCALAPPDATA%\Ergopti\ollama`, rather than sibling `%LOCALAPPDATA%\Ergopti-ollama`. Generated app dirs and canonical `_shared/modules/paths/app_dirs.toml` agree.

The migration now iterates `AppDirsMigrationWindowsLegacyOllamaFolders()` in declared order `["ergopti_plus_ollama", "Ergopti-ollama"]`. Both source paths are direct LocalAppData children and target the same new internal runtime directory. The existing collision owner handles each move: first source can populate target, second source with occupied target goes to its declared conflict backup. The new source comment explicitly claims a rename retains protected ACL and file identity recorded by root-owner.json; this review did not execute or certify that native claim.

**Superseded intentional row:** the baseline explanation that Windows must keep a protected _sibling_ because the runtime can only be a direct LocalAppData child is historical, not current product behavior. Current explicit architecture admits the runtime inside the main root while preserving its own protected ACL. Do not present the sibling exception or its prior open maintainer acceptance question as a current limitation.

The changed `modules/llm/ollama_managed_files.ps1` adds `Assert-OllamaTrustedParent`, admits a root one level below a direct LocalAppData child, creates/adopts the parent when allowed, holds that parent without DELETE sharing and checks its owner/write/delete/permission rights. This is a **changed native ownership/admission surface not freshly audited** here. No inference that its ACL/race protections are complete, and no new finding, follows from reading this delta. Native tests, ancestor replacement, retained root-owner.json identity and both legacy-runtime collisions need their own targeted review if required.

## Static identities checked

- LegacyFolderRenameInto byte-identical body
- LegacyFolderMoveEntry byte-identical body
- LegacyFolderMergeEntries byte-identical body
- LegacyFolderRewritePathsText byte-identical body
- LegacyFolderRewritePathsFile byte-identical body
- infra/boot.ahk byte-identical file
- adapters/file_system.ahk byte-identical file
- infra/config_transition.ahk byte-identical file
- infra/config_transition_runtime.ahk byte-identical file
- infra/toml/toml_helpers.ahk byte-identical file
