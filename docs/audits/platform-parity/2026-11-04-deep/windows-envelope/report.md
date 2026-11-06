# windows deep module audit

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`. Date: 2026-11-04.

This immutable evidence groups separately reviewed modules. Reproductions using real modules and controlled native seams are distinguished from unexecuted native scenarios in each source report. Native desktop certification is not claimed.

| Module             | Findings                            | Evidence, intentional differences and limits                                        |
| ------------------ | ----------------------------------- | ----------------------------------------------------------------------------------- |
| windows-hotstrings | AHK-001                             | [Module report](../windows-hotstrings/report.md) |
| windows-input      | AHK-002, AHK-003                    | [Module report](../windows-input/report.md)      |
| windows-llm        | No new confirmed actionable finding | [Module report](../windows-llm/report.md)        |
| windows-metrics    | AHK-004, AHK-005, AHK-006           | [Module report](../windows-metrics/report.md)    |
| windows-lifecycle  | No new confirmed actionable finding | [Module report](../windows-lifecycle/report.md)  |
| windows-gestures   | AHK-007, AHK-008, AHK-009           | [Module report](../windows-gestures/report.md)   |

## Confirmed actionable findings

### AHK-001 — Reload of a repaired programmable source clears its problem but leaves callback admission disabled

Source ID: `WH-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

Leave programmable sources configured on. Cause a missing/unreadable source or throwing factory, repair the source to publish the clock example, invoke the actual Reload source menu command and wait for metadata loading. Owner.ready becomes true and the problem indicator clears, but owner.enabled remains false; @clock plus the configured magic key never reaches its callback. Toggling off/on restores operation. Production-source state transition confirmed; native execution unavailable. The accompanying recovery-repro.ahk calls the actual Windows policy class, but was not executed in this Linux environment.

**Root cause:**

The menu binds Reload directly to UserHotstringsReload at windows/ui/menu/menu_hotstrings.ahk:1588. RefuseSource sets enabled=false at \_shared/modules/hotstrings/user_code.ahk:180-183. On successful reload the policy sets only entries/source/ready at :172-175, and the production completion at windows/modules/dynamic_hotstrings/user_code.ahk:284-289 clears the problem without restoring the effective desired enabled state. Find returns false for disabled owners at shared user_code.ahk:203-205. In contrast shared Lua user_code_driver.lua:194 restores \_desired_enabled after metadata reload.

**Why existing handling misses it:**

Successful metadata publication removes the source problem indicator and admits a nonzero metadata count, while disabled Find returns without creating a callback ticket or reporting a new output failure.

**Required regression:**

Use the real source loader and actual Reload command: desired enabled -> genuine missing-source or throwing-factory failure -> repair -> menu reload -> wait -> assert owner.enabled and ready, cleared problem, preview and callback admission. Verify desired-off reload stays disabled. Existing native source-admission tests repair using UserHotstringsSetEnabled(true), which bypasses this faulty recovery path. Reconcile enabled with current effective desired configuration, never unconditional true.

### AHK-002 — LAlt Tab tap with explicit None hold still activates navigation

Source ID: `WI-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

SOURCE-ONLY, not executed AHK: choose left_alt tap_action=tab and hold None (serialized hold_modifier="", inherited hold_layer evicted), then hold LAlt and press a nav-bound letter. lalt.ahk special Tab criterion matches without testing hold_layer and calls TapHoldOwnImmediateLayer. Long LAlt emits no Tab. source-checks.cjs asserts exact production source and negative controls.

**Root cause:**

Special LAlt Tab hotkey omits a nonempty hold_layer criterion while unconditionally entering the layer helper; generic tap-only excludes Tab as special, so None cannot fall back to tap-only.

**Why existing handling misses it:**

Picker persists and shows no hold, yet non-native nav layer activates. Default Backspace+nav and shared default/catalogue gates do not exercise this custom combination.

**Required regression:**

On Windows capture/evaluate actual LAlt registration criteria across Tab x None/nav/Ctrl; invoke winner through hold ownership seams and assert None never activates nav. Include custom RCtrl+LAlt path and other special tap/hold combinations.

### AHK-003 — Composer Save-and-use treats pending selection launch as completed active layout

Source ID: `WI-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

