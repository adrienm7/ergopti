<!-- docs/layout-composer.md -->

# Per-layer layout composer

Design of the October 13 request (big item 4 of `ERGOPTIPLUS_TODO.md`): a
keyboard layout built from layers. Each of the four layers (base, Shift,
AltGr, Shift+AltGr) is taken from any layout of the registry, a shortcuts layer
says what a key gives while Ctrl, Alt or Win is held, and every key of every
layer can be tuned by hand, up to the user's own complete `.keylayout`.

## Decision: the composer's only output is a `.keylayout`

The registry holds one `.keylayout` per layout and nothing derived from it
(`static/layouts/registry/README.md`). The composer keeps that rule: a
composition is **compiled by one shared pure model into one complete
`.keylayout`**, and the three drivers then consume that file through the
channels they already have. There is no second layout format, no per-OS
composition code and no driver that re-implements the composition.

```
 page (shared JS)                      host (per OS)                   typing
 ┌────────────────────┐   save   ┌───────────────────────────┐
 │ composition.json   │────────▶│ <config>/layout_composer/  │
 │ (the declaration)  │          │   composition.json         │
 │ composer_model.js  │          │   composed.keylayout       │──▶ Windows: emulation
 │  compose + validate│          └───────────────────────────┘     macOS: input source
 │  + serialize       │                                            Linux: XKB conversion
 └────────────────────┘
```

The declaration (`composition.json`) exists only so the page can reopen the composition; no driver reads it. A driver installs the compiled `composed.keylayout` (see below).

## Shared data model

Defined and validated by
`static/ergopti_plus/_shared/ui/layout_composer/composer_model.js` (the only
implementation; Node tests and the page run the same file).

- **Physical keys** are named by W3C `KeyboardEvent.code` (`KeyQ`,
  `Digit1`, `IntlBackslash`, ...), the 49 keys of
  `_shared/modules/layouts/mac_keycodes.json`. The macOS code of the two keys
  that differ between Apple ISO and ANSI keyboards depends on the file's
  `keycode_convention`; the model reads every source through its own
  convention and writes the composition through the declared one.
- **Source layers** of a layout: `base`, `shift`, `altgr` (macOS Option),
  `shift_altgr`, and `command` (the layout's own Command level, which the
  Windows emulation uses for Ctrl/Alt/Win chords). `caps` is not a source
  layer: it is derived (the Shift cell for a cased letter, the base cell for
  everything else) and can be overridden key by key.
- **A cell** is nothing, a text of 1 to 8 code points, or a dead key. A dead
  key carries its whole state machine (actions, terminator, the states it
  enters), renamed `<source>__<name>` so two sources never collide. Dead keys
  compose by **character**, not by position: for every text cell of the
  composed layout, each dead state the layout can reach gets the composition
  its source defines for that character (the rule `_KLE_BuildCompositions` of
  the Windows emulation already applies). QWERTY letters under an AZERTY `^`
  therefore still produce `ê`.
- **Reference sources.** The registry holds Ergopti and Ergo-L only, so the
  model also offers two built-in reference sources, `qwerty` (US) and `azerty`
  (French, with its `^` and `¨` dead keys), as plain data
  (`reference_layouts.js`). Registry ids and reference ids share one namespace
  (`[a-z][a-z0-9_]*`); the registry may not use `composed`, the composition's
  own id.
- **The declaration**:

```json
{
	"schema_version": 1,
	"name": "My layout",
	"keycode_convention": "iso",
	"layers": {
		"base": { "source": "qwerty" },
		"shift": { "source": "azerty" },
		"altgr": { "source": "ergopti" },
		"shift_altgr": { "source": "ergol" }
	},
	"shortcuts": {
		"default": { "source": "qwerty", "layer": "base" },
		"ctrl": { "source": "ergol", "layer": "command" }
	},
	"overrides": {
		"base": {
			"KeyQ": "x",
			"KeyW": null,
			"KeyE": { "copy": { "source": "ergol", "key": "KeyA", "layer": "altgr" } }
		},
		"ctrl": { "KeyZ": "z" }
	}
}
```

