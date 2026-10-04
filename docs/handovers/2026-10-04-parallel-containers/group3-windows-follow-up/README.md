# Group 3 Windows continuation on the user's PC

This handoff preserves the Windows work explicitly deferred on 2026-10-04.
The ready macOS/Linux slice may be integrated while these Windows requirements
remain partial in `docs/ERGOPTIPLUS_TODO.md`. Read that current TODO before
using this historical handoff. Do not mark Group 3 complete from this document.

The basic Windows item 106 implementation and its registered tests are intended
to remain in the integrated ready slice. Their presence is **not native Windows
qualification**. The constructor correction in `inactive/windows106-ctor-handoff/`
is separately prepared, source-reviewed and **not installed**. Every native
Windows regression described below is **unexecuted by this Linux container**.
No physical keyboard, real Windows GUI, WMI brightness, compiled installation
or Windows process/HANDLE cleanup result is claimed here.

## Resume from actual current sources

1. Read `AGENTS.md`, `docs/memory/README.md`, the routed Windows and verification
   memories, `.agents/skills/verify-change/SKILL.md`, the current TODO, and this
   handover's parent `README.md` and `PARALLEL-WORK.md`. The user's later lock
   and multi-group integration instructions supersede the older sole-coordinator
   wording. Item 22 is deliberately withdrawn; do not restore it. Keep the
   cross-cutting validation requirements of items 16 and 38.
2. Inspect both working tree and index; preserve existing changes. Fetch the
   current `origin/dev`. Verify ownership of `feat/actions` and any proposed
   continuation branch before taking it over. Coordinate with the Windows
   workstation agent and Group 7 (`feat/windows-native`, items 19/49/50/51/101).
   Do not edit or delete another owner's branch/worktree.
3. Use an agreed continuation branch from the freshly fetched `origin/dev`.
   Stage exact owned paths. Never use `reset`, `clean`, `stash`, force-push or
   `backup/*` as shortcuts. Code, commits and technical documentation are English;
   user labels require all 21 real translations. Keep AHK UTF-8 BOM and all text LF.
4. Install the repository-pinned Node dependencies with `npm ci`, and the actual
   Windows runtime/compiler versions and verified archive checksums from
   `static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json`.
   Re-read the current pin; do not substitute an unverified executable.
5. Establish a native baseline on the actual current merged sources **before**
   applying the inactive constructor packet. Record SHA, interpreter/compiler,
   counts, failed tests, ignored tests, nonexecuted tests and physical prerequisites.
   A failed baseline requires diagnosis, not removal of assertions.

Use Git Bash and `tools/rtk/rtk.sh` for human-readable command output. Execute
children directly when stdout feeds a parser, manifest, checksum or test assertion.
The normal changed-source gate is:

```bash
bash tools/rtk/rtk.sh node tools/test/verify-change.cjs --plan
bash tools/rtk/rtk.sh node tools/test/verify-change.cjs
# For committed continuation changes, select the actual branch range:
bash tools/rtk/rtk.sh node tools/test/verify-change.cjs --range=origin/dev..HEAD
```

Do not run JS drift/generation gates concurrently with native suites. A selected
Windows production change requires the native unit/meta and E2E gates as well
as encoding and the other selected checks. `verify-change` discovers AutoHotkey
at its current built-in install paths; at this checkpoint it does **not** use
`ERGOPTI_AHK_EXE`. An interpreter installed only elsewhere can therefore produce
`SKIPPED`, which is not a native pass. Inspect the current discovery code before
assuming it ran. Native manifests must be complete and belong to that run.

If running a native lane directly, use the actual `/ErrorStdOut` interpreter,
`static/ergopti_plus/windows/tests/run_all.ahk` or `tests/e2e/run_e2e.ahk`, the
runner's expected working directory, and a fresh `ERGOPTI_AHK_RESULTS_FILE` TAP
path. Require exit status zero **and** validate the complete manifest:

