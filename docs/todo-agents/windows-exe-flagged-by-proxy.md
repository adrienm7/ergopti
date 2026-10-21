<!-- docs/todo-agents/windows-exe-flagged-by-proxy.md -->

# ErgoptiPlus.exe v1.0.4 flagged by a corporate proxy (Netskope)

## Symptom

A tester behind a corporate Netskope proxy cannot download the v1.0.4 `ErgoptiPlus.exe`. The block
page says `ERR00: "ErgoptiPlus.exe" a peut-être été infecté par un virus`: an antivirus or threat
engine verdict on the file, not a size limit. v1.0.0 and v1.0.3 download fine.

## Evidence (static inspection of the release assets, never executed)

Asset sizes and SHA-256 (`gh release view <tag> --json assets`, `sha256sum`):

| Asset                          | Bytes    | SHA-256                                                          |
| ------------------------------ | -------- | ---------------------------------------------------------------- |
| v1.0.0 ErgoptiPlus.exe         | 10528256 | 54be80668a07f160c72bfa9d78d2bb502a0ffa455815a65cc6442f1966a2a7f8 |
| v1.0.1 ErgoptiPlus.exe         | 10718208 | af75fd5960fad0f94e8c5ca521701e6350926edf67d710eebac088bd2b786c71 |
| v1.0.3 ErgoptiPlus.exe         | 11195904 | 377f2939ec1556a6811c193e77f2eb1d7ebe659e6c200e89581c45261bd9735e |
| v1.0.4 ErgoptiPlus.exe         | 11403776 | a4ed8e50de44c4ec4116bdefeb7cb71c7feb54913cebfc837a9b433ce230ad13 |
| v0.0.0-dev.159 ErgoptiPlus.exe | 11408896 | (not hashed)                                                     |
| Ergopti_windows.exe, every tag | 1662976  | e7aaf0b9b4f485b4ee5ac3f9cecf95f3b26ecc5ce9989c0a7626305b1f409dc8 |

`Ergopti_windows.exe` is the layout installer. It is byte-identical in every release, so it is a
clean control for the release URL path.

PE comparison of v1.0.0, v1.0.3 and v1.0.4 (7-Zip PE resource listing):

- `.text`, `.rdata`, `.data`, `.pdata`, the manifest and the version resource are identical. The
  base is the same authenticated AutoHotkey v2.0.26 runtime (Ahk2Exe v1.1.37.02a2). None of the
  three is Authenticode-signed (stable Windows releases are unsigned by decision).
- The version resource carries only the runtime defaults (`FileVersion`/`ProductVersion` 2.0.26).
  It has no `ProductName`, `CompanyName`, `FileDescription` or product version. This did not
  change between releases, so it explains no delta, but it can raise a reputation score.
- Only two resources differ. `RCDATA/1` is the compiled script, stored as **uncompressed plain
  text**: 4976005, then 5539257, then 5702858 bytes. `RCDATA/BUILD/STATIC_BUNDLE.ZIP` is the
  runtime bundle: 4196115, then 4300767, then 4344787 bytes.
- Bundle: no new binary. `vendor/ergopti_network_pac.exe` changes hash in every release even
  though its sources did not change. The two copies differ in only 100 bytes (the PE timestamp
  and the debug-directory GUID), so the build is not reproducible. Every bundled `.ps1` that
  uses `Add-Type`/`DllImport` in v1.0.4 already did so in v1.0.3.
- Win32 APIs newly called from the script (`DllCall`/`DllImport` names, v1.0.3 to v1.0.4):
  `CountClipboardFormats`, `GetClipboardOwner`, `MultiByteToWideChar`, plus a new inline
  `user32.dll` (x5) and `gdi32.dll` P/Invoke block. Nothing else is new: the reload command channel,
  the menu replay, the CapsWord pointer watch and the curl tree owner add AHK logic only, and no new
  API surface.

## Ranked candidate triggers

1. **High: inline PowerShell clipboard grabber pattern, new in v1.0.4.** This is
   `_GestureScreenshotRegionSaveScript` in `static/ergopti_plus/windows/modules/gestures/screenshots.ahk`
   (commits `defb01f5c0`, `c7d6d1959d`, `f1de20560f`, `bd0f94b1a4`). It launches
   `powershell.exe -NoProfile -NonInteractive -Sta -WindowStyle Hidden -Command "..."` with
   `Add-Type -TypeDefinition` C# `[DllImport("user32.dll")] OpenClipboard/GetClipboardData/CopyImage`,
   `System.Windows.Forms`, `System.Drawing.Image::FromHbitmap` and a PNG saved under `%TEMP%`. The
   string `ErgoptiScreenshotClipboard` and the `DllImport`/`TypeDefinition` text appear in
   `RCDATA/1` only from v1.0.4 (0, 0 and 7 hits in v1.0.0, v1.0.3 and v1.0.4). A hidden PowerShell
   window that compiles P/Invoke to read clipboard images is a classic stealer stage. It is stored
   as plain text where every string scanner reads it.
2. **Medium: first-seen reputation of a new unsigned hash.** v1.0.4 was published on 2026-10-21 at
   06:38 Paris time, and the tester tried it the same day. Every release has a new hash, and an
   unsigned "first seen" file scores worse than one that is days old.
3. **Context (pre-existing, not the delta):** a module literally named `keylogger` (about 600 hits),
   `-EncodedCommand` launchers (crash report, updater), `-ExecutionPolicy Bypass`, hidden windows,
   `CopyFromScreen`. These were already present in builds that pass, but they raise the baseline,
   so a small new pattern can cross the threshold.
4. **Low:** the non-reproducible nested `ergopti_network_pac.exe` gives a new unknown nested PE hash
   every release. v1.0.3 had the same property and passed.