A layer entry takes the same-named layer of `source`, or another layer of
it with `"layer"`. An override is a text (1 to 8 code points), `null` (the
key types nothing) or a `copy` of any cell of any source (the way to put a
dead key by hand). Shortcut modifiers are `meta` (Win/Cmd), `ctrl` and
`alt`; each takes its own entry, else `shortcuts.default`, else the composed
base layer. A shortcut cell is a text only: a dead key in a chord types
nothing, as in the shared vectors.

- **Validation** is one pure function returning stable problem codes (never
  prose): unknown source or layer, unknown key, output too long or containing
  control characters, ambiguous composition (two different results for one
  character in one dead state), empty base layer. The page maps codes to the
  `layout_composer.problem.*` locale keys; serialization refuses an invalid
  composition (fail fast).

## Serialization to `.keylayout`

One modifierMap, eight keyMaps, mutually exclusive selectors (so the first
match is the only match, on macOS and in the Windows/Linux readers):

| index | level       | `modifier keys`                     |
| ----- | ----------- | ----------------------------------- |
| 0     | base        | (empty)                             |
| 1     | Shift       | `anyShift caps?`                    |
| 2     | Caps        | `caps`                              |
| 3     | AltGr       | `anyOption caps?`                   |
| 4     | Shift+AltGr | `anyShift anyOption caps?`          |
| 5     | Win/Cmd     | `command anyShift? caps?`           |
| 6     | Ctrl        | `anyControl anyShift? caps?`        |
| 7     | Alt         | `anyOption command anyShift? caps?` |

Keys outside the 49 of the table are not written. The `id` is derived from the
name (a stable negative number, like the Ergopti files), `maxout` from the
longest output.

## How each driver consumes it

The composition has the reserved registry-shaped id `composed`. The registry and
the reference layouts may not use it (`tools/build/build-layouts-index.cjs`
refuses it); the id, the `layout_composer` folder of the configuration folder
and the bounds are declared once in the `composer` table of
`_shared/modules/layouts/defaults.json`. A driver stores `composition.json` as
sent and installs the compiled file as an installed layout of that id, with a
record entry built from the file (size, SHA-256, keycode convention, name), so
the picker, the verified local copy, the uninstall and the selection work on it
like on a registry layout. The page lives in the layout manager window, opened
by "Compose a layout…", and speaks three more host messages: `composer_open`
(answered by `composerData`: every verified registry layout as a source, the
stored declaration, whether the composition is in use, and `shortcuts`
"full" or "single"), `composer_save` (declaration, keylayout, use) and
`composer_remove`; the answer is `composerResult`. The hosts re-check what the
page sends (bounds, schema, name, map set) and never trust it.

- **Windows.** `[layout] emulated_layout = "composed"` (an existing key, so no
  new switch: the default `""` keeps the composer dormant). The emulation
  reads the verified copy and the convention from the record. It looks the
  Ctrl, Alt and Win chords of the layout `composed` up in their own keyMap
  (6, 7, 5) and falls back to the Command level when the layout selects none;
  every other layout still types all chords from its Command level, so Ergopti
  and Ergo-L type exactly as before. Boot never downloads `composed`. The host
  is `windows/ui/layout_manager/composer.ahk`.
- **macOS.** The file is installed as a system input source by the code that
  installs a registry layout (`macos/modules/keymap/layout_registry.lua`,
  `install_local`). Karabiner is not involved: the system types the layout. No
  file of `macos/platform/remap/` is touched. As for an updated registry
  layout, macOS may read a rewritten file only after the input source is
  toggled or the user logs in again.
