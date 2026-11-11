<!-- docs/memory/maintainer-decisions.md -->

# Maintainer decisions

Settled product and engineering choices. Do not raise them again unless the
named constraint changes; a change of mind comes from the maintainer.

## Linux stages are named per process and reaped at start (2026-11-11)

Decided by the maintainer on 2026-11-11 (CFD-1): the Linux TOML writer
(`_shared/lua/toml_codec/writer.lua`, native writer only) and `storage.json`
stage as `<file>.ergopti-<pid>-<start>.tmp`, `<start>` being the kernel start
tick of `/proc/<pid>/stat` (field 22) so a reused pid is never the owner
(`infra/stage_owner.lua`). A stage a kill or a power cut left therefore never
blocks a later write, and at start the daemon removes, in the folders of
`config.toml` and `storage.json` (`reap_settings`), every stage of this pattern whose owner is
gone (no process, a zombie, another start tick) and older than
`[adapters] stale_temp_age_ms`, as Windows `_TOML_ReapStaleTemps` does. A
file outside the pattern (an older build's `.tmp`, another program's) is
never touched and still refuses the exclusive creation of its own name. The
identity is read at load, before a test or caller can replace `io.open`;
`tests/helpers.lua` `stage_path` gives tests the same name. macOS needs no
change: it stages through stdio `"w"`, which overwrites a leftover `.tmp`.
Other Linux writers that stage `<file>.tmp` themselves (API entries, agent
learning, tap-hold, app categories) are outside the decision and unchanged.
Regressions `cfd1-stage-owner`.

## The Linux application identity is the WM class or app_id (2026-11-11)

Decided by the maintainer on 2026-11-11 (ADD-3): Linux names an application
by its WM class under X11 (the class string of `WM_CLASS`,
`x11_focus.window_class`, also in `clients()`) and by its app_id or class
under Wayland, so one exclusion list matches under both session types.
`/proc/<pid>/comm` is only the fallback (a window without `WM_CLASS`, or the
xdotool route without the native transport); the kernel cuts it to 15 bytes
(`TASK_COMM_LEN` 16 with its NUL), so `gnome-terminal-server` reads
`gnome-terminal-`. Saved lists (`metrics.disabled_apps`,
`llm.trigger.disabled_apps`, `llm.agent_disabled_apps`) are converted once at
boot by `infra/app_identity_migration.lua` through
`_shared/data/linux_app_identities.json` (`aliases` comm to class, `same`
for names that do not change); an unknown entry is kept and logged at INFO,
never dropped, and the `migrations.linux_app_identity` marker in
storage.json is written only after every list is persisted. The conversion
runs outside the shared config migration registry, whose closed op set the
Windows interpreter validates at boot and whose identity (the process name)
does not change (decided by the coordinator on 2026-11-11, to review by the
maintainer). macOS keeps bundle ids unchanged; Windows keeps process names.
Regressions `add3-app-identity`.

## A password manager is a secure field as a whole, from one list (2026-11-11)

