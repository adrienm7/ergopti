<!-- docs/design/layout-source-format.md -->

# Ergopti layout source, version 1

The layout source is a TOML 1.0 document identified by `format = "ergopti-layout"`
and `version = 1`. The executable schema is
`static/ergopti_plus/_shared/ui/layout_composer/source_model.js`; the existing
`smol-toml` codec owns parsing and writing. Comments and ordinary TOML strings,
inline tables and arrays of tables are accepted. A canonical save retains data,
not TOML comments or formatting.

The generator foundation provides validation, interchange, an exact `.keylayout`
preservation path and partial Linux XKB / Windows KLC exports of admitted imports. It does **not** compile the superset,
install layouts, change a driver, create the ISO/ANSI bundle, or replace either
editor. Those consumers must use this model when the existing composer,
navigation layer editor and layout manager are unified. The target remains
[KbdEdit parity](layout-generator-kbdedit-parity.md).

## Commands available now

Run from the repository root with the pinned Node version and installed npm
dependencies. Output paths must not already exist.

```sh
npm run layout-source -- import my_layout iso source.keylayout source.toml
npm run layout-source -- validate source.toml
npm run layout-source -- report source.toml
npm run layout-source -- export-keylayout source.toml restored.keylayout
npm run layout-source -- export-xkb source.toml new-output-directory
npm run layout-source -- export-klc source.toml new-output-directory
```

`import` takes an explicit `iso` or `ansi` keycode convention; the XML itself
does not establish which physical convention its author used. `validate`
prints the accepted format/version/id. `report` prints every target's actual
tool support, artifact and refusal reason. `export-keylayout` is explicitly a
single-file preservation operation, not the future default bundle exporter.
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
Superset edits and physical relocations remain refused. Linux name/description
metadata are compiled, while other target preferences do not affect this
export. Description characters unsafe in the existing converter's XKB quoted
string are refused. Registry-specific driver hints are not inferred from a name.

The common registry corpus currently exports all four Ergopti variants with
document-specific partial reports; Bépo's alternative hardware maps and Ergo-L's
character-key control outputs are refused. Tests compare admitted files against
the existing converter byte for byte. Installation, native keyboard execution,
Windows DLL generation and macOS bundles remain separate work. The pure browser
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

| Record               | Required fields                                      | Optional fields and contract                                                                                                                                                                                                                         |
| -------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Root                 | `format`, `version`, `layout`, `physical`            | The records below. A new source without an import requires a layer named `base`.                                                                                                                                                                     |
| `layout`             | `id`, `name`                                         | `description`, `author`, unique `languages` strings; these describe the source, not installation state.                                                                                                                                              |
| `physical`           | `base` (`iso` or `ansi`)                             | `ansi_extra_key`: destination of the ISO extra key when deriving ANSI; no relocation is applied yet. Newly authored layouts use ISO.                                                                                                                 |
| `imported_keylayout` | `text`, `convention` (`iso` or `ansi`)               | The exact original XML; no cached conversion projection.                                                                                                                                                                                             |
| `modifiers[]`        | `id`, `mode`, nonempty unique `keys[]`               | Mode is `held` or `locked`. Custom IDs, including `kana`, `roya` and `loya`, cannot shadow built-ins.                                                                                                                                                |
| `layers[]`           | `id`, `required[]`, `optional[]`, `keys`             | Ordered layers; required and optional modifier IDs cannot overlap. `platform_keys` contains optional `windows`, `macos`, `linux` mapping tables, each overriding `keys` by physical position. This retains the navigation editor's per-OS ownership. |
| `dead_keys[]`        | `id`, `terminator`, `rules[]`                        | Optional `name`. A rule has unique nonempty `input` and at least one of `text` or `next`; `next` names a declared dead key. Both may be present. Cycles and multi-character results are representable.                                               |
| `keys.<physical>`    | None                                                 | `name`, `caps_lock` (`unaffected`, `shift`, `separate`), `caps_altgr` boolean, `virtual_key` integer 0–255. `separate` requires `caps_layer` and `caps_shift_layer` referencing layers; those fields are forbidden in the other modes.               |
| `remap`              | None                                                 | Physical source keys map to physical target keys; an empty target disables the key. Repeated destinations are legal.                                                                                                                                 |
| `shortcuts[]`        | `key`, `modifiers[]`, `send_key`, `send_modifiers[]` | Physical chord output is independent of typed text. Modifiers reference built-ins or declarations; duplicate unordered source chords are refused.                                                                                                    |
| `tap_holds[]`        | `key`, `tap`, `threshold_ms`                         | Exactly one of `hold_layer` or `hold_modifier`, referencing its declaration. Threshold is a positive safe integer in milliseconds. `tap` is a mapping.                                                                                               |
| `windows`            | None                                                 | Unique `flags[]` identifiers and `nls[]` records. Each NLS record has `key`, `modifiers[]`, `function`, with optional `parameter_key`, `keyup_function`, `keyup_parameter_key`; source chords are unique.                                            |
| `exports.macos`      | `format`                                             | `bundle`, `iso` or `ansi`; the future ordinary export defaults to `bundle`. The preservation command refuses any format other than the import's convention.                                                                                          |
| `exports.windows`    | None                                                 | `locale`, `layout_id`, `dll_name` strings. KLC requires all three; `layout_id` must be a language LCID, while custom KLIDs remain reserved for a future installer.                                                                                   |
| `exports.linux`      | None                                                 | `name`, `description` strings. XKB export requires an identifier name and a description without quotes, backslashes or controls.                                                                                                                     |

A key mapping has exactly one of `text`, `dead_key`, `action`, `key` or
`disabled = true`. The `key` form may also contain a unique `modifiers` array.
Empty text is an explicit empty output. Dead keys and modifiers must resolve
to declarations. The built-in modifiers are `shift`, `control`, `alt`, `meta`,
their `_left` and `_right` variants, and `caps_lock`, `num_lock`, `scroll_lock`.
Their separate names avoid collapsing platform-specific shortcut semantics.

For example, this new source expresses a ligature, a locked custom modifier,
a navigation layer, a physical shortcut and a tap-hold. It validates and saves;
every target remains unavailable until its compiler is implemented.

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

## Capability evidence and remaining consumers

The report covers macOS, Linux, Windows, the three driver emulators and web.
Only a preserved imported `.keylayout` can report `native`; this denotes its
artifact format, not native execution evidence. The CLI's Linux and Windows routes report
`partial` with its actual projection losses or `unavailable` with the refusal
reason. The pure browser model reports `tooling_export_required` for Linux and Windows;
other unfinished routes report `exporter_not_implemented`. The preservation
route names edits it cannot compile. These are tool limitations, not claims that
the operating system cannot express a feature. No route reports `emulated`
until a driver actually consumes the source.

Next consumers must replace these conservative reports with measured per-feature
native/emulated/impossible results and golden vectors before enabling export.
The work still includes lossless structural import, superset target compilers,
ISO/ANSI derivation, bundle construction, the single shared editor, website
embedding, and direct source loading by every driver. More detailed hardware,
printing/palette and NLS semantics should evolve through an explicit versioned
schema change if they cannot fit the declared records.
