<!-- docs/memory/shared-architecture.md -->

# Shared architecture memory

## Ownership and vocabulary

### project-shared-tree-layout

`_shared/` is a source of truth per layer, not a dumping ground. Drivers may own
adapters and runtime orchestration while consuming shared schemas, constants,
and generated data. Bypassing the shared source creates silent drift.

### project-a-second-vocabulary-fails-silently

Use the same field names at every boundary. Translating a concept into a second
vocabulary often yields `nil` plus a plausible default rather than an exception.

### project-fixed-field-lists-drop-flags

When a record schema grows, fixed allowlists silently discard new fields. Prefer
schema-owned projection or update every serializer, bridge, and test together.

### feedback-loader-target-explicit

AHK loaders and writers that populate a shared `Map` take that map explicitly.
They must not reach through a global with the same conceptual name.

### project-a-path-resolver-must-know-every-layout-that-ships

Path resolution is a product contract. Test packaged, source-tree, installed,
and test-harness layouts rather than assuming one directory depth.

### project-a-depth-cap-is-right-for-a-provider-and-wrong-for-a-filesystem

Depth limits belong to bounded provider APIs, not generic filesystem discovery.
Use explicit roots or cycle-safe traversal for real directory trees.

## Cross-driver UI and data

### feedback-complex-settings-use-a-shared-webview

Reserve native prompts for very simple decisions. Configuration reviews and
long settings lists use one shared WebView on Windows, macOS and Linux, with
bounded window geometry, a scrollable list and a permanently visible action
footer. The obsolete-settings cleanup is the reference: preview every entry,
keep confirmation explicit, and preserve the backup-first transaction.

### feedback-ui-must-be-i18n

All user-facing text uses the locale system in every supported language. English
is the canonical key set; developer logs remain English.

### project-a-page-that-builds-labels-from-data-waits-for-i18n