Decided by the maintainer on 2026-11-11 (ADD-1): every application of
`_shared/data/secure_apps.json` (1Password, Bitwarden, KeePassXC, KeePass,
LastPass, Dashlane, RoboForm, Authy, the system keychains and authenticators)
is a secure field as a whole on the three drivers, so hotstrings, keymap
output, AI requests, clipboard borrowers and metrics stay inert there. The
file holds one row per application with its `windows` process names (no case),
`macos` display names (exact) and `linux` lowercase fragments of the WM class
or Wayland app_id (substring, so `org.keepassxc.KeePassXC` matches); the rule
is `_shared/lua/secure_apps.lua`. macOS `adapters/secure_field_detector.lua`
`isSecureApp` reads it; Linux reads it once in `infra/secure_apps.lua`, used by
`secure_field_detector.isSecureApp` and the metrics' `_SECURE_APPS` (still
behind the metrics secure filter for recording), and
`keystats.is_context_protected` returns true for a listed application
whatever the metrics filters say: that verdict is what the focus guard
publishes to the detector every text consumer reads. A missing or malformed
list raises (fail closed). `test-secure-apps-single-source.cjs` fails on a
driver-local list and on a Windows `SFD_SECURE_APPS` name missing from the
file. Windows (maintainer): read the file in `secure_field_detector.ahk` and
call `SFD_IsSecureApp` from `SFD_IsSecureField`; see TODO « Windows (the PC
agent's) ». Regressions `add1-secure-app`.

## A borrowed unowned Linux clipboard goes back unowned (2026-11-11)

Decided by the maintainer on 2026-11-11 (ADD-2): when a Linux borrower
(paste, selection read or transform, paste stage) finds a clipboard nobody
owns, it restores it unowned, as macOS clears its pasteboard, instead of
writing an owned empty string that clipboard managers record. The snapshot
carries `unowned = true` and `restore_snapshot` calls the backend's `clear`:
X11 `x11_selection_stamp.disown` (`XSetSelectionOwner(CLIPBOARD, None)`,
checked by reading the owner back), Wayland `wl-copy --clear`; a backend
with no `clear` refuses the borrow. Regressions `clipboard-unowned-empty`.
Windows needs no change: assigning an empty `ClipboardAll` runs
`EmptyClipboard`, which offers no format.

## No Linux keyboard slot runs through a pause (2026-11-11)

Decided by the maintainer on 2026-11-11 (SCD-1): on Linux a keyboard slot
(`[shortcuts.keyboard]`) bound to a `script_*` action is held back while the
driver is paused, in dry-run, or with Shortcuts off, like every other slot, as
Windows (slot hotkeys suspended) and macOS (every slot paused) already do; the
way back is the AltGr script chords and the menu. `keyboard_shortcuts.match`
holds every slot back under `only_script` and `consume` no longer exempts a
script action from the pause epoch or the live admission. What does run
through a pause (script chords, gestures, tap keys in dry-run,
`ScriptActions.allows`) is the shared `paused_actions` list of
`_shared/modules/actions/script_chords.json`, read by
`ScriptActions.runs_while_paused`, not the `script_` prefix:
`script_save_reload` waits, `open_personal_shortcuts` runs. Regressions
`scd1-slot-paused`, `scd1-paused-actions`. Windows needs no change.

## Windows swipes step with the fingers through raw HID reports (2026-11-11)

Decided by the maintainer on 2026-11-11: Windows gets the incremental touchpad
gesture modes and step sizes of macOS and Linux (`gestures.modes`,
`gestures.sensitivities`, the `[gestures.modes]` / `[gestures.sensitivities]`
sections and the shared swipe-slot template), through a raw HID digitizer
reader the driver owns: `RegisterRawInputDevices` for usage page 0x0D, usage
0x05 (`modules/gestures/raw_touchpad.ahk`, natives in
`adapters/raw_input.ahk`), contact X/Y and contact count read with `HidP_*`
from the preparsed descriptor, travel turned into millimetres with the
descriptor's logical-to-physical scale, and the shared step and reversal rule
ported to AutoHotkey and pinned by `_shared/tests/corpus/gestures/incremental_steps.json`.
`platform_reason.gesture_modes_and_steps_need_finger_travel` is retired; the
two- and five-finger, diagonal and axis entries keep
`platform_reason.windows_touchpad_slots_are_three_and_four_fingers`.

- Ownership of a swipe: the Precision Touchpad settings keep sending each
  finished swipe's shortcut (`^#+F2`..`^#+F10`). A raw touch that stepped
  owns its swipe: its shortcut is swallowed whether it arrives before or after
  the last raw frame (within `[gestures] incremental_handoff_ms` of the lift).
  A touch that did not step lets the shortcut fire once; an incremental slot's
  shortcut waits for the touch's end, an x1 slot's fires at once. This is the
  Linux rule (`if not _incremental:finish() then dispatch`) made independent
  of the order Windows delivers the two.
- Only a slot the system routes to Ergopti's shortcut steps: an unmapped slot
  also runs Windows' own gesture. A descriptor without a physical size fires
  incremental slots once, as Linux does for a pad with no resolution.
- Do not write the PrecisionTouchPad registry to silence the shortcut of an
  incremental slot: the handoff owns the double-fire risk, and the registry
  mapping stays the discrete path for x1 slots and for pads the reader cannot
  measure.

## The config migration registry starts at v20, the schema of 1.0.9 (2026-11-11)

Decided by the maintainer on 2026-11-11: the old steps of
`_shared/core/config_schema/migrations.toml` are squashed, which cuts most of
the registry every driver parses at boot and most of the config test time.
`oldest_version` is v20, what 1.0.9 (the latest public release) and every
1.0.10 pre-release wrote; only `v20_to_v21` remains. A file stamped below it,
including the v12 of 1.0.0 to 1.0.6 and the v16 of 1.0.7 and 1.0.8, is refused
cleanly on every driver: never written, the session read-only, one ERROR at
boot and the `config.read_only.older_schema` notice naming 1.0.9 as the bridge
(it still climbs v12 and v16). There is no silent partial upgrade. Do not bring
the squashed steps back; the next squash raises the floor only to the schema
of a public release that climbs every older public schema, and moves the
bridge and the compiled-upgrade pin with it.

## The Windows physical shortcut host is built, delivery refused (2026-11-11)

Decided by the maintainer on 2026-11-11: Windows gets the host and the editor
of the physical shortcuts, as macOS and Linux have them, while delivery stays
refused. The production getter `PhysicalShortcutDeliveryAvailable`
(`windows/ui/physical_shortcuts/host.ahk`, the Windows
`physical_delivery_available`) answers false until the maintainer qualifies
it on real hardware; only the maintainer turns it true.

- Chain: the shared page `_shared/ui/physical_shortcuts/` in a WebView2 host
  (WebView only, no native form), the menu port `PhysicalEditorMenu` and the
  scope `PhysicalShortcutsScope`. While the getter answers false the editor
  stays closed with no scope captured, the refusal is told once and the shared
  row greys with `physical_shortcuts.delivery_unqualified`; the row no longer
  carries a Windows platform restriction.
- Even with the getter true, `PhysicalShortcutsScope.Edit` refuses every
  mapping until a Windows collision owner exists. Key capture is
  `KHCapturePosition` (`adapters/keyboard_hook.ahk`).
- Pinned by `tests/unit/ui/physical_shortcuts/test_physical_shortcut_host.ahk`
  on the real chain. Do not turn the getter true, or drop the collision
  refusal, without the maintainer's hardware qualification (TODO.md).

## A Windows layout registry change is captured at once (2026-11-11)

Decided by the maintainer on 2026-11-11: a change of the Windows keyboard-layout
registry must be seen immediately, not only at the one-second layout poll's
next capture. `modules/keymap/layout_registry_watch.ahk` arms
`RegNotifyChangeKeyValue` (subtree, names and values) on `HKCU\Keyboard Layout`
and `KLS_LAYOUTS_KEY`, one auto-reset event each. AutoHotkey has one thread and
a thread-pool wait would call back on another, so the driver polls the events
with a zero timeout every `[adapters] layout_registry_watch_poll_ms` (100 ms),
arms a signaled key again, then runs `CheckKeyboardLayoutChange` at once. The
entry starts it after the poll's timer and `Ergopti_OnShutdown` stops it; a
second start throws and a refused start closes what it opened. The poll stays
the backstop: do not remove it, and do not lengthen the event poll to the
poll's second. macOS and Linux have no such registry; their own layout owners
are outside this decision.

## The Windows uninstall recycles the exact checked file (2026-11-11)

Decided by the maintainer on 2026-11-11 (finding 3 of
`docs/audits/windows-2026-10-28`): the portable uninstall worker
(`windows/vendor/ergopti_uninstall.ps1`) must recycle the very executable it
checked, not whatever holds its name once the pin is released (Windows cannot
recycle a pinned file). `Invoke-ErgoptiRemoval` reads the volume serial and
file index under the pin, keeps an attribute-only anchor handle open (it blocks
nothing and keeps the file index from being reused), renames the file to an
unguessable `.ergopti-uninstall-<guid>.exe` in the same directory, checks that
name's identity, recycles it, then requires the same identity among the
Recycle Bin's `$R` entries. A replacement before the rename gets its name back
and nothing is recycled; one inside the recycle fails the uninstall with an
error, never a success. Permanent deletion stays out of the contract. Windows
PowerShell 5.1 has no public identity reader and the bundled scripts may not
declare P/Invoke (`tools/ci/windows-exe-av-surface.json`), so the identity is
read through PowerShell's own `GetFileInformationByHandle` wrapper; do not
replace it with `Add-Type`. Linux and macOS remove their installed trees
through their own owners (`uninstall.sh`, `UninstallWorker.swift`); this
pinned-image race is specific to the portable Windows executable.

## The Windows personal editors are WebView only (2026-11-11)

Decided by the maintainer on 2026-11-11: on Windows the personal hotstrings
editor (`OpenPersonalEditor`) and the personal information editor
(`PersonalInformationEditor`) open only the shared WebView pages under
`_shared/ui/`, as macOS does. Their native AutoHotkey Gui fallbacks were
removed. When WebView2 cannot open the page, the editor shows the single
`webview.required` message (install the WebView2 Runtime) and logs the reason
at ERROR through the central logger; it never builds a native form. Do not
bring a native editor back for these two windows. Linux already opens both
through its WebKitGTK webview manager only.

## Metrics rows store UTC and their recorded offset (2026-11-11)

Decided by the maintainer on 2026-11-11 (KMD-1): every raw `events_*` row
stores `ts` in UTC and `utc_offset_min`, the local UTC offset in force when it
was recorded (nullable column, last in each table, `schema.sql` and every
`events.*` catalogue statement); `date` stays the local day. Hour-of-day,
night wakes and a day read from `ts` use ts + offset, the local time the user
lived (`_shared/lua/keystats/local_time.lua`). Rows recorded before the column
have NULL: a Linux row then held UTC and is read with the reading device's
current offset, which the rebuild logs; a macOS or Windows row held local time.
Display follows the viewer's zone: no dashboard shows a raw instant today, so
a future one converts `ts` from UTC.

- Writers: Linux `sqlite_writer` stores the offset of each row's UTC instant
  (`_render_event`); macOS `sqlite_writer` converts today.log's local stamp
  with `local_time.from_local` (the system's choice in a fall-back hour). The
  purge tombstone's `metadata.utc` carries milliseconds and the Linux tombstone
  stamps `ts` in UTC.
- Migration: `_shared/lua/keystats/utc_offset_column.lua` adds the column to an
  older store and drops the purge triggers written before it, run on open
  before `purge_schema.sql` (Linux `_ensure_utc_offset_column`, macOS
  `_initialize_db`). `purge_schema.sql` compares a row with an offset (or an
  older Linux row) in UTC and an older macOS or Windows row with the
  tombstone's local time.
- Readers: Linux `ledger_rebuild.walk_device`, macOS
  `_publish_rebuilt_partitions` (log_manager).
- Windows (maintainer): add the same column on open of an existing cache and
  drop the 16 purge triggers before `KLR_LoadPurgeSchema`
  (`keystats_reader_db.ahk`); until then an existing Windows cache refuses
  every raw INSERT, which now names the column. Pass `ts` in UTC and
  `utc_offset_min` in every `KeystatsQuery("events.*")` of `keystats_sql.ahk`
  and the network, topology, capture, ROI and clipboard writers; the
  tombstone of `keystats_maintenance.ahk` gives `utc` milliseconds and its own
  offset; `keystats_walker_events.ahk` reads ts + offset (an older Linux row
  with the current offset) for `KLW_IsNightWake`, the hour slot and the days
  of `KLW_WalkAppSwitch`, `KLW_WalkWindowSwitch` and `KLW_WalkSystemEvent`.

## A pair swipe decides from 3.0 mm on macOS and Linux (2026-11-11)

Decided by the maintainer on 2026-11-11 (GSD-3): a two-finger swipe, an
incremental one included, decides its direction from 3.0 mm of travel
(diagonal 5.0 mm) on Linux as on macOS; three fingers or more keep 1.5 mm.
The one value is the shared timings registry's `[gestures]`
`swipe_minimum_mm`, `pair_swipe_minimum_mm` and `pair_diagonal_minimum_mm`
(`_shared/modules/timings/constants.toml`), read with `Timings.count` by macOS
`geometry.lua` and the Linux `incremental_tracker.lua`; the finger-count rule
is `gestures.direction.minimums_mm`. `test-gesture-defaults-single-source.cjs`
fails on a gesture source (any driver, Windows included) that declares a swipe
minimum locally. « Still user-adjustable » is read as the slot's own step
(`[gestures.sensitivities]`), which stays the user's: the minimum only gates
the direction (reading decided by the coordinator on 2026-11-11, to review by
the maintainer). Windows receives finished swipes, has no live minimum and no
literal to remove. The Linux decoder's own threshold and pair-scroll travel
(120 device units) are GSD-2, still pending: not moved.

## An unbound diagonal falls back to its dominant straight slot (2026-11-11)

Decided by the maintainer on 2026-11-11, reversing the coordinator's default of
the same day: on macOS and Linux a diagonal swipe (live or completed) whose
own slot is unbound runs the slot of its dominant straight direction
(`gestures.direction.dominant`, a tie is horizontal), and that slot's own
horizontal-axis fallback; a bound diagonal still wins inside the diagonal
band. Linux: `answering_slot` (manager), the decoder's `dominant` field and
the incremental tracker, which counts and fires along the straight direction;
macOS: `resolveSwipeSlot` returns the answering slot and its axis.
Regressions `diagonal-unbound-fallback`. Windows receives finished swipes
classified by the Precision Touchpad and has no diagonal slots.

## Linux awake_ms is keep-awake time (2026-11-11)

Decided by the maintainer on 2026-11-11 (KMD-3): Linux `awake_ms` is the time
of finished keep-awake sessions, as Windows (`KLR_RebuildAggregates`, the
`passive_period` kind `awake` rows) and macOS (`aggregator/events.lua`)
define it. `modules/keep_awake.lua` credits a session from its confirmed
inhibition to its native release through
`system_metrics.record_awake_session`, which adds the day's `awake_ms` and a
`passive_period` row; the sampler no longer credits unlocked uptime to any
field. Old Linux days held sampled uptime: `sqlite_writer.ensure_awake_definition`
clears this device's `agg_system_day.awake_ms` once (a rebuild from raw rows
gives the same 0) and records `meta.linux_awake_ms_definition` and the first
date it holds for, `meta.linux_awake_ms_since`, so the two periods are never
added (clearing rather than keeping the old values: decided by the
coordinator on 2026-11-11, to review by the maintainer).

## Non-typing metrics rows follow the excluded-app rule (2026-11-11)

Decided by the maintainer on 2026-11-11 (KMD-2): rows that do not come from
typing (connectivity, window topology, capture presence) are refused while an
excluded app is focused, on every OS, as Windows' `KL_AppendLog` refuses
every entry; a neutral app label is not used. Linux: `record_network_event`
and `record_topology_event` return on `is_unrecorded_app` (regressions
`linux-network-excluded-app`, `linux-topology-excluded-app`); macOS: the
topology, capture and network watchers take the whole `PrivacyContext`
verdict (`macos-network-private`, `macos-topology-private`).

## A settings change retires the AI request in flight (2026-11-11)

Decided by the maintainer on 2026-11-11 (AID-3): a change of the backend, the
API entry, its provider, model, endpoint or key while a prediction is in
flight retires that request on macOS and Linux, as Windows does; the next
request uses the new settings. The field list and the comparison are shared
(`_shared/lua/llm/request_settings.lua`); each driver snapshots its own
sources at dispatch (Linux `prediction_engine.predict`, macOS
`modules.llm.request_settings()`) and compares at every backend and
streaming callback: the macOS engine routes every request id read through
it, Linux checks it in `request_current` and before admitting a new
request. A retired request is dismissed (its transport cancelled, its answer
never shown). The key is only compared, never logged.

## A token exchange answering 400 is a refused key (2026-11-11)

Decided by the maintainer on 2026-11-11 (AID-2): a token exchange (watsonx
IAM, Vertex OAuth) that answers HTTP 400 is never retried on any OS; the
request fails at once with the service's own message. The rule lives in the
shared classifier (`_shared/lua/llm/failure_class.lua`, phrase « the token
exchange answered http 400 », corpus `auth_failure_vectors.json`) and the
message in `api_token_exchange.read`'s refusal (error_description,
errorMessage, error.message, message, then error; one line, at most
`MAX_SERVICE_MESSAGE_BYTES`; corpus `api_token_exchange_vectors.json`).
Windows mirrors both corpora: `LLM_TokenExchange_Read` must append the same
message and `api_common.ahk`'s phrase list take the same phrase (or its
prediction classifier honour `key_refused`).

