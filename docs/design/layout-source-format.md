<!-- docs/design/layout-source-format.md -->

# Ergopti layout source, version 1

The layout source is a TOML 1.0 document identified by `format = "ergopti-layout"`
and `version = 1`. The executable schema is
`static/ergopti_plus/_shared/ui/layout_composer/source_model.js`; the existing
`smol-toml` codec owns parsing and writing. Comments and ordinary TOML strings,
inline tables and arrays of tables are accepted. A canonical save retains data,
not TOML comments or formatting.

A source is either **structured** (layers, dead keys and the other records
below, the form a user edits) or a **preserved import** (the original XML kept
byte for byte). The one generator,
`static/ergopti_plus/_shared/ui/layout_composer/source_compiler.js`, compiles a
structured source into a `.keylayout` per physical variant, lays out the macOS
bundle, and reports per record what each target leaves out. The Linux XKB and
Windows KLC exports read that same compiled `.keylayout` through their existing
converters, so every target consumes one compilation. It is a pure classic
script: pages, the app webviews and the Node tools load it after
`composer_model.js` and `source_model.js` and pass it the key tables. The [unified
layout editor](layout-editor.md) consumes this model through
`layout_editor/source_io.js`; it adds no second format. The target remains
[KbdEdit parity](layout-generator-kbdedit-parity.md).

## Commands available now

Run from the repository root with the pinned Node version and installed npm
dependencies. Output paths must not already exist.

```sh
npm run layout-source -- import-structured my_layout iso source.keylayout source.toml
npm run layout-source -- export-all source.toml build/layout-source/my_layout
npm run layout-source -- export-macos source.toml new-output-directory [bundle|iso|ansi]
npm run layout-source -- import my_layout iso source.keylayout source.toml
npm run layout-source -- validate source.toml
npm run layout-source -- report source.toml
npm run layout-source -- export-keylayout source.toml restored.keylayout
npm run layout-source -- export-xkb source.toml new-output-directory
npm run layout-source -- export-klc source.toml new-output-directory
```

`import-structured` converts a `.keylayout` into structured records (below);
`import` keeps it as a preserved import. Both take an explicit `iso` or `ansi`
keycode convention; the XML itself does not establish which physical convention
its author used. `export-all` writes `macos/`, `linux/` and `windows/` (each with
its `export.json`) and `report.json` into a new directory; a refused target
writes no folder and is listed with its reason. Generated Windows files go to a
build directory such as the ignored `build/layout-source/`, never into the
driver tree. `validate`
prints the accepted format/version/id. `report` prints every target's actual
tool support, artifact and refusal reason. `export-keylayout` is explicitly a
single-file preservation operation of an import; `export-macos` is the bundle exporter.
No command overwrites an existing destination, and an export refusal creates
no file. Input must be valid UTF-8.

`export-xkb` also requires Lua 5.4 on `PATH`. It creates a new directory containing
`<name>.xkb`, `<name>.XCompose`, `xkb_types.txt` and `export.json`, and prints the
same report. The reusable `exportXkb(document)` API in
`tools/lib/layout-source-xkb.cjs` returns a file map and report without filesystem
publication. It passes explicit input and assets to the shared Lua converter;
it does not invoke the regeneration script or depend on the working directory.
Compilation and admission finish before any output directory is created. A later
filesystem write failure is reported and may leave an incomplete directory.

The Linux result is explicitly **partial**, never a claim of native behavior
parity. Seven character levels are generated: base, Caps, Shift, Shift+Caps,
Command shortcuts, Option and Shift+Option. The report compares the actual
source entries (including action identities) against native selection for all
32 combinations of Shift, Caps, Option, Control and Command, listing changed
physical keycodes for each combination. Option becomes AltGr; Linux Alt,
Control and Super select the Command shortcut level. Source keycodes outside
the character-key table stay system-owned and are listed. Empty character
cells emit `NoSymbol` and are listed because inherited XKB behavior can differ
from disabling a source key. XCompose needs support from the consuming client;
macOS state cancellation and implicit fallback behavior are not certified.
Stateful actions without a physical binding are listed; only a single-scalar
action ID is admitted in that case, for its defined Unicode keysym fallback.