```bash
node tools/test/validate-ahk-suite-manifest.cjs --input /path/to/unit.tap
node tools/test/validate-ahk-e2e-manifest.cjs --input /path/to/e2e.tap
```

Do not treat `AutoHotkey /validate` or `/parse` as a safe real-driver smoke:
they can execute the resident driver and its `SingleInstance` behavior.
`npm run test:ahk-parse` uses the repository's actual safe compiler gate. Then
run the isolated real-entry startup gates when selected/required:

```bash
node tools/test/test-ahk-full-startup-smoke.cjs
node tools/test/test-ahk-fresh-clone-startup.cjs
```

Those startup scripts support `ERGOPTI_AHK_EXE`; that is a different contract
from `verify-change` discovery. Unit tests, compiler parsing, real entry startup,
E2E, compiled packaging/installation and physical acceptance prove different
things. Follow the current `.github/workflows/ci-windows.yml` for the additional
isolated native, compiled launch and desktop evidence gates. Do not replace
those gates with an ad hoc launch of a user's live installation.

## Windows item reprise

These are remaining Windows slices, not new implementations of already proven
features. Start with bounded native qualification/fixes on current code; coordinate
shared model changes before undertaking the larger 91/96/97/98 behavior changes.
A named test file below is an existing regression surface; inclusion in a passing
complete native suite must be checked, not inferred from the filename.