## The macOS quick retry spends the attempt budget (2026-11-11)

Decided by the maintainer on 2026-11-11 (AID-1): the quick retry of a failed
prediction variant on macOS (`api_ollama`, `api_mlx_fetch`, `api_remote`
`fetch_sequential`) is one of the `max_attempts` attempts, as on Windows and
Linux (`Inference.max_attempts`). One prediction at multiplier 2 sends at most
two requests, never four. The retry keeps its extra tokens and warmer
temperature; it is simply counted.

## Linux installed trees load a precompiled bytecode package (2026-11-11)

Decided by the maintainer on 2026-11-11, following
`docs/design/linux-bytecode-package.md`: the installer and the updater compile
an installed tree with the target's own luajit into `<root>/.bytecode/` (a
bundle and a manifest naming `jit.version`, the architecture, the GC64 flag,
the physical root and each chunk's source SHA-256). Bytecode is trusted only
in an installed tree, launched through its physical path, and only when the
whole manifest matches the running luajit; a checkout never reads it. On any
mismatch the daemon loads every module from source and logs one warning, and
the next updater run recompiles; no boot mixes the two. The tree is derived:
excluded from the ownership receipt, admitted by name
(`OWNERSHIP_DERIVED_TREE`) and removed whole by uninstall. Do not ship
bytecode built on a CI runner.

## The AI menu lists no model; the model browser page selects (2026-10-27)

Decided by the maintainer on 2026-10-27 and built in e55038c902 on the three
drivers: the tray draws one button, the backend's emoji then the model, which
opens the model browser page; the Backend chooser, the model list, the API
entries, the provider Add rows and the custom-model dialog left the tray. Do
not bring tray model rows back. The menu vectors that described them
(backend, model header, hardware, catalogue, readout and complete-model frames,
and the Windows backend and model-health captions) were retired with no
consumer left on 2026-11-11.

## X11 same-group XKB notify renews the layout receipt (2026-11-11)

Decided by the maintainer on 2026-11-11: after an XKB new-keyboard notify that
keeps the group (Xorg switching the slave keyboard feeding the core
keyboard), the Linux driver re-reads the server keymap and, when it is
identical to the capture's map, renews the layout receipt instead of leaving
`KeyboardLayout.is_ready()` false. A keymap that really differs keeps the
receipt revoked. The renewal mints a fresh receipt through
`xkb_capture.inverse_retarget`; old plans are never revived.

## A restored API entry without its key asks for it again (2026-11-11)

Decided by the maintainer on 2026-11-11: deleting an API entry keeps
deleting its Keychain item (macOS) or secret-service item (Linux), even when
a retained backup still names it. An entry restored from such a backup is
listed, greyed, with `model_browser.hint_api_key_reenter` and an « API key… »
action that stores a new key. macOS tells the absent item apart through the
launcher's `itemNotFound` exit (69); Linux through secret-tool's silent exit 1
confirmed by `search`. A locked or refused read is never taken for an absent
key. Do not keep Keychain items alive for backups.

## Linux API key migration never blocks the daemon (2026-11-11)

Decided by the maintainer on 2026-11-11: the boot-time move of a plaintext API
key to the Linux keyring never blocks the daemon. The daemon starts at once;
`modules/llm/api_key_migration.lua` runs the move in the background, each
secret-service call an owned child with a bounded deadline, and retries until
the keyring is unlocked (a D-Bus read of the default collection's `Locked`
property, which never prompts, gates each attempt; the retry is periodic and
bounded rather than an unlock signal). The plaintext key stays in
`api_keys.json` until the move succeeds; each attempt logs a paired start and
success or warning. Do not move a secret-service call back onto the boot
path or into a synchronous `ui/modal` hand-over there. macOS already keeps
every Keychain call async with a deadline; Windows DPAPI has no prompt.

## Physical shortcut delivery is on (2026-11-11)

Decided by the maintainer on 2026-11-11 (LIN-004): the production getter
`keyboard_shortcuts.physical_delivery_available` answers true on Linux and
macOS (both Lua drivers). Every safety refusal stays: each dispatch and each
editor save still passes the source, collision and output-custody checks
(`physical_match`/`physical_admitted` on Linux, `physical_admission` on macOS,
`shortcuts.physical_availability`), and a getter answering false greys the
editor row with `physical_shortcuts.delivery_unqualified`. Tests pin the true
answer and drive each refusal under an explicit false answer. Windows has its
host since the decision above, its delivery refused. The Mac field report
validates the macOS side.

## A superseded site deployment stays red (2026-11-11)

Decided by the coordinator on 2026-11-11, to review by the maintainer.

- A `main` push whose site deployment is overtaken by a newer push keeps
  failing with "target branch no longer names the admitted source"
  (`tools/ci/site-deploy-admission.cjs`, `SupersededSource`). The red job is
  true: that source was never deployed, and the newer push deploys its own.
- No admitted skip output is added: the closed publication chain of
  `test-ci-pipeline-wiring` forbids conditional jobs and steps, and a quiet
  skip (bc14746520, reverted) would let a real admission failure read green.
  Action: when a deploy fails with that message, check that the newer `main`
  push deployed, then ignore the red one.

## Linux PAC lists and the managed-Ollama data folder (2026-11-10)

- Linux evaluates the PAC itself: GIO (GNOME) keeps only the first entry of
  a PAC answer, so `PROXY a; DIRECT` never fell back when relay `a` was down.
  The driver runs the PAC it already downloads and walks the whole ordered
  list with the shared route timeout, as Windows and macOS do.
- The managed-Ollama installer accepts a group-writable parent folder only
  when the group is the user's own private group (same name and gid as the
  user, no other member), the Ubuntu umask 0002 layout; another shared group
  or a world-writable folder is still refused.

## Tap-hold settings, minimum tap, tap-to-click and Linux proof (2026-11-10)

- One home for the tap-hold settings on every OS: a shared `tap_hold.toml`
  holds the keys, the global and sticky delays, the lone-tap window and the
  modifier combinations (`mod_combos`); `config.toml` keeps the
  `[[features.*]]` rows; the macOS-only Karabiner integration is its own
  section of that file. Each driver migrates its old files once
  (macOS `config_karabiner.toml`, Linux `config.toml` `mod_combos`, Windows
  `config.toml` tap-hold keys), and a cross-driver test writes the file on one
  driver and reads it on the other two.
- The minimum tap duration applies to every tap that waits for its release,
  the Linux rule, on the three drivers; Windows stops limiting it to LShift,
  LCtrl, RShift, CapsLock holding the layer and LAlt with a non-Backspace tap.
- Linux counts tap-to-click: features follow the most complete, most precise
  OS unless that is overkill. The daemon already decodes the touchpad without
  a grab; it counts the touches libinput would turn into a click, under the
  desktop's own tap setting.
