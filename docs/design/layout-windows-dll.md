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
| `kbd-dll/pe-writer.cjs` | The same four images with no toolchain: the emitter's rows laid out as its C structures, the resources, exports, relocations and checksum written directly.         |
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
- `modifier_vks` (optional): the virtual key holding Kana, Roya or Loya when it is not the standard one, as
  KbdEdit's momentary Kana on `VK_OEM_8`; `scancodes_e0` (optional): `{sc, vk}` moves of E0 keys, such as Right Alt
  (E0 38) sending `VK_OEM_8`. The comparison checks `VK_TO_BIT` and the E0 table against them.

`kbd-dll/source.cjs` converts both ways between this model and the Ergopti layout source: `toSource` writes one
layer per column (`alt_right` for AltGr, `kana` for Kana), Caps Lock attributes as `keys.<code>.caps_lock` and
`caps_altgr`, moved virtual keys as `virtual_key`, key names on their physical key (or `windows.key_names` for scan
codes the registry has no key for) and the version texts in `exports.windows`; `fromSource` reads a source back,
Caps Lock layers read per column pair (a column and its Shift): unchanged, swapped (CAPLOK for the base pair,
CAPLOKALTGR for the AltGr pair), or any other change, the Kana columns included (kbd.h has no Caps Lock attribute
for Kana), held by a Caps Lock row (SGCAPS) for every column; a Caps Lock row cannot hold a dead key or a ligature,
nor sit beside a dead key, and such a source is refused. That SGCAPS rows apply to the Kana columns is to confirm
on Windows. The Kana level the KBDKANA column held by
`windows.kana_key` (Right Alt by default, through `VK_OEM_8`: decided by the coordinator on 2026-11-11, to review by
the maintainer), and lists what Windows has no key or column for. `tools/test/test-layout-sources.cjs` proves
`static/layouts/sources/bepo.toml` gives back the official `bepo.klc` table for table and that the four DLLs of
bépo and of Ergopti (Kana included) read back as their tables.

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

The compiler-free writer (`pe-writer.cjs`, `kbd-dll.cjs build … --writer pe`) is proven against the clang image of
every one of those models, and of the layout sources' DLLs in `test-layout-sources.cjs` (bépo, bépo 1.1rc2's chained
dead keys, Ergopti's Kana, CAPLOKALTGR, SGCAPS Kana), on all four images:

- the reader's `trace` (every value it reads from the tables, in order, each pointer as the table it names) is equal,
  so the tables are byte for byte the same wherever each image places them;
- the logical layout, machine, pointer width, wow64 flag, ordinal and subsystem are equal;
- every resource leaf (string 1000, the version resource) is byte for byte llvm-rc's;
- both images carry a correct PE checksum. A changed table byte changes the trace (negative control).

The files themselves differ: lld-link adds a reproducibility debug entry and places sections and tables its own
way, which the loader does not read. Decided by the coordinator on 2026-11-11, to review by the maintainer: the
Windows host may build with `--writer pe`, so a user's PC needs no compiler.

KbdEdit parity: this is limited to what is proven above. KbdEdit's own packages (`.kbe` and its installers) are
encrypted; they were not decrypted, so no structural comparison with them was made.

## Installer

`kbd-dll/installer.cjs` writes the NSIS script of a standalone, unsigned installer and builds it with `makensis`
(Linux: `tools/ci/ubuntu_apt.py -y nsis`); `kbd-dll build` writes `<dll>-setup.exe` and `installer.nsi` beside the
images. It is never run here: `tools/test/test-kbd-installer.cjs` extracts it with 7-Zip, requires exactly the four
verified images, and checks the script.

- **Files:** System32 gets the native image (x86, x64 or ARM64, file-system redirection off on 64-bit Windows);
  SysWOW64 gets the wow64 image on 64-bit Windows, for 32-bit applications. Windows 10 or later, administrator.
- **Registration:** `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\<KLID>` with `Layout File`,
  `Layout Text`, `Layout Display Name` (`@%SystemRoot%\system32\<dll>.dll,-1000`, expandable) and `Layout Id`, one
  above every installed one. The KLID is the first free `a0nn<LCID>`, kept in the uninstall entry and reused on an
  upgrade. The input profile is added with `InstallLayoutOrTip("<LANGID>:<KLID>", 0)` (input.dll), so the text
  services list it as any layout.
- **Uninstall:** `InstallLayoutOrTip(..., ILOT_UNINSTALL)`, the current user's `Substitutes` value naming the KLID
  and the `Preload` values naming it or that substitute, the KLID key, the files (at reboot when still loaded) and
  the uninstall entry. Other users' `Preload` lists are not edited: Windows drops a layout whose KLID is gone.
