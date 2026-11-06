<!-- docs/tooling/windows-keyboard-layout.md -->

# The Ergopti Windows keyboard layout

Windows installs Ergopti as a system layout from a keyboard DLL generated from the
same `.keylayout` macOS and Linux install (`static/layouts/registry/ergopti/`). The
approach is kalamine's (`kalamine`, MIT): the layout becomes the C tables of a
keyboard DLL, compiled with MSVC and the Windows SDK's `kbd.h`; MSKLC is not used.

## Sources: generated, tracked

`npm run codegen:windows-keyboard-layout` reads the layout through the shared Lua
parser and writes `kbdergop.c`, `.h`, `.rc` and `.def` to
`static/ergopti_plus/windows/native/keyboard_layout/_generated/`. Never edit them:
change the `.keylayout` or `tools/codegen/lib/windows-keyboard-layout.cjs`, then
regenerate. The DLL name, language and Windows labels come from
`_shared/modules/layouts/windows_system_layout.json`.
`tools/test/test-windows-keyboard-layout-codegen.cjs` fails when the tracked sources
drift and pins what the conversion may do:

- each Windows column is the keyMap the layout's modifierMap selects (base, Shift,
  AltGr, Shift + AltGr); the Ctrl columns stay empty;
- a virtual key follows the letter the key types, so Ctrl+C is on the key typing c.
  Windows keys characters by virtual key, so the macOS Command keyMap's left-hand
  shortcuts cannot be expressed;
- multi-character outputs are ligatures; a dead-key sequence whose key or result is
  longer than one UTF-16 unit is named in the generated header, never dropped
  silently; a Caps Lock that is neither "none" nor "like Shift" is refused.

The MSKLC source of the same layout, for a maintainer who wants to open it in MSKLC
or KbdEdit, is a build output: `node tools/codegen/codegen-windows-keyboard-layout.cjs
--klc <folder>` writes `kbdergop.klc` there (UTF-16LE, CRLF, as MSKLC reads it).

## DLLs: built, never tracked

`tools/build/build_windows_keyboard_layout.ps1` (Windows, Visual Studio with the
x64/x86 and ARM64 C++ tools and a Windows SDK) compiles `amd64`, `arm64`, `x86` and
`wow64` (x86 with 64-bit table pointers, `BUILD_WOW6432`, for SysWOW64) into
`static/ergopti_plus/windows/vendor/keyboard_layout/<build>/kbdergop.dll` with a
`build_receipt.json`. `-PackagePath <zip>` also writes the stand-alone package. CI
runs it in the Windows package job before the static bundle, so the compiled
`ErgoptiPlus.exe` ships the DLLs; a source run without them shows
« not built into this copy » in the menu.

## Install: unsigned, through UAC

The installer is unsigned by maintainer decision (2026-11-06).
`vendor/keyboard_layout/install_keyboard_layout.ps1` runs elevated: it copies the
builds into System32 and SysWOW64 and registers the layout under the first free
`A0nn040C` KLID. `add_user_keyboard_layout.ps1` then adds it to the user's
languages, as the user. The driver runs both from Layout > « Install the Ergopti
system layout » and switches to the layout; `Ergopti_windows_layout.zip` (CI
artifact `ergopti-keyboard-layout-windows`, `install.cmd`) runs the same two
scripts without the driver. `tools/test/test-windows-keyboard-layout.ps1` installs
the build on the CI runner, asks `ToUnicodeEx` what keys type and removes it.

The release still publishes the KbdEdit-made `Ergopti_windows.exe` as the
stand-alone layout asset; replacing it with the generated package is a release
decision left to the maintainer.