- A Linux check the cloud cannot run on real hardware closes on a container
  proof: a headless session (Xvfb/X11, sway, KWin or GNOME headless), a Docker
  distro, a uinput fake or a `libinput record` replay. macOS checks close on
  the GitHub Actions macOS lane or the next field report.

## Layout emulation on the three OS (2026-11-06)

Every feature about the user's keyboard layout is the same on Windows, macOS
and Linux. The emulation is the first part: the user keeps any installed
system layout and Ergopti types the selected layout over it, with the same
options and menu rows as Windows (layers, rows, number-row ordering and edge
keys, dead keys, AltGr, the shortcut chords' Command level, the magic key).
macOS and Linux run one shared engine, `_shared/lua/layouts/keylayout_emulation.lua`,
the twin of `windows/modules/keymap/keylayout/keylayout_emulation.ahk`; the
three replay `_shared/tests/corpus/layouts/keylayout_vectors.json` (the
cross-OS oracle) and the Lua drivers `emulation_vectors.json` for the options.
The built-in Ergopti variants are emulated from their registry `.keylayout`
(`ergopti`, `ergopti_plus`) on macOS and Linux. Mechanisms: macOS rewrites the
keymap tap's key-down (`setUnicodeString`, the magic key's route; a Cmd/Ctrl
chord takes the input source's key code of the Command-level character),
Linux consumes the grabbed press and types in its place (the magic key's
route). Installing or switching the OS layout is a separate feature with its
own owner. The decisions of 2026-11-03 below that say macOS and Linux emulate
no layout, and « the layout row switches stay Windows-only », are superseded.

## Every commit carries the maintainer's identity (2026-11-06)

Every commit an agent creates, in this checkout or in a cloud session it
starts, is authored AND committed as `Adrien MOYAUX
<49562406+adrienm7@users.noreply.github.com>`, never as Claude or another tool
identity, whatever a harness hook or default asks. Set `git config user.name`
and `user.email` to that identity before the first commit, pass the rule to
every child session, and keep tool attribution out of messages (the strict
convention lint already rejects attribution trailers).

## System keyboard layout features are the same on every OS (2026-11-06)

Every feature about the user's system keyboard layout follows macOS on all
three OS. A driver start applies the layout of the live pause state (resume
layout running, pause layout paused; `PauseSwitchPolicy.startup_event` and its
AHK twin, pinned by the `startup` vectors of `pause_switch_vectors.json`), a
pause, a resume and a user quit switch as before, and a pause transition that
already ran since init (a restored pause) keeps its choice over the start.
Layout > « Input sources » (`active_layouts`) is declared for every driver: the
active layout ticked, a pick switching the system (macOS TIS, Windows
`KLS_Select` on the user's installed layouts, Linux GNOME gsettings, the KDE
Plasma keyboard daemon over D-Bus, or setxkbmap; other Wayland compositors show
`menu.layout.active_layouts_unsupported_desktop`). Installing Ergopti into the
system is on every OS: macOS from the `.bundle` rows (`layout_bundle`), Linux
for the user from the layout manager (install.sh on Xorg), and Windows from
Layout > « Download the Ergopti system layout installer » (`layout_system_install`,
`windows/modules/keymap/system_layout_install.ahk`). The Windows installer is
UNSIGNED by decision (2026-11-06), and the row's label says it; since 2026-11-07
(confirmed 2026-11-08, below) the row opens its download instead of running it. Its keyboard DLL is
generated from the registry `.keylayout` (`codegen-windows-keyboard-layout.cjs`,
written from kbd.h, no MSKLC; kalamine may be read for ideas, never copied)
and built in CI
(`docs/tooling/windows-keyboard-layout.md`). Action: a new layout feature lands
on the three drivers or names its blocker in the row's reason; change the
Windows layout through the `.keylayout` and its generator, never the DLL.

## Dead keys: one lifecycle contract, macOS output for the magic key (2026-11-06)

Every OS follows the native macOS dead-key behaviour. A continuation with no
composition types the dead key's terminator, then that key: Windows already
did, Linux gets it from explicit fallback lines both XKB converters write. An
expiry (the legacy Windows two-second wait) or Ergopti's pause cancels the
pending dead key: nothing is typed and nothing composes later; the Windows
registry engine resets its pending state from `Ergopti_OnSuspendEnter`. A
named control that completes a dead key is replayed with the modifiers the
capture recorded (OSW-001, extended to the legacy `DeadKey` path), never
stripped. On macOS and Linux the pending state belongs to the OS or the
receiving application, which Ergopti's pause does not reach; cancelling it
would mean injecting a key, which is not done. The Ergopti+ magic key inside a
dead key types what macOS types (j, ξ, ʲ, ⱼ in the circumflex, Greek,
superscript and subscript states) on Windows and Linux too, pinned by shared
keystroke vectors.

## Open parity questions follow the most complete OS (2026-11-06)

Every Linux or macOS parity question left open in TODO (feature inventory,
end-to-end, one-shot Shift) is settled by one rule: the OS whose existing
implementation is the most complete defines the contract, and the others
follow it. Do not ask again per feature. Where a follower cannot reach the
contract with its native tools, it refuses loudly rather than degrade
silently (Linux clipboard borrowers refuse a clipboard holding formats the
text writers cannot restore, LCP-001), states the reason in the menu and
diagnostics, and keeps the full implementation as a TODO follow-up. An item
that needs real hardware goes under "To confirm on ...".

## An installed release whose restart was refused waits, it never fails (2026-11-06, MUR-001)

When the Versions install has installed a release (Linux) or armed the app swap
(macOS) and the restart is refused, the shared session
(`_shared/lua/updater/release_install.lua`) holds it as `restart_pending`: the
page says it is installed and offers « Redémarrer maintenant »
(`complete_install_restart`), the About check row becomes « Redémarrer pour
terminer l'installation de {tag} », a window opened later is seeded with it,
and a new install is refused meanwhile. It is never reported failed or idle.
macOS bounds the hold by the swap worker's own wait
(`release_installer.SWAP_WAIT_SECONDS`, the `SWAP_WAIT_TICKS` the script
counts) and then reports `install_error_restart_expired`, since the worker
replaced nothing. Windows has no such state: a refused exit makes the updater
cancel its swap worker (`_Updater_FailSwapTransaction`), so its failure is
true and its reason set leaves out the two macOS swap-only reasons.

## A published owned runtime gets « Réparer le service » (2026-11-06, MRT-004)

An already published macOS owned runtime whose service needs recovery
(`runtime_job_not_loaded`, or a first install that ended
`files-published-service-cleanup-pending`) is to get its own localized repair
action, not the install row: `--owned-install-first` refuses an existing
`Runtime` by design. Built 2026-11-11 as the helper role `--owned-repair-service`
(launcher `--request-owned-runtime-repair`): it adopts only an exact owned
Core or VirtualHIDDevice plist and keeps the first-start `core.json` absence
fence unchanged (a present system `core.json` refuses and is never moved),
decided by the coordinator overnight, to review by the maintainer. It ships
with the next runtime build. Windows and Linux run no installed privileged
remap service, so they have no counterpart.

## The layout menu keeps layers and rows apart (2026-11-03)

The Windows Keyboard layout menu read as a duplicate: the Base/Shift and AltGr
emulation rows, then the four `layout.emulate_*_row` switches. Both axes stay,
because they answer different questions (which Ergopti layers the emulation
types, and on which keyboard rows). The layer rows sit under the header
« Couches émulées » (`menu.layout.header_layers`); the row switches moved into
the submenu « Rangées émulées (apprentissage progressif) »
(`menu.layout.emulated_rows`, `layout_emulated_rows_group` in `menu.toml`),
since switching rows on one by one is how a user learns the layout gradually.
macOS and Linux emulate the layout too since 2026-11-06 (see « Layout
emulation on the three OS ») and draw the same rows.

## Windows boot: keyboard before tray, early tray click queued (2026-11-03)

The Windows boot registers the layout, shortcuts, tap-holds, hotstrings and the
prefix watcher first, and builds the configured tray root only then, still
before readiness: the first keystroke never waits for the menu build. A tray
clicked before input is ready is queued and opened once it is, because an open
native menu stops the auto-execute thread and three boots of 3 November waited
24, 26 and 446 s on one. The startup smoke's shell receipt asserts this order.

## Restore holds its stage by handle (2026-11-01)

The audit's "restore staging substitution" is fixed on Windows, after two rejected
designs: a raw copy lost streams and metadata, and a pinned `CopyFileW` still wrote
through a replaced ancestor. `FSCopyReplaceAtomic` resolves one pathname, the anchor
folder. Every folder below opens relative to its parent without delete sharing, the
stage opens relative to its folder sharing nothing, `BackupRead`/`BackupWrite` copy
what `CopyFileW` copied (content, named streams, extended attributes) by handle, and
the rename goes through the stage's handle into the folder handle. No native helper
is needed: ntdll and kernel32 cover it. `test_config_restore_custody.ahk` runs a
separate process against it and, as a control, against the old pipeline.

macOS and Linux have the same hole and cannot close it: POSIX renames by name and
denies a same-user process nothing. The shared `owner.restore` reads each file back
and reports a substituted one as a failure, naming the pre-restore backup. A foreign
file can still reach the destination there, but never as a success.

## N-gram keys are token encoding 2 (2026-11-01)

A key is a run of markers from `_shared/data/keystats_tokens.json`, the escape `[[`
for a typed `[`, and single characters, so `[BS]` no longer reads as both a Backspace
and four typed characters. The long spellings won (`[PAGEUP]`, `[PAGEDOWN]`,
`[DELETE]`); `[PGUP]`, `[PGDN]` and `[DEL]` stay aliases because raw events keep them.
Change the JSON, run `tools/codegen/codegen-keystats-tokens.cjs`, and replay
`token_encoding_vectors.json`.

Stored data moves once, and raw events are never rewritten. Windows (cache format 16)
and macOS (aggregate revision 3) rebuild every key from the raw events, which were
never ambiguous, keeping the old image as `*.pre-ngram-encoding-2.bak`. Linux has no
replay, so `ensure_token_encoding` writes a `VACUUM INTO` backup, then rewrites its keys
and records the version in one transaction. Its keys are read with the family's token
count; a key with two readings of that length takes the earliest marker, so such a
row can be wrong on Linux only.

## The Windows proxy override takes every relay of the grammar (2026-11-01)

https relays, socks5 relays and credentials in the address are accepted on Windows
instead of refused. Each PowerShell channel (managed worker, updater staging,
artifact engine, Ollama archive) hops through a loopback listener in its own
process; the daemon reads the real relay from `HTTPS_PROXY`. The system curl
serves loopback requests only, so no override reaches it. A credential lives in
a DPAPI envelope in config.toml (the whole relay, sealed once at start when found
clear) and in the private environment of a network worker, never in the driver's
own environment, a log, command line, receipt or request file;
`test-windows-proxy-override-e2e.cjs` proves each form. macOS and Linux keep the
relay in clear in their settings store: their route decisions read it synchronously,
the Keychain answers asynchronously through the signed launcher, and secret-tool
hands the keyboard to the desktop. Moving it means caching the secret at start
there, and the macOS prelude still writes the relay into shell text.

## Perplexity speaks the Agent API (2026-11-01)

Perplexity left Sonar chat completions for the Agent API on the three drivers:
format `perplexity_agent`, `POST <base_url>/agent`, base
`https://api.perplexity.ai/v1`, default model `perplexity/sonar`. Its image input
takes a URL, so it serves every text use and no screenshot. `GET /v1/models`
declares no authentication, so the save-time ping proves the address, not the key;
the Test action sends a real request. The shapes come from the docs and were only
run against the fake of `tools/test/lib/fake-network.cjs`: no key existed for a
live call. No retirement date is recorded, none being confirmed by Perplexity.

## DashScope keeps `dashscope-intl`, a workspace domain is optional (2026-11-01)

The default address stays the shared `dashscope-intl.aliyuncs.com`. Alibaba calls
it legacy but available and recommends workspace-dedicated domains, so the
provider's `optional_address` block in `api_providers.json` adds one optional
field to the add-entry form on the three drivers. Empty keeps the catalogue's
address; a value must end with `.maas.aliyuncs.com`. Such a domain takes only a
key of its workspace. `llm/api_url_template` (Lua, AHK port) owns the rule and
`api_url_template_vectors.json` pins it.

## Windows keeps the system curl (2026-11-01)

The Windows driver runs `System32\curl.exe` and does not pin its own copy, the
SYS class of the owned-runtimes registry. `HTTP_CheckCurlAtStart`
(`windows/adapters/http_client.ahk`) names its absence or a version below
`HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION` in words. Do not propose a pinned curl again
unless that check stops being enough.

The dialog belongs to the AI (2026-11-01): `HTTP_ScheduleCurlCheck` runs at boot
when the AI is on and when it gets turned on, and with the AI off nothing opens.

## French sticky modifiers are « rémanents » (2026-10-31)

The French sticky-modifier labels say « rémanent »: `📌 Maj rémanente`,
`📌 Ctrl rémanent`, `📌 Option rémanente`, a chord `📌 Cmd + Maj rémanents`, and
the delay strings say « modificateur rémanent ». Other Latin-script locales keep
their own wording. Since 2026-11-03 each `sg_actions.sticky_<mods>` value is a
template (`📌 {1} rémanents`) whose `{1}` the modifiers fill from the key name
table on the platform that shows it (`_shared/lua/actions/sticky_label.lua`,
Win and Alt on Windows); keep the gender and number agreement in the template.
The French rows of
`_shared/tests/corpus/menus/script_action_original_catalogue_projection.json`
pin the labels.

## Dutch rolls are "Rolbewegingen" (2026-10-31)

Dutch names the rolls category "Rolbewegingen" (`category.rolls`,
`hs_config.cat_rolls`, and the `nl` description of the registry's
`ergopti/hotstrings/rolls.toml`): "Rollen" means "roles". The locale
completeness gate fails if Dutch falls back to the English "Rolls", which is no
longer allowlisted.

## The local servers "none" row is one sentence (2026-10-31)

When a finished sweep found no local AI server, the menu row says
`menu.llm.local_servers.none_detected` (« Aucun serveur local détecté ») and
lists no server; the names stay in the local servers panel and the "other
address" submenu. The row of a running sweep (`searching`) keeps the list. The
shared `_shared/lua/llm/local_server_menu.lua` owns the rule; the Windows twin
follows through the PC handoff.

## config.toml `[script]` wins at start on macOS and Linux, without migration (2026-10-31)

A `config.toml` `[script]` row (`locale`, `log_level`, `show_error_dialog`) wins
over the native store (hs.settings, storage.json) at start, as on Windows:
`_shared/lua/script_config_authority.lua` writes it into the native alias
(`infra/script_scope.lua` `adopt_configured`) before the error window, the log
level and i18n read it, and every menu or wizard change rewrites the row first
when the file holds one (`rewrite_configured`). There is no migration or
adoption marker (sole user, clean state): a file without the row leaves the
native value in force, and nothing is copied between the stores. Only a
shipped locale code is adopted.

## Decisions without code of 2026-10-31

- **Published release notes** that carry agent session lines are rewritten
  once by the coordinator; `build_changelog.py` already strips them from new
  notes.
- **The `WH_KEYBOARD_LL` probe** (`windows/.../input_probe.ahk`) stays in the
  release exe, flagged or not by a corporate proxy.
- **Windows builds the timer-delay ceiling and key-chord policies** that macOS
  and Linux replay (`_shared/tests/corpus/timer/delay_ceiling_vectors.json`,
  `_shared/tests/corpus/tap_hold/key_combination_chords.json`); the work is in
  the PC handoff.
- **`dev` history is kept as it is**: the October 22 commits whose message
  belongs to another change are not rewritten.
- **Item 109 (branded debug GUI) and a real `Comments` field in the exe's
  version resource** go to the PC agent (handoff).
- **L115 is closed**: the provider error envelope guard did not reproduce
  under WSL LuaJIT (6 of 6 runs pass); reopen only on a new failing run.

## Every owned-runtime row is decided (2026-10-31)

The maintainer accepted every row's proposal of the owned-runtimes inventory.
The rows live in `_shared/data/owned_runtimes.json` (decision
PIN/SYS/OPT/DELETE/NA, status done/follow_up); where a proposal named two ways,
the first is decided and the second kept as `alternative`. WebView2 stays the
Evergreen system runtime (2026-10-27). Edit the JSON, then run
`node tools/codegen/codegen-owned-runtimes.cjs`; never hand-edit the generated
tables of `docs/design/owned-runtimes.md`. Do not re-raise per-row choices.

## One shared config template for the three drivers (2026-10-31, PAR-73)

The default `config.toml` of the three drivers is generated once, in
`_shared/_generated/config_template.toml`: a shared key appears once, a
driver-only key or a default the drivers disagree on is written
`platform.<driver>.<key>`, and each driver's table order is
`[platform.<driver>] sections`. The `{windows,macos,linux}/_generated/config_template.toml`
files stay committed as byte-exact projections
(`tools/lib/config-template-projection.cjs`, proved by
`test-config-template-shared.cjs`) because the .deb/.rpm, the macOS .app and
the AHK smoke test ship or seed them. No driver reads a template at run time:
the effective defaults come from the features manifest. Change them only
through `npm run build:manifest`.

## Shared local-server ports are told apart by response fingerprint (2026-10-31)

vLLM shares 8000 with oMLX and TabbyAPI 5000 with text-generation-webui. Each
row of a shared default address declares `fingerprint { model_field, equals }`
in `_shared/modules/llm/local_servers.json`, matched against the `owned_by` of
`GET /v1/models` (`vllm`, `tabbyAPI`, `omlx`, `user`).
`_shared/lua/llm/local_server_fingerprint.lua` and the shared discovery
controller keep one row per answering address: the fingerprinted row, else the
address's default row (first in `server_order`), which is also kept on 401/403.
A generic entry at a shared address belongs to the default row only. A merged
row per port and order-only affinity were rejected; add a new port collision
as a new fingerprinted row.

## A clone run reads the published layout registry unless the clone changed it (2026-10-31)

A source run (developer mode or any run from a checkout) reads the published
layout registry like a release, from its channel's branch with the same cache
and ETag, unless `git status --porcelain --untracked-files=all` lists changes
under the clone's `static/layouts/registry` (index.json and the layout files
count, untracked included); then it shows the clone's folder without HTTP. A
git failure shows the clone's folder and logs an ERROR: the clone is the code
being run, and the published registry would hide a local edit. The decision is
shared (`Catalogue.registry_source` and `registry_changes_args` in
`_shared/lua/layouts/catalogue.lua`); the Windows port is in the PC handoff.

