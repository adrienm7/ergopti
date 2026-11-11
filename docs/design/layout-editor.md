<!-- docs/design/layout-editor.md -->

# Unified layout editor

The layout editor of the « Layout generator from an Ergopti TOML source » project (`TODO.md`). One page edits every
layer of the [Ergopti layout source](layout-source-format.md) and runs unchanged on the website and inside
ErgoptiPlus. It follows the maintainer decision « One layout editor for every layer »
(`docs/memory/maintainer-decisions.md`): it is built on the existing models, never as a parallel editor.

## Modules

All under `static/ergopti_plus/_shared/ui/layout_editor/`, classic scripts that run in a page and in a Node `vm`.

| File               | Owns                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_io.js`     | The only module that touches the format: TOML through the vendored smol-toml (`vendor/smol-toml.js`, pinned by digest), validation through `LayoutSource` (`layout_composer/source_model.js`), structured import, `.keylayout` compilation of both variants and the per-target report through the shared generator `LayoutSourceCompiler` (`layout_composer/source_compiler.js`, key tables in `_generated/key_tables.js` from `codegen-layout-editor-tables-js.cjs`), the approximate fallback through the composer reader, `layers.toml` through `LayerModel`. |
| `editor_model.js`  | Pure edits returning a new validated document, refusals with stable codes, layer selection by held modifiers, the typing simulation behind the live preview, undo/redo snapshots.                                                                                                                                                                                                                                                                                                                                                                                |
| `editor_page.js`   | The DOM: toolbar, layer tabs, the physical board (`LAYER_EDITOR_DATA` geometry, numpad, media keys), the key inspector, modifiers and dead-key panels, Unicode palette, preview, export report, printable stickers. `LayoutEditorPage.mount(root, host)`.                                                                                                                                                                                                                                                                                                        |
| `standalone.js`    | The website host: browser file picker, downloads, `?lang=` locale.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `lua_runner.js`    | Runs the shared Lua export adapter (`_shared/lua/layouts/source_export.lua`) in the vendored fengari VM (`vendor/fengari-web.js`, Lua 5.3), the module list the host fetches included, for the XKB conversion and the canonical `.keylayout` reading the KLC needs.                                                                                                                                                                                                                                                                                              |
| `toml_prelude.js`  | The `exports` object the unmodified vendored CommonJS file assigns to.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `unicode_names.js` | Decodes the generated Unicode names table: name, aliases and block of a code point, and the name search.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

A format change touches `source_io.js` and the format owner only; the editor shows the generator's per-target
report as it is.

## Hosts

« New » opens « Start from » (`startPanel`): a blank layout, QWERTY or AZERTY (`LAYOUT_COMPOSER_REFERENCE`), or a
copy of every layout the host lists (`loadSources`: the registry index on the site, `composer_open` in
ErgoptiPlus, so Bépo, Ergo-L and Ergopti). `LayoutSourceIO.startFrom` takes a registry `.keylayout` through the
generator's exact importer and falls back to its five character levels, listing what it drops; the copy is named
« My <layout> » with the id `<id>_custom`. The current system layout is not offered: no OS hands a page its active
layout as a file (Apple's built-in layouts have no `.keylayout`, an XKB keymap has no importer here, a Windows DLL
is read only by `tools/lib/kbd-dll/reader.cjs`), so the panel says to open its `.keylayout` or `.toml` instead.
Decided by the coordinator on 2026-11-11, to review by the maintainer.

- **Website.** `src/routes/editeur/+page.svelte` frames `layout_editor/index.html` served from `static/`.
- **ErgoptiPlus, macOS and Linux.** The layout manager window (`layout_manager/index.html`) loads the same scripts and
  mounts the editor when `initData` carries `source_editor: true`. The page posts `source_open` and
  `{action: "source_save", filename, text}` on `layout_manager_bridge`; the shared bridge
  (`_shared/lua/layouts/manager_bridge.lua`) routes them to the registry's `source_open` / `source_save`, which use
  `_shared/lua/layouts/source_store.lua`. The host answers `window.sourceData({text, filename, folder})` and
  `window.sourceResult({ok, code, detail, filename})`. Files go to `layout_sources/` of the configuration folder
  (bounds in `_shared/modules/layouts/defaults.json` `[source]`); saving never installs or selects a layout.
  « Install and use » sends `composer_save` with `source`, the compiled `.keylayout` for the host's OS, the
  source's `emulation` table for that OS (`LayoutSourceIO.emulationTable`; none for a preserved import) and
  `use: true`: the composer host (`_shared/lua/layouts/composer.lua`) stores it, replaces any composition, installs
  it as the `composed` layout and switches to it; its `composerResult` is routed back to the editor.
  « Emulate without installing » (shown when `initData` carries `emulate: true`) sends
  `{action: "composer_emulate", source, keylayout [, emulation]}`: the composer's `store` keeps the source, its
  compiled `.keylayout` (`keylayout_file`) and its emulation table in `layout_composer/` and installs nothing; the
  host's `emulate` port then makes `composed` the emulated layout as « Layout to emulate » stores it
  (`infra/layout_emulation_preferences.lua` `choose`) and reloads the layout emulation, which reads that copy
  (`layouts/emulation_settings.lua` `source`, `read_composed`) while the composed layout is not installed. No
  admin right, no input source; the layout types over the system one while ErgoptiPlus runs. Failures come back as
  `composerResult {action: "composer_emulate", ok: false, code}` with `emulate_not_saved` or `emulate_failed`.
  macOS binds the port from the menu (`ui/layout_manager` `set_emulation_applier`, it holds the preferences
  state); Linux binds it in `ui/layout_manager/bridge.lua`. Decided by the coordinator on 2026-11-11, to review by
  the maintainer.
  « Fill a layer from a layout » takes the host's `composer_open` sources (its `composerData` is routed to the
  editor too), so on these hosts the page hides « Compose »: the editor does the composer's job. macOS also sets
  `source_pick` in `initData`: the editor's « Open » posts `source_pick`, the host opens an `NSOpenPanel` limited
  to `.toml` and `.keylayout` (`infra/dialog_util.lua`), bounds the file with `SourceStore.read_picked` and answers
  `window.sourcePicked({filename, text} | {} | {code, detail})`. Linux keeps WebKitGTK's own file chooser.
  « Apply the navigation layer » (shown when the source has the `nav` layer and `initData` carries
  `nav_apply: true`) posts `{action: "nav_save", text}` with the `layers.toml` text `LayoutSourceIO.navLayerFile`
  builds; the shared bridge hands it to the host's `apply_nav`, which runs the navigation layer editor's own save
  (macOS `ui/layer_editor` `apply_text`: every OS's validation, the exact-byte publish against the `layers.toml` it
  reads now, the Karabiner regeneration and the wheel bindings; Linux `ui/layer_editor/bridge.lua` `apply_text`: the
  same save and the remap manager reload) and answers `window.navResult({saved, applied, errors})`. The navigation
  layer editor window keeps working: Windows still needs it. Decided by the coordinator on 2026-11-11, to review by
  the maintainer.
- **ErgoptiPlus, Windows (maintainer).** Until then the shared page shows the composer there.
  `windows/ui/layout_manager/init.ahk` needs `source_open`, `source_save` (and `source_pick` only if WebView2's own
  file chooser is not enough) in
  `LAYMGR_ACTIONS`, `source_editor: true` in its `initData`, and the store's rules: a plain lowercase file name
  `^[a-z][a-z0-9_]*\.(toml|keylayout)$` of at most `max_name_length` characters, non-empty UTF-8 text of at most
  `max_file_bytes`, written in `layout_sources\` of the driver's configuration folder, the last source name in
  `last_file`, results pushed as `sourceData` / `sourceResult` through the WebView2 `ExecuteScript` path the page
  already uses; `windows/ui/layout_manager/composer.ahk` needs to accept `composer_save` with `source` for « Install
  and use », and `nav_save` routed to the AHK navigation layer editor's save with `nav_apply: true` in `initData`
  for « Apply the navigation layer ». Then drop `windowsPending` in `tools/test/test-layout-manager-page.cjs`, and retire the composer
  section (`layout_composer/composer_page.js` and its markup) once no host shows it.

## Limits stated to the user

- An imported `.keylayout` stays verbatim (exportable unchanged) until « Convert to an editable source »: the
  generator's importer converts it exactly or refuses it; only after a refusal does the page offer « Convert
  approximately », which lists what it drops (sided modifiers, ANSI described on ISO, ambiguous compositions).
- The page downloads the source, `layers.toml`, a `.keylayout` per variant (ISO, ANSI) compiled in the browser and,
  on the site, the macOS bundle as one stored ZIP (`zip_writer.js`), the Linux XKB files as one stored ZIP (the
  `export-xkb` tree: symbols, `XCompose`, `xkb_types.txt`, `export.json`) and the Windows `.klc` (MSKLC bytes). The
  XKB and KLC downloads run the repository tool's own steps, byte for byte (`test-layout-editor-target-exports.cjs`):
  the shared target export (`layout_composer/target_export.js`, also loaded by `tools/lib/layout-source-xkb.cjs` and
  `layout-source-klc.cjs`), the shared Lua export adapter in fengari (the tool runs it with Lua 5.4 through
  `tools/lib/layout_source_export.lua`) and the tool's KLC generator wrapped verbatim
  (`_generated/klc_generator.js`, from `codegen-layout-editor-klc-js.cjs`). The site host (`standalone.js`) loads the
  VM, the Lua sources, the XKB data (`static/ergopti/linux/xkb_generation/data/`) and the generator on the first
  click only. The `.klc` needs the Windows metadata (language tag, LCID, DLL name) set in « Windows options ». The
  ErgoptiPlus hosts inline the page and cannot fetch these files, so they show a note pointing to the site instead:
  ErgoptiPlus installs the compiled layout itself. Each report row names its status, reason and the elements the
  target does not carry.
- A `layers.toml` binding using `primary` is written per OS on the way back (same effect on every OS, pinned by
  `test-layout-editor-model.cjs`); a sequence of several chords is refused.
- KbdEdit-style editing: drag a key onto another to swap (Ctrl copies), copy and paste a mapping, ISO or ANSI board,
  locate a character, exact sticker size. The palette searches characters by Unicode name or alias (every word must
  match; `*` any text and `?` one character inside whole words; a glyph or `U+XXXX`; a result cap of 1000 by
  default, at most 20000), and its results insert into the mapping or drop onto a key. The character magnifier
  shows the hovered or focused key legend, palette cell or result large, with each code point, its name and block,
  and copies it.
- The names are Unicode 17.0.0: `_generated/unicode_names.js` (418 KB, from `tools/codegen/codegen-unicode-names.cjs`
  over the files vendored in `tools/codegen/unicode/`) is decoded by `unicode_names.js`. The site loads the table
  lazily, beside the decoder, the first time a search or the magnifier needs a name; the layout manager page lists
  it among its scripts, because the macOS and Linux hosts inline the page and cannot fetch a file (decided by the
  coordinator on 2026-11-11, to review by the maintainer: inlining doubles the scripts the window injects, about
  410 KB to 830 KB, rather than add a host action that serves the table on demand).
- The macOS open panel and the install are not yet checked on a real Mac.
