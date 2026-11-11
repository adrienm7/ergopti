<!-- docs/design/layout-windows-dll.md -->

# Windows keyboard layout DLLs

Part of the « Layout generator from an Ergopti TOML source » project (`TODO.md`). `tools/kbd-dll.cjs` builds the
DLLs of a Windows keyboard layout from a KLC file or a kbd tables model on Linux, macOS or Windows, without MSKLC,
the WDK or KbdEdit, and proves each image by reading it back.

```sh
npm run kbd-dll -- build tools/test/fixtures/kbd-dll/bepo.klc build/kbd-dll/bepo   # four DLLs, sources, report
npm run kbd-dll -- model some.klc model.json                                     # the model only
npm run test:kbd-dll
```

The toolchain is LLVM 18: `clang`, `llvm-rc`, `lld-link` (`tools/ci/ubuntu_apt.py -y clang lld llvm`; the Common
unit lots install them).

## Pipeline

| Module                  | Owns                                                                                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kbd-dll/constants.cjs` | Virtual-key codes, modifier bits (Shift, Ctrl, Alt, Kana, Roya, Loya), attributes, `WCH_*`, `DKF_DEAD`, `KLLF_*`, the standard set 1 scan-code tables, system keys. |
| `kbd-dll/model.cjs`     | The kbd tables model (below) and `check`, which refuses an invalid model with a stable `kbd_*` code.                                                                |
| `kbd-dll/klc.cjs`       | `fromKlc`: MSKLC's KLC (UTF-16LE with BOM, or UTF-8) into the model.                                                                                                |
| `kbd-dll/emit-c.cjs`    | The C tables, the resource script and the module definition of a model.                                                                                             |
| `kbd-dll/build.cjs`     | clang, llvm-rc and lld-link for the four images.                                                                                                                    |
| `kbd-dll/reader.cjs`    | An independent PE and KBDTABLES reader: no code or constant shared with the emitter side.                                                                           |
| `kbd-dll/compare.cjs`   | The golden comparison of a read image with its model.                                                                                                               |

## The model

JSON, `format = "ergopti-kbd-tables"`, `version = 1`. Characters are UTF-16 code units, as the DLL stores them.

- `dll_name` (1 to 8 lowercase letters or digits), `layout_text`, `locale_name`, `lcid` (4 hex digits),
  `version_string`, `copyright`, `company`, `descriptions`, `language_names`.
- `flags`: `altgr` (KLLF_ALTGR), `shiftlock` (KLLF_SHIFTLOCK), `lrm_rlm` (KLLF_LRM_RLM).
- `columns`: the modifier-bit combination of each column, base (0) first. A bit is Shift 1, Ctrl 2, Alt 4, Kana 8,
  Roya 16 or Loya 32, so the Kana level is a column like AltGr (Ctrl+Alt, 6); up to 126 columns.
- `keys[]`: `vk`, `attributes` (CAPLOK 1, SGCAPS 2, CAPLOKALTGR 4, KANALOK 8), `cells[]` one per column, each
  `null`, `{char}`, `{dead}` (a declared dead key) or `{ligature: [units]}` (2 to 15 units, so a non-BMP character
  is its surrogate pair); an SGCAPS key adds `caps_cells[]`.
- `dead_keys[]`: `dead`, optional `name`, `rules[]` of `{base, result}`, `dead: true` when the result is another dead
  key (DKF_DEAD, chains of any depth).
- `scancodes[]`: the `{sc, vk}` moves of character keys; every other scan code keeps the standard table.
- `key_names`, `key_names_ext`: `{sc, name}`.

`fromKlc` follows MSKLC: KLLF_ALTGR when a column is Ctrl+Alt (6) unless an ATTRIBUTES section states the flags;
a DEADKEY result written `xxxx@` is a chain; a keypad scan code keeps its navigation virtual key.

## Structure decisions

Our own definitions of the kbd.h structures, written from Microsoft's documentation of `KBDTABLES` and its members;
each size is pinned by `_Static_assert` in the generated C and checked again by the reader.

- **Four images.** `x86` (32-bit Windows), `wow64` (the 32-bit copy a 64-bit Windows keeps in SysWOW64), `x64`,
  `arm64`. In kbd.h every table pointer is `KBD_LONG_POINTER`, 64 bits wide when the layout is built with
  `BUILD_WOW6432`; the wow64 image therefore stores each pointer as a 32-bit address and a zero word, 8-aligned,
  so its tables have the x64 layout. To confirm natively: that 32-bit applications on 64-bit Windows read this
  image.
- **Tables:** `KBDTABLES` (104 bytes with 64-bit pointers, 60 with 32-bit ones), `fLocaleFlags` =
  `MAKELONG(KLLF_*, KBD_VERSION = 1)`, `dwType = 4`; `MODIFIERS` with `VK_TO_BIT` and `ModNumber[wMaxModBits + 1]`
  (`SHFT_INVALID` for a combination without column); one main `VK_TO_WCHARS` table as wide as the columns, then the
  one-column keypad table last, as VkKeyScan expects; a dead key's cells are `WCH_DEAD` followed by a `0xFF` row
  holding the dead characters, an SGCAPS key by a `0xFF` row holding its Caps Lock characters; `WCH_LGTR` cells
  with `LIGATURE` entries (`nLgMax`, `cbLgEntry = 4 + 2 * nLgMax`); `DEADKEY` entries
  `{MAKELONG(base, dead), result, flags}`; `VSC_LPWSTR` key names and `pKeyNamesDead` strings (dead character then
  name); the 128-entry scan-code table with the standard E0 and E1 tables. The control keys (Tab, Backspace, Enter,
  Escape, Space, Cancel) and the keypad operators get the characters Windows' own layouts give them unless the
  layout defines them.
- **Export:** `KbdLayerDescriptor` at ordinal 1, undecorated on every architecture (a no-argument function, so
  `__stdcall` and `__cdecl` agree on x86).
- **Image:** no entry point, no CRT, subsystem native, `/release` checksum, `/Brepro` (reproducible bytes); every
  table const in `.rdata`, no writable section, base relocations for every table pointer. A version resource typed
  as a keyboard driver (VFT_DRV, VFT2_DRV_KEYBOARD) and the display name as string 1000, for a Layout Display Name
  of the form `@%SystemRoot%\system32\<dll>.dll,-1000`.

## What is proven, and how

`test-kbd-dll.cjs` builds the official `bepo.klc` (`tools/test/fixtures/kbd-dll`, CC BY-SA, see its NOTICE), the
KLC `export-klc` writes for the registry Ergopti (ligatures, Shift+Ctrl), a Kana/Roya model with a chained dead key
and a non-BMP ligature, and seeded random models, in all four images. For each image the reader:

- parses the PE headers, sections, exports and base relocations; finds the tables by decoding KbdLayerDescriptor's
  own instructions (x86 `mov eax, imm32; ret`, x64 `lea rax, [rip + d]; ret`, arm64 `adrp; add; ret`);
- requires every table pointer to land in a read-only initialized section, aligned, with the base relocation of its
  width, every list terminated inside its section, `cbSize = 2 + 2 * nModifications`, `cbLgEntry` against `nLgMax`,
  each column selected by exactly one modifier combination, `KBD_VERSION = 1`, `dwType = 4`, every dead cell,
  chain and dead name tied to a declared dead key;
- returns the logical layout, compared with the model: every key × column (Kana included) × dead key × chain ×
  ligature, the names, scan codes and keypad table. Every image of every model compares with no difference.

Negative controls: one changed character in an image is exactly one difference; a wrong machine or a missing export
is refused. Invalid models (undeclared dead key, reserved or out-of-range unit, too long ligature, duplicate key,
SGCAPS without its row, chain to nowhere, unknown modifier bit, too many columns) are refused before any build.

KbdEdit parity: this is limited to what is proven above. KbdEdit's own packages (`.kbe` and its installers) are
encrypted; they were not decrypted, so no structural comparison with them was made.

## Not done here

- The installer that copies the images and registers the layout is not generated by this tool.
- Native loading on Windows (x86, x64, arm64, and the wow64 image read by a 32-bit application), and the stability
  of the text-services process with the layout in use, need a Windows machine.