| Item | Ordered Windows continuation and acceptance                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 63   | Execute `tests/unit/test_screen_brightness.ahk` against the real owned worker and `tests/fixtures/screen_brightness_provider.ps1`; retain request-ID fencing, late predecessor/suspend cancellation and refusal/readback assertions. Qualify `adapters/screen_brightness.ahk` and `vendor/ergopti_brightness_worker.ps1` with actual WMI providers, including absent providers and native cleanup refusal. The test provider must preserve nested `LASTEXITCODE`; do not shadow policy/status to obtain green. Require readback from each target plus genuine process/Job retirement. Then record physical luminance behavior on supported hardware and an honest unavailable result elsewhere; packaging/install remain separate.                                                                                                                                                                     |
| 71   | Run the Metrics retirement and full-save tests, including `test_metrics_shortcut_persist_guard.ahk`, `test_metrics_shortcut_transaction.ahk`, `test_metrics_shortcut_named_key.ahk` and `test_metrics_preferences_global_barrier_20260813.ahk`. Prove removed dedicated shortcut machinery stays retired while ordinary `open_metrics_typing`/`open_metrics_apps` actions and consent/privacy/widget compensation still work. Keep unknown values and unowned comments byte-preserved through the actual writer; do not weaken whole-image preservation to align an obsolete expectation. Qualify installed startup, upgrade and full save.                                                                                                                                                                                                                                                            |
| 73   | Run the 182-entry combination family/pair catalogue and real 21-locale label tests in `test_key_combinations.ahk`; check actual visible menus and the three hidden script-management pairs on Windows. The historical French Magic disabling has no established cause: the supplied historical config had `french_magickey=false`; absent contemporaneous logs/configs do not prove a writer regression. Ask for the needed private diagnostic evidence through an appropriate channel and reproduce before fixing; never force-enable the preference or invent a cause.                                                                                                                                                                                                                                                                                                                               |
| 91   | Preserve already implemented recommended/clear menus and unrelated/future parameters. With the Group 7 keyboard-hook owner, add meaningful native regressions for symmetric chord delay, tap-to-chord copy versus existing key-down hold, AltGr's synthetic LCtrl ordering, and first-key-alone then second-key joins without unintended activation. Existing `test_altgr_*` and `test_key_combinations.ahk` provide baselines; run complete suites and real keyboard order tests, including both chord orders and current hook epochs. Do not relabel structural tests as physical input evidence.                                                                                                                                                                                                                                                                                                    |
| 96   | First prove actual picker handoff to `ergopti_base`/`ergopti_plus` when `emulated_layout` is empty. Preserve the six historical AltGr descriptors and eight SC012 roll cases in `test_ergopti_keylayout_tables.ahk` and the independent `tests/fixtures/ergopti_plus_altgr_output_matrix.json`. Determine wrapping, word spacing, Shift-percent ligature and whitespace behavior with actual Windows output. A legacy true switch while base/AltGr gates are false affects only three keys; blindly selecting the full plus layout changes unrelated behavior. Migrate through a proved shared contract, with occupied, absent, false and malformed layout/source cases. Never regenerate the independent historical expectations from the replacement implementation.                                                                                                                                 |
| 97   | Design the shared user-owned, empty-by-default physical-key/modifier mapping model with add/edit/remove, shared actions or arbitrary Unicode output; then implement native Windows capture/persistence/emission. Include accented characters, punctuation, circumflex/diaeresis composition and arbitrary layouts. Existing `test_accented_shortcuts.ahk` is a fixed-shortcut baseline, not proof of the requested new feature. Coordinate schemas, manifest, locales, generators and capture hooks with their current owners before edits. Validate cancelled/refused capture and writes as well as accepted mappings.                                                                                                                                                                                                                                                                                |
| 98   | Implement this through item 97's generic physical-key-to-output model, including J, any other physical key, arbitrary output and explicit none. Do not add another fixed J/star switch. Prove no accidental interaction with built-in layout state or current Magic ownership.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| 106  | First qualify the current basic program action implementation, registered private real-script/literal/status/cancellation tests and actual shutdown/reload envelope. Then review/apply the inactive constructor packet only with Group 7 ownership, and execute its 12 native cases and causal controls below. Keep automation discovery (including installed script/launcher/application actions and truthful platform availability) as remaining scope; launching a configured program alone does not complete that scope. Windows currently rejects a new program whenever `_UserProgramEntries.Count != 0`; no native requirement for a global healthy-one-program limit was established. Healthy supervised concurrency parity is deferred: distinguish active owners from cancelled/unsettled debt and same-binding replacement before changing admission. Do not simply remove the count guard. |
| 107  | Qualify actual HKL digit-row detection and native symbols emission through the current layout descriptor; retain the existing historical expected-vector prefix in `test_layout_digit_row_probe.ahk`. Test actual AZERTY/QWERTY, Ergo-L digits, Shift-symbols, dead-key state, AltGr, Caps/Nav category admission and repeats. Run `test_accented_shortcuts.ahk`, `test_keylayout_emulation.ahk` and `test_ergopti_keylayout_tables.ahk`. Read the current schema before modifying migration; this checkpoint's earlier Windows-Boolean migration is not authority to overwrite a newer schema. Forced HKL symbols and Lua forced owners were remaining feature scope; unavailable paths must retain translated reasons.                                                                                                                                                                               |
| 108  | Qualify the current editable default hotstring-editor slot against actual HKL/effective physical Magic key: Mac Ctrl versus Windows Win/Linux policy, direct star/ù, missing key explicit none, personal override, edited chord and explicit none priority. Test ambiguous/dead/modified outputs and source-owned tap conflicts as real refusals. Execute `test_magic_editor.ahk` and `tests/support/magic_editor_native.ahk`, plus real namespace hotkeys across pause/reload/category publication. Preserve current implementation without evidence of a regression; native packaging and installation remain required.                                                                                                                                                                                                                                                                              |
| 109  | Run `test_native_dialog_titles.ahk` with all five actual policy families, strict body/options/results, exact child status/stderr/retirement and the 15-second child process-tree bound. Exercise actual FileSelect filter controls: TXT visible/BIN absent, All Files BIN positive control, restore selected filter and cancellation; retain every independent UIA assertion. Exercise folder HWND/cookie/PIDL/COM cleanup and real dialogs. Variables/KeyHistory identity uses `A_ScriptHwnd`; direct retitling was withdrawn as unsafe for SingleInstance/Reload. Use a separately owned debug window or prove identity preservation through genuine duplicate/reload/retirement before completing that sub-scope.                                                                                                                                                                                   |
| 111  | Run `test_window_utils.ahk` and `test_alt_tab_monitor_catch.ahk`, then use two real displays to distinguish global native AltTab/app switcher from pointer-display window cycling. Move pointer and active window independently; check span, negative coordinates, minimized/closed windows, activation refusal and unavailable display access. Target membership uses window centre on the pointer's display. Do not add a monitor selector or global fallback that changes the requested behavior. Linux virtual RandR fixtures are not Windows physical-display proof.                                                                                                                                                                                                                                                                                                                              |

