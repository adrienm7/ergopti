# Deep parity audit: macOS × lifecycle, updates, setup and diagnostics

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`.
Date: 2026-11-04. Read-only audit. Both completed LLM artifact directories retained
unchanged. Paths below are relative to `static/ergopti_plus/`, unless specified.

## Result and proof boundary

Two bounded source/behavior passes found two new confirmed defects: failed onboarding
Finish leaves a newly selected configuration locator published; and a successful
backup restore followed by a refused reload still reports the complete success
message promising restart. The latter also exists in the Linux counterpart.

Real Lua 5.4.8 with lfs 1.8/luv 1.50 executed production controllers over repository
fixtures; pinned Node 22.22.2 executed shared contract gates. No real install,
uninstall, application replacement, login registration, native Mac boot, native
security/signature command or diagnostic upload was performed. Installer tests
use owned scratch files, fake executables/commands and recording process ports.
Their results are not native macOS install proof.

Previously documented differences in `docs/audits/platform-parity/2026-11-04/lifecycle.md`
(macOS-only unavailable-feature diagnostic section, feed-only Sparkle fallback,
backup extension/native-settings scope, App Cloner/Encryptor) are referenced as
known coverage, not counted as new findings.

## MC-001 — Failed onboarding Finish leaves the configuration locator changed

Severity: medium. Confidence: high, executed real Finish controller and actual
migration refusal with recording persistence ports.

`macos/ui/onboarding/init.lua:695` validates answers, then `:722` persists the new
configuration directory. `:736` switches `_config_path` to that directory;
`:743` persists locale; only at `:753` does `Answers.commit` prepare/version the
selected destination and publish the configuration batch. Every error calls
`fail_commit` (`:570`), which closes the wizard and shows an error, without
restoring the old directory or locale. `publication.finish` at `:848` settles the
configuration-file publication owner; it does not own either preceding scalar.
`previous_config_path` at `:720` is used to select a later tap-hold import path,
not to compensate a failed Finish.

This is persistent state, not just a wizard text field:
`macos/ui/menu/menu_paths.lua:157` calls the canonical ConfigPaths writer;
`macos/infra/config_paths.lua:729` saves paths.toml and updates the current resolver.
Its local rollback at `:774` handles failure of that one paths publication only;
a later onboarding config failure has no inverse. Locale persistence is separate
(`infra/i18n.lua:258`), including rewriting an existing configured locale row.

Reproduce with `repro-onboarding-partial-state.lua` (executed): choose `/new-config`
from `/old-config`, submit valid answers, then refuse/throw the final writer.
The actual controller leaves current_dir `/new-config`, path_writes=1,
locale_persists=1, reports one error, and schedules no reload. Successful control
publishes the same directory and schedules exactly one reload.

Stronger normal-condition control: select a directory whose config.toml declares
`[_meta] schema_version=999`. The real migration engine rejects it before any main
configuration write. Observed:

```
write=newer-schema current_dir=/new-config path_writes=1 locale_persists=1 config_writes=0 error_alerts=1 reloads=0
```

No native I/O refusal is needed for that branch. The fixture's locale and path
persistence ports record writes; migration/catalogue/answers/Finish orchestration
are production code. On a live rerun this can leave the existing process using
old runtime options while subsequent saves resolve the new directory, even though
Finish reported failure. No deletion/loss of the original directory is asserted.

Parity: Linux `linux/ui/onboarding/bridge.lua:466` snapshots locale/directory and
`:494` retains snapshot restoration on failed config publication. Windows
`windows/ui/onboarding/finish.ahk:232` places targets and the stable locator under
an owned WAL transition with the locator last. MacOS lacks the equivalent outer
transaction despite having a strong main-config publication owner.

Regression/fix direction: capture directory and locale before publication; either
validate/render the destination before publishing the locator, or give all fields
one exact transaction/compensation owner. On destination-version refusal, ordinary
writer failure and thrown callback, require prior directory/locale or explicitly
retained compensation debt; require no success/reload and protect against restoring
over a genuinely newer external change. Include a successful moved-directory control.

## MC-002 — Backup restore promises restart even when reload is refused

Severity: medium. Confidence: high, executed real Versions bridge.

`macos/ui/changelog/init.lua:587` restores via the current backup owner. On success
`:610` sends `phase='restored'`, then `:611` asks the termination coordinator to
reload. A false/throw result at `:613` only emits an error log. It sends no failed
or “saved, reload required” phase, and owns no later abort callback.

The success message is user-visible and stronger than a disk-only acknowledgment:
canonical locale `en.json:201` reads “Configuration restored: ErgoptiPlus restarts
on it.” `_shared/ui/changelog/script.js:1307` selects it for restored;
`:1322` hides the restore button after that phase.

Executed `repro-restore-reload-ack.lua` posts the genuine restore_backup bridge
message, with backup success and reload true/false/throw respectively. All three
produce exactly `page_phases=restoring,restored`. A rejected reload therefore looks
identical to successful handoff, while the disk configuration has changed and the
old process can remain alive. Coordinator refusal is an actual contract:
`infra/termination_coordinator.lua:620` can return false before accepting a request
(uninitialized/invalid admission/retirement debt), and `:813` exposes that result.

Parity: Linux `linux/ui/changelog/bridge.lua:614–634` has the same false-success
message on failed restart; **do not claim Linux reports a page failure**. Windows
`windows/ui/changelog/init.ahk:1066/:1096` reports refused restore reload and retains
its exact terminal configuration barrier while the old runtime survives.

Fix direction: reflect immediate refusal and later owned abort with an explicit
reload-required/failure state, preserving the restored disk state and its
pre-restore backup path. Do not call failed disk restore when the disk operation
actually succeeded. Regression must drive true/false/throw and asynchronous abort,
and require the page not promise restart for refused/aborted handoff.

## Pass 1 — forward coverage register

| Scope                         | Production ownership / observed evidence                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Startup/native prerequisites  | `macos/init.lua:380` requires ConfigPaths commit before consumers; `:491` reconciles durable config decisions; `:1360` first-launch guard precedes input pre-start. Selected boot meta-tests validate source ordering and fail-fast boundaries, not real Hammerspoon startup. Routed memory's packaged launch/Accessibility consent limits remain applicable.                                                      |
| Configuration paths           | `infra/config_paths.lua:729` canonical paths.toml writer normalizes, creates chosen directory, commits locator with local rollback on its own refusal. `ui/menu/menu_paths.lua:157` is wizard bridge. Outer onboarding failure compensation is MC-001.                                                                                                                                                             |
| Backup snapshot               | `modules/updater/config_backup.lua:94` supplies classified reads, create-only copy and compare-and-publish replacement; `:145` roots only canonical config directory. Shared `updater/config_backup.lua:280` snapshot writes manifest last, read-verifies copies and refuses incomplete records. Binding/shared backup tests pass.                                                                                 |
| Restore                       | Shared `config_backup.lua:413` validates all backup files then snapshots current config before replacements. Each replaced file is read back; write failure returns backup path. Controller reload acknowledgment is MC-002.                                                                                                                                                                                       |
| Channels/checks               | `modules/updater/auto_check.lua` uses shared schedule/check-state, ETag cache, channel registry and offer rule; checks never install. Manual/automatic clients have distinct lifetime owners; retirement/isolation tests pass.                                                                                                                                                                                     |
| Chosen release integrity      | `modules/updater/release_installer.lua:217` stages declared asset; `adapters/release_stage.sh:100` SHA-256, `:115` exact short version, `:119/:130` extracted app must satisfy running bundle designated requirement with deep strict signature check. No unchecked historical/feed asset installation discovered.                                                                                                 |
| Install handoff               | `release_installer.lua:270` requires exact ARMED receipt before controlled exit. Emitted swap script admits same filesystem, retained previous app, occupied-destination refusal, native rename role and serialized installer lock. Scratch emission/race/receipt tests pass; native APFS/code-sign identity not executed.                                                                                         |
| Cancellation/session lifetime | Versions install session captures original recipient and acceptance owner (`ui/changelog/init.lua:539/:573`). Accepted operations continue after later close/pause by explicit policy; stale results cannot publish into a successor page. Managed-admission and bridge-retirement tests pass. This is not the behavior of a fresh action attempted while paused, which is rejected.                               |
| Login/uninstall               | `ui/menu/start_at_login.lua:21` updates checkmark only after enabled/disabled/approval receipt; queues one pending toggle. `ui/menu/uninstall.lua:49` requires READY→COMMIT→ACK then controlled exit. Native `UninstallWorker.swift:180` validates exact bundle and clean exit, removes owned runtime/login entries and moves app to Trash; personal configuration is retained. Only fake protocol/menu tests ran. |
| Onboarding imports/reload     | `ui/onboarding/init.lua:753` main answers publication; `:814` tap-hold import, separate recommended layer owner and timeout; `:668` owned reload reports refusal/abort. Existing transaction/retarget/locale/write/import tests pass. MC-001 is outside their main-file owner coverage.                                                                                                                            |
| Diagnostics/privacy           | `ui/healthcheck/report.lua` delegates report creation to closed typed shared share policy, excludes arbitrary paths/free text, opens browser after clipboard/local attachment with no upload. `ui/healthcheck/core.lua:1090` day-log collection is explicit opt-in and unchecking drops it. Host privacy/share/report tests and shared model tests pass on synthetic snapshots; no real personal log was exported. |

## Pass 2 — adversarial candidates and refutations

- **Confirmed MC-001:** successful locator/locale publications precede refused
  destination migration or main writer. Main file compensation does not encompass
  these already committed fields. Actual schema-refusal control rules out an
  issue caused solely by an invented native failure.
- **Confirmed MC-002:** disk restore is acknowledged as complete application
  restart before the reload owner's actual receipt. False/throw controls are
  indistinguishable to the page from success.
- **Refuted: backup only exists on Windows.** Real macOS shared binding/Versions
  owners are present and tested. Backup scope is extension-filtered configuration,
  not an archive of all personal source/runtime/native settings; previous report
  already documents this caveat.
- **Not classified as defect: a restore can publish earlier files before a later
  write fails.** The shared owner explicitly creates a pre-restore backup and
  returns its path on failure; canonical failure locale explains that recovery
  copy. Windows comments acknowledge the same possibility, then retain a write
  barrier. Do not advertise every restore as an atomic multi-file rollback.
- **Refuted: closing Versions must cancel an accepted install.** Code and tests
  explicitly retain accepted transaction execution while fencing original page
  publications. The new page never acquires an old install's phase recipient.
- **Refuted: a failed API list permits unauthenticated feed-only install.**
  Direct install requires asset details/digest. Feed handoff admits only the
  newest subscribed-channel offer and delegates verification/consent to Sparkle.
  Arbitrary historical feed-only entries remain refused.
- **Not promoted: uninstall worker lost after rejected quit.** Lua failure path
  retires owner then calls task.terminate; native worker also has 30-second COMMIT
  and 60-second clean-exit windows. A hypothetical native termination refusal
  followed by another clean quit within that interval was not executed or proven
  with genuine process ownership. No destructive probe was attempted.
- **Bounded: ad hoc signatures and designated requirements.** Chosen release
  staging requires the next app satisfy the running designated requirement. This
  is a strict security boundary; same ad hoc identifier alone is not proof of
  equivalent signing identity. No fabricated “all ad hoc updates work” claim is
  made without native codesign/Sparkle validation.
- **Refuted: diagnostics always attach today's raw log.** Shared typed projection
  and explicit day-log action gate are enforced; synthetic oracle tests reject
  unknown/free-text/network identity fields and no-opt-in collection. Actual
  native probe outputs/permissions remain outside this environment.

## Intentional differences and provenance

| Difference                                             | Provenance / rationale                                                                                                                                            | User effect and counterpart                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sparkle plus custom chosen-version installer           | Explicit `release_installer.lua:7`: Sparkle refuses version downgrades; chosen release uses authenticated API digest plus designated requirement and staged swap. | Mac can install a chosen older listed release through separate verified path. Windows/Linux archive installers use their own authenticated asset/swap owners; implementation differs, feature family exists.                                                                                    |
| API-failure fallback                                   | Explicit `feed_handoff.lua:6`: Atom lacks assets/digests; only newest offered tag handed to Sparkle's user-confirmed signed-enclosure path.                       | Mac may still install newest offer during API failure; Windows/Linux list feed but refuse direct install without authenticated details. Previously known, not new. EdDSA authenticates the update enclosure consumed via appcast; do not infer that arbitrary Atom metadata is signed.          |
| Lua owns automatic cadence, Sparkle scheduler off      | Explicit `auto_check.lua:6/:12`: shared cadence supports presets below Sparkle's minimum hour and coherent restart/wake behavior.                                 | Same channel/frequency contract across OS; Mac's native updater only downloads/installs after user request.                                                                                                                                                                                     |
| Accepted update continues after page close/later pause | Explicit Versions controller comment and managed-admission behavioral tests.                                                                                      | Closing the UI does not cancel already accepted app replacement; stale phases remain private to retired original page. Fresh paused install clicks are refused. Other drivers' install sessions retain their own accepted transaction owners; exact process timing is native-specific.          |
| Native login item approval                             | Explicit receipt states in start_at_login plus native SMAppService host mechanism.                                                                                | Mac may require System Settings approval; UI does not falsely check enabled. Windows startup registration/Linux desktop autostart are equivalents, without the same Apple approval UI.                                                                                                          |
| Developer ad hoc guardian uses legacy registration     | Explicit routed memory `project-hs-adhoc-guardian-runs-legacy-only`: background-item launch constraints killed ad hoc registrations.                              | Developer/ad hoc builds avoid unsupported Background Items registration; signed builds retain it. This is signing-mode-qualified support, not total Mac login/remapping absence. No live registration performed.                                                                                |
| Uninstall retains personal data                        | Explicit UninstallWorker source contract and completion log.                                                                                                      | App/owned remap runtime/login entries removed, config/logs remain. Windows/Linux have own uninstall scopes; retaining user data is distinct from failing to uninstall application.                                                                                                              |
| Backup roots/extensions                                | Explicit Mac binding roots only config directory; shared extension/exclusion policy.                                                                              | hs.settings is not copied; .lua/.ahk arbitrary programmable source excluded by common extension rules. Linux also binds settings_store; Windows uses its config-root policy. Ordinary manifest options are in TOML; native store exclusion is not proof all preferences are lost. Known caveat. |
| Diagnostics unavailable-feature section                | Explicit diagnostics schema platform restriction and real macOS collector.                                                                                        | Mac explains unavailable features in diagnostics; Windows/Linux section absent. Previously recorded feature gap, not deliberate technical impossibility.                                                                                                                                        |
| Failed Finish locator/locale left published            | No explicit intentional exemption found.                                                                                                                          | MC-001: differs from Linux snapshot compensation/Windows WAL and leaves partial setup after error. Do not label intentional merely because order is documented.                                                                                                                                 |
| Restore reports restart despite refused reload         | No intentional rationale found.                                                                                                                                   | MC-002 on Mac/Linux; Windows reports refusal/protects disk transition.                                                                                                                                                                                                                          |
| Native prerequisites/permissions                       | Real native constraints, not blanket capability absence.                                                                                                          | Mac Accessibility/Automation/Karabiner/guardian paths differ from Windows hooks and Linux uinput/session tooling. This audit traced ownership/order only; native permission consent and full startup readiness were not executed.                                                               |

## Verification

Final targeted Lua results: **289 passed, no remaining failures**, 21 selected
repository test modules. `updater-backup-tests.log` initially records 161 pass and
2 failures because Python child controls could not discover Lua on PATH. With
parent's scratch toolchain bin on PATH, `release-installer-rerun.log` passes all
29 installer cases including both previously blocked controls. This supersedes
those two environment failures. `onboarding-lifecycle-diagnostics-tests.log`
records 126 pass. No actual target application was replaced/uninstalled.

Repro artifacts: `repro-onboarding-partial-state.lua/.log` and
`repro-restore-reload-ack.lua/.log`, both executed with recording persistence and
reload ports. The directory control, main write/refusal, migration and controller
logic are production code; actual user folders were not touched.

Pinned Node 22.22.2 gates passed: update channels (292 checks), update schedule
(524 checks), healthcheck model (16 sections/79 fields/216 labels/21 locales plus
synthetic privacy/summary controls), onboarding wizard page/folder/keyboard
controls. These are contract and synthetic-host tests, not native installation.

Remaining native work: packaged-app startup and trust/consent on Apple silicon and
Intel; actual codesign/Sparkle update acceptance; APFS rename/rollback; SMAppService
and uninstall exit monitor; native dialog/permission/diagnostic probe behavior.
No live credential, personal log, registry/login entry or application data changed.
No repository edits, commits or pushes. This is bounded two-pass coverage, not a
claim of complete native lifecycle equivalence under all failures.