The conversion boundary refuses alternative hardware layouts, additional
modifier maps, sided modifiers, ranges/multipliers, unknown/duplicate XML
attributes, non-decimal/fractional numeric attributes, missing keymap/action
references, ambiguous transitions, controls on character keys or in action IDs,
states and outputs,
Compose conflicts and unplaced non-keypad typing keys. It reuses the canonical
reader's tag scanner; it is not an additional XML parser or a DTD validator.
An edited preserved import is refused; a structured source reaches the
converter as its compiled `.keylayout` (see [The generator](#the-generator)). Linux name/description
metadata are compiled, while other target preferences do not affect this
export. Description characters unsafe in the existing converter's XKB quoted
string are refused. Registry-specific driver hints are not inferred from a name.

The common registry corpus currently exports all four Ergopti variants with
document-specific partial reports; Bépo's alternative hardware maps and Ergo-L's
character-key control outputs are refused. Tests compare admitted files against
the existing converter byte for byte. Installation, native keyboard execution
and Windows DLL generation remain separate work. The pure browser
model stays conservative; the CLI's `report` augments it with the installed Lua
tooling route, including runtime failures.

`export-klc` requires the same Lua runtime and explicit Windows metadata:

```toml
[exports.windows]
locale = "fr-FR"
layout_id = "0000040c"
dll_name = "kbdlocal"
```

It creates `<dll_name>.klc` (UTF-16LE with BOM and CRLF) and `export.json` in a
new directory. `exportKlc(document)` in `tools/lib/layout-source-klc.cjs` returns
the bytes/report without writing. The existing Windows generator owns every
character row, Caps Lock flag, dead-key transition, ligature and native key name.
Its current limits are four UTF-16 units per ligature, one UTF-16 unit per dead
character/result, standard Caps Lock (no SGCAP/CAPLOKALTGR), and its existing
virtual-key allocation. Omissions are refused, including non-BMP or multi-unit
dead results, Caps-only keys the underlying model cannot emit, empty/unbound
stateful actions, cycles in keymap inheritance and Windows-reserved U+F000–U+F002 output.
Chained dead keys are accepted when every destination has an emitted dead key.

The name is one to eight lowercase letters/digits, starting with a letter.
`layout_id` must be a language LCID of the form `0000xxxx`; a custom `A0nnxxxx`
keyboard-layout ID cannot be reserved by KLC and is refused. Locale/LCID pairing
is retained as supplied, without claiming native Windows validation. The layout
name and optional author are written; quotes, backslashes and controls in quoted
metadata are refused. New artifacts explicitly start at version 1.0 because the
source schema has no release-version field; this is not the TOML schema version.

KLC reports **partial**: source Ctrl/Command combinations are not compiled, and
their actual source cells for all 24 affected modifier combinations are reported.
The report also retains each source mapping of system/keypad keys the character
table does not own. Windows supplies its normal control-key behavior; the KLC
generator emits the standard decimal point. Its assigned virtual keys are listed;
source shortcuts are not inferred from displayed characters. This does not certify shortcuts,
native loading or installation. No DLL, C sources or installer are published.

The common corpus exports Ergopti and Ergopti ANSI. Ergopti+ variants are refused
for their Caps Lock behavior; Bépo and Ergo-L keep the same structural/control
refusals as XKB. Tests compare character tables with the existing Windows golden
generator and exercise UTF-16 ligatures, chained dead keys, metadata and refusal
before output-directory creation.

## Imported documents and the lossless boundary

An import stores the complete XML in `imported_keylayout.text`, with its
physical convention in `imported_keylayout.convention`. That text is the sole
owner of imported mappings. The existing `LayoutComposer.parseModel` reader
checks that the file is readable; no second XML parser was introduced.

The conversion reader deliberately folds left/right modifiers and projects
the default hardware layout. It also does not model every action range or
attribute. Its result is therefore **not** serialized as a purported lossless
editable representation. Retaining the original text preserves comments,
declarations, alternative hardware layouts, modifier maps, inheritance,
state ranges and multipliers, terminators, non-BMP output, original line
endings and a byte-order mark. External/custom entity declarations are refused;
the standard external KeyboardLayout DTD declaration stays inert text and is
never fetched.

The tests prove `.keylayout` → TOML → `.keylayout` byte equality across all
registry entries, shared edge fixtures and a fixture covering those otherwise
unrepresented attributes. They do not certify that an arbitrary retained XML
document is a valid native macOS layout. Admission has the existing reader's
limits; native loading and a complete XML/DTD validator remain separate work.

Adding superset records, changing the layout name or physical convention,
requesting an ANSI relocation, or selecting a bundle/other variant makes the
preservation exporter refuse. It never returns old XML while ignoring those
edits. An imported source can still be saved with those records for a future
compiler. Native structural editing of the XML is not implemented by this model.

## Document schema

All records are closed: unknown fields are errors, including misspellings and
fields from a future schema version. The validator reports stable codes and a
source path, makes no changes, inserts no defaults and drops nothing. Duplicate
IDs, conflicting mapping kinds, duplicate selectors within a shortcut list,
unknown references and unpaired UTF-16 surrogates are errors. Unicode output
may contain non-BMP scalars, multiple characters, combining marks and controls.

Identifiers use `[a-z][a-z0-9_]*`. Physical key names use KeyboardEvent.code
spelling (`KeyA`, `IntlBackslash`, `NumpadEnter`, `AudioVolumeMute`), checked
syntactically as `[A-Z][A-Za-z0-9]*`. Action names, Windows flags and NLS
function names are also checked syntactically. A future compiler must admit
them against its actual catalogues and platform limits; structural validation
does not claim that every syntactically valid name is implemented.

| Record               | Required fields                                      | Optional fields and contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| -------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Root                 | `format`, `version`, `layout`, `physical`            | The records below. A new source without an import requires a layer named `base`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `layout`             | `id`, `name`                                         | `description`, `author`, unique `languages` strings; these describe the source, not installation state.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `physical`           | `base` (`iso` or `ansi`)                             | `ansi_extra_key`: where the ANSI derivation moves the ISO key left of Z (default `Backquote`); `ansi_swaps`: further `[key, key]` position pairs swapped for ANSI, each key in one pair at most. A structured source is always `iso`.                                                                                                                                                                                                                                                                                                                                                                               |
| `imported_keylayout` | `text`, `convention` (`iso` or `ansi`)               | The exact original XML; no cached conversion projection.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `modifiers[]`        | `id`, `mode`, nonempty unique `keys[]`               | Mode is `held` or `locked`. Custom IDs, such as `roya` and `loya`, cannot shadow built-ins (`kana` is one, see [The Kana level](#the-kana-level)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `layers[]`           | `id`, `required[]`, `optional[]`, `keys`             | Ordered layers (the first matching selector wins); required and optional modifier IDs cannot overlap. `alternatives[]` holds further `{required, optional}` combinations selecting the same layer. `platform_keys` contains optional `windows`, `macos`, `linux` mapping tables, each overriding `keys` by physical position for that target. This retains the navigation editor's per-OS ownership. `ansi_keys` overrides `keys` in the ANSI variant only, after the derivation rule (an imported ANSI hardware map that the rule does not reproduce).                                                             |
| `dead_keys[]`        | `id`, `terminator`, `rules[]`                        | Optional `name`; `state` and `action_id`, the `.keylayout` state and dead-key action names when they differ from the defaults (the id; the terminator when it is one free character, else `dead_<state>`). A rule has exactly one of `input` (the typed text it answers to) or `input_dead_key` (a dead key pressed while this one is pending), unique within the dead key, and at least one of `text` or `next`; `next` names a declared dead key. Cycles and multi-character results are representable.                                                                                                           |
| `keys.<physical>`    | None                                                 | `name`, `caps_lock` (`unaffected`, `shift`, `separate`), `caps_altgr` boolean, `virtual_key` integer 0–255. `separate` requires `caps_layer` and `caps_shift_layer` referencing layers; those fields are forbidden in the other modes.                                                                                                                                                                                                                                                                                                                                                                              |
| `remap`              | None                                                 | Physical source keys map to physical target keys; an empty target disables the key. Repeated destinations are legal.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `shortcuts[]`        | `key`, `modifiers[]`, `send_key`, `send_modifiers[]` | Physical chord output is independent of typed text. Modifiers reference built-ins or declarations; duplicate unordered source chords are refused.                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `tap_holds[]`        | `key`, `tap`, `threshold_ms`                         | Exactly one of `hold_layer` or `hold_modifier`, referencing its declaration. Threshold is a positive safe integer in milliseconds. `tap` is a mapping.                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `windows`            | None                                                 | Unique `flags[]` identifiers and `nls[]` records. Each NLS record has `key`, `modifiers[]`, `function`, with optional `parameter_key`, `keyup_function`, `keyup_parameter_key`; source chords are unique.                                                                                                                                                                                                                                                                                                                                                                                                           |
| `exports.macos`      | `format`                                             | `bundle` (ISO + ANSI, the default), `iso` or `ansi` (one `.keylayout`). `icon`/`ansi_icon`: a PNG file name beside the source (see [macOS bundle](#macos-bundle)). `internal_name`/`ansi_internal_name` (file name, `KLInfo_` key and strings key; default the layout id and `<internal>_ansi`), `ansi_display_name` (default `<name> ANSI`), `keyboard_id`/`ansi_keyboard_id` (default derived from the internal name), `input_source_id` (default `com.apple.keyboardlayout.<id>`, ANSI adds `.ansi`), `version` (default `1.0`). The preservation command refuses any format other than the import's convention. |
| `exports.windows`    | None                                                 | `locale`, `layout_id`, `dll_name` strings. KLC requires all three; `layout_id` must be a language LCID, while custom KLIDs remain reserved for a future installer.                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `exports.linux`      | None                                                 | `name`, `description` strings. XKB export requires an identifier name and a description without quotes, backslashes or controls.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

A key mapping has exactly one of `text`, `dead_key`, `action`, `key` or
`disabled = true`. The `key` form may also contain a unique `modifiers` array.
A `text` mapping takes part in the dead keys through its **compose identity**:
the text itself, or `compose_as` when the key answers to another rule input (the
Ergopti+ magic key types `★` and composes as `j`). `compose = false` types the
text outside every dead key: a pending dead key types its terminator, then the
text.
Empty text is an explicit empty output. Dead keys and modifiers must resolve
to declarations. The built-in modifiers are `shift`, `control`, `alt`, `meta`,
their `_left` and `_right` variants, and `caps_lock`, `num_lock`, `scroll_lock`.
Their separate names avoid collapsing platform-specific shortcut semantics.

For example, this new source expresses a ligature, a locked custom modifier,
a navigation layer, a physical shortcut and a tap-hold. It validates, saves and
compiles; every export lists the custom modifier, its layer (with the action
mapping it holds), the shortcut and the tap-hold as omitted. The fuller fixture
`_shared/tests/corpus/layouts/source/source.toml` and its golden
`source.keylayout` pin the compiler.

```toml
format = "ergopti-layout"
version = 1

[layout]
id = "my_layout"
name = "My layout"

[physical]
base = "iso"
ansi_extra_key = "Backquote"

[[modifiers]]
id = "kana"
mode = "locked"
keys = ["ScrollLock"]

[[layers]]
id = "base"
required = []
optional = []
keys = { KeyA = { text = "a" }, KeyB = { text = "ffi🦆" } }

[[layers]]
id = "nav"
required = ["kana"]
optional = []
keys = { KeyJ = { action = "arrow_left" } }

[[shortcuts]]
key = "KeyA"
modifiers = ["control"]
send_key = "KeyB"
send_modifiers = ["control"]

[[tap_holds]]
key = "CapsLock"
tap = { key = "Escape" }
hold_layer = "nav"
threshold_ms = 180

[exports.macos]
format = "bundle"
```

## The generator

### Structured import

`importStructured` reads a `.keylayout` with the composer reader and refuses
what its records cannot hold: a nonzero `defaultIndex`, an action without a
neutral transition, or two dead-key actions entering one state. Several hardware
layouts are imported as Bépo declares them: one modifierMap, keyboard type 0
alone on the ISO map the layers come from, every other type on one ANSI map
(ISO convention only). Each layer's `ansi_keys` then holds the ANSI map's keys
where it differs from the derivation rule, so the bundle's ANSI variant types
what the ANSI map types; the per-hardware automatic choice becomes the bundle's
two variants. Any other combination is refused (`source_import_hardware_layouts`),
as is an ANSI key typing nothing where the rule types something. A printable key
at a macOS code no key table names (Ergo-L's code 66, a legacy keypad position)
is named `MacCode<n>`: the macOS target places it, XKB and KLC list it as
`mac_only_key_code_not_in_<platform>`. An action with an empty id that no key
reaches (Bépo declares one) has no behaviour and is not imported. Each `keyMapSelect` becomes a layer named after its first
selector's required modifiers, its unfolded tokens kept (`shift` is the left
Shift, `anyShift` either). Action and state names survive where the compiler
would not derive them. System keys typing their standard control output are left
implicit; every other key is recorded. Physical names come from
`mac_keycodes.json` (the 49 character keys, by convention), `physical_keys.json`
and the keys no layer binds in `hid_usages.json` (`unregistered`; F13 wins over
PrintScreen for the same macOS code).

The tests import the registry `ergopti`, `ergopti_ansi`, `ergopti_plus`,
`ergopti_plus_ansi`, `bepo` (ISO and ANSI maps) and `ergol` (an ANSI-numbered
file, compared with the ANSI variant) files, write and reread the TOML, compile it and compare the
result with the original as macOS runs it: the same selectors, and the same text
for every key of every keyMap from every reachable pair of dead-key states. The
XKB files of the structured sources equal those of the original files byte for
byte, and the Ergopti KLC likewise.

### Compilation and what is left out

`compileKeylayout(source, tables, {variant, platform})` writes one keyMap per
layer whose modifiers have a `.keylayout` token, the standard control output of
every system key a layer does not map, one action per compose identity that a
rule answers to (keys typing a text no rule uses stay plain outputs), one action
per dead key, and its terminators. A remap between two character keys is applied
natively (the source key does what the target did, read before any remap). The
report lists, with a stable reason, every record no `.keylayout` holds: custom
modifiers and their layers, remaps of system or modifier keys, shortcuts,
tap-holds, Windows flags, per-key Caps Lock fields (layer selection owns Caps
Lock there), `action`/`key` mappings, and keys with no macOS code. Two keys
sharing a compose identity with different texts are refused
(`source_compose_conflict`).

For Linux and Windows the compilation is the input of their converters, which
read Option as AltGr: `alt_right` folds onto it (AltGr is the right Alt key),
other sided modifiers drop their layer with `sided_modifier_not_in_<platform>`,
and a disabled character key becomes an empty cell
(`disabled_key_is_empty_cell`). Each converter's own report (projection levels,
KLC column limits) follows.

### The Kana level

`kana` is a built-in modifier: Windows' Kana level (`KBDKANA`), which Ergopti's KbdEdit layout uses in place of
AltGr. Each target maps it to its closest native level; decided by the coordinator on 2026-11-11, to review by the
maintainer:

| Target                | Kana becomes                                                                                                           | Cannot                                                                                                   |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| macOS `.keylayout`    | The Option level (`anyOption`), where Ergopti's macOS layout puts it; KbdEdit's own export uses Command.               | Keep Option shortcuts free: both Option keys select the level, as for any macOS layout with Option text. |
| Linux XKB             | The AltGr level (Option through the converter: `ISO_Level3_Shift`).                                                    | Have a separate Kana level: XKB's fifth level is not generated.                                          |
| Windows KLC           | The AltGr columns, the only extra level MSKLC writes.                                                                  | Carry `KBDKANA`: the keyboard DLL generator (`docs/design/layout-windows-dll.md`) writes the real level. |
| Emulation and preview | A native layer: no driver reports Kana, so the engines know the id and never select it; the preview types it with Alt. | Emulate a Kana level the target left out.                                                                |

When the source also selects a layer with `alt`, `alt_left` or `alt_right`, Kana cannot share the Option level: its
layers are left out with `kana_level_taken_by_alt` (macOS, Linux, Windows KLC, emulation). `static/layouts/sources/ergopti.toml`,
imported from KbdEdit's macOS export of Ergopti v2.2.2 (Command renamed back to `kana`), compiles to that export with
Kana on Option, every key, level and dead-key state (`tools/test/test-layout-sources.cjs`).

### ISO edits, ANSI derived

Decided 2026-11-06: the user edits the ISO layout. The ANSI variant swaps the
mapping of `IntlBackslash` with `ansi_extra_key` (default `Backquote`), then each
`ansi_swaps` pair. The Ergopti rule
(`keylayout_ansi_creation.py`: macOS codes 10↔50 and 42↔30) is
`ansi_swaps = [["Backslash", "BracketRight"]]`; with it the compiled ANSI
variants of Ergopti and Ergopti+ behave exactly as the registry ANSI files.

### macOS bundle

`exportMacos` writes, by default, `<internal>.bundle/Contents/` with
`Info.plist` (one `KLInfo_<internal>` entry per variant, its `TISInputSourceID`
and the first `layout.languages` entry as `TISIntendedLanguage`),
`version.plist`, `Resources/<internal>.keylayout` and
`<internal>_ansi.keylayout`, and `en.lproj`/`fr.lproj` `InfoPlist.strings` in
UTF-16LE with a byte-order mark, keyed by the internal name, as the shipped
Ergopti bundles are: macOS rejects a bundle whose strings are keyed by the input
source id. `iso` and `ansi` write one `.keylayout`. Native loading by macOS is
not certified by the export.

Icons: `exports.macos.icon` names a square PNG (16, 32, 64, 128, 256, 512 or
1024 pixels) beside the source file, `ansi_icon` the ANSI variant's own (else
the same). Each variant gets `Resources/<internal>.icns`, holding the PNG as
the element of its size, and its `KLInfo_` entry names it (`ICNS`,
`TISIconIsTemplate` false), as the shipped Ergopti bundles do; a single
`.keylayout` gets `<internal>.icns` beside it. The page and the CLI pass the PNG
bytes in; the compiler reads only the PNG header and refuses a missing file,
another format or an unsupported size (`source_icon_missing`, `source_icon_png`,
`source_icon_size`). Without an icon macOS shows its generic layout icon and the
report says so. The image is the user's: the generator draws none.

### Emulation of what no `.keylayout` holds

`compileEmulation(source, tables, {platform})` writes the **emulation table**
(`format = "ergopti-layout-emulation"`, `version = 1`, JSON) of the records the
platform's compiled `.keylayout` leaves out: every custom modifier with the keys
a driver sees (held or locked), every layer in order with its selectors, whether
the `.keylayout` holds it (`native`) and the mappings the emulation performs
(all of an emulated layer's `text`, `key` and `disabled` mappings; a native
layer's `key` chords), the shortcuts, the tap-holds and the remaps of system
keys. `not_emulated` lists, with a stable reason, what even the emulation
cannot perform: dead keys and actions in an emulated layer, layers or chords
needing a sided modifier other than `alt_right` (no driver reports sides), keys
the physical-key registry does not have (`ScrollLock`, `F13`, `Pause`) and
modifier keys (`CapsLock`, which the drivers see as a lock or a flag).

One engine performs it: `_shared/lua/layouts/source_emulation.lua` on macOS
and Linux, its twin `_shared/ui/layout_composer/source_emulation.js` for the
web. A press goes first to it, then (when it leaves the key alone) to the
keylayout emulation or the OS. Selection is TN2056's: the first layer whose
selector matches the held built-in modifiers and the active custom ones; an
unsided id (`alt`) matches either side, two sides never match; an emulated layer
types nothing on a key it does not map. A shortcut matches its exact modifiers,
Caps Lock ignored unless named, and sends its key with its own modifiers; a
remap sends its target with the held modifiers, an empty target disables the
key. A tap-hold follows the shared tap-hold catalogue's typing rule (as macOS
resolves it): a press under the pending key before its threshold types the tap
first, a press after it or the threshold passing (`tick`) starts the hold of the
layer or modifier (a built-in one the driver applies to the keys under it), and a
release before the threshold types the tap. No keystroke is held back or
reordered (decided by the coordinator on 2026-11-11 overnight, to review by the
maintainer: the release-order rule of Windows and Linux would need the drivers
to delay and replay keys).

`export-emulation <source.toml> <output.json>` writes the three platforms'
tables (the committed goldens are regenerated by
`tools/codegen/codegen-layout-source-emulation.cjs`); `export-all` adds `emulation/` (one table per platform and its report)
and `web/` (the macOS `.keylayout` and its table: the web emulation types both,
having no installed layout). The fixture
`_shared/tests/corpus/layouts/source/emulation_source.toml`, its golden
`emulation.json` and the typing vectors `emulation_vectors.json` pin the
compiler and both engines (`npm run test:layout-source-emulation`, and the Lua
contract `_shared/lua/test/source_emulation_contract.lua` on both drivers).

### Drivers: the source through the layout composer host

On macOS and Linux the layout manager page may save an Ergopti source in place
of a composition: it sends the TOML and the `.keylayout` the shared compiler
built from it (`composer_save` with `source` instead of `declaration`), and,
when the source has records no `.keylayout` holds, the emulation table the
compiler wrote for that driver's platform (`emulation`, JSON text).
`_shared/lua/layouts/composer.lua` checks the bounds (`source_file`,
`max_source_bytes`, `emulation_file`, `max_emulation_bytes` in
`_shared/modules/layouts/defaults.json`), the format and version, the display
name, and that the layout carries the source's internal name (a preserved
import must send its own XML); a table must compile in the shared engine and be
this source's (`layout`) for this driver (`platform`). It stores the TOML and
the table, removes the other form (and a table a later save no longer sends),
and installs the layout as the `composed` entry, which each driver then
emulates or installs as for any composition. The host never recompiles: what
it stores is what the page compiled.

While the composed layout is emulated, the driver's layout emulation
(`macos/modules/keymap/layout_emulation.lua`,
`linux/modules/keymap/layout_emulation.lua`) also loads the stored table and
hands each press to the source emulation first. On Linux the keyboard hook's
consumption receipt names a `release_callback`, called once on the consumed
press's key-up: a held custom modifier or a tap-hold key ends there; a real
press of a key the engine still holds means a release was lost and is settled
first. Texts are typed in the key's place, keys go out through the input
broker with exactly their modifiers. On macOS one output rides the key-down
event itself (its text, or its key code and flags, the key-up rewritten
alike) and several are posted after the callback in physical order; the keyUp
tap ends the held keys. A built-in modifier a tap-hold holds is added to the
keys pressed under it (typed shifted, or sent with it), not to a mouse click.
The report's `driver_macos` and `driver_linux` list what neither the
`.keylayout` nor the table carries. The page side belongs to the unified
editor. Windows has the same host in `windows/ui/layout_manager/composer.ahk`,
which does not accept a source yet.

## Capability evidence and remaining consumers

The report covers macOS, Linux, Windows, the three driver emulators and web.
A preserved imported `.keylayout` reports `native` from the pure model; a
structured source reports the bundle export's `native` or `partial` with its
omissions. Either denotes the artifact format, not native execution evidence. The CLI's Linux and Windows routes report
`partial` with its actual projection losses or `unavailable` with the refusal
reason. The pure browser model reports `tooling_export_required` for Linux and Windows;
other unfinished routes report `exporter_not_implemented`. The preservation
route names edits it cannot compile. These are tool limitations, not claims that
the operating system cannot express a feature. The CLI reports `driver_macos` and
`driver_linux` from the composer host route above (`emulated`, or `partial` with
the omissions); Windows and web stay `unavailable` until they consume the source.

Next consumers must replace these conservative reports with measured per-feature
native/emulated/impossible results and golden vectors before enabling export.
The work still includes the single shared editor and its page side of the
source save, website embedding of the web emulation, the Windows host and its
emulation of the table, keyboard DLL and installer from the generated KLC, and
native loading proof of the generated bundle on a Mac. More detailed hardware,
printing/palette and NLS semantics should evolve through an explicit versioned
schema change if they cannot fit the declared records.
