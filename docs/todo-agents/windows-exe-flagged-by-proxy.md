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
   `LegalCopyright` in `ErgoptiPlus.ahk` (or as Ahk2Exe options in `ci-windows.yml`). This
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
- No size budget gate: a hard size threshold was added (`422ce140fd`) and reverted by decision
  (`03d9c017ed`). Each file stays as small as possible, without a fixed limit.
- Fix 1, commit `6d9eae1f94`: every screenshot (region save, window, fullscreen, instant) now
  captures in the driver with GDI and GDI+ (`BitBlt` into a DIB section, `CopyImage` of the
  admitted `CF_BITMAP` under the clipboard lock, `GdipSaveImageToFile`). No screenshot path starts
  `powershell.exe` any more; the window and fullscreen captures had also used a hidden PowerShell
  `CopyFromScreen`. `test_screenshot_tree_owned_default.ahk` fails if the screenshot module
  launches a script host again. A local Ahk2Exe build of that commit holds 0 `DllImport`, 0
  `TypeDefinition`, 0 `ErgoptiScreenshotClipboard` and 0 `CopyFromScreen` (v1.0.4: 7 hits), and
  is 10915840 bytes (v1.0.4: 11403776).
- Fix 2, commit `1965c2ffac`: the exe's version resource is ProductName `Ergopti+`, CompanyName
  `Ergopti`, FileDescription `Ergopti+ keyboard layout companion`, LegalCopyright
  `Copyright (c) 2024 Adrien MOYAUX (MIT License)`, OriginalFilename `ErgoptiPlus.exe`,
  InternalName `ErgoptiPlus`, and FileVersion/ProductVersion derived from the stamped
  `BUNDLE_VERSION` (an unstamped local build reads `0.0.0-dev`). The Windows build stage checks the
  compiled exe ("Verify the ErgoptiPlus.exe version resource"); the test is js-0451.

## v1.0.5 follow-up (October 22): passed once, blocked two hours later

Report: v1.0.5 (published 2026-10-22 09:02 Paris) downloaded fine on the tester's PC, then the
proxy blocked it on another PC two hours later; v1.0.2 still downloads there.

| Asset                  | Bytes    | SHA-256                                                          |
| ---------------------- | -------- | ---------------------------------------------------------------- |
| v1.0.2 ErgoptiPlus.exe | 11194368 | 1292b8d5d8222ed4d54d7b5fbbbcc3998addaa65993c627cb7c4835d4df2e670 |
| v1.0.4 ErgoptiPlus.exe | 11403776 | a4ed8e50de44c4ec4116bdefeb7cb71c7feb54913cebfc837a9b433ce230ad13 |
| v1.0.5 ErgoptiPlus.exe | 11521024 | 631e50c2051854a4940ca5a41f9e55cc1167ce3b0e9efd8691ba2a600d73af35 |

Static comparison (assets never executed):

- PE: `.text`, `.rdata`, `.data`, `.pdata`, imports (16 DLLs, same functions), manifest and
  timestamp are identical in the three; no packer, no overlay, no Authenticode directory. Whole
  file entropy 7.2 comes from the deflated bundle resource (7.998), present since v1.0.0.
- Version resource: bare AutoHotkey 2.0.26 defaults in v1.0.2 and v1.0.4, complete Ergopti+
  identity in v1.0.5.
- Compiled script (`tools/ci/windows-exe-av-surface.cjs` counts): v1.0.4 alone has Add-Type 4,
  DllImport 6, TypeDefinition 1; v1.0.5 has none, like v1.0.2. Unchanged in all three:
  ExecutionPolicy Bypass 19, -EncodedCommand 3, FromBase64String 2, ScriptBlock::Create 1, \*RunAs
  3, hidden windows 4-5, about 640 "keylogger" identifiers and about 430 more in the bundle.
- Bundle: no new binary between v1.0.4 and v1.0.5 (`ergopti_network_pac.exe` is now reproducible,
  same hash in both; fix 3 is done by `/Brepro`). Only `vendor/ergopti_curl_attempt.ps1` changed.

Conclusion: v1.0.5 carries nothing that v1.0.2 does not, so the verdict is not a content
signature. "Allowed first, blocked later" is the patient-zero pattern of cloud sandboxes
(Netskope, Zscaler): an unknown unsigned file is released or held, detonated, and later
downloads follow the sandbox verdict. The detonation sees what the first launch does: an unsigned
exe that drops about 330 files, including PowerShell scripts, through a hidden
`powershell -ExecutionPolicy Bypass` child, then installs a keyboard hook. v1.0.2 passes because
its hash was cleared (or never re-scored) before. Every release resets this, so the durable fix
is a signed publisher (item 132, [SignPath application](signpath-foundation-application.md)).

