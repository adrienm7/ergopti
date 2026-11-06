<!-- docs/memory/maintainer-decisions.md -->

# Maintainer decisions

Settled product and engineering choices. Do not raise them again unless the
named constraint changes; a change of mind comes from the maintainer.

## Every commit carries the maintainer's identity (2026-11-06)

Every commit an agent creates, in this checkout or in a cloud session it
starts, is authored AND committed as `Adrien MOYAUX
<49562406+adrienm7@users.noreply.github.com>`, never as Claude or another tool
identity, whatever a harness hook or default asks. Set `git config user.name`
and `user.email` to that identity before the first commit, pass the rule to
every child session, and keep tool attribution out of messages (the strict
convention lint already rejects attribution trailers).

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
`Runtime` by design. Not built yet (TODO MRT-004). The native half must adopt an existing exact Core and
VirtualHIDDevice plist and decide how the first-start `core.json` absence
fence applies to a runtime that already ran; today's provision owners refuse
both, so it is a new authenticated helper role that needs a Swift build and
native macOS qualification. Windows and Linux run no installed privileged
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
macOS and Linux emulate no layout: they draw that submenu's row greyed with
`platform_reason.layout_emulation_is_windows_only`.

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
- **The layout row switches stay Windows-only.** `layout.emulate_*_row` mixes
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
four-finger gestures off. On macOS the three-finger horizontal swipes scale with
the distance (mode "incremental"); Windows gets one shortcut per swipe and
cannot, and the four-finger swipes stay one step per swipe everywhere. Linux
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