5. **Ruled out: size.** v1.0.3 (11195904 bytes) passes, and the block message names a virus.

## Proposed fixes (separate items, each with its own regression test)

1. **Acquire the region image in-process instead of through a hidden PowerShell P/Invoke stage.**
   The driver already owns the clipboard natively (the `CB_*` code in screenshots.ahk) and already
   uses GDI+ in-process (`adapters/graphics_renderer.ahk`, `ui/wpm/wpm_gdiplus_ownership.ahk`). Do
   `CopyImage` + `GdipCreateBitmapFromHBITMAP` + downscale + `GdipSaveImageToFile` under the same
   clipboard lock and sequence check, from AHK. This is justified on its own engineering merits:
   `Add-Type -TypeDefinition` runs the C# compiler on every region capture (hundreds of ms to
   seconds), and so does a PowerShell process start. Keep the custody rules
   (`tests/unit/adapters/crash_report/test_screenshot_region_sequence.ahk` pins the current needles
   and must be rewritten against the new owner). The smallest interim alternative is to move the
   type definition into a bundled `vendor/*.ps1` worker. Bundled workers with `DllImport` passed in
   v1.0.3, but the PowerShell launch and the compile cost stay.
2. **Add product version metadata to the exe.** Set `;@Ahk2Exe-SetProductName`, `CompanyName`,
   `FileDescription`, `ProductVersion`/`FileVersion` stamped from the release version, and
   `LegalCopyright` in `ErgoptiPlus.ahk` (or as Ahk2Exe options in `ci-windows-build.yml`). This
   gives a proper identity instead of the bare runtime defaults.
3. **Make `ergopti_network_pac.exe` reproducible.** Link it with `/Brepro` (and no random PDB GUID)
   in `tools/build/build_windows_network_pac.ps1`, so that unchanged sources keep a known hash.
4. **Long term: code signing.** SignPath Foundation (checklist item 132). Corporate engines trust a
   signed publisher far more than a new unsigned hash. This is the only fix for candidate 2.

Do not ship a zip "to get through". Netskope unpacks archives, and repackaging to evade a verdict
would be evasion, not a fix. The in-app updater downloads the same `ErgoptiPlus.exe` asset from
the release, so the same proxy would block an in-app update to v1.0.4 too.

## Test matrix for the tester (downloads only, nothing to run)

| #   | Download                                                             | Blocked means                         | Passes means                        |
| --- | -------------------------------------------------------------------- | ------------------------------------- | ----------------------------------- |
| T1  | v1.0.4 `Ergopti_windows.exe` (identical to v1.0.0's)                 | proxy blocks the release path or host | verdict is per file                 |
| T2  | v1.0.4 `ErgoptiPlus.exe` again, 3 or more days after publication     | content signature (candidate 1 or 3)  | first-seen reputation (candidate 2) |
| T3  | `v0.0.0-dev.159` `ErgoptiPlus.exe` (same clipboard code, other hash) | content, not this one hash            | hash-specific verdict (reputation)  |
| T4  | the next prerelease with fix 1 (clipboard stage removed)             | another trigger: report it            | candidate 1 confirmed               |

## Playbook for the maintainer

1. Look up `a4ed8e50de44c4ec4116bdefeb7cb71c7feb54913cebfc837a9b433ce230ad13` on VirusTotal
   (`https://www.virustotal.com/gui/file/<sha256>`), or upload the asset there, to see which
   engines flag it and under which detection name. A name such as `PowerShell/...Clipboard` or a
   heuristic `Trojan:...AutoIt/AHK` points to candidate 1 or 3.
2. Submit the file as a false positive to Microsoft
   (`https://www.microsoft.com/wdsi/filesubmission`) and to each flagging vendor's false-positive
   form.
3. Ask the tester to open a ticket with their Service Desk (the block page asks for this). Give the
   SHA-256 above and the release URL, and request an allow-list or a re-scan by Netskope.
4. Ship fixes 1 to 3 in a dev prerelease, have the tester run T4, then release.

## Size findings (the size lead is dropped, kept for the record)

v1.0.4 composition: compiled script `RCDATA/1` 5.70 MB uncompressed, bundle zip 4.34 MB (largest
entries: `sqlite3.dll` 1.34 MB deflated, 22 locales 1.46 MB, `ergopti_network_pac.exe` 0.33 MB,
WebView pages 0.56 MB), runtime sections 1.24 MB, icons 0.1 MB. Ahk2Exe stores the script
uncompressed and only a packer (UPX/MPRESS, excluded) would compress it. Minifying the bundled JSON
saves only 18.5 KB after deflate. So 9.5 MiB is not reachable without dropping features. Zipping
the exe gives 6177221 bytes (54 %), which a size cap would let through but an AV verdict would not.

## Done

- This analysis (static, on the published assets in the session scratchpad).
- A CI size budget gate: `tools/ci/windows-exe-size-budget.cjs` owns
  `WINDOWS_EXE_SIZE_BUDGET_BYTES` (12 MiB, v1.0.4 is 1179136 bytes under it), and the build stage
  runs it in the step "Check the ErgoptiPlus.exe size budget" after compiling and before signing.
  The test is `npm run test:windows-exe-size-budget` (js-0451, distribution-and-updates). It has
  not yet run on a hosted Windows build.

## Remaining

- Fix 1 (ship-fix, Windows driver, full AHK suite before commit), fix 2, fix 3.
- T1 to T4 by the tester, and the VirusTotal lookup by the maintainer.
- Retire this file when the tester confirms a release passes and the lesson is in
  `docs/memory/windows-ahk.md` ("no inline P/Invoke PowerShell stages in the compiled script").