## Decisions moved out of TODO by its 2026-10-31 shrink

- **Every web-view page has a toggle action (2026-10-27).** Ten actions of the
  shared catalogue (`_shared/modules/actions/actions.toml`, group "UI"):
  `open_metrics_typing`, `open_metrics_apps`, `open_hotstrings_editor`,
  `open_paths_editor`, `open_hotstrings_settings`, `open_layout_manager`,
  `open_layer_editor`, `open_model_browser`, `open_changelog`,
  `open_healthcheck`. Closed or hidden: open and focus; covered by another
  window: bring to front, never close; frontmost: close through the page's own
  close. Owners: macOS `ui/window_toggle.lua`, Linux `ui/webview_manager.lua`
  `toggle()`, Windows `GestureToggleOrFocusUI`. Not toggles, on purpose:
  onboarding (a shortcut would abandon a half-finished setup), the download
  window (owned by a running download), the release notes (a pane) and the
  contextual dialogs. A model-browser rework keeps macOS `ui/model_browser`
  `window()`/`close()` and the `set_opener("model_browser", …)` line of
  `menu_llm/models_selector.lua`.
- **Windows app categories follow macOS and Linux with no migration
  (2026-10-30).** The shared TOML writer is the reference, the installed-record
  corpus follows Lua, and `metrics\app_categories.json` is no longer read.
