<!-- docs/design/layout-generator-kbdedit-parity.md -->

# Layout editor: KbdEdit parity target

Maintainer request of 2026-11-06, part of the « Layout generator from an Ergopti TOML source » project in `TODO.md`.
Ergopti's layout editor must offer every capability of [KbdEdit](http://www.kbdedit.com/) (Windows layout editor,
release 26.10.0), or better, in a modern, free, online interface that also runs locally inside ErgoptiPlus.

## How Ergopti goes further

- **One complete source.** The layout lives in an Ergopti TOML file, a superset of every target (decided
  2026-11-06), because a `.keylayout` cannot hold Kana, Roya, Loya, physical remapping or alternative-key
  shortcuts. A `.keylayout` imports without loss and exports.
- **Every OS, not only Windows.** The TOML generates macOS (bundle ISO + ANSI by default, or one variant), Linux
  XKB, Windows (`.klc`, DLL, unsigned installer for x86, x64 and ARM64) and the emulation tables of the three
  drivers and the web. KbdEdit has no Linux output and a lossy macOS conversion.
- **Emulation where the OS cannot.** When a target format cannot express a feature (more than 15 Windows modifier
  positions, ligatures from dead keys, non-BMP dead-key results, left/right Shift distinction, togglable extra
  levels), the ErgoptiPlus driver emulates it, as the AutoHotkey driver already does. The export never drops a
  mapping silently: it lists, per target, what is native, what is emulated and what is impossible.
- **Free, online and local.** The same editor page is a tab of the Svelte site and a webview page of ErgoptiPlus on
  Windows, macOS and Linux; no edition tiers.
- **Tested output.** Each target is checked against shared golden vectors, as the composer corpus does today.
- **Clean-room.** Take ideas from KbdEdit and kalamine, never their code; write each generator from the formats'
  own documentation.

## Editor status (2026-11-11)

The [unified layout editor](layout-editor.md) covers, on the site and in the macOS and Linux layout manager:
extra modifier levels (user modifiers, held or locked, and layers that require them), shortcuts sending another
chord, per-key Caps Lock modes (unaffected, Shift, separate layers), dead keys with chains, terminators and
multi-character results, ligatures, numpad and media keys, physical remapping, tap-holds, a Unicode palette
(blocks and code-point entry), printable stickers (four levels per key), a live typing preview and undo/redo.
Added the same night: drag and drop between keys (swap, Ctrl copies), copy/paste of a mapping, ISO/ANSI board,
locating a character, exact sticker size, Caps Lock + AltGr, Windows virtual keys, layout flags and NLS
functions, compiled `.keylayout` and bundle exports, and filling a layer from another layout. Unicode 17.0 name
search (words, `*` and `?` wildcards, glyph, `U+XXXX`, aliases, adjustable cap of 1000) and the character
magnifier (glyph, code points, names, block, Copy) on hovered keys, palette cells and results. Still open against
this inventory: auto case mapping, sticker per-block visibility, keyboard types beyond ISO/ANSI, XKB/KLC exports in the browser
and the Windows DLL.

## Capability checklist (2026-11-11)

Each capability of the inventory below, checked against the unified editor and the generator. « Editor » names the
element of `layout_editor/editor_page.js` that offers it; « Windows » marks what only the maintainer's Windows host
or build can deliver.