All test/adapter paths in that table are relative to
`static/ergopti_plus/windows/`; some named meta tests are under `tests/meta/`
rather than `tests/unit/`. Resolve each actual current path with `rg --files`.
Native runner registration, current production filenames and upstream ownership
can evolve; re-read them rather than copying a stale include order.

## Current Windows 106 basic regression

The registered `tests/unit/test_run_program_actions.ahk` has a combined real-child
literal fixture: an actual copy of `A_AhkPath` in a Unicode/spaced executable
path, an independently authored BOM AHK script in a Unicode/spaced path, and
independent UTF-8 byte expectations for empty, NFC/NFD Unicode, quotes, backticks,
`$()`, percent/environment syntax, newline and trailing backslash arguments.
An owned gate holds the real child while the test duplicates the exact Job HANDLE
and opens an exact process observer. Private capture must stay disabled with no
capture file/directory; native stdout/stderr are discarded. Completion must expose
only fixed closed numeric status 37, observe the root signalled and Job active
process count zero, and clear production handles before fixture cleanup.

The registered shutdown helper `tests/support/run_program_shutdown_envelope.ahk`
extracts the actual shutdown/reload functions but uses explicitly declared
surrounding state doubles. It covers pause posture, held-input release, bounded
veto, compensation and updater retry. Its exact native child wrapper requires
strict exit/stderr and physical retirement; extracted-source checks alone do not
prove the live driver. Run the current unit/E2E and actual resident-entry/startup
checks as well. These tests were prepared, not executed here.

## Inactive constructor packet: exact capability, not empty acknowledgement

`inactive/windows106-ctor-handoff/` contains the complete producer preimage,
reviewed candidate, canonical relative-path patch, 12-case native fixture,
original frozen source checker and design/receipt files. `manifest.json` pins
all handoff bytes. `verify_packet.py` is portable and has no container-path
dependency (Python 3.9 or later). Run it from the handoff directory or by its
absolute path. It validates bytes/encoding only; the copied historical
`check_source.py.txt` retains its original `/tmp` and `/workspace` paths and is
archival evidence, not a portable Windows gate. Frozen historical Python and
Markdown source files carry an additional `.txt` suffix so repository formatters
do not rewrite their hash-pinned bytes. The other inactive payload names remain
unchanged. The copied `DESIGN.md.txt` is
also historical: its original pending-review wording is retained byte-for-byte;
this handoff records the subsequent bounded v3 source-review clearance.

```bash
python verify_packet.py
python verify_packet.py --producer /path/to/ergopti/static/ergopti_plus/windows/adapters/shell_runner.ahk
```

The producer preimage is **8f8539df2026523b13a325b81f126f35e78724b4dc6a6463c8416b4fbd6b656f**.
It includes the Group 3 basic Windows106 composition; it is **not** the plain
older `origin/dev` producer at `689d`. Patch receipts are SHA-256 of file bytes,
not Git commit IDs. Review the actual merged `infra/program_actions.ahk`, lifecycle
and registered RPA helpers too; parent source parsing fixes and newer upstream
changes can differ without changing this producer preimage.

| Frozen v3 file                             | SHA-256                                                            |
| ------------------------------------------ | ------------------------------------------------------------------ |
| `candidate-shell_runner.ahk`               | `49ea8b6ca63cf189e8d3e07d5f2dfb01d1698c454b774551bcc446af8b41f98a` |
| `candidate.patch`                          | `6000a0ac5a7a6bd680794090356781fede03aed97b37a433f4b91e9d9021c052` |
| `test_run_program_constructor_failure.ahk` | `4cda45f678cc8f2799e7884c5cf3b3ec7c45b796c637b1870d4c48419e464b4e` |
| `check_source.py.txt` (historical)         | `3474baae61758bdd025db991e75c0f53547a14a1b346b3883b6e302526e5860a` |