- Decided by the coordinator on 2026-11-11, to review by the maintainer: NSIS (free, builds on Linux, small stub)
  rather than WiX or Inno Setup; unsigned, as the request states.

## Signing (maintainer)

The images and the installer are unsigned. Windows loads unsigned keyboard layout DLLs (MSKLC's are unsigned too),
but an unsigned `<dll>-setup.exe` downloaded from the Internet meets SmartScreen's « Windows protected your PC »
until it has reputation, and a corporate proxy may detonate it as an unknown (see
[windows-exe-flagged-by-proxy.md](../tooling/windows-exe-flagged-by-proxy.md)). The project's Windows signing is
decided in [signpath-foundation-application.md](../tooling/signpath-foundation-application.md): unsigned until
SignPath Foundation is on, then SignPath, or the PFX secrets `WINDOWS_SIGNING_CERTIFICATE_BASE64` and
`WINDOWS_SIGNING_CERTIFICATE_PASSWORD` the Windows release job already reads. For these artifacts:

1. **What to sign, in order.** Each DLL first (x86, wow64, x64, arm64: the installer embeds them and a later
   signature would change bytes the reader verified), then the uninstaller NSIS writes, then the installer. Sign
   with SHA-256 and an RFC 3161 timestamp, so the signature outlives the certificate.
2. **On Windows** (signtool from the Windows SDK):
   `signtool sign /fd SHA256 /f cert.pfx /p <password> /tr http://timestamp.digicert.com /td SHA256 <file>`, then
   `signtool verify /pa /v <file>`.
3. **On Linux** (CI or this tool): `osslsigncode sign -pkcs12 cert.pfx -pass <password> -h sha256
-ts http://timestamp.digicert.com -in <file> -out <file>.signed`, then `osslsigncode verify -in <file>.signed`.
   A certificate kept in a hardware or cloud key (EV certificates must be) is used through its own signer
   (`jsign` with the provider's key store, Azure Trusted Signing's `signtool` dlib, or SignPath's GitHub action),
   never as a file in the repository or the build log.
4. **NSIS hooks.** NSIS 3.08+ runs a signing command on the uninstaller and on the installer at build time:
   `!uninstfinalize 'osslsigncode sign … -in "%1" -out "%1.signed" && mv "%1.signed" "%1"' = 0` and
   `!finalize '…' = 0`; `installer.cjs` would add them when the build is given a signing command, and read the
   images after signing, so the comparison and the 7-Zip check run on the signed bytes.
5. **SmartScreen.** An EV certificate (or SignPath's) carries reputation at once; an OV certificate builds it with
   downloads. Keep one publisher name across releases, and submit a flagged build through Microsoft's file
   submission ([windows-exe-false-positive-submission-pack.md](../tooling/windows-exe-false-positive-submission-pack.md)).
6. **Check on Windows:** right-click → Properties → Digital Signatures shows the publisher and the timestamp for
   each DLL in System32/SysWOW64 after install and for the installer; `Get-AuthenticodeSignature <file>` answers
   `Valid`.

## Not done here

- Native loading on Windows (x86, x64, arm64, and the wow64 image read by a 32-bit application), the installer run
  itself, and the stability of the text-services process (ctfmon) with the layout in use need a Windows machine.
  On ARM64 Windows, whether x64-emulated applications load the ARM64 image is also to confirm there.
- Which DLL fields old KbdEdit packages (bépo 1.1rc2, 2018) got wrong cannot be read here: their payloads are
  encrypted and were not decrypted.

## Windows check (maintainer)

1. On Windows 11 (x64, and ARM64 if available), run `npm run kbd-dll -- build static/layouts/sources/bepo.toml
build/kbd-dll/bepo` (or take the CI artifact) and install `bepo-setup.exe` as administrator.
2. Settings → Time & language → Language & region: the layout « Bépo » is listed under French; select it.
3. Type in Notepad (64-bit) and in a 32-bit application (for example `%WINDIR%\SysWOW64\notepad.exe` if present, or
   any 32-bit program): every level, AltGr, and the dead keys (^ then e gives ê; a dead key followed by space gives
   its character).
4. Use the layout for a day, then Event Viewer → Windows Logs → Application: filter on source « Application Error »
   and check that no fault names `ctfmon.exe` (or names the layout DLL) since the install.
5. Repeat with `kbdergop-setup.exe` from `static/layouts/sources/ergopti.toml`: Right Alt holds the Kana level.
6. Uninstall from Settings → Apps; check that `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts` no longer
   holds the `a0nn040c` key, that `HKCU\Keyboard Layout\Preload` and `Substitutes` name it nowhere, and that the
   DLL is gone from System32 and SysWOW64 after a reboot.