- **Cloud providers not added (2026-10-30)**, reasons in their commits: GitHub
  Models, Lambda, 01.AI, Aleph Alpha, Liquid AI, Writer, Tencent Hunyuan,
  BytePlus ModelArk, Cloudflare AI Gateway.
- **Local servers left out of `local_servers.json`**: AnythingLLM always needs a
  key and takes a workspace slug as the model; Msty documents no port or
  dialect. Foundry Local (Windows) and `mlx_lm.server` (macOS) belong to those
  drivers, not to the shared list.
- **Superseded 2026-11-06 (layout emulation on the three OS):** the layout row
  switches stay Windows-only. `layout.emulate_*_row` mixes
  Ergopti rows with the OS layout, which has no `.keylayout` source on macOS or
  Linux; an Ergopti bundle source types digits on both levels, so its rows stay
  greyed on macOS. The number-row options work everywhere by rebuilding the one
  generated `.keylayout` (`docs/design/layout-option-emulation.md`).
- **Forced number-row output is not owed by a hook (item 107).** macOS and Linux
  apply the number-row ordering and edge keys by rebuilding the layout, so the
  Linux hook's input+XI2+writer join is deliberately unreachable
  (`docs/design/linux-number-row-runtime.md`).

## Earlier decisions (moved from TODO, 2026-10-31)

- **Delta updates (item 22)**: withdrawn by the maintainer; full signed downloads stay below 20 MB.
  Full signed, checksummed downloads keep one install and rollback path, without delta-base
  selection, patch rebuild or extra fallbacks. Reconsider only if release size or measured
  repeated-download cost grows.
- **Report a bug has no review screen**: the report is reviewable on GitHub (October 21).
- **Not defects after native review**: L48, L83 and the release-notes CR handling on Windows; L30,
  L85, L88 and L18 on macOS.
- **Configuration file style (October 20)**: `config.toml` keeps the 5/3 blank-line style everywhere
  (templates and the Windows writer); `windows/_generated/config_template.toml` changes only
  through `npm run build:manifest`; the release list and its ETag persist across restarts.
- **Credentialed redirects** are not followed, by design (L42).
- **Unsigned stable Windows releases** are authorised until SignPath signing is integrated (item
  132).
- **The AHK suite watchdog** is not raised to make a run finish; shard the suite instead.
- **Obsolete configuration scalars** are preserved until explicit cleanup; ordinary saves refuse a
  colliding subtree (ADR-009).
- **Unicode general categories and graphemes** are out of scope for the metrics character classes
  (L137); there is no Lua 5.4 AT-SPI backend, the FFI needs LuaJIT (L67).
- **A stored layout or number-row choice is never rewritten** by a layout change: where it cannot
  apply it stays ticked, greyed and suffixed « — non appliqué », and applies again by itself.
- **Moving the Karabiner lease token out of the rule text** is impossible: Karabiner compares
  variables only to fixed values. Fewer recovery deploys need fewer lease failures first.
- **Do not deduplicate the macOS Swift launcher XCTest classes between E2E and Build.** The managed
  native E2E cells run the SDK, logger and daily-log cohorts on macOS 15 (Apple silicon and Intel);
  Build's full Swift run repeats them on macOS 26 (`macos-latest`). Skipping them in Build saves
  about 42 s of 364 s of test time (measured 2026-10-20, run 39388400901) and nothing on the
  critical path, and drops their only macOS 26 coverage. Job, lot and step names state each cell's
  macOS version, read from `HOSTS` in `tools/ci/macos-stage-roles.cjs`.
- **Windows unit shards are grouped by test category, not by duration.** A new test file with no
  category fails a gate; a minute more of wall time buys a CI whose red job says what broke.
- **Ergopti's own Karabiner follows Ergopti running, not a menu switch (2026-10-31, ADR 011).** While
  Ergopti runs and is not paused it always uses its own Karabiner runtime and closes a running user
  Karabiner-Elements; paused or quit, it stops its runtime and restarts the user's Karabiner only if it
  closed it (a persisted marker, so a crash or forced quit still restores it). No Tap-Hold or other
  feature switch takes part; the default-on consent row « close other Karabiner apps while Ergopti is
  running » stays. The shared-mode merge into the user's `karabiner.json` is retired.
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.

## Defaults and recommended values (2 November 2026)

A manifest row is a feature or a setting. A feature changes the keyboard or the behaviour: its default is neutral (off, none) and its recommended value is the Ergopti setup, so an empty config leaves the keyboard alone. A setting says how a feature works once active (prediction style and count, indentation, delays, the password and address bar filters): its recommended value equals its default. An option missing from the file takes its manifest default, not `false`. "Restore recommended" puts back every recommended value, adjusted settings included: the user wants to revert their trials. Each row declares its `family`; `test-feature-family-rule.cjs` and the generator enforce the rule, exceptions justified in the manifest (`rule_exception`, `restore_exempt_reason`).

## Built-in hotstring sections wait their declared delay (3 November 2026)