The known failure is exact partial HANDLE cleanup, not a proved runaway live
payload: a creator failed after allocation, anonymous native cleanup debt survived
refused `CloseHandle`, but the start catch claimed its unrelated empty State.
Program retirement could then acknowledge that empty claim and delete the entry.
The existing generic `_SRTCR_UnpublishedCloseRecovery` in
`tests/unit/test_shell_runner_tree_close_recovery.ahk` provides a genuine
protected-HANDLE fault. Preserve its existing legacy no-OwnerState assertion.

The candidate prepares one per-call carrier before native allocation. On failure
it moves actual process/thread/Job/PID/Assigned into that exact capsule and zeroes
the producer locals before callback/native cleanup can yield. Start, cancellation,
ProgramActions retirement and retries refer to that same capsule. The carrier
retains authority if binding refuses or throws; `catch Any` contains String as
well as Error faults and never exposes private thrown values. The STARTING
request-before-binding latch preserves a genuine once-only callback. Omitted
carrier legacy callers remain unchanged. There is no new public Spawn API,
global native debt fence or concurrency policy in this packet.

### Import and qualification order

1. Obtain exact Group 7 producer/test-harness ownership coordination first.
   Prior discussion is issue 86, comment 5984429077. Source review clearance
   does not grant exclusive ownership or native qualification.
2. Run the packet validator. Compare the actual current producer with the complete
   `base-shell_runner.ahk`. If bytes differ, preserve all upstream corrections and
   forward-port the small reviewed changes using current/base/candidate; re-review
   the result. **Never overwrite current production with the archived preimage
   or candidate.** A mismatch is a refusal to blindly apply, not permission to
   restore an old version.
3. Only for the exact matching preimage, from the repository root:

   ```bash
   git apply --check -- /path/to/handoff/inactive/windows106-ctor-handoff/candidate.patch
   # After source/ownership review, apply that exact patch without replacing files:
   git apply -- /path/to/handoff/inactive/windows106-ctor-handoff/candidate.patch
   ```

4. Review the 12-case fixture against current helpers. It is **not registered**
   by this inactive packet and is not a standalone runner. Append the reviewed
   definitions/cases to the already registered `test_run_program_actions.ahk`,
   or agree a new native include and suite contract entry with the harness owner.
   The `_RPA_*` helpers and `_SRTOW_*` exact observers must resolve in the actual
   runner. Do not put runner-only references in shared `test_framework.ahk`:
   E2E/child includes can otherwise show hidden load-time warning dialogs.
5. Execute the actual protected-HANDLE baseline control to demonstrate the old
   owner mismatch. Define/execute a bounded public `ProgramActions_Run`
   constructor-fault integration if needed: the inactive fixture currently uses
   explicit surrounding State/handle/acquisition fixtures, so it does not prove
   the entire unmodified public acquisition stack. A meaningful original failure
   must not be obtained by deleting generic assertions or changing expected data.
6. Run the selected native gates and require all 12 new test records plus every
   old assertion. Execute compile/startup, E2E and required packaging/install
   qualification on the final sources. Refused physical cleanup retains exact
   capabilities and the fixture directory; do not turn debt into magic success.

### Twelve source-defined, native-unexecuted cases

