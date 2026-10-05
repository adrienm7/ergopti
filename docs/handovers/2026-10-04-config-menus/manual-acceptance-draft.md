# Group 1 manual acceptance draft: Windows and macOS

This is a scenario draft for TODO5/7/38, not an executed result or a claim that
a build is available. The coordinator must supply the qualified artifact,
exact source SHA, launch instructions and a verified isolated test profile
before execution. Record the artifact/SHA with the results. Keep TODO16/38
requirements and any Linux/native packaging gaps open.

## Isolation and minimal reporting

Use synthetic data only, such as `Ergopti test`, in a blank local text editor.
The coordinator must verify the selected configuration and log directories
before starting. Use a separate test account or a verified test configuration;
do not run two Ergopti drivers against one profile. On macOS, a separate
Ergopti configuration alone does not isolate the active Karabiner profile or
system input source: physical remapping needs an explicitly selected disposable
Karabiner profile and a tested way to return to the original one. If that is
unavailable on the work Mac, perform the wizard/menu observations only and mark
physical remapping and global resets not executed.

No logs, screenshots, paths, configuration contents, work text or company data
need to leave the machine. A sufficient report is `case ID / Windows or macOS /
passed, failed, not executed / short synthetic observation`. Keep backups and
file comparisons local. Stop the candidate and restore the previous profile
using the coordinator's instructions after testing.

## Wizard: TODO7 and real UI acceptance in TODO38

1. **W1 — Fresh setup and cancellation.** Open the qualified candidate with a
   fresh test profile. Confirm the wizard appears, choose French, and select
   the supplied empty test folder. Visit the feature pages and return with
   Back. Close the wizard before Finish. No selected recommendation should
   become an active remapping merely from visiting a page or cancelling. The
   host may create the selected directory or persist its location; compare
   feature settings rather than treating those path side effects as failure.

2. **W2 — Finish, restart, and rerun.** Reopen setup from Configuration. Use the
   supplied test folder, enable one supported category and one unmistakable
   recommendation from its displayed checklist, and leave AI and metrics
   consent at No. Finish. Inspect that category's menu, restart, and reopen
   setup. The selected category/item should match its stored state; AI and
   metrics consent must remain off. Reopening setup must not silently import
   every recommendation. Keep this test limited to features actually supported
   by that driver.

3. **W3 — Trigger intent and input validity.** On Hotstrings, observe the
   current trigger and advance/back without editing it. Finish and reopen;
   its value must stay the same. Rerun and explicitly choose another displayed
   valid trigger; finish/restart and check it persisted. Try custom `ab`: the
   page must refuse to advance/finish while that changed answer contains two
   code points. Clear that edited field: it must also refuse. Repair it with
   `★` and continue. Existing untouched empty/obsolete stored values have a
   different preservation policy; do not use this edited-field refusal as an
   assertion that reopening such values automatically repairs them.

4. **W4 — Folder change and current values.** The coordinator prepares two
   test folders with visibly different harmless category/trigger settings.
   Open setup on A, return to the folder page, select B and advance. Later
   pages must use B's current values. Finish and inspect B locally; A must
   retain its original settings. If the host response is slow enough to
   observe, Next/Finish must remain blocked until B's response is admitted.
   Fast completion does not prove the pending-response interval; mark that
   subcase not observed instead of manufacturing a result.

5. **W5 — Platform catalogue and labels.** In French and then English, visit
   every wizard page and the main configuration/category menus. Confirm useful
   translated labels, stable ordering, and no raw translation keys. Windows
   and macOS trigger presets include `★`, `ù`, and `;`. The macOS keyboard
   layout page should explain its system input-source ownership rather than
   pretending to have the Windows category switch. AI/metrics consent is not
   preselected. Observing these two languages does not qualify all 21 locales.

## Category scopes and global composition: TODO5/38

Scope restore/clear commands apply immediately and create backups; they do not
ask for an additional confirmation. Use only the disposable profile. The
coordinator should supply local before/after reference values from the final
shared manifest, so observations are not guessed from labels alone.

6. **S1 — Tap-Holds clear and restore.** In Tap-Holds, assign one harmless
   non-neutral tap/hold pair through the actual menu and retain a different
   harmless Shortcuts preference. Choose Clear to system behaviour. The
   Tap-Holds assignments should become neutral, its enabled switch should
   retain its previous state, and the unrelated Shortcuts preference should
   remain. Verify the scope backup exists locally. Restore recommended values;
   inspect the selected key against the coordinator's manifest reference.
   Restart and inspect the same state. Do not assume macOS timing/engine controls
   are identical to Windows per-key controls.

7. **S2 — Hotstrings clear and restore.** With one known supported test
   hotstring enabled and one unrelated shortcut customized, choose Hotstrings
   Clear to system behaviour. The supported hotstring/gates should become
   neutral while the unrelated shortcut remains. Restore recommended values,
   compare selected gates/delays to the final manifest reference, and restart.
   Locally check backups and the retained synthetic unknown/outdated markers
   in any coordinator-prepared fixture. Ordinary clear/restore must not act as
   explicit unused-key cleanup. Do not infer editor/delay features owned by
   another group are complete from this scope observation.

8. **S3 — Global clear and restore.** With at least two tested categories
   customized, run Configuration Clear to system behaviour. Inspect the same
   Tap-Holds/Shortcuts/Hotstrings items together, then restart. Run Configuration
   Restore recommended values and inspect them together again. Both commands
   must create their required backups. Restore must not grant AI or metrics
   consent. This is a successful composition smoke check; it does not prove
   rollback after a controlled native read/write/unlink/release refusal.

9. **P1 — Physical key ownership and exit.** Only with the verified disposable
   native input profile, test the selected tap, deliberate hold and ordinary
   typing in the blank editor. After scope clear, the cleared key should have
   its system behaviour. After restore it should follow the displayed known
   recommendation. Toggle the category off and on and check settings survive
   while physical effects follow the switch. Quit the candidate and verify
   ordinary typing and native modifier release. On macOS, perform these checks
   only when real Karabiner, permissions and the disposable active profile are
   available. A menu check or a Lua stub is not a physical result.

## Follow-up evidence still required

Record failures by case and synthetic symptom; logs are optional and local.
The coordinator should supply separate disposable fixtures/scripts for
outdated scalar preservation, unsafe/typed wizard input, changed-source
refusal and rollback/retry. Do not hand-edit a work profile, change directory
permissions, lock native source files or alter active Karabiner state to invent
those faults. The frozen registered tests plus final native runners establish
their controlled software evidence; these user observations supply real UI and
physical evidence. E2E, packaging, installation, Linux real input/session and
unobserved platform/locale cases remain separately reported.
