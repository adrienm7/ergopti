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
| `lua_runner.js`    | Runs the shared Lua export adapter (`_shared/layouts/engine/composer/source_export.lua`) in the vendored fengari VM (`vendor/fengari-web.js`, Lua 5.3), the module list the host fetches included, for the XKB conversion and the canonical `.keylayout` reading the KLC needs.                                                                                                                                                                                                                                                                                  |
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
  (`_shared/layouts/engine/manager_bridge.lua`) routes them to the registry's `source_open` / `source_save`, which use
  `_shared/layouts/engine/composer/source_store.lua`. The host answers `window.sourceData({text, filename, folder})` and
  `window.sourceResult({ok, code, detail, filename})`. Files go to `layout_sources/` of the configuration folder
  (bounds in `_shared/layouts/data/defaults.json` `[source]`); saving never installs or selects a layout.
  « Install and use » sends `composer_save` with `source`, the compiled `.keylayout` for the host's OS, the
  source's `emulation` table for that OS (`LayoutSourceIO.emulationTable`; none for a preserved import) and
  `use: true`: the composer host (`_shared/layouts/engine/composer/composer.lua`) stores it, replaces any composition, installs
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
- **ErgoptiPlus, Windows.** Done on 2026-11-12 as planned in [Windows host](#windows-host): `init.ahk` accepts
  every action of the page (`source_pick` is refused there, WebView2's own file chooser opens files) and sends
  `source_editor`, `emulate` and `nav_apply`; the layout editor's strings travel with `sourceData`, since this host
  does not seed `window._i18n_strings`; `source_store.ahk` keeps the files; `composer.ahk` takes the source form of
  `composer_save` and `composer_emulate`; `kbd_register.ahk` is the elevated helper (`kbd_register_core.ahk` holds
  its steps behind ports; the compiled driver runs them with `--kbd-register`); `keylayout_emulation.ahk` reads the
  composer copy and performs the emulation table through `source_emulation.ahk`. Left: retire the composer section
  (`layout_composer/composer_page.js` and its markup) now that no host shows it, and the maintainer's checks on a PC
  (install, type, uninstall).

## Windows host

Plan for the maintainer (WebView2 host, AutoHotkey), written so it lands in one pass. The shared parts it calls are
done and tested on macOS and Linux: the page, the message contract below, the emulation table, the composer
folder layout and `tools/kbd-dll.cjs`. Decided by the coordinator on 2026-11-11, to review by the maintainer.

**Message contract** (the page sends these on the WebView2 channel exactly as on `layout_manager_bridge`):

| Action                   | Payload                                                      | Host answer                                                                      | Refusal codes                                                                                                         |
| ------------------------ | ------------------------------------------------------------ | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `source_open`            | —                                                            | `sourceData {text, filename, folder}` (the last saved source, else `text: null`) | —                                                                                                                     |
| `source_save`            | `{filename, text}`                                           | `sourceResult {ok, code, detail, filename}`                                      | `source_invalid_file`, `write_failed` (`source_store.lua`)                                                            |
| `source_pick` (optional) | —                                                            | `sourcePicked {filename, text} \| {} \| {code, detail}`                          | as `source_save`                                                                                                      |
| `composer_save`          | `{source, keylayout, emulation?, use: true, dll_name, dlls}` | `composerResult {action, ok, code, detail, used, pending}`                       | `invalid`, `write_failed`, `use_failed`, `install_failed`, `elevation_refused`, `foreign_layout`, `profile_not_added` |
| `composer_emulate`       | `{source, keylayout, emulation?}`                            | `composerResult {action: "composer_emulate", ok, code, detail, used}`            | `invalid`, `write_failed`, `emulate_not_saved`, `emulate_failed`                                                      |
| `composer_remove`        | —                                                            | `composerResult {action, ok, code, detail}`                                      | `write_failed`, `uninstall_failed`                                                                                    |
| `nav_save`               | `{text}`                                                     | `navResult {saved, applied, errors}`                                             | the layer editor's codes                                                                                              |

`initData` then carries `source_editor: true`, `emulate: true` and `nav_apply: true`. The checks are the shared
composer's (`_shared/layouts/engine/composer/composer.lua` `check_source` and `check_emulation`): the source is TOML of format
`ergopti-layout` version 1, the `.keylayout` is named after `exports.macos.internal_name` or the layout id, the
emulation table compiles and names the source's layout and `windows` as its platform (the page compiles one per
host platform; `LayoutSourceIO.emulationTable(doc, "windows")`). Bounds and file names come from
`_shared/layouts/data/defaults.json` `[composer]` (`layout_source.toml`, `layout_source.keylayout`,
`layout_source_emulation.json`) and `[source]`.

**Files and functions.**

1. `windows/ui/layout_manager/init.ahk`: add `source_open`, `source_save`, `nav_save`, `composer_emulate` (and
   `source_pick` if WebView2's chooser is not enough) to `LAYMGR_ACTIONS`; the three flags in the `initData` that
   `LayoutManager_HandleMessage` pushes on `ready`; `LayoutManager_OpenEditor()` = `LayoutManager_Open()` then, once
   `ready` arrives (`_LayMgrWeb_OnNavigationCompleted` / the page's `ready`), the same answer as `source_open`. Then
   empty `windowsPending` in `tools/test/test-layout-manager-page.cjs`.
2. `windows/ui/layout_manager/source_store.ahk` (new): the rules of `_shared/layouts/engine/composer/source_store.lua` (file
   name `^[a-z][a-z0-9_]*\.(toml|keylayout)$`, at most `max_name_length`, UTF-8 text at most `max_file_bytes`, folder
   `layout_sources\`, `last_file`), replaying its Lua tests' cases.
3. `windows/ui/layout_manager/composer.ahk`: `LayoutComposer_Handle` gains the source form of `composer_save` and
   `composer_emulate`. Both store the three files in `layout_composer\` and delete `composition.json`.
   - `composer_emulate` installs nothing: it writes `[layout] emulated_layout = "composed"` and
     `ergopti_base = true` (the leaves `_LayMgrWeb_SelectionOperations` already writes for a registry choice) and
     reloads the emulation.
   - `composer_save` stages the DLL images the page sent and registers them through the elevated helper (below),
     then switches to the layout.
4. `windows/modules/keymap/keylayout/keylayout_emulation.ahk`: in `KeylayoutEmulation_Boot`, when the id is the
   composer's and `read_local` fails, read `layout_composer\layout_source.keylayout` (what `read_composed` does on
   macOS and Linux) instead of logging « save it again »; and perform `layout_source_emulation.json` for what the
   `.keylayout` cannot hold (tap-holds, layer holds, multi-character outputs): an AHK port of
   `_shared/layouts/engine/composer/source_emulation.lua`, tested by replaying `_shared/tests/corpus/layouts/source/
emulation_vectors.json` like `test-layout-source-emulation.cjs` does.
5. `windows/ui/layout_manager/kbd_register.ahk` (new): the elevated helper below, `install <staging dir>` and
   `uninstall <dll>`.
6. Menu: in `_shared/menu/data/menu.toml` row `open_layout_editor`, drop `platforms`, `unavailable` and `reason_key`
   (and the locale key `platform_reason.layout_editor_is_on_the_website_on_windows`); in `windows/menu/ui/builder/menu_init.ahk`
   bind `Commands[MenuCommand.OPEN_LAYOUT_EDITOR] := LayoutManager_OpenEditor` next to `LAYOUT_MANAGER` (line 700).

**Installing from Windows.** No Node, no NSIS, no clang on the user's PC. The page writes the four DLL images itself
(`_generated/kbd_dll_writer.js`, the repository tool's compiler-free writer, proven equal to the clang images in
[layout-windows-dll.md](layout-windows-dll.md#what-is-proven-and-how)). On a host whose `initData` platform is
`windows`, `composer_save` adds `dll_name` and `dlls: {x86, wow64, x64, arm64}`, each the image in base64
(`LayoutSourceIO.installPayload`). The host checks each image before anything is elevated: decoded size at most
1 MiB, an `MZ` header, and `dll_name` matching `^[a-z][a-z0-9]{0,7}$` (the model's DLL name rule) and equal to the source's `exports.windows.dll_name`.

1. **Staging (unprivileged, `composer.ahk`).** Decode the four images into
   `%LOCALAPPDATA%\Ergopti\layout_composer\dll\<dll>\<arch>\<dll>.dll`, and write `request.json` there:
   `{action: "install", dll, text, lcid, company}`. The text, the LCID and the company come from the stored source's
   `exports.windows`, the same fields `tools/lib/kbd-dll/source.cjs` reads.
2. **Elevation.** `RunWait('*RunAs "' A_AhkPath '" "' A_ScriptDir '\ui\layout_manager\kbd_register.ahk" "' Staging
'"')`. This is the one UAC prompt. A refused prompt (`RunWait` throws, or exit code 1223) answers
   `composerResult {ok: false, code: "elevation_refused"}`.
3. **`kbd_register.ahk install` (elevated, new file).** The same steps as the NSIS installer of
   `tools/lib/kbd-dll/installer.cjs`, in this order:
   - Read `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\Ergopti_kbd_<dll>` `KLID`. When present, it is
     an upgrade: keep that KLID and its `Layout Id`.
   - Otherwise, take the first free KLID `a0nn<lcid>`, with `nn` from `01` to `ff` and no `Layout File` under
     `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\<KLID>`. The `Layout Id` is one above the largest
     `Layout Id` of every key there, as 4 hexadecimal digits.
   - Copy the images with `DllCall("Wow64DisableWow64FsRedirection")` around the System32 copy:
     - ARM64 Windows: `arm64` into `%WINDIR%\System32` and `wow64` into `%WINDIR%\SysWOW64`;
     - x64 Windows: `x64` into System32 and `wow64` into SysWOW64;
     - 32-bit Windows: `x86` into System32.
     - The machine comes from `IsWow64Process2` (native machine `0xAA64`, `0x8664`, or none).
   - Write `Layout File` = `<dll>.dll` (REG_SZ), `Layout Text` = text (REG_SZ), `Layout Display Name` =
     `@%SystemRoot%\system32\<dll>.dll,-1000` (REG_EXPAND_SZ) and `Layout Id` (REG_SZ) under the KLID key.
   - `DllCall("input\InstallLayoutOrTip", "WStr", "<LCID upper>:<KLID>", "UInt", 0)`. A zero return is reported
     as `profile_not_added`; the layout is installed and can be added in Settings.
   - Write the uninstall entry: `DisplayName`, `Publisher` (the company), `KLID`, `NoModify` = 1, `NoRepair` = 1,
     and `UninstallString` = `"<AutoHotkey>" "<...>\kbd_register.ahk" uninstall <dll>`.
   - Write `result.json` `{ok, code, klid}` next to `request.json`; exit 0 on success, 1 on failure.
4. **Switching (unprivileged).** Read `result.json`, then call `LoadKeyboardLayoutW("<KLID>", KLF_ACTIVATE)` and post
   `WM_INPUTLANGCHANGEREQUEST` with that HKL to the foreground window. Answer `composerResult {ok, used: true}`.
5. **Already installed.** The uninstall entry `Ergopti_kbd_<dll>` holds the KLID. A `Keyboard Layouts` key whose
   `Layout File` is `<dll>.dll` but no entry is someone else's layout: refuse with `foreign_layout` and never
   overwrite it, as the Linux host refuses a file it does not own.
6. **`kbd_register.ahk uninstall <dll>` (elevated, from `composer_remove` or Settings → Apps).** The NSIS uninstall
   section:
   - `InstallLayoutOrTip("<LCID>:<KLID>", ILOT_UNINSTALL = 1)`.
   - The current user's `HKCU\Keyboard Layout\Substitutes` values whose data is the KLID, and every
     `HKCU\Keyboard Layout\Preload` value naming that substitute or the KLID.
   - The KLID key.
   - The DLLs in System32 and SysWOW64. When one is still loaded, `MoveFileEx(path, 0,
MOVEFILE_DELAY_UNTIL_REBOOT)` removes it at the next start.
   - The uninstall entry.
   - `result.json` as above.

`tools/kbd-dll.cjs build … --writer pe` remains the developer's route to the same images plus a signed-or-not
NSIS installer for distribution ([layout-windows-dll.md](layout-windows-dll.md#signing-maintainer)).

**Tests to add (AHK).**

- The actions list (the page test above).
- `source_store.ahk` against the Lua store's cases.
- The composer's source save and emulate: files written, `composition.json` gone, `[layout]` leaves written, the
  emulation reloaded.
- The emulation's composer-folder fallback.
- The emulation vectors replayed through `keylayout_emulation.ahk`.
- The menu row bound and enabled.
- The « already installed » and « foreign layout » detection on a fake registry, the KLID and Layout Id allocation,
  and `kbd_register.ahk`'s install and uninstall steps against a fake registry and file system (the helper's
  `DllCall`s and registry writes injected), each step in the NSIS script's order.
- The staged images: the base64 of `installPayload(doc, "windows")` decodes to the bytes
  `test-layout-editor-model.cjs` proves equal to the tool's.
- A manual check on a PC: install, type, uninstall, as in [layout-windows-dll.md](layout-windows-dll.md).

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