- **Linux.** The file goes through the converter the registry layouts use
  (`static/ergopti/linux/xkb_generation`, `linux/modules/keymap/layout_registry.lua`,
  `install_local`, with a one-layout index written next to the copy). XKB has
  one level for every chord modifier (Level5 of `ERGOPTI_SEVEN_LEVEL`), which
  the converter fills from the keyMap the Command modifier selects, here the
  composer's Win/Cmd map. The composition's Ctrl and Alt layers do not exist
  there: the host sends `shortcuts: "single"` and the page locks those rows and
  says why.

## What exists already, and how it relates

- **Number-row and row switches** (`layout.emulate_number_row`, `emulate_top_row`,
  `emulate_home_row`, `emulate_bottom_row`, `direct_access_digits`,
  `layout_rows_policy.*`): they narrow an emulation row by row between the
  Ergopti layers and the OS layout. They stay as they are; they cannot take one
  level from another layout, which is the point of the composer.
- **Layer editor** (`_shared/ui/layer_editor`): edits the _navigation_ layer
  (what a held key does), a different thing; the composer reuses its page
  mechanics (host bridge, legends from the active layout, locale files) and
  nothing of its data.
- **Layout manager** (`_shared/ui/layout_manager`): installs and selects
  registry layouts; the composer reads the same bundled and installed files as
  sources, and selecting the composition goes through the same
  `emulated_layout` write.

## Tests

- Node (`tools/test/test-layout-composer-model.cjs`): the reader against the
  shared `keylayout_vectors.json`, identity compositions of Ergopti and Ergo-L
  against the source layout, mixed compositions, dead-key composition across
  sources, overrides, shortcuts, validation, and a round trip of every
  serialized composition through the reader.
- Per driver, all replaying the shared corpus: Windows AHK (`test_layout_composer_host.ahk`), the shared Lua contract (`_shared/lua/test/layout_composer_contract.lua`) run by the macOS and Linux registry tests, and the converter test `test_composer_corpus.py` (WSL, `python3 -m unittest`).

## The Debug check

The Debug menu's `composer_check` row (« Test the composed layout », declared
once for the three drivers in the shared menu manifest) installs the small
composition shipped in `_shared/modules/layouts/composer_check/`
(`composition.json`, and `composed.keylayout` generated by
`npm run codegen:layout-composer-check` from the built-in reference layouts)
through the composer's real save path and reports one line per step:

| step               | meaning                                                                                                                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `composer_fixture` | the shipped files are readable                                                                                                                                                                                                         |
| `composer_mode`    | `fresh`, or `existing` when a composition is already stored, installed or in use                                                                                                                                                       |
| `composer_install` | the host accepted and installed it (skipped when existing)                                                                                                                                                                             |
| `composer_copy`    | the installed copy still matches its record                                                                                                                                                                                            |
| `composer_ready`   | the host can type it. Windows: the emulation's reader accepts it (`KeylayoutEmulation_Check`). macOS: the input source is enabled. Linux: the installer verified the XKB layout (`not_reprobed` for a composition that already exists) |
| `composer_cleanup` | a fresh run removed what it installed (skipped when existing)                                                                                                                                                                          |

The check never overwrites a user's composition: when one exists it is only
verified. It selects nothing and reloads nothing. The result is one evidence
record (`check=composer verdict=... steps=N id=state:value ...`, values from a
closed grammar, never a path or a name) and a window with a « Copy report »
button. The steps live in `windows/ui/layout_manager/composer_check.ahk` on
Windows and in `_shared/lua/layouts/composer_check.lua` on macOS and Linux
(`_shared/lua/test/composer_check_contract.lua` replays them over each
registry).

## What needs a person

Typing the composed layout on a real keyboard on each OS (the compiled file is
proven by the readers and by the shared vectors; the system or hook that
delivers keys is not). The Debug check above reports whether the host accepted
the layout; a person still has to type with it. On macOS the system may read a
rewritten file only after the input source is toggled or the user logs in again.