SOURCE-ONLY, not executed AHK: with another layout selected, Save-and-use a valid composition; allow selection reload to launch then refuse later terminal handoff. LayoutManager_Select returns true for pending, composer immediately publishes used=true; scoped gateway later rolls config back without a composer terminal callback. source-checks.cjs asserts actual branches and already-selected negative control.

**Root cause:**

Unselected composer use branch consumes bool API LayoutManager_Select that conflates pending/committed receipts, instead of retaining terminal receipt/callback as the already-selected refresh branch does.

**Why existing handling misses it:**

Shared page marks composition active and clears busy before runtime replacement commits; a later refusal leaves old runtime/config but no corrected composer result.

**Required regression:**

Use actual pending selection owner with later refusal/success and synchronous refusal; keep pending=true used=false until terminal completion and publish one final result after rollback/acknowledgement.

### AHK-004 — Movement-only pointer distance is silently excluded from every typing-buffer flush

Source ID: `WM-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

In an isolated Windows store set/supply positive pointer distance with empty keyboard events and zero clicks/scrolls, then invoke real KL_FlushBuffer. It returns true without emitting a row or consuming distance. Quit with no additional input and data.sql lacks movement. App-switch then later typing can attribute retained distance to successor app. Source-confirmed; native AHK procedure not executed.

**Root cause:**

keystats.ahk:667-670 and \_KL_PublishBufferSnapshot at :734-735 define empty using events/clicks/scrolls only, omitting mouse_distance / Snapshot.Distance. Collector keystats_mouse.ahk:637-645 accumulates movement independently. macOS log_manager.lua:572-575 has the same omission; Linux pending.mouse rows persist motion without keyboard events.

**Why existing handling misses it:**

Both flush paths report success although no owner or durable row receives positive distance; shutdown proceeds. Context changes can move retained distance into a later app row.

**Required regression:**

Run real distance-only collector/flush and direct snapshot publisher; assert conservation and correct source app through movement-only flush, app change, pause, rollover and shutdown. Cover both predicates and macOS comparator; native Windows runtime unavailable here.

### AHK-005 — Enabled metrics encryption leaves typed text and per-key events in durable plaintext today.log

Source ID: `WM-002`; severity: **high**; confidence: **high**.

**Reproduction and evidence:**

Enable Encrypt logs on disk and wait for migration. Type a unique synthetic marker in a permitted editor, wait for journal ingest/flush, then inspect the local device today.log and data.sql before rollover. Journal contains literal marker and per-key events while SQL typed payload is encrypted. Repeat during SQL failure or migration to cover retained journals. Source-confirmed; native Windows disk procedure not executed.

**Root cause:**

keystats_ingest.ahk:256-259 journals KL_JsonEncode(e) directly. keystats_journal.ahk:82 and :369 use the same raw generic codec before native durable append. Encryption runs later only in keystats_sql.ahk:68-69. Normal today.log deletion occurs at rollover, and migration rewrites data.sql only. Shared menu comment menu.toml:2002-2006 and en locale label promise encrypting logs on disk; no journal exemption found. macOS rotation.lua:313 shares raw JSON journaling.

**Why existing handling misses it:**

The encryption switch can remain enabled and SQL encryption/migration can succeed while the same protected typed payload persists plainly in today.log. No error warns that this durable copy remains clear.

**Required regression:**

Native enabled-encryption disk scan of raw journals before/after ingest, restart, migration and failure. Assert synthetic text and reconstructible key payload absent from disk while replay conserves aggregates. Include macOS raw journal; clear aggregate columns remain an explicit separate design constraint.

### AHK-006 — Explicit dashboard cache Reset preserves and reuses its durable reader image

Source ID: `WM-003`; severity: **low**; confidence: **high**.

**Reproduction and evidence:**

On a private synthetic metrics store build a valid cache/reader.sqlite, retain unchanged ledgers, alter an aggregate in this private cache without invalidating cache metadata, then invoke actual dashboard Reset. Successor full worker reattaches the same durable image and with no tails returns its prior aggregates. Alternatively instrument real reader image identity to prove explicit reset does not revoke it. Source-confirmed; native worker reproduction not executed.

**Root cause:**

clear_cache at keystats_webview.ahk:700-725 calls KLR_ResetCache and deletes only prefetch JSON. KLR_ResetCache at keystats_reader_db.ahk:139 resets RAM state, not KLR_CachePath (cache/reader.sqlite). Full worker keystats_prefetch.ahk:1016 calls KLR_BuildDatabase, which restores durable cache at :218 and returns unchanged aggregates at :258-266. No force-cold or reset-generation reaches this layer.

**Why existing handling misses it:**

Cachespurged diagnostic and a successful new build can still return the exact stale derived image the explicit purge was intended to clear. No ordinary corruption of valid normal aggregates is claimed.

**Required regression:**

Use a real saved reader image and subsequent worker through actual Reset, assert durable observed image is retired/revoked and aggregates reconstructed, with peer-publication/active-job fencing and unrelated stores preserved. Existing reset-owner test replaces external worker and covers RAM/prefetch only.

### AHK-007 — Onboarding publishes success when Precision Touchpad restart is absent or fails

Source ID: `WG-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

