# Updater: the manual check without its window, asset binding, pause

Audited source: `9feb515a` (`claude/ergopti-todo-parity-audit`), against the
[updater campaign](../2026-11-11-updater/report.md). Date: November 12, 2026.

## Scope

The campaign's two rows left uncompared:

- the macOS manual check when its window cannot open;
- the Linux release asset bound by exact name rather than by repository
  path.

While tracing the manual check, its behaviour during a pause was compared
too. The campaign's fixes, UPD-1, UPW-005 and its refuted list are not
repeated.

## Fixed

| Id      | OS    | Sequence                                                                                               | Windows                                                                                                       | Before                                                                       | Regression                     |
| ------- | ----- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------ |
| UPX-001 | macOS | « Check for updates » when the update-check window fails to open                                       | The manual check answers in a message box (`_Updater_ShowAvailableUpdateCallback`)                            | An ERROR log only: no check ran and nothing was shown                        | `upx-001-check-without-window` |
| UPX-002 | Linux | A release answer whose bundle or checksum asset has the right name but another host, owner or tag path | `_Updater_FindAsset` requires `<repository>/releases/download/<tag>/<name>` and refuses the release otherwise | Any URL was taken for the bundle and for the checksum it is verified against | `upx-002-asset-url-binding`    |

UPX-001 reuses the Linux wording of the same answer: `check_notice` moved to
`_shared/lua/updater/`, so each outcome keeps the sentence the window shows on
both drivers. The macOS archive selection (`updater.release_assets`) already
bound its URL, as Windows does; UPX-002 gives the Linux bundle, checksum and
signature the same binding. The Linux test fixtures that served assets from
`example.invalid` now use the repository path a real release carries.

## Decided

- **UPD-2, a manual check during a pause** (decided by the coordinator on
  2026-11-12, from the maintainer's rule that installs stay allowed during a
  pause): the check runs, as on macOS (`auto_check.check_now`) and Linux
  (`check_for_updates`). Windows counterpart, for its worker: drop
  `_Updater_RefuseManualWhileSuspended` from the manual check
  (`modules/updater/self_update.ahk`) and update the AHK test that expects
  the refusal.

## Open

Native receiving is unqualified: no network, Sparkle or Hammerspoon run.