`_shared/ui/i18n.js` fills `data-i18n` attributes and stores the active locale
in `window._i18n_strings`, but a page that builds its text from data (the layer
editor's keys, actions and picker) has nothing to read until the locale fetch
lands. Draw again on the `i18n:applied` DOM event i18n.js fires after every
apply; a page drawn once at `init()` keeps raw keys on screen.

### project-layer-editor-legends-are-the-hosts

The layer editor never spells a key's character itself: a registry key sent
by scan code (`ahk_send: null`, the generated data's `character`) shows the
legend its host read from the layout the user types with, and its registry
code when the host had none. Windows reads the layout emulation first (digit
row, registry layout, Ergopti base from its `.keylayout`), then ToUnicodeEx
with flag 0x4 on `KS_ResolveKeyboardLayout`; macOS `hs.keycodes.map` in the
ISO form of `platform/remap/nav_layer.lua`; Linux the daemon's loaded keymap
(`keyboard_layout.base_symbol`). Only Windows emulates a layout. The shared
Lua reads `ahk_send` as `type ~= "string"` because json.lua decodes a null to
a sentinel table. Action: change the contract with
`_shared/tests/corpus/layer_editor/legends.json` and
`test-layer-editor-legends.cjs`, which also pins the Windows tap-hold id to
registry code table the layer-key mark needs.

### project-inline-webviews-cannot-fetch-their-locale

macOS loads every shared page inline (`wv:html`, about:blank origin) and
WKWebView refuses its `file://` locale fetch; WebKitGTK refuses it too unless
`allow-file-access-from-file-urls`, which the Linux driver never sets. Only
Windows' virtual host serves the fetch. The page's strings therefore come from
the host: the macOS and Linux builders seed `window._i18n_strings` (the
`catalogue()` of the locale core: active over en over fr) in the boot script.
The store in i18n.js only merges; a replacing `apply()` let the always-failing
fetch wipe the host's strings and the diagnostics page showed raw keys.

### project-shared-ui-logic-is-a-classic-script

`package.json` declares `"type": "module"`, so Node loads any `.js` under
`_shared/ui/` as an ES module and a `module.exports` branch never runs. Page
logic that Node tests need (the layer editor's `layer_model.js`) is a classic
script defining one top-level `var`; the tests run the page's scripts in one
`vm` context, as the browser does, and read that global from it.

### project-locale-placeholder-parity-is-not-a-defect

Locale values may reorder placeholders. Validate placeholder sets and types, not
byte-identical order, unless the formatter itself requires order.

### project-one-menu-two-shared-descriptions

Shared menu metadata has one canonical description per action. Drivers own
rendering but must not fork labels or help text.

### project-a-caller-owned-menu-is-still-the-renderers-to-fill

Owning a native menu object does not transfer content ownership. The shared
manifest remains authoritative for ordering and entries.

### project-action-catalogue-is-generated

No driver parses `_shared/modules/actions/actions.toml`: run
`npm run codegen:action-catalogue` after editing it, and each driver loads its
platform-filtered `_generated/action_catalogue.*`. Each driver suite compares
that catalogue with its runnable registry in both directions
(`(action-catalogue-parity)`). On Linux the runnable set is exactly the
executor's tables, so a new Linux action is a row in one of them, never an
`elseif` the parity test cannot see. Actions another module owns (script
control, the shortcuts manager's text actions) are injected at init through
`modules/shortcuts/action_handlers.lua`; the parity test builds the same table.

### project-action-confirm-is-a-dispatcher-gate

A catalogue action with `confirm = true` is asked for by each driver's single
dispatch choke point, never by the action: macOS `execute_single` (non-blocking
`modules/gestures/action_confirm.lua`), Windows `GestureInvokeAction` (deferred
MsgBox), Linux a zenity/kdialog question chained in front of the command of
`modules/gestures/system_actions.lua`. Linux therefore refuses to load a confirm
action that is not one of those commands. Action: declare `confirm` in the
catalogue and add the confirm-gate test case; do not add a second prompt inside
the handler. The question's own window takes the focus, so an action that
acts on the active window must not read it after the answer: macOS reads the
frontmost application before its alert (from NSWorkspace: the accessibility API
cannot read a hung or windowless application) and hands it to the action,
Windows gives the window it was asked from its focus back and, when it cannot,
refuses only an action that reads the active window
(`GESTURE_ACTIONS_ON_ACTIVE_WINDOW`), Linux reads it (`TARGETS`) before the
question. Windows
native calls of system actions go through
`adapters/system_control.ahk`: the modules/infra/platform OS-call ratchet has
almost no headroom left.

### project-text-case-is-one-rule

Selection case conversion follows one rule, pinned by
`_shared/tests/corpus/text_case/vectors.json`, which the three suites replay.
macOS and Linux call `_shared/lua/unicode_case` over a generated Unicode table
(`npm run codegen:unicode-case` refuses any Node but the `.node-version` pin);
Windows calls `infra/text_case.ahk` over StrUpper/StrLower, so ß, the final
sigma and title digraphs are Lua-only vectors. Never case user text with Lua
`string.upper`/`string.lower` (bytes only) or AHK `Format("{:T}")` (a capital
after a digit, none after a hyphen).

### project-api-entry-names-are-computed

Maintainer rule (2026-09-30): the user never names a remote API entry. Every
tray names it `<provider>/<model>`, with the model and base URL its requests
use, adding the host and then the order when two entries share that name:
`_shared/lua/llm/api_entry_names.lua` (macOS `api_panel`, Linux
`llm_backend_rows`) and its Windows port `_LLM_ApiEntryNames` in
`menu_api_entries.ahk`, all replaying
`_shared/tests/corpus/llm/api_entry_names_vectors.json`. The stored name field
(Windows `Name` and Linux `label`, which older builds still require, and the
optional macOS `label`) is written with the automatic name or left as stored,
and never read. Action: a new place that shows an entry names it through the
driver's naming function over the whole entry list, never from a stored field.

### project-a-toggle-is-opt-in-per-driver

A shared setting is not automatically supported by every driver. Add explicit
capability wiring and parity tests rather than inferring support from schema
presence.

### project-a-row-that-opens-a-submenu-is-never-clicked

No tray fires the action of a row that opens a submenu: AppKit never sends it,
appindicator binds `fn` only on leaves, and Win32 sends no command. A category
switch is therefore the manifest `toggle` row, the first row of its submenu,
and every driver that shows it registers its command. Both renderers report a
missing toggle command and a provider row carrying `action` plus a subtree as
errors; `test-menu-toggle-registered.cjs` pins the registrations.

### project-a-setting-with-values-is-one-choice-row

An enum feature shown in the tray is ONE manifest `choice` row (`path` = the
feature, `i18n` = the row label), not one row per value. `build-menu-manifest.js`
projects the feature's `enum_values` into the row's `choices` with label keys
`<i18n>.<value>` and refuses a path that is not an enum feature or a platform
the feature lacks. Both renderers draw it; the driver registers
`commands[<row id>]`, called with the chosen value, and a state getter under
the feature path. The macOS menubar icon (`ui.menubar_icon`) is the first one;
the update channel and frequency rows have the same shape.

### project-script-chords-are-active-by-default

An empty configuration alters no input: every input-altering manifest entry
defaults to off. The one exception is the script-management chords. The
maintainer decided on 2026-09-30 that they are no typing feature, since they
pause, reload, quit and edit the driver. Such an entry carries
`active_by_default = true` and a default equal to its recommended value. The
builder refuses any other shape, and `test-defaults-single-source.cjs` pins
the approved list. A config.toml that names "none" keeps a chord off, and a
missing key takes the preset. The wizard lists only entries whose preset
differs from their default, so the chords left its Shortcuts page. Action:
never extend the list without a maintainer decision. A clear that must give
the system's behaviour writes the off value explicitly, because deleting the
key restores the preset: such an entry declares it as `cleared`, and the scope
builders (`config_defaults.scope_operations`, `ManifestScopeOperations`) write
it in every clear, the Shortcuts and global ones included. On Windows the
submenu's switch
(`shortcuts.script_control.chords_enabled`) only narrows what the slots
enable, so it is a parameter that starts on, like the key-combinations switch.

### project-restore-and-clear-read-two-shared-keys

Every row that puts a section back to Ergopti's preset reads
`common.restore_recommended`, and every row that removes a section's settings
so the OS behaves as without Ergopti reads `common.clear_to_system`, whatever
the menu. A new reset or clear row takes one of the two keys, never a per-menu
label; `test-menu-reset-terminology.cjs` holds the manifest rows, the rows
drivers build by hand and the retired keys. Neither asks: each owner backs up
first, and the maintainer retired the restore question, then the clear one
(2026-09-30, per menu and global). The macOS scoped owners and global scope
refuse a `confirm` port; `test-restore-recommended-no-confirm.cjs` rejects a
question in a function given a scope mode or naming either label.

### project-a-settings-menu-opens-with-switch-restore-clear

Every manifest menu that shows a scope row opens with its `toggle` (when it
has one), `scope_restore`, `scope_clear`, then `---`, and shows no scope row
after that separator (the maintainer's rule of 2026-09-30); Configuration
opens with the global pair. The ids are the same in every menu, so each
driver registers `scope_restore`/`scope_clear` on that menu's scope owner.
`test-menu-first-group.cjs` checks each platform's projection; its declared
exceptions are restore-only menus (AI, Metrics: the maintainer said clearing
them means nothing, while the global clear still composes their owners).
Action: add a scope row to the first group of the manifest menu, never below
it and never natively. Every other row belongs in the manifest too (the
maintainer's rule): `test-native-menu-rows.cjs` ratchets the rows drivers still
build themselves against `native-menu-rows-baseline.json`, which lists each
site as file:line; lower it with `--update-baseline` as rows move.

### project-a-row-a-platform-lacks-is-hidden-or-greyed

A manifest row restricted by `platforms` declares how the other platforms lack
it (the maintainer's two cases, 2026-09-30): `unavailable = "hide"` when it is
not applicable there (never drawn, no `reason_key`), `unavailable = "grey"`
when it is not yet ported there (drawn disabled as its label plus the head of
its translated reason, the text before the first colon, so the tray stays
narrow). An undeclared restriction stays hidden, its reason read by the health
check only. A `command` row its `disabled_when` greys where it is drawn says
why the same way through `disabled_reason_key` (the Uninstall row of a local
version run from source), drawn by the same stand-in with nothing to run;
`reason_key` cannot carry that reason, since a restricted row keeps it for the
platforms it leaves out. Provider rows take `disabled_reason_key` too. The
generator, both renderers and `test-menu-unavailable-rows.cjs` hold the rule; a
greyed reason's head must stay short in all 21 locales.
Action: classify a restriction you add or touch, never with a long reason head.

### project-a-composite-scope-composes-revertible-owners

The global restore/clear never writes category keys itself. On the Lua
drivers `config_scope_composition` runs each category's own scope owner in
the manifest's `[scopes.global]` order and reverts the committed ones, newest
first, when a later one refuses; a category with no registered owner is
skipped and reported. An owner joins by exposing apply/revert/release/pending/
retry_restore: build it on `config_scope_transaction` (its `revert()` puts
the runtime snapshot back, then each published file while it still holds our
bytes) and wrap it with `config_scope_participant.synchronous`, then register
it in `linux/infra/global_scope.lua` or the macOS `apply_global_scope` owners.
A macOS `scoped_preferences` owner with its own `transaction_factory` must
return `revert` and `release` too, holding any fence its runtime restore needs
(the Hotstrings override fence), or the composition raises on rollback.
A scope whose manifest declares a `preset` owns that file through the
transaction's `presets` port; rows under its prefixes never reach config.toml.

### project-tray-root-is-the-manifest-top-level

Each of the three drivers builds its tray root with one loop over the manifest
`top_level` and an id → builder table: macOS `Builder.generate`, Windows
`_MI_TopLevelBuilders`/`_MI_StageTopLevel`, Linux `M.build`. To reorder the root,
edit `manifest.toml`, not a driver. `test-menu-top-level-parity.cjs` pins the
approved order and checks both directions of each table. The macOS and AHK drift
gates also render a shuffled top level. The rows a pause greys carry
`greyed_when_paused` in the manifest: macOS and Linux grey what it marks, the AHK
pause test holds each Windows builder's `TrayMenuStage_AddFeature` to it, and a
new feature row needs the mark, never a driver-side id list.

### project-tap-hold-key-catalogue

`[tap_hold.catalog] keys` in `_shared/tap_hold/defaults.toml` owns which keys
each Tap-Hold tray lists, in which order, under which hand and with which
label key. Each driver column (`ahk`, `hs`, `linux`) must equal the keys its
engine can remap — the Windows `platform/remap/*.ahk` hotkeys, macOS
`tap_hold_keys.json` in the same order, Linux `KEY_CODES` — which
`test-tap-hold-key-catalog-single-source.cjs` pins and the Linux manager
refuses at load. Keep it one multi-line inline-table array under a
single-bracket header: the Windows narrow tap-hold parser recognises only
`[x]` headers, so the lines after a `[[x]]` header would land in the previous
`[tap_hold.keys.*]` section. The first-run wizard's Tap-Holds page lists each
engine's recommended keys from this table; their answers
(`tap_holds.keys.<id>`, marked `tap_hold_key`) are no configuration paths, and
each host hands the checked keys to its own tap-hold writer, never to
config.toml. On a re-run each host reads the keys the folder's tap-hold owner
already configures (the preset reads as `true`, any other setting as the
item's `customised_value`); the page locks those rows and the writers refuse
to import over a customised key, backing up the file they replace. Action:
add a key to the catalogue and to its engine in the same change, and keep
every manifest path out of `tap_holds.keys`.

### project-the-nav-layer-comes-with-its-key

An absent or empty layers.toml binds no key on every driver, and no loader
falls back to `_shared/keymap/layers.recommended.toml` (the W1 neutral
install). Importing Ergopti's recommended key whose hold enters that layer
(Windows/Linux `hold_layer = "nav"`, macOS hold `layer`) must therefore bring
the layer along, or the key enters an empty layer: the first-run wizard's
Tap-Holds import and the Tap-Holds « Restore recommended values » (so the
global restore too) create layers.toml with the preset's exact bytes, only
while it is absent (`_shared/lua/keymap/layer_preset.lua`; Windows
`TapHoldLayerImportImage`, in the same transition cohort). An existing file,
even empty or unreadable, is the user's and is never replaced; a refused
import or restore removes only the file it created. Windows threads the
folder as the `layers_config_dir` option, set only by the tray's own command
factories, so tests that inject options never write the real folder. Action:
a new flow that imports a layer-holding key calls the same owner; never make
a loader substitute the preset for an absent file.

### project-key-combinations-have-their-own-gate

The modifier combinations are the Shortcuts group `key_combinations_group`
with a switch of their own, the only one they follow on every OS. macOS
persists it as `[mod_combos] enabled` in `config_karabiner.toml`, read only by
`Generator.key_combinations_enabled`; Windows as `KeyCombinations`, whose
families the master gate reads from the group's `feature` rows and the
Shortcuts master skips. Absent is on on both, because the sparse writer drops
a value equal to the default and an absent key must keep the families. With
Tap-Holds off, the generator gives each key 1 of a hold slot a passthrough
rule that only tracks its held variable, since the hold slots read it. The
Windows wizard's Shortcuts answer writes the switch through its page's
`sub_switch`, whose families come from the same `feature` rows, and only where
the answer changes what is in force: off when it turns Shortcuts from Yes to
No, on when it newly imports a family. Action: never mark combo rules as
Tap-Holds feature rules again, add a Windows family as a row of the group, not
as a gate list, and never make that default off.

### project-two-keys-for-one-row-is-two-menus

Two manifest keys that describe one visible row create two sources of truth.
Normalize aliases before rendering or remove the duplicate schema key.

### project-an-enumeration-is-not-a-feature

Discovering or listing a value is not proof that selecting, persisting, and
applying it works. Test the complete user transaction.

### project-debug-menu-sync

The debug submenu order lives in
`_shared/modules/menu/menu_manifest.json`; both desktop drivers consume it.

Native debug consoles use each driver's `ui/console_window` owner for menu and
gesture actions. Minimum geometry lives in `native_windows.console` in the
shared UI manifest. Windows targets `A_ScriptHwnd`, never the foreground
application. macOS places the console after its native window is created.
Linux has no native console; these actions remain excluded by platform instead
of opening or resizing an unrelated terminal.

### project-menu-manifest-macos-hotstrings-layout-gap

macOS does not yet consume every hotstrings/layout manifest key that Windows
does. Treat the asymmetry as known scope, not proof that all menu parity exists.

### project-layer-key-under-another-holder

A tap-hold key whose own hold is the layer another key already holds follows
one rule on every driver: the layer's mapping when the layer maps the key,
otherwise the plain key (typed at once, auto-repeated), with one exception:
the layer swallows the left-thumb key tapping Backspace (Windows LAlt, macOS
left Command), which passed through puts a modifier under every layer chord
(Alt+Up moves the line in VS Code, Cmd+Left jumps to the line start). Windows
is the reference: `not LayerEnabled` on every tap-hold variant plus the
nav_layer.ahk LAlt swallower. macOS follows it with a `variable_unless
layer_active` condition on the key's Karabiner rule (layer_keys.json runs
first) and a `SWALLOWED_ON_LAYER` manipulator; Linux in its tap-hold engine.
Pins: `test_layer_key_under_another_holder.ahk`, `test_generator.lua`,
`test_tap_hold_engine.lua`. Action: a new layer hold path on any driver must
stand down while the layer is on, or a second holder's release turns the layer
off under the first; change the swallow list on every driver at once.

### project-ui-dynamic-buttons

Windows dialogs use `Gui_HarmoniseButtonWidths`; macOS web UIs size through CSS
padding. Do not hardcode per-label widths.

### project-tooltip-shared-style

Tooltip style constants are shared. Per-driver alpha differences are
intentional because native compositors blend differently.

### project-llm-tooltip-chords-are-exact

Maintainer rule (2026-09-30), every OS: while predictions are shown, the exact
navigation chord (`nav_modifiers` + an arrow: ↑/← the previous slot, ↓/→ the
next, as `menu.llm.nav_label` says), Shift+Tab (the left Shift back, the right
one forward, whatever `nav_modifiers`) moves the active slot and the exact
validation chord (`val_modifiers` + digit N) inserts slot N, and the
application receives none of them. Any other modifier set, an arrow over a single
prediction (macOS, the reference, passes it and dismisses) and a digit beyond
the shown slots reach the application. macOS has two consumers, the tooltip's
per-render keyDown watcher and the keymap fallback `handle_llm_keys`, and tap
restarts decide which runs first; the fallback must match the watcher (Up is
the previous slot) and run before the keymap's idle word wipe, which resets the
predictions. Windows cycles and consumes the arrows in AHK, never natively
(`project-llm-nav-cycle-is-ahk-owned`). The validation digit is the
digit-row key on every driver: macOS keycodes, Linux `EvdevCodes.DIGIT_ROW_SLOT`
(the typed character made Shift+2 an `@` that never matched) and Windows
`_LLM_Menu_NavDigitRowKey`. A tap-hold whose tap is Tab is the user's Tab
(`project-llm-tap-hold-tab-is-the-users-tab`), and so is its Tab under one
Shift. The footer strings of `_shared/modules/tooltip/constants.toml`
(`hint_nav_left` "⇧G + Tab", `hint_arrow_left` "↑/←") are the advertised
contract: Windows and Linux cycled on ↑/↓ only, so ←/→ and Shift+Tab reached
the application behind a tooltip that named them, and the Windows footer hid
the bare arrows. `test-llm-nav-chord-contract.cjs` parses those strings and
every driver's tables; the Linux keyboard hook names the Shift side
(`held_shift_side`) because its modifier set does not. Action: change the rule
on all three drivers with the `llm-tooltip-chords-consumed`,
`llm-nav-left-right-windows` and `llm-accept-inserts` tests.

## Logging and observability

### errors-only-log-sink

Daily `ErgoptiPlus_errors_YYYY-MM-DD.log` files contain WARNING and ERROR events.
`crash_reports/` is reserved for uncaught fatal failures.

### project-logs-folder-single-resolver

`_shared/modules/paths/app_dirs.toml` (generated by `codegen-app-dirs.cjs`)
owns the `ergopti_plus` folder name, each OS default logs folder, the
LogsDirPath key and every log file-name prefix. Each driver has one resolver
consumers call at the moment of use: macOS `Logger.logs_dir()` /
`today_log_path()` / `today_errors_path()` / `crash_reports_dir()`, Windows
`LoggerLogsDir()` and siblings, Linux `logger_sink.log_dir()` and siblings.
Never cache a dated path: the macOS menu once kept the one chosen at boot and
opened yesterday's file after midnight.
`test-log-file-names-single-source.cjs` rejects a new prefix literal. A
LogsDirPath that is neither the default nor named `ergopti_plus` gets that
subfolder, because retention (and, on macOS, the owner-only chmod) must never
touch a folder the user merely picked.

### project-diagnostic-snapshot-contract

Each driver logs one post-boot `[Diagnostics] Diagnostic snapshot (...)` line
whose fields come from `_shared/modules/logger/diagnostic_snapshot.json`. Add a
field there, in both formatters and in every collector; the parity test and the
three driver suites fail otherwise. macOS emits it from the menu prime, not from
`init.lua`, and freezes `boot_ms` at the `Boot complete` mark; renaming that
mark turns `boot_ms` into `unknown`.

### project-instrumentation-absence-is-invisible

Missing profiling instrumentation produces deceptively clean output. Assert the
expected segment and boot-stamp inventory before interpreting timings.

### project-profile-label-placeholder-convention

Profiler labels and placeholders are schema. Producers and reports must use the
same exact names so missing segments cannot masquerade as zero cost.

## Intentional asymmetries

### project-category-gating-ahk-only

Runtime category gating through `CategoryEnabled[...]` is intentionally AHK-only
unless another driver explicitly implements equivalent ownership.

### project-declared-answered-and-absent

Distinguish declared capability, answered query, and absent value. Collapsing
them into false changes fallback and UI behavior.

### project-the-wrong-dialect-is-invisible

Shared data can be syntactically valid in the wrong consumer dialect. Validate
with each real parser, not only a generic JSON/TOML check.

### project-dynamic-places-list-materialises

Dynamic lists become persisted user choices. Preserve stable identifiers and
handle entries disappearing between discovery and use.

### feedback-windows-are-focused-never-topmost

Maintainer rule (2026-09-29): an ErgoptiPlus window is shown, raised and
focused when it opens or is requested again, and never given a level or
topmost flag. On macOS `hs.webview:bringToFront()` does not raise a window: it
SETS the level (floating, or screen saver with `true`), so the diagnostics
window stayed above every app. Present windows with `ui_builder.force_focus`
(macOS), `Gui.Show` for a first open and `WMPresentWindow` for a window
requested again (Windows; `Gui_Create` refuses a topmost option) and
`webview_manager._present_gtk_window` (Linux). Only the overlay allowlist in
`tools/test/test-ui-focus-fix.cjs` (tooltips, previews, WPM widget, spotlight)
may stay on top, each entry pinned to its exact site count; the overlay
adapters are topmost by default, so every file loading one is listed. That
gate scans the three drivers, the shared Lua, extensions and Ergopti's own
vendor scripts.
