<!-- docs/design/layout-editor.md -->

# Unified layout editor

The layout editor of the « Layout generator from an Ergopti TOML source » project (`TODO.md`). One page edits every
layer of the [Ergopti layout source](layout-source-format.md) and runs unchanged on the website and inside
ErgoptiPlus. It follows the maintainer decision « One layout editor for every layer »
(`docs/memory/maintainer-decisions.md`): it is built on the existing models, never as a parallel editor.

## Modules

All under `static/ergopti_plus/_shared/ui/layout_editor/`, classic scripts that run in a page and in a Node `vm`.

| File              | Owns                                                                                                                                                                                                                                                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_io.js`    | The only module that touches the format: TOML through the vendored smol-toml (`vendor/smol-toml.js`, pinned by digest), validation, capabilities and `.keylayout` export through `LayoutSource` (`layout_composer/source_model.js`), `.keylayout` import through the composer reader, `layers.toml` through `LayerModel`. |
| `editor_model.js` | Pure edits returning a new validated document, refusals with stable codes, layer selection by held modifiers, the typing simulation behind the live preview, undo/redo snapshots.                                                                                                                                         |
| `editor_page.js`  | The DOM: toolbar, layer tabs, the physical board (`LAYER_EDITOR_DATA` geometry, numpad, media keys), the key inspector, modifiers and dead-key panels, Unicode palette, preview, export report, printable stickers. `LayoutEditorPage.mount(root, host)`.                                                                 |
| `standalone.js`   | The website host: browser file picker, downloads, `?lang=` locale.                                                                                                                                                                                                                                                        |
| `toml_prelude.js` | The `exports` object the unmodified vendored CommonJS file assigns to.                                                                                                                                                                                                                                                    |

A format change touches `source_io.js` and the format owner only. The generator work (TOML compilers, bundle, DLL)
lands in `LayoutSource` and its tooling; the editor shows its per-target report as it is.

## Hosts

- **Website.** `src/routes/editeur/+page.svelte` frames `layout_editor/index.html` served from `static/`.
- **ErgoptiPlus, macOS and Linux.** The layout manager window (`layout_manager/index.html`) loads the same scripts and
  mounts the editor when `initData` carries `source_editor: true`. The page posts `source_open` and
  `{action: "source_save", filename, text}` on `layout_manager_bridge`; the shared bridge
  (`_shared/lua/layouts/manager_bridge.lua`) routes them to the registry's `source_open` / `source_save`, which use
  `_shared/lua/layouts/source_store.lua`. The host answers `window.sourceData({text, filename, folder})` and
  `window.sourceResult({ok, code, detail, filename})`. Files go to `layout_sources/` of the configuration folder
  (bounds in `_shared/modules/layouts/defaults.json` `[source]`); saving never installs or selects a layout.
- **ErgoptiPlus, Windows (maintainer).** `windows/ui/layout_manager/init.ahk` needs the same two actions in
  `LAYMGR_ACTIONS`, `source_editor: true` in its `initData`, and the store's rules: a plain lowercase file name
  `^[a-z][a-z0-9_]*\.(toml|keylayout)$` of at most `max_name_length` characters, non-empty UTF-8 text of at most
  `max_file_bytes`, written in `layout_sources\` of the driver's configuration folder, the last source name in
  `last_file`, results pushed as `sourceData` / `sourceResult` through the WebView2 `ExecuteScript` path the page
  already uses. Then drop `windowsPending` in `tools/test/test-layout-manager-page.cjs`.

## Limits stated to the user

- An imported `.keylayout` stays verbatim (exportable unchanged) until « Convert to an editable source », which
  lists what the projection drops (original XML, sided modifiers, ANSI described on ISO, ambiguous compositions).
- Edited layouts export only the source and `layers.toml` in the page: `.keylayout` compilation of edited mappings,
  the macOS bundle, the Windows DLL and the browser-side XKB/KLC exports wait for the generator; the report names
  each target's status and reason, and the CLI (`npm run layout-source -- export-xkb|export-klc`) exports admitted
  imports.
- A `layers.toml` binding using `primary` is written per OS on the way back (same effect on every OS, pinned by
  `test-layout-editor-model.cjs`); a sequence of several chords is refused.
- On macOS, `<input type="file">` in the Hammerspoon webview is not qualified: the editor reopens the last saved
  source through the host, and opening other files there needs a Mac check.