| KbdEdit capability                                                  | Ergopti status                                                                                                                                     |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Extra modifier levels (Kana, Roya, Loya, more than 15 positions)    | Done: user modifiers held or locked (`le-modifiers`), any number of layers; the compiler reports per target what it emulates.                      |
| Active/unused combinations, reorder, remove with confirmation       | Done: layer tabs, add/remove layer (refused while referenced).                                                                                     |
| Uses AltGr, SHIFTLOCK, LRM-RLM, KANALOK flags                       | Done: Windows layout flags (`le-win-flags`), Caps Lock + AltGr per key (`le-caps-altgr`); applied by the KLC generator (Windows DLL: maintainer).  |
| Low-level VK / scan-code remapping, disable a key                   | Done: physical remap (`le-remap`), disabled mapping, Windows virtual key per key.                                                                  |
| Drag and drop swap, Ctrl+drop copy, clipboard copy/paste            | Done: board drag and drop, `le-copy` / `le-paste`, Ctrl+C/V on a key.                                                                              |
| Move all keys between modifier positions                            | Done (2026-11-11): « Move every key of this layer » (`le-move-all`), move or copy.                                                                 |
| Shortcuts bound to another key than the typed character             | Done: shortcuts sending another chord (`le-shortcut`), emulated by the drivers.                                                                    |
| Physical key names                                                  | Done: key name per key (`le-key-name`).                                                                                                            |
| Caps Lock modes (unaffected, as Shift, separate SGCAPS)             | Done: per-key Caps mode and its layers (`le-caps`).                                                                                                |
| CAPLOKALTGR                                                         | Done: per-key Caps Lock + AltGr.                                                                                                                   |
| Dead keys, chained dead keys, terminators, rename, delete           | Done: dead-key panel (`le-dead-keys`), chains through `next`, multi-character results (beyond KbdEdit's single BMP character).                     |
| Compose emulation                                                   | Done: chained dead keys, and the Linux XCompose export.                                                                                            |
| Import dead tables from another layout                              | Done: fill a layer from a catalogue or registry layout, dead keys included (`le-fill`).                                                            |
| Ligatures (multi-character output)                                  | Done: any text on a key, no 9-character limit.                                                                                                     |
| Numpad, media keys, mouse-key VKs                                   | Done for numpad and media keys (board numpad toggle, media chips); mouse keys are not a layout feature on macOS/Linux and stay Windows-native.     |
| NLS special functions, alternative VK                               | Done: NLS entries (`le-nls-*`); compiled into the Windows KLC/DLL only (Windows: maintainer).                                                      |
| .klc import, .kbe                                                   | `.keylayout` imports losslessly; KLC import is not offered (Windows-only format; the source TOML replaces KBE).                                    |
| .keylayout import (bundle or file) and export                       | Done: exact import, bundle/ISO/ANSI export following the macOS drop-down (`le-macos-format`), native load checked on a CI Mac.                     |
| DLL build, registration, installer package, language bar            | Windows (maintainer): the KLC from `export-all` feeds the DLL and installer; macOS and Linux install through ErgoptiPlus (« Install and use »).    |
| Auto-map upper/lower case, overwrite option                         | Done (2026-11-11): « Fill the other case on the Shift layer » and « Replace a mapping already there » (`le-auto-case`, `le-case-overwrite`).       |
| Locate a character                                                  | Done: `le-locate`.                                                                                                                                 |
| Unicode palette, subranges, jump by code                            | Done: palette blocks, glyph and code-point entry.                                                                                                  |
| Unicode search by name with wildcards, character magnifier          | See the editor status above.                                                                                                                       |
| Sticker map: per-level visibility, hide case duplicates, exact size | Done (2026-11-11): « Levels on the stickers » and « Hide a Shift legend that is only the capital » (`le-sticker-levels`); fit or exact size in mm. |
| Live preview, clickable keys, lock lights                           | Done: typing preview with held modifiers and dead keys.                                                                                            |
| Undo/redo                                                           | Done: unlimited snapshots (`le-undo`, `le-redo`).                                                                                                  |
| Keyboard types ISO, ANSI                                            | Done: board form selector and both compiled variants.                                                                                              |
| Keyboard types JIS 109, ABNT, Typematrix                            | Left: the JIS/ABNT keys (Yen, Ro, Henkan, Muhenkan, Kana, keypad comma) are not in `physical_keys.json`, which the Windows driver parses at boot.  |
| Login screen, UAC, Windows upgrade restore                          | Windows only; not applicable on macOS and Linux.                                                                                                   |

## KbdEdit capability inventory

Paraphrased from the KbdEdit manual and release notes. « (premium) » marks features that KbdEdit sells only in its
paid editions; Ergopti offers all of them for free. Windows-only notions (VK codes, NLS functions, KLID) map to the
nearest native mechanism on each OS, or to driver emulation.

### Shift states and modifiers (incl. Kana/KanaLok and custom levels)

- Six modifiers exist: Shift, Ctrl, Alt, plus the exotic Kana, Roya and Loya. (premium/personal)
- Each layout can activate up to 15 modifier positions, a limit set by Windows. The theoretical maximum is 48 valid combinations, because Alt without Ctrl is invalid. Older versions allowed only 10. (premium/personal)
- Modifier combinations are split into "active" (editable in the high-level view) and "unused" lists. Entries move between lists with arrow buttons or by double-click. Base is always active and always first.
- Removing an active combination deletes its mappings, after a confirmation prompt.
- Reordering the active combinations only changes display order. The mappings stay with their modifier position.
- Each modifier has an enable checkbox. Enabling one auto-enables every modifier before it in the list (Shift, Ctrl, Alt, Kana, Roya, Loya), but you can leave the unneeded combinations inactive.
- Disabling the Alt modifier does not remove Alt shortcuts. Fully disabling a modifier key requires removing its VK code from the physical keys.
- "Uses AltGr" flag: shows Ctrl+Alt as AltGr, and Right Alt then acts as Ctrl+Left Alt.
- SHIFTLOCK flag: Caps Lock can then be turned off only by pressing Shift, and Shift is no longer inverted while Caps is on.
- LRM-RLM flag: Left Shift+Backspace emits U+200E and Right Shift+Backspace emits U+200F, for bidirectional text.
- Kana is togglable when mapped to VK_KANA (a system-wide on/off state, like Caps Lock). It is momentary when mapped to another VK such as VK_OEM_8.
- KANALOK flag per key: for togglable Kana, a key's Kana mappings take effect only if the flag is set. The flag is auto-set whenever the key has a non-empty Kana mapping, and a menu can clear, set or auto-set it for all keys. A color marker shows it. (premium/personal)
- Roya and Loya are fixed to VK_OEM_FJ_ROYA and VK_OEM_FJ_LOYA. They are independent modifiers, so Roya, Loya and Roya+Loya are three distinct positions. (premium/personal)
- AltGr can be replaced by non-togglable Kana, Roya or Loya, to avoid clashes with application Ctrl/Alt hotkeys.
- Kana, Roya and Loya were ignored by UWP apps before Windows 10 20H2.
- The CTRL position is not recommended as a general modifier. It clashes with app shortcuts, and Windows turns Ctrl+letter into ASCII control codes. Edit it only to produce control characters.
- A key mapped to a modifier VK that has no physical key effectively turns the modifier off. KbdEdit does not check for this.

### Virtual-key / scan-code remapping and Ctrl/Alt shortcuts independent of the typed character

- The low-level editor assigns any VK code to any physical key (scan code plus extended flag). (premium/personal)
- Keys can be swapped by drag and drop. Ctrl+drop copies instead of swapping. A VK can also be set from a combo box, a right-click menu, or the clipboard.
- The right-click VK menu is split into mappable/non-mappable and free/in-use lists, with 10 sub-lists each.
- VK\__none_ disables a key. One VK can be mapped to several physical keys (for example both Return keys).
- Any key, including Shift, Caps Lock and Num Lock, can be moved. Only Pause, with its Ctrl+Pause quasi-key (scan 0x46 ext, "Break"), is hard-wired.
- Windows shortcuts bind to VK codes, not typed characters. Ctrl+V stays on the VK_V position even when that key types another script.
- Non-mappable keys (F-keys, navigation, media/web, modifiers) can be made character-producing by first giving them a free mappable VK.
- Physical keys can carry a human-friendly name. It is informational only and used by games and similar software.
- Mouse-button quasi VKs (VK_LBUTTON and others) can be assigned to keys but have no effect. VK_ICO_00 types "00" and cannot take a Unicode mapping.
- Right-clicking a non-editable key still shows the popup. Activating a key not shown in the UI works by pressing it on the physical keyboard.
- A reference list gives about 200 VK codes with hex values, split into mappable and non-mappable.

### Caps Lock behaviours (SGCAPS, per-level)

- "Effect of Caps Lock" per key has three modes: unaffected; same as Shift (inverts Shift for Base/Shift only); separate mapping for Caps (SGCAPS-style, giving "caps on" Base and Shift slots).
- A separate Caps mapping can be used, for example, for the Czech digit row, where Caps gives capitals without disturbing Shift.
- Separate Caps mappings now allow ligatures in the "caps off" state (since 26.02). They still cannot take dead keys or ligatures on the affected Base/Shift positions in multi-alphabet tricks.
- CAPLOKALTGR flag: with Caps on, AltGr and AltGr+Shift swap, and so does any combination containing AltGr (for example Roya+AltGr). It is auto-set when AltGr+Shift is mapped, can be bulk-set, and has a color marker.
- Caps Lock same as Shift also applies to numpad keys, and CAPLOKALTGR does as well.
- Caps on/off plus togglable Kana gives a tri-alphabet keyboard (Caps off+Kana off, Caps on+Kana off, Kana on).
- Plain Caps Lock can be repurposed, for example to Kana, while Ctrl+Caps keeps the Caps function (via NLS alternative VK).
- Preview shows Caps/Num/Scroll lock state with a lit key.

### Dead keys, chained dead keys, compose

- The dead character table (triplets of dead, base, result) is edited in the dead-char editor. (premium/personal)
- Standard dead chars come from a filterable list of nearly 100 Unicode diacritics (multi-select supported), with a preview. A dropped palette character is also accepted. Unicode-aware standard transformations are auto-filled.
- Non-standard dead chars start with a single space-to-self pair.
- Transformation pairs can be added by dropping characters, deleted (the list must keep at least one), and edited by hex code, clipboard, drag-drop or typing. NUL is allowed in the from/to fields.
- Chained dead chars: the "Into" of a pair can be another dead char, so sequences such as Circumflex then Tilde give a double accent. Only root nodes need a key mapping, and the others are reached by chaining. (premium/personal)
- Switching an Into to "Chained" offers to create the missing dead char on the fly, and navigation menus move between parents and children.
- The dead char's own Unicode value is editable. Existing key mappings follow the change, and a collision opens a resolve dialog (replace or merge, with a conflict choice).
- Deleting a dead char turns its key mappings into normal ones.
- Dead char names are descriptive only, but they become macOS state names on keylayout export.
- A dead key mapped in the key dialog can be created on the fly ("[new]").
- Dead tables can be imported from another installed layout. They can also be exported to or imported from a KLD file, which is a trimmed KLC in UTF-8/16. Import can replace or merge, with a conflict policy. (premium/personal)
- Limitation: dead keys work only on single BMP characters. They cannot yield ligatures or non-BMP characters.
- Dead-key preview shows a tooltip of the pairs, and an active dead key re-labels the keyboard with the combined results.
- Compose emulation: a "Compose" dead key at a Scroll Lock position (VK_EXECUTE), plus 55 private-use dead chars (E000-E036) chained to give Linux-style sequences.

### Ligatures (multi-char output)

- A key position can emit a sequence of up to 9 characters (non-BMP counted as one). Ligatures are drawn in red. (premium/personal/lite)
- A ligature editor offers a length spinner, a preview, a right-to-left reading-order option and an editable field per character.
- Characters can be entered by hex (including 6 digits), drag-drop, clipboard or typing, with Home/End/Delete/Backspace working.
- Dropping a word onto a key offers a choice between a ligature and its first letter.
- Non-BMP characters are internally ligatures of surrogate pairs, and the UI hides this.
- Characters F000-F002 are reserved placeholders and cannot be mapped.

### Numpad, mouse keys, media keys

- VK_NUMPAD0-9 and VK_DECIMAL switch to navigation functions with NumLock off. They remain normally mappable (any Unicode, dead key, ligature) with NumLock on, wherever they are assigned.
- Shift on numpad inverts NumLock instead of acting as a modifier, so those Shift slots are read-only. They become editable with Caps-same-as-Shift or CAPLOKALTGR.
- Numpad VKs can be put on any physical key to emulate a keypad.
- Mouse Keys function assignments (VK_CLEAR for click, the arrow-like keys, and so on) are shown in the low-level editor by a grey mark and tooltip. Layout customisations are preserved, but not editable yet.
- Web/media VKs can be remapped to other keys, for example to a numpad (copy with Ctrl+drag), or turned into character keys.

### NLS special functions (togglable states, CapsLock/AltGr sharing, simulated keys)

- Per key and per Shift/Ctrl/Alt combination, an NLS function can override the usual output. All 8 combinations are available, not only the active ones. (premium/personal)
- The simple mode, "Alternative VK code", makes a key emit another VK under chosen modifier combinations, for example VK_APPS from Ctrl+OEM_2. Shift/Ctrl/Alt cannot be used as the produced VK.
- The advanced editor offers 15 NLS function types (No Event, Send Base VK, Send Param VK, Kana Lock, Alpha Num, Hiragana, Katakana, Sbcs-Dbcs, Roman, Code Input, Help or End, Home or Clear, Numpad, Kana Event, Conv or Non-conv). Param VK is used by two of them.
- Alternative key-up functions ("keydown switches to alternative keyup") give separate key-up behaviour and reduce stuck keys.
- Togglable Roya/Loya is simulated through the alternative key-up trick: key-up sends the opposite modifier's key-up. Untoggle combinations use other Ctrl+key pairs.
- Caps Lock and AltGr/Kana share one key: the key sends VK_OEM_8 (Kana), and Ctrl+key sends VK_CAPITAL.
- Limits: the Ctrl/Shift/Alt "down" state cannot be suppressed, which makes cursor and function keys poor candidates. The original key can stick if the release order is wrong.
- Existing FE layouts (KBDJPN, KBDKOR) keep their NLS functions and mouse keys when edited. Japanese/Korean shadow-DLL registration via i8042prt is not supported, and NEC/Fujitsu layouts cannot be edited.

### Import/export formats (.klc, .kbe, macOS .keylayout, dead-key tables)

- KBE is KbdEdit's own interchange/backup format. It is platform independent (32 or 64-bit) and can live anywhere. Exporting is not allowed in Player. (premium/personal/lite)
- Import of a KBE creates and registers a new DLL. A Save As step resolves name clashes, auto-suggesting "name #1".
- KLC import reads MSKLC source files (UTF-8, UTF-16 LE/BE, MSKLC 1.4 blocks) with syntax checks, and uses KBD and LOCALEID to prefill the attributes. It avoids MSKLC's dead-key DLL bugs. Non-BMP characters become surrogate ligatures.
- KLC import does not auto-fill case equivalents.
- Mac .keylayout import accepts a bundle (picking a layout) or a single file, plus a layout Id choice. (premium/personal)
- Import maps Caps Lock either "best effort" (Caps plus a Kana fallback) or fully to togglable Kana, and Option to AltGr and Cmd to Roya (Right Ctrl replaced only when Roya is needed). It selects a US or ISO physical type (not JIS).
- Import is limited by Windows: 15 positions, no left/right Shift distinction, dead-key ligatures truncated to the first character, no non-BMP in dead keys, no `<terminators>`. The NBSP+combining heuristic is applied. Chaining works.
- Mac .keylayout export (since 24.7) preserves single and ligature mappings, non-BMP characters, Caps behaviours and dead/chained transformations. (premium/personal)
- Export maps Shift, AltGr to Opt and Ctrl to Ctrl (Kana to Cmd, weak). It drops Roya/Loya, low-level changes, NLS and unreachable dead pairs. State names come from the dead-char names.
- Installing on a Mac: copy to ~/Library/Keyboard Layouts/ (or /Library/Keyboard Layouts/ for all users), then log out and in. The layout appears under "Others".
- Characters `< > ' " &` and chained dead chars were fixed in the export (24.12).
- KLD dead-table import/export (see Dead keys). Layout DLLs from other tools can be registered.

### Building, DLL, installer packages, architectures, registration, language bar, admin deploy

- Save builds a PE layout DLL in System32 (plus a Wow64 copy in SysWOW64 on x64) named KbdEdit\*.dll, and registers it under HKLM\...\Keyboard Layouts with a new KLID (highest digit B). (premium/personal/lite)
- Save As sets the layout text, locale and DLL name. Default naming auto-increments (US #1, KbdEditUS_1.dll), and "Base on layout" borrows attributes.
- System and non-KbdEdit layouts cannot be overwritten. Save falls back to Save As, with an explanatory prompt.
- Editing a layout that is loaded may need a log off/on to take effect, and a warning says so.
- Save failures list the processes locking the DLL (taskhostw and similar).
- Save As prompts to replace the original layout in the language bar.
- Locale search finds locales by name, BCP 47 tag, or LCID. It supports custom locales without an LCID (for example eo, sga-Ogam), a history, and copying of name/code/native name/LCID.
- Register Layout DLL lets you attach an existing or foreign DLL under a new name/locale, with a "show only unregistered" filter. Warnings cover the 32-bit copy and DLL corruption. This is also how a layout from a newer Windows can be borrowed.
- Delete keyboard layout unregisters a KbdEdit layout, optionally deletes the DLL (only if it is not shared), and refuses layouts still in the language bar.
- Manage Language Bar list adds, removes, reorders, and sets a default layout, and can place one layout under several locales. Its tree supports layouts per locale. IME entries are preserved but not manageable. Windows 8+ language list sync and Ctrl+Shift stepping are noted.
- Premium: Generate Layout Install Package creates a standalone EXE installer for x86, x64 and ARM64 (since 20.8). It needs no KbdEdit on the target, offers Install/Reinstall/Uninstall, an "Add to language bar" checkbox and UAC elevation. (premium)
- Installer file naming matters because the DLL name is the identity for upgrades.
- Windows 10 upgrades wipe layout registrations. KbdEdit (19.8+) restores them from Windows.old\...\config, with duplicate checks and DLL-existence checks. (all editions)
- Custom layouts work on the Windows 8/10/11 login screen. Fixes cover code-integrity alerts and US fallback at first login on Windows 11 (26.10).
- A registered-to reminder popup appears when a Personal/Lite/Player layout is activated, rate-limited to once an hour, with a "don't show" checkbox.
- KbdEdit needs Administrator rights and elevates via UAC. The MSI contains x86, x64 and ARM64 builds, with signed binaries (since 20.6). Windows XP and Server 2003 support was dropped.
- Layout DLL payload limits were raised repeatedly ("layout too complex" / "saving failed" errors).
- Uninstalling KbdEdit makes layouts built by Personal/Lite/Player fall back to US English.

### Editor UX (drag and drop, Unicode palette, search, char magnifier, sticker map, preview, printing, undo/redo, clipboard)

- Four main views: High level, Low level, Dead char, Preview, plus Sticker map. The window is resizable (1.5.0) and an option can keep the keyboard's aspect ratio.
- High-level editing methods: drag and drop (Ctrl copies, plain drop swaps), clipboard (Cut/Copy/Paste with type retention, shortcuts Ctrl+X/C/V and others), the key-mapping mini dialog, typing a character from the active layout, and the right-click menu.
- A "move all keys" drop moves all mappings between modifier positions in one operation.
- Drop from other apps is allowed (words give a ligature choice). It works only from elevated apps, so the clipboard is the workaround.
- Auto-map upper/lower case: assigning a lower-case letter also fills its upper-case Shift partner (and the reverse, also for Caps positions). "Overwrite non-empty mappings" is optional.
- Popup hints offer case-equivalent suggestions in the context menu. Locate (middle click) finds the character in the palette.
- Key mapping dialog: Empty, Normal (hex or Unicode name search), Ligature, Dead key; the old mapping is kept when switching type.
- The "current key" zone shows all modifier positions (scrolls beyond 10), with a "Caps on" row and clickable headers.
- Character magnifier shows a large glyph, code and name for the hovered key/field/palette entry, and supports Copy. It appears on High level, Dead char, Preview and Ligature views.
- Unicode palette: 16/32 columns, subrange filtering, jump by hex code, previous/next mapped character, previous/next subset, subset menu, and Ctrl+Space/F/arrows/Enter shortcuts. It is a drag source and target, with flash preview and a tooltip.
- Palette color-coding marks normal mappings, ligature use, dead chars (mapped or chained), transformed and produced characters, which helps spot redundancy. A right-click lists all mappings and jumps to them, and the character can be looked up on the web (unicode.org, compart.com, fileformat.info, unicode-table.com).
- Subrange dialog: active/inactive lists, sorting, add/remove all, "adjust to fit layout" (default on open, optional), and named subranges to save, rename and delete.
- Unicode search: by name, glyph or hex, with `*` and `?` wildcards, a result cap (default 1000, adjustable), an "include inactive subsets" toggle, and a history. Current-subrange hits come first, results can be sorted and copied, and keyboard navigation works from the box.
- Unicode data has advanced to version 18.0.0.
- Font selector for key captions (live preview). Special glyphs are shown for NBSP, LRM and similar, and bigger fonts for non-BMP.
- Sticker map generator: per-block visibility, a cell matrix with free placement of modifier positions, rules for hiding duplicates and case equivalents (Shift/Caps/AltGr/Kana), color overrides for non-mappable and dead keys, and graphical symbols for special keys. A reset to default is available. (premium/personal/lite)
- Sticker printing: fit to page, or exact key size in mm across several pages (each cap whole), via the standard print dialog, with landscape as default. Printing is not available in the Demo edition; Player can print but not customise.
- Preview: tests the current layout live in a text box (Undo/Redo, New and Open still work there). On-screen keys can be clicked to simulate physical presses, which helps with keys the hardware lacks. NumLock/Shift change numpad display.
- Undo/Redo: unlimited multi-level history shared by all views, with descriptive labels (Ctrl+Z/Y, Alt+Backspace, Alt+Shift+Backspace).
- Options: keyboard type (see Hardware), aspect ratio, auto-complete toggles, open default layout at startup, auto-reset palette, font.
- Context help on F1 (pages open in a browser), and help works inside dialogs. A manual index is installed locally.
- Tooltips on key buttons show mapping type, code and name.

### Hardware/keyboard types

- Drawn keyboard variants: Big Return/small Backspace, mid Return/big Backspace, small Return/big Backspace.
- ABNT (Brazilian) with 3 sub-types and the extra ABNT_C1/C2 keys.
- BigKeys LX, Japanese 109 (5 extra keys), and Typematrix 2030 (101/102/106-key modes).
- NEC PC-98 keyboards are not supported.
- Dvorak and Colemak positions can be done via VK remapping. Mac Boot Camp key swaps are possible.

### Editions (free/lite vs premium differences)

- Demo (free): all editing features and Preview, KBE export/import, KLC import, and Manage Language Bar. No DLL saving, no new layouts, no register/delete, no sticker printing. Demo KBE files carry restrictions.
- Premium: everything, including Generate Layout Install Package and standalone installers. (premium)
- Personal (formerly "Full"): everything except install-package generation. Deploying elsewhere needs a Player on each target.
- Lite: high-level editing only (characters, ligatures, existing dead chars to existing modifier positions). No low-level or dead-char edits, no Mac export, no install packages. It imports Premium/Personal KBEs and Demo KBEs without low-level changes.
- Player: read-only deployment of KBE/KLC/DLL (registered layouts) and sticker printing. No editing, no export (KBE or Mac), no packages, and no Demo KBE import.
- All editions cover 32-bit, 64-bit and ARM64 Windows. Pre-1.1 Personal/Demo KBEs cannot go into Lite/Player.

### Stated limitations

- Windows only (it edits the registry and System32). Admin rights are required, and UAC prompts are normal.
- A maximum of 15 modifier positions. Ligatures are limited to 9 characters.
- Dead keys cannot give ligatures or non-BMP characters.
- Ctrl-based mappings are unreliable. Alt cannot be used alone as a modifier.
- Kana, Roya and Loya are ignored by UWP apps before Windows 10 20H2.
- IME layouts and the Japanese/Korean shadow DLLs cannot be created or registered. NEC/Fujitsu layouts cannot be edited.
- Mouse-key customisation is not editable. Mac conversion is lossy (see import/export).
- The Pause key's VK cannot be changed, and mouse-button VKs do nothing.
- Edits to a layout currently loaded may need a re-login, and old layouts need a re-save to get DLL fixes.
- Multiple layouts under one locale make switching clunkier.
- Windows 10 upgrades drop registrations. Windows.old must still exist to restore them exactly.

### Examples worth supporting

- ex01 Swap Caps Lock and Ctrl by dragging the VKs in the low-level view.
- ex02 Disable the Windows keys by assigning VK\__none_ (Start menu remains on Ctrl+Esc).
- ex03 Map web/media keys onto the numeric keypad using Ctrl+drag copies.
- ex04 Give web/media keys mappable VKs and type Greek letters on them.
- ex05 English/French in one layout, with togglable Kana on Scroll Lock and KANALOK keys.
- ex06 Serbian Latin/Cyrillic via togglable Kana, using a second KbdEdit instance as the drag source.
- ex07 French improved (Galeron): separate Caps mapping for accented capitals, AltGr extras, AltGr+Shift, numpad fractions, circumflex-to-superscripts.
- ex08 Russian phonetic (two variants) plus US English on Kana.
- ex09 Bulgarian phonetic plus US English on Kana.
- ex10 Colemak with Caps/Backspace swapped, and AltGr dead keys.
- ex11 Hindi/English on a Windows-key Kana toggle, with F-keys and navigation keys remapped to Devanagari letters.
- ex12 Tri-lingual Serbian Latin (Caps off), Cyrillic (Caps on) and Greek (Kana on).
- ex13 German AltGr replaced by non-togglable Kana (VK_OEM_8 on Right Alt).
- ex14 Hebrew/English with a Scroll Lock Kana toggle.
- ex15 French multilingual (Galeron): adds Vietnamese/Pinyin/African characters using Kana as extra positions.
- ex16 Absent from the manual set.
- ex17 Linux-style Compose key via chained dead keys (Scroll Lock/VK_EXECUTE, 56 dead chars, imported KLD table).
- ex18 US layout with all Latin accents: 26 single and 36 double accents from 26 chained dead keys on AltGr positions.
- ex19 Mac Boot Camp: swap Alt and Win, and turn the right Win into a right Ctrl.
- ex20 Simulate the Context-menu key as Ctrl+VK_OEM_2 using the NLS alternative VK.
- ex21 German layout with Kana on the Caps key and Caps Lock on Ctrl+key, which frees Right Alt (also adds the capital sharp S).
- ex22 Togglable Roya/Loya simulated through NLS key-up functions for a tri-lingual layout, keeping Caps Lock free.
- ex23 Sanskrit with Vedic extensions: Devanagari on Base/Shift and Vedic Extensions plus Devanagari Extended on Kana/Shift+Kana, with a toggle on Print Screen.