Done on dev: `3d2c78d7b7` (first launch extracts with System32 `tar.exe`, no script host),
`745f07fa51` (build gate over the compiled exe, js-0454), `61fb29d64d` (SignPath signing wired,
off until configured), `c6db589c76` (README code signing policy and privacy).

### Microsoft false-positive submission (maintainer, https://www.microsoft.com/wdsi/filesubmission)

Submit as "Software developer", product "Microsoft Defender Antivirus", file v1.0.5
`ErgoptiPlus.exe` (SHA-256 above), "Incorrectly detected as malware/malicious". Text:

> ErgoptiPlus.exe is the Windows build of Ergopti+, an open-source (MIT) keyboard productivity
> tool: text expansion, key remapping and tap-hold keys, built with AutoHotkey v2. It is built by
> GitHub Actions from https://github.com/adrienm7/ergopti and published at
> https://github.com/adrienm7/ergopti/releases/tag/v1.0.5. Corporate proxies and antivirus
> engines block its download. Like every text expander it installs a low-level keyboard hook; its
> optional typing statistics are off by default, stored locally only, and never uploaded. On
> first launch it extracts its own resources to `%LOCALAPPDATA%\Ergopti`. It contacts only the GitHub
> API for update checks. Please review the detection and clear this file. Earlier hash for the
> same product: a4ed8e50de44c4ec4116bdefeb7cb71c7feb54913cebfc837a9b433ce230ad13 (v1.0.4).

Also ask the tester for the exact block page text (vendor and detection name): with a named
engine, use that vendor's false-positive form too (Netskope: the Service Desk ticket with the
SHA-256 and release URL, asking for an allow-list or re-scan).

## Remaining

- Fix 4 (code signing, item 132): apply to SignPath Foundation and switch it on
  ([steps](signpath-foundation-application.md)). Fix 3 is done (`/Brepro`, verified above).
- Other hidden PowerShell launchers that AHK could replace, not changed (they were present in the
  builds that pass): the Recycle Bin action (`GESTURE_SYS_EMPTY_TRASH_COMMAND`, AHK has
  `FileRecycleEmpty`), the screen brightness adapter (WMI, reachable through `ComObjGet`), and the elevated touchpad registry
  scripts (`modules/gestures/config.ahk`, `ui/onboarding/gesture_registration.ahk`). The updater,
  crash report, curl, managed network, Ollama and diagnostics workers are vendor scripts: kept.
- Done: the updater bootstrap (base64 fragments in environment variables, `[ScriptBlock]::Create`,
  `-EncodedCommand`) is gone. The updater runs `vendor/ergopti_updater_staging.ps1` with `-File`
  and one `-TransportPrefix` argument (release data stays in inherited environment values), the
  staging worker copies `vendor/ergopti_updater_swap.ps1` next to the staged exe, and the
  crash-report minimal writer is `vendor/ergopti_crash_fallback_worker.ps1`. Measured on a local
  Ahk2Exe build, compiled script before/after: `-EncodedCommand` 3/0, `[ScriptBlock]::Create` 1/0,
  `FromBase64String` 2/0, `ExecutionPolicy Bypass` 18/17, `WindowStyle Hidden` 4/3 (the swap
  worker's `Start-Process -WindowStyle Hidden` moved to the bundle). The gate now forbids the first
  three in the script and `-EncodedCommand` in the bundle. `-ExecutionPolicy Bypass` stays on the
  `-File` launches: it is process scope only, and the default Windows client policy (Restricted)
  refuses every script file without an override.
- "keylogger" names the typing metrics in about 1 070 shipped strings and identifiers (and 10 600
  repository occurrences in 1 350 files across the three drivers, config keys and locales). A
  rename to typing metrics is a cross-driver campaign of its own; the gate reports the count.
- After the next build that contains both fixes: hash its `ErgoptiPlus.exe`
  (`sha256sum` or `Get-FileHash`), look the hash up on VirusTotal and give it to the tester for
  T4, with the Service Desk ticket if it is still blocked. Keep the v1.0.4 hash above for the
  false-positive report.
- T1 to T4 by the tester, and the VirusTotal lookup by the maintainer.
- Retire this file when the tester confirms a release passes and the lesson is in
  `docs/memory/windows-ahk.md` ("no inline P/Invoke PowerShell stages in the compiled script").