Executed real PowerShell7.4.6/Linux with exact extracted worker bodies and fake registry/PnP cmdlets: onboarding exits0/publishes token0 for no devices, Disable-PnpDevice refusal and Enable-PnpDevice refusal. Same injected scenarios against actual tray restart body exit1/token1. See run-worker-probes.py and worker-output.txt. No Windows PnP or AHK execution.

**Root cause:**

Onboarding worker allows empty device enumeration, overrides Stop with explicit SilentlyContinue for both PnP operations, then unconditionally sets success0. It lacks the standalone restart worker zero-device guard, terminating errors and re-enable finally.

**Why existing handling misses it:**

Wizard reads valid success token and shows successful setup even though cached native mapping was not activated; failed re-enable can leave device unrecovered by that worker.

**Required regression:**

Execute both emitted workers with none/disable failure/enable failure/partial multi-device failures, assert truthful failure token plus re-enable attempts. Pin one shared restart implementation or behavioral equivalence.

### AHK-008 — Existing invalid touchpad backup authorizes destructive registry configuration

Source ID: `WG-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

SOURCE-ONLY AHK scenario, not executed: existing backup file contains garbage (or unreadable/wrong-header/incomplete current inventory), original current registry has custom DWORD values. EnsureBackup returns true by existence; Apply overwrites all34 values. Restore rejects same backup before mutation. Unexecuted fixture case in native-repros.ahk; source-checks.cjs asserts actual paths.

**Root cause:**

TouchpadRegistryEnsureBackup uses FSStrictExists as restoration authority for an existing backup and create-race fallback, without read/parse/current inventory proof. Restore has strict validation but only after original values have been overwritten.

**Why existing handling misses it:**

Apply/onboarding can report configuration success with no readable backup capable of restoring original user values. Failure surfaces only at later Clear/Restore.

**Required regression:**

Use real owner with in-memory seams: malformed/unreadable/wrong-key/version/missing-name existing backups refuse Apply/onboarding with zero writes. Valid existing original snapshot stays immutable; concurrent create must also be validated.

### AHK-009 — Onboarding cross-account UAC writes elevated administrator HKCU instead of original user hive

Source ID: `WG-003`; severity: **medium**; confidence: **medium**.

**Reproduction and evidence:**

SOURCE/PLATFORM conditional scenario, native Windows test not executed: launch onboarding as standard user A, enter different administrator B credentials for RunAs. Resident process backs up A HKCU; elevated worker uses bare HKCU which resolves to B. B hive changes while A gestures stay unchanged. Compare both SID hives; negative controls same-account consent and tray Apply-before-elevate.

**Root cause:**

Entire onboarding registry+PnP worker is elevated with \*RunAs but target remains HKCU and no original-user SID/explicit HKU hive is retained. Backup owner runs before elevation under original account.

**Why existing handling misses it:**

Worker can report success for wrong profile; original user sees unchanged gestures and backup/clear for A cannot undo B profile modifications.

**Required regression:**

Native two-user UAC test verifying original SID hive changes only, backup matches same identity, administrator hive unchanged; preferably write current-user registry in resident process and elevate only PnP restart as tray already does.

## Validation and coverage boundaries

Each linked module report records executed commands, initial dependency failures, successful reruns, unsupported native scenarios, refutations and explicit versus inferred intentional differences. Counts from overlapping batches must not be summed as unique test coverage. Performance is unmeasured unless a report supplies actual timing evidence.

The shared audit workflow validates the AHK and Hammerspoon manifests. Its scope vocabulary does not support Linux; the Linux manifest is validated against the same required field types/enums by the integration check, without claiming official Linux workflow support.