A built-in section waits, in order: the user's own delay (the override file, then
on Windows the section's `time_activation_seconds` in config.toml), else the
`time_activation_seconds` its manifest row declares, else its category file's
`[_meta]` delay, else the 0.75 s base. The base is only for sections that
declare nothing (the user's personal files, rows without a delay). Every driver
reads it through `hotstrings.languages.section_default_delay` or its AHK twin
`HotstringsSectionDefaultDelay`. "Restore recommended" keeps writing the
recommended value where the inheritance differs, so today it writes no delay.
A category file's `[_meta]` delay names the delay its declared sections wait,
which the category rows of the delay menus show; a CI check pins the two equal.

## One recommended gesture set, in the macOS direction (3 November 2026)

The recommended gestures are the same on every OS, in the macOS direction where
the content follows the fingers: three fingers left / right = next / previous
tab, up / down = new / close tab; four fingers left / right = next / previous
desktop (`space_next` / `space_prev` on macOS), up / down = next / previous
window of the active app; `tap_3` = `left_click_toggle`, `tap_4` =
`alt_tab_monitor`; on macOS five fingers up / down = `mission_control` /
`app_expose` (the macOS order), so both overviews survive turning the system's
four-finger gestures off. The three-finger horizontal swipes scale with the
distance (mode "incremental"; on Windows through the raw touchpad reader since
2026-11-11, see the first entry), and the four-finger swipes stay one step per
swipe everywhere. Linux
keeps the 2026-10-24 rule for its swipes, which stay "none": the touchpad is
read without a grab, so the desktop acts on the same swipes (a double action);
its five-finger swipe stays "none" too (no Mission Control equivalent). macOS
cannot take the system gestures over, so its Gestures « Infos… » dialog tells
the user to turn the four-finger swipes and Look up off first. The set lives in
the features manifest (`recommended_per_platform`) and
`test-gesture-defaults-single-source.cjs` pins it.

## Never a double action on macOS; menu rows stay short (3 November 2026)

While a three-or-more-finger macOS gesture is on (Spaces, Mission Control, App
Exposé, Look up, the three-finger swipes or drag), the Ergopti slots it covers
are greyed in the Gestures menu with a suffix of about 20 characters
(« — pris par macOS ») and the engine does not fire them; turning the macOS
gesture off brings them back without a reload (`gestures/conflicts.lua`
rechecks the Trackpad and Dock preferences every `system_prefs_recheck_ms`,
off the touch path, and never writes them). Two-finger touches never block a
slot. The long explanation goes in « Infos… », never in a row: every menu row
stays short so the menu does not stretch.

## The Gestures clear restores the Windows touchpad (3 November 2026)

« Tout effacer (comportement du système) » in Gestures, and the global clear
that composes it, also put the Precision Touchpad registry back on Windows: the
values backed up before Ergopti's first gesture configuration, or, without a
backup, the Windows factory defaults declared in
`precision_touchpad_registry.toml`. The separate Configuration row « Restaurer
les gestes du pavé tactile Windows » is gone. The Windows factory defaults stay
the real Windows values; they are not Ergopti's recommended gestures.

## Linux fires the horizontal axis gesture slots (6 November 2026)

`swipe_3_horiz`, `swipe_4_horiz` and `swipe_5_horiz` stay offered on Linux and
now fire (LIN-009 / LG-001): they are not hidden. An axis slot is the binding
of both horizontal directions of its finger count. A straight left or right
swipe whose own direction slot is unbound runs the axis slot's action; a bound
`swipe_N_left` / `swipe_N_right` always wins, so one gesture never runs two
actions. Diagonals, vertical swipes, taps and two fingers have no axis slot.
The decoder's shared direction thresholds apply unchanged, and Linux fires once
per completed gesture (no incremental repeat: modes and sensitivities stay
macOS only). `linux/modules/gestures/manager.lua` (`dispatch_gesture`) owns the
rule and `test_gesture_axis_slots.lua` pins it from evdev frames. The macOS
engine does not read the axis slots yet (it resolves only direction slots);
bringing it onto the same rule is a separate TODO item, not a reason to change
the Linux rule.

## AI predictions run only while the user does nothing (6 November 2026)

A prediction is requested only through the typing pause (the existing debounce)
and shown only if the user stayed idle until the answer arrived. Any activity
cancels the debounce, the request in flight (its late answer, retries and
pacing timer are dropped) and hides the tooltip at once: a non-zero pointer
move, a click, a wheel or touchpad scroll, a trackpad gesture, an application
or window switch, or a key the tooltip does not own. The keys that act on a
shown prediction (accept, select, cycle) and bare modifiers do not count;
zero-distance motion and Ergopti's own synthetic events do not count. No
setting, no minimum-display grace window and no pointer travel threshold (the
Windows 100 px threshold is retired). Activity is not navigation: the AI
context survives a move or a key, while a click keeps its own reset. Owners:
macOS `prediction_engine.revoke_for_activity` (O(1) in the keymap mouse and
keyDown taps) and the keymap utils app/window watchers; Windows
`LLM_Bridge_OnUserActivity` from the pointer watcher, `_OnPrefixKeyDown` and
the AltGr foreground WinEvent hook; Linux `prediction_engine.note_user_activity`
from `on_pointer_event`, `on_consume` and the existing focus poll.

## Date hotstrings are bare on every OS (6 November 2026)

The dynamic date hotstrings are `td★`, `dt★` and `date★`, without an `@`, on
Windows, macOS and Linux. Windows registers them without the AHK `?` flag, so
the shared word-start rule (`HSE_IsWordChar`, as `word_boundary_allows` in the
Lua engine) applies: they never fire inside a larger word. The `@td★` / `@dt★` /
`@date★` spelling is retired; `@` stays the prefix of personal-information
tags only.

## The +33 phone form drops only a leading 0 (6 November 2026)

The international phone hotstring (`+33` followed by the first digits) types
`+33` plus the stored number with a leading national `0` removed, on every OS.
A number that does not start with `0` keeps all its digits; Windows no longer
cuts whatever digit comes first (`_DynHS_InternationalPhone`).

## A refused credential is never retried (6 November 2026)

A failed AI prediction call is not retried when the credential was refused:
HTTP 401/403, a missing key, or a provider "invalid key" message (Gemini
answers 400 "API key not valid"). The request also sends no further variant;
it ends. Every other failure keeps the shared retry policy (extra tokens,
higher temperature). One verdict serves the drivers: `llm/failure_class.lua`
for macOS and Linux, `LLM_ApiCommon_IsAuthenticationFailure` for Windows, both
replaying `_shared/tests/corpus/llm/auth_failure_vectors.json`.

rule and `test_gesture_axis_slots.lua` pins it from evdev frames. macOS applies the same rule
(`resolveSwipeSlot` in `macos/modules/gestures/engine.lua`, on the commit and
live paths; `test_gesture_axis_slots.lua`). Windows has no axis slots: the OS
recognises its gestures. No `swipe_N_vert` slot exists on any OS.

## Crash reports are redacted before persistence on macOS too (2026-11-06)

macOS local crash reports pass the whole encoded document through the logger
redactor before opening the file, and a redactor that cannot answer refuses the
report (no raw fallback), as Linux does. Windows keeps its documented full local
detail.

## An accepted deferred connector honours pause and AI-off (2026-11-06)

Windows runs an accepted agent connector on a fresh timer thread; it is refused
when the script is paused or the AI is off by the time it starts, like ordinary
accepted text. macOS and Linux run the connector on the acceptance itself.

## The Linux WPM widget does not need the tray (2026-11-06)

The floating WPM widget is drawn without --tray, as on Windows and macOS: the
daemon pumps the widget's own GLib context instead of leaving it to the tray's
pump. WPM pointer-hide and colour precedence align on Windows (mouse after the
last keystroke hides unless a preview is up; AI, then hotstring, then
autocorrection); the Lua trackers still owe that change.

## The WPM readout sits in the Windows notification area too (6 November 2026)

Aligned on macOS and Linux: Windows shows the live typing speed as a second
notification-area icon with the number painted on the source colour, shown
while typing (`ui/wpm/wpm_tray_readout.ahk`, `adapters/notify_icon.ahk`). The
`metrics_menu.wpm_menubar` / `menubar_colors` rows and the two
`metrics.wpm_menubar_*` keys are declared on `ahk`;
`platform_reason.wpm_readout_needs_a_menubar` is retired. Windows alone decides
whether a new icon starts in the overflow; the user pins it.

## Output types instead of pasting over a borrowed clipboard (6 November 2026)

When another family borrows the clipboard (a selection read, a plain paste, an
Apps or Search capture), macOS TextSender and keymap output do not snapshot it:
they type the text as keystrokes, as Windows' `SendInstant` does when the
shared clipboard owner is busy. Output is neither dropped nor delayed
(`infra/clipboard_borrowers.lua`, MCP-002).

## The one-shot Shift timeout is a user setting on every OS (6 November 2026)

Aligned on macOS: `sticky_timeout_ms` (2000 ms registry default) is editable on
Windows (`config.toml` `[tap_holds]`, `_TH_CommitOneShotTimeoutMs`) and Linux
(`tap_hold.toml` `[tap_hold]`, `set_one_shot_timeout_ms`), each with a tray row;
only a positive whole number of milliseconds is admitted, no zero or unlimited.

## CapsWord setting changes reach the running session (6 November 2026)

Aligned on macOS: a delimiter, pointer or idle-delay change acknowledged by the
CapsWord menu applies to the session already running from its next event; a
new delay counts from the last keystroke and 0 stops the idle check. A hand
edit of `config.toml` still waits for the next activation. Linux owner:
`modules/shortcuts/manager.caps_word_policy_published`, called by
`caps_word_auto_off` after each acknowledged write.

## The CapsWord star delimiter is the literal ★ (6 November 2026)

Aligned on the policy every OS already applies (Windows documents it): the
CapsWord ★ delimiter is the built-in literal ★, not the renamed magic key, and
its menu caption says ★ on Windows, macOS and Linux.

## CapsWord variants follow one contract (6 November 2026)

The catalogue action toggles on every OS (macOS used to re-request ACTIVE).
Escape, Delete, the arrows, Home/End, Page Up/Down and F1-F12 always end
CapsWord, as macOS's fixed Karabiner exits do: one list,
`FIXED_EXIT_KEYS` in `_shared/lua/caps_word/auto_off.lua`, pinned by
`test-capsword-fixed-exits-single-source.cjs`. A modifier pressed alone is no
keystroke for the idle delay (macOS and Linux; Windows follows).

## The magic-key repeat has the magic key's activation window (6 November 2026)

Aligned on macOS: the repeat fallback fires only within the magic key
category's delay (`magickey`, 0 = always) measured from the repeated letter,
complex-key widening included, on every OS. Linux gates it in Main's
character callback (`RepeatKey.WINDOW_CATEGORY`), Windows through the
dispatcher's time gate (`HSE_RepeatWindowSeconds`). An expired registered
candidate must not mask the repeat (macOS and Linux); Windows still lets it.

## One-shot Shift is a generic action on every OS (6 November 2026)

Aligned on Windows (`one_shot_shift`) and macOS (`sticky_shift`): the one-shot
Shift is a catalogue action any origin can run (gesture, keyboard slot, tap),
with the shared results, magic-key and title rules; system StickyKeys is not
its equivalent. Key-combination chords keep refusing it on every OS. Linux
still offers it on tap-holds and tap keys only (`platform_reason.action_sticky_keys_are_the_systems`)
until a non-keyboard origin can arm the engine.

## An immediate Backspace restores the trigger on every OS (6 November 2026)

Aligned on Linux: a Backspace pressed right after a literal expansion erases
it and types the trigger back, outside the matcher. Anything else first
(another key, a click, a focus change) voids it, and Ctrl/Cmd/Option+Backspace
stay the application's. Owners: Linux `_undoable` in `ergopti_hotstrings.lua`,
macOS `Expander.undo_on_backspace`; Windows is still to build.

## The metrics dashboard reads the live store and offers reset, export, purge (6 November 2026)

The metrics dashboards (typing and applications) are not read-only windows: they
read the live data correctly while a write may be in progress, and they offer
explicit user actions. The same behaviour holds on Windows (AHK v2), macOS
(Hammerspoon Lua) and Linux (LuaJIT).

**Stores and journal.** Linux and macOS keep `db.sqlite` (`_shared/data/db/schema.sql`
and the writers: `PRAGMA journal_mode = DELETE`, `synchronous = FULL`). It is a
rollback-journal store; no driver uses a WAL, and none may switch to one without
a new decision. The "hot journal" is `db.sqlite-journal`, left by a write
interrupted before its COMMIT. Windows has no database the dashboard opens: the
single writer appends to the per-device `data.sql` ledger, and the reader replays
it into a private image (`keystats_reader_db.ahk`). Its hot journal is the
ledger's trailing open transaction or a NUL hole from an interrupted append.

**Reading rules.**

1. One writer owns each store (the keystats flush); the dashboard never writes
   to it, never deletes or rolls back a journal, never opens it with create flags.
2. Linux: `sqlite3 -readonly` with `.timeout`; macOS: `OPEN_READONLY` with
   `PRAGMA busy_timeout`. The wait is `keystats.sqlite_read_busy_timeout_ms`
   (500, below the 1000 ms deadline of one SQLite child) and covers only the
   writer's COMMIT lock. Without it a read during a flush was refused at once.
3. A hot journal is never waited for: a read-only connection cannot recover it
   (SQLite answers "attempt to write a readonly database"); the next writer open
   recovers it. The read is refused, the refusal is logged with its cause, and the
   dashboard keeps its last good projection. A failed pass never publishes a
   partial one.
4. Windows: a ledger ending inside an open transaction or a NUL hole keeps the
   last-good projection and logs the error; the reader's image is private.

**User actions.** Reset (end the typing session, nothing stored is deleted: the
existing `metrics_reset_session`), export (a copy of the stored data) and purge
(delete the stored data) all go through the single owning writer, never through a
second process opening the store, and each asks for confirmation naming what is
deleted. Reset exists on all three drivers. Export and purge are decided but not
built: they follow once the writer-side protocol (flush settled, then act, then
receipt) is written for each driver (see TODO).

Pinned by `test_keystats_sqlite_read_concurrency.lua` (Linux, real `sqlite3`: held
lock, hot journal) and `test_sqlite_reader_busy_wait.lua` (macOS).

## Metrics purge applies to every device (2026-11-06)

The dashboard's « Purger » removes the data on every device. The owning writer appends a dated tombstone row to its
append-only ledger, and each device applies it while replaying, so a sibling device never re-imports purged rows.

## One layout editor for every layer (2026-11-06)

The layout generator's editor unifies the navigation layer editor (`_shared/ui/layer_editor`), the layout composer
(`_shared/ui/layout_composer`) and the layout manager window into one shared model and page. No second layout
editor is written; the navigation layer becomes one layer of the Ergopti TOML source.

## A dead, unpublished Ollama daemon never blocks the pause (2026-11-06)

When the owned Ollama serve process has exited and never published its port (no READY
frame), the pause treats it as stopped and proceeds, logging why through the central
logger. A process exit without the RETIRED frame still never retires a _published_
daemon: only the unpublished, physically exited case is released. The rule lives in the
shared lifecycle (`managed_ollama_daemon_receipt.release_unpublished`, called by
`managed_ollama_daemon_lifecycle` `terminate`), so every driver using it behaves the same.

Pinned by `test_managed_ollama_daemon_protocol.lua` (`daemon-dead-unpublished-release`).

## A lossy hotstring overrides rewrite is refused (2026-11-07)

The safety check that refuses to rewrite a hotstring overrides file holding
content no override owns (a root key, an unknown table or leaf, a foreign table
array) wins over every migration that would rewrite it. On Windows the boot step
`HotstringsOverridesBoot` therefore refuses to rewrite legacy absolute delays as
offsets when `_HotstringsOverrideSourceIsRepresentable` refuses the source: it
returns false, logs « Cannot rewrite overrides without losing source data » and
that the rewrite is retried at the next start, leaves every byte of the file
unchanged, and the session runs on the adopted delays. A migration never drops
user bytes to finish; the user's cleanup or edit does. Action: a test of a
migration whose source holds unrelated content expects this explicit refusal,
not a settled rewrite. Pinned by `test_common_autocorrection_migration.ahk`
(`common-autocorrection-split`, native initialization).

## The Windows keyboard DLL folders are genuinely per-driver (2026-11-07, confirmed 2026-11-08)

Proposed by the coordinator on 2026-11-07, confirmed by the maintainer on 2026-11-08.
`windows/native/keyboard_layout` (the keyboard DLL sources generated from the
.keylayout) and `windows/vendor/keyboard_layout` (its elevated installer) exist
on Windows only: macOS and Linux install the .keylayout and XKB files
themselves and build no DLL. `test-driver-tree-parity.cjs` records them by
raising `BASELINE_UNION` 63 → 65 with a dated note. Action: no counterpart
folder is created on macOS or Linux, and these files are not moved into another
folder to dodge the count.

## The Windows layout installer ships outside the exe (2026-11-07, confirmed 2026-11-08)

Proposed by the coordinator on 2026-11-07, confirmed by the maintainer on 2026-11-08.
The elevated keyboard layout installer and its P/Invoke
(`windows/vendor/keyboard_layout/*.ps1`) and the keyboard DLL builds never ship
in `ErgoptiPlus.exe`: the exclude group `system-layout-installer` of
`tools/build/windows_bundle_manifest.json` keeps them out, and no antivirus
ceiling of `tools/ci/windows-exe-av-surface.json` is raised for them. They ship
only as `Ergopti_windows_layout.zip` (`release_asset` of
`_shared/modules/layouts/windows_system_layout.json`), an asset of every release
(`ci-release.yml` preflight and notes, pinned by
`test-release-notes-assets-are-uploaded.cjs`). Layout > « Download the Ergopti
system layout installer » (`layout_system_install`) says whether the layout is
installed and opens that asset of the running release; the driver never starts
an elevated process for it. Action: install or update the layout through the
release asset; do not move the scripts back into the bundle or raise a ceiling
to do so.

## Dev prereleases are named after the next patch (2026-11-08)

A dev prerelease is `vX.Y.Z-dev.N`: `X.Y.Z` is the patch after the last stable
tag, whatever the subjects since it, and `N` is one counter across the whole
series, never restarted by a stable release. The patch, not the bump `main`
would compute, because semver must order every dev tag after the previous one:
a predicted major or minor core could not come back down when `main` releases a
lower version (`Release-As`), and the updaters would keep offering the older
build. The `v0.0.0-dev.N` tags before 2026-11-08 are the same series; the dev
channel of `_shared/modules/updater/channels.json` matches any core since
`v0.0.0-dev.169`, the bridge release that installed builds, which only know the
old rule, still pick up; `ci.yml` keeps the `0.0.0` core for every counter up to 169, so a failed bridge run is
published by the next request under the same legacy name. Action: never delete `v0.0.0-dev.169`; compute the dev
tag in `ci.yml` (pinned by `test-ci-release-reruns.cjs`), and read the series
with the general `-dev.N` pattern everywhere a dev tag is listed.

## A push to dev publishes a prerelease only on request (2026-11-08)

Every push to `dev` runs every lane, but `ci.yml` publishes a dev prerelease
only when a commit since the last dev tag carries a line of its own
`Dev-Prerelease: yes` (`git commit --allow-empty -m 'chore(release): request a
dev prerelease' --trailer 'Dev-Prerelease: yes'`); the maintainer did not want
one release per commit. The publication path stays push-only (the persisted
plan, the qualification policies and the changelog all bind to `push`), so the
request is a trailer, not a `workflow_dispatch` input. Any other value fails
the plan; `main` ignores the line. The request carries until a dev tag exists,
so a red or cancelled requested run is published by the next push. Action: ask
for a prerelease before the complete field report, which installs one
(`collect-macos-field-report.sh --installed`); keep the opt-in pinned by
`test-ci-release-reruns.cjs`.

## The field report tests the branch; --installed adds Karabiner (2026-11-08)

By default `collect-macos-field-report.sh` runs on the developer app of the
clone, so any tester checks the branch with no release and no certificate. The
owned Karabiner runtime installs only under the stable CI certificate (its root
daemon serves raw keystrokes only to that signed app), so the steps
`field_run.json` marks `signed_app` are left out of that run. `--installed`
runs every step, those included, on the newest signed dev prerelease. Action:
keep the root daemon's signature check; mark any new step that needs the owned
runtime installed `signed_app`, never weaken the check for test runs.