| #   | Case                  | Boundary                                                                                                                                            |
| --- | --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `normal`              | Exact protected-root carrier binds normally.                                                                                                        |
| 2   | `before-refuse`       | Adopter returns refusal before binding.                                                                                                             |
| 3   | `before-throw`        | Adopter throws Error before binding.                                                                                                                |
| 4   | `after-refuse`        | Adopter binds then returns refusal.                                                                                                                 |
| 5   | `after-throw`         | Adopter binds then throws Error.                                                                                                                    |
| 6   | `malformed`           | Adopter returns a private String instead of a strict receipt.                                                                                       |
| 7   | `before-string`       | Adopter throws private non-Error String before binding.                                                                                             |
| 8   | `after-string`        | Adopter binds then throws private non-Error String.                                                                                                 |
| 9   | `stream-string`       | Real post-allocation launch-stream close port throws String.                                                                                        |
| 10  | `request-before-bind` | Actual requestTerminate(true) latches before binding, without prior Stop(false); genuine callback completes exactly once after physical retirement. |
| 11  | `start`               | Start creator port throws non-Error before native root allocation; Starting ends with a closed no-root receipt.                                     |
| 12  | `create`              | CreateFn throws non-Error before actual process creation, after acquiring a real Job; that exact Job must retire.                                   |

Each **protected-root** case delegates real process creation, protects the actual
root HANDLE from closure, retains independent root/Job observers and exercises
actual native cleanup and ProgramActions boundaries. The two no-root cases
intentionally do not create a root. Cancellation modes require callback suppression;
request-before-bind requires the actual completion callback exactly once, root
signalled, Job zero and genuine claim quiesced. The fixture's additional independent
`must-not-run106` argv makes the no-output assertion nonvacuous against its actual
child script. Version 3 changes only that fixture marker relative to v2; production
candidate bytes are unchanged. Native causal red, all 12 cases, whole public-run
injection and AHK runtime compilation remain **not run**.

## Unvalidated shared provider drafts

`inactive/program-provider-drafts/` preserves two interrupted drafts from item106.
The `.json.txt` and `.lua.txt` suffixes keep them inactive and byte-identical.
Their production preimages were absent. No adapters, picker integration, labels,
tests, syntax checks or native qualification were completed; do not install them
as a finished feature. They require a reviewed shared discovery contract and
actual native structured enumeration before resuming Windows or other OS work.
The existing script-provider/Apple Shortcuts requirements remain in the TODO.

## Commit, targeted CI and integration

Keep each completed correction coherent, update only its Group 3 TODO block and
push the owned branch immediately. After every push, cancel all automatic
workflows for that exact pushed SHA, including branch and PR events. Do not
cancel manually dispatched native validation. Do not delete partial items merely
because some tests pass; keep physical/package/install and external scope explicit.

For any operation that moves `codex/ci-validation` or performs final integration,
reserve remote `codex/ci-lock` as a **lock only**: a new empty commit from latest
`origin/dev`, message identifying Group 3, owned branch and exact candidate SHA,
then a normal non-force push. An existing lock blocks reservation: inspect its
owner and wait; never take over/delete it. Only the owner releases it after the
final manual CI result. Final integrated validations use only `codex/ci-validation`, which must never
be force-pushed. Preparatory source validations may run concurrently without
the lock on the group-owned `codex/ci-actions` branch through `workflow_dispatch`
on `ci.yml`, with `os_lanes` restricted to affected OSes and release disabled.
The lock serializes final integration and its integrated-SHA qualification only.

While holding that phase, refresh/merge current `origin/dev`, preserve other
owners' changes and regenerate with artifact owners, rerun necessary gates, merge
without squash (`--no-ff`), immediately push `dev`, cancel automatic workflows on
its exact SHA, then qualify the **integrated** SHA via `workflow_dispatch` on
`ci.yml`, using `os_lanes=windows` for truly Windows-only changes. Shared changes
affecting all drivers require all three OS lanes. Verify the current manual path
cannot release, the branch/actual tested SHA match, and allow CI to reach its final
result. Never use `codex/ci-lock` for validation. Delete only the owned feature
branch after all its commits are in `origin/dev` and required validation passed;
otherwise preserve/push the branch and explain the exact blocker.

Report actual integrated commits, removed TODO items, native records/results,
E2E/startup/package/install results and physical limits. The present packet has
**no integrated constructor commit, no removed TODO item and no native pass**.
