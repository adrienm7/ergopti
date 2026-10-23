<!-- docs/todo-agents/windows-exe-false-positive-submission-pack.md -->

# ErgoptiPlus.exe false-positive submission pack and string-surface hygiene

Companion of [windows-exe-flagged-by-proxy.md](windows-exe-flagged-by-proxy.md) (analysis and
history) and [signpath-foundation-application.md](signpath-foundation-application.md) (signing).
Everything below is stated from files in this repository; nothing here claims a verdict,
acceptance or registration that the repository does not show.

## 1. What the build now measures

`node tools/ci/windows-exe-av-surface.cjs [--breakdown] [--sources static/ergopti_plus/windows]
[--record counts.json] <ErgoptiPlus.exe>` reads the compiled script and the bundled files out of
the exe. Policy: `tools/ci/windows-exe-av-surface.json` (test: `tools/test/test-windows-exe-av-surface.cjs`).
Every family is either forbidden (zero today) or held at a ceiling equal to its last measurement,
so any growth fails the Windows build. CI writes the record (exe SHA-256, size, Authenticode
state, every count) to the job summary and to the artifact `ergoptiplus-av-surface-<run>-<attempt>`
(30 days), even when a ceiling fails.

Measured on a local Ahk2Exe build of `dev` (2026-10-23, 11 624 960 bytes, unsigned):

| Family                                           | Compiled script | Bundled text files                    | Where it comes from                                                                                                          |
| ------------------------------------------------ | --------------- | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `keylog` wording                                 | 0 (forbidden)   | 0 (forbidden)                         | The keystats rename is complete in shipped text; `KeylogConst` was the last identifier (commit `ae8ed7788e`)                 |
| `SetWindowsHookEx`                               | 2               | 0 (forbidden)                         | Only `infra/input_probe.ahk`, the Debug input probe; the driver's own hooks are AutoHotkey's                                 |
| `GetAsyncKeyState`, `GetKeyState` families       | 62              | 0 (forbidden)                         | `adapters/key_state.ahk`, AltGr and shortcut modules: documented modifier reads                                              |
| Clipboard listener APIs                          | 3               | 0 (forbidden)                         | `modules/keystats/keystats_clipboard.ahk` (paste observer for the opt-in metrics)                                            |
| `SendInput`                                      | 124             | 127 (locale texts naming the setting) | `infra/send_input_parameter.ahk`, `adapters/text_sender.ahk`, terminal output, hotstring send                                |
| `URLDownloadToFile` and PowerShell web cmdlets   | 0 (forbidden)   | 3                                     | `ollama_install.ps1` (optional local AI runtime, official source)                                                            |
| `WScript`, `cscript`, `mshta`                    | 2               | 1                                     | `infra/webview_script.ahk` and `adapters/network_info.ahk` (script-host naming), `ergopti_uninstall.ps1`                     |
| Registry Run keys                                | 0 (forbidden)   | 0 (forbidden)                         |                                                                                                                              |
| Elevation words (`*RunAs`, UAC, requireAdmin.)   | 3               | 0 (forbidden)                         | `modules/gestures/config.ahk`, `ui/onboarding/gesture_registration.ahk`: the user-initiated touchpad registry write          |
| Injection words (`LoadLibrary` and the classics) | 11              | 0 (forbidden)                         | `LoadLibraryW` of gdiplus, sqlite3, UIA and the nav-owner DLL; the remote-thread family is forbidden and absent              |
| Screen capture (`BitBlt`)                        | 1               | 0 (forbidden)                         | `adapters/screen_capture.ahk`, the in-process screenshot (replaced the former hidden PowerShell `CopyFromScreen`)            |
| `powershell` mentions                            | 52              | 9                                     | `modules/updater/self_update.ahk`, `adapters/http_client.ahk`, Ollama, crash report, uninstall                               |
| `ExecutionPolicy Bypass`                         | 16              | 1                                     | Process scope on `-File` launches of bundled workers; the default client policy refuses scripts otherwise                    |
| `WindowStyle Hidden`                             | 3               | 3                                     | Brightness worker, touchpad registry scripts, Ollama install, updater swap                                                   |
| `DllImport` and `Add-Type` (bundled workers)     | 0 (forbidden)   | 52 and 18                             | Vendor workers (WinHTTP transport, native proxy, PAC, diagnostics) and the Ollama files; never in the compiled script itself |

Per-file origin of every count: run the command with `--breakdown --sources`. The compiled script
keeps no file boundaries, so the script side is attributed from the source tree.

Finding for the coordinator: the committed WinHTTP transport (`7c001b2456`) added 19 `DllImport`
to `vendor/ergopti_winhttp_transport.ps1`; the bundle ceiling `pinvoke_declaration` is therefore 52
(it was 33), and `ergopti_curl_attempt.ps1` is gone, which lowered `ExecutionPolicy Bypass` to 16/1.

## 2. Honest hygiene already done in this pass, and what is left

Done: the `KeylogConst` identifier is renamed `KeystatsConst` (shipped wording is now free of
"keylog"; the gate forbids it); the families above are capped; a record of counts and hash per build.

Left, as proposals with trade-offs. None of these hides behaviour, and none is implemented:

1. **`input_probe.ahk` installs a real `WH_KEYBOARD_LL` hook (`SetWindowsHookExW`, id 13) inside the
   release exe** for the Debug input probe. Trade-off: it is the one place that spells the hook
   API, which is the strongest keyboard-hook string in the file. Options: keep it (it is a
   documented Debug action and the string is honest); or move the probe into a bundled
   AutoHotkey helper run on demand so the main exe imports no hook API. Cost of moving it: a second
   process to own and log, and a larger bundle. Recommendation: keep, and describe it in the
   submission text (below); revisit only if a vendor names that string.
2. **Dynamic API names.** The repository has no obfuscated or computed API name: `DllCall`
   targets are literals, `GetProcAddress` runs over fixed export tables (`infra/sqlite3.ahk`, the
   nav-owner DLL, UIA), and `"bcrypt\" . fn` in `adapters/crypto.ahk` selects between the literals
   `BCryptEncrypt` and `BCryptDecrypt`. Splitting that last call into two literal calls would make
   a scanner see both names at the call site, but both names are already present as literals a few
   lines above, so the gain is nil and the duplication is real. Not worth changing.
3. **Remaining hidden-window PowerShell launchers** (Recycle Bin, brightness, touchpad registry
   scripts): replace by `FileRecycleEmpty`, `ComObjGet` WMI, and a bundled `-File` worker. Each
   removes a `powershell` mention and one `WindowStyle Hidden`; each needs its own regression test
   and a Windows run, so they are separate items (handoff "Remaining").
4. **`ExecutionPolicy Bypass`** (16 + 1): required by the default Restricted policy for `-File`;
   the alternative, `Unrestricted` for the process, is the same signal. Keep, capped.
5. **Bundled `DllImport` workers (52).** Fewer, larger P/Invoke blocks would lower the count but
   not the capability; compiling a small native helper (like `ergopti_network_pac.exe`, now built
   with `/Brepro`) would remove the C# compile at run time and replace the strings by an import
   table, at the price of one more signed binary to maintain. Worth it only after SignPath works,
   because an unsigned native helper adds a new unknown nested PE.

## 3. Hash procedure

1. CI: open the Windows run, "Check the ErgoptiPlus.exe antivirus surface" step summary (SHA-256 and
   size), or download the artifact `ergoptiplus-av-surface-<run>-<attempt>/ergoptiplus-av-surface.json`.
   It hashes the compiled exe before signing, so for a signed release the signed file has another
   hash: always hash the asset that users download.
2. Release asset: `gh release download <tag> --pattern ErgoptiPlus.exe`, then
   `Get-FileHash -Algorithm SHA256 .\ErgoptiPlus.exe` (PowerShell) or `sha256sum ErgoptiPlus.exe`.
3. Compare with the record; they must match for an unsigned build. Quote only the hash of the
   asset that was actually blocked.
4. VirusTotal lookup: `https://www.virustotal.com/gui/file/<sha256>` (a lookup does not upload; an
   upload shares the file with the vendors and is permanent).

Known hashes (from the handoff, taken from published assets): v1.0.4
`a4ed8e50de44c4ec4116bdefeb7cb71c7feb54913cebfc837a9b433ce230ad13`, v1.0.5
`631e50c2051854a4940ca5a41f9e55cc1167ce3b0e9efd8691ba2a600d73af35`. The Windows hash of the next
release is not known yet.

## 4. Microsoft Defender false-positive submission (exact text)

Portal: https://www.microsoft.com/wdsi/filesubmission, signed in with a Microsoft account.

- Submitter type: Software developer.
- Product: Microsoft Defender Antivirus (or the product named by the detection).
- File: the blocked `ErgoptiPlus.exe` (upload the exact asset from step 3).
- Detection name: from the tester's block page or VirusTotal, if any; leave it empty otherwise.
- Verdict wanted: "Incorrectly detected as malware/malicious".
- Additional information (paste, replace `<tag>` and `<sha256>`):

> ErgoptiPlus.exe is the Windows build of Ergopti+, a free open-source (MIT licence) keyboard
> productivity tool: text expansion, key remapping and tap-hold keys, built with AutoHotkey v2.
> It is compiled by GitHub Actions from https://github.com/adrienm7/ergopti (workflow
> .github/workflows/ci-windows.yml) and published at
> https://github.com/adrienm7/ergopti/releases/tag/<tag>. SHA-256: <sha256>. The file is unsigned
> at this time; Authenticode signing through SignPath Foundation is being prepared, not yet active.
> Like every text expander and key remapper it reads and rewrites key presses with the operating
> system's keyboard input mechanisms; AutoHotkey, on which it is built, does the same. Its optional
> typing statistics are off by default, stay on the user's computer and are never uploaded;
> password fields and private windows are skipped. The project runs no server and collects no
> telemetry. Its network requests are update checks against the GitHub API (turn-off available),
> layout files from the same repository, and, only if the user enables the optional AI features,
> downloads of the local Ollama runtime and models from their official sources. On first launch it
> extracts its own resources to bundle-<version> under %LOCALAPPDATA%\Ergopti with the system
> tar.exe. Source and privacy statement: README, sections "Code signing policy" and "Privacy".
> Please review the file and remove the detection.

Corrections to the older draft in the handoff: it said the app "contacts only the GitHub API"; the
README Privacy lists three more request kinds (layout files, optional AI downloads, bug reports
opened in the browser), so this text lists them. The submission must not say more than the README.

Other vendors: submit the same text to each engine VirusTotal shows (their false-positive form;
Netskope: the tester opens a Service Desk ticket with the SHA-256 and the release URL and asks for
an allow-list or re-scan).

## 5. Privacy policy and signing status (links to quote)

- Privacy statement: README section "Privacy"
  (https://github.com/adrienm7/ergopti#privacy) and the metrics notes
  `static/ergopti_plus/docs/security/keystats_privacy.md`.
- Code signing policy: README section "Code signing policy"
  (https://github.com/adrienm7/ergopti#code-signing-policy). It says plainly that signing is being
  prepared and the exe is currently unsigned.
- Signing status today: unsigned (Authenticode absent, recorded per build). The workflow signs
  only after the SignPath variables exist (`.github/workflows/ci-windows.yml`); a stable release
  without them keeps the recorded exception (`.github/ci/stable_windows_signing_exception.json`).

## 6. SignPath application readiness check (against the repository only)

| Item                                       | Evidence in the repository                                                                       | Status                                           |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| OSI licence                                | `LICENSE` (MIT); README "License"                                                                | Ready                                            |
| Code signing policy page with roles        | README "Code signing policy": built-by-workflow rule, committers, approver, MFA statement        | Ready; the MFA sentence is the maintainer's word |
| Privacy policy                             | README "Privacy"                                                                                 | Ready                                            |
| Artifact configuration                     | `.signpath/artifact-configuration.xml`, slug `ergoptiplus-exe`, one `ErgoptiPlus.exe`            | Ready, to paste into SignPath                    |
| Verifiable automated build                 | `ci-windows.yml` job on a GitHub-hosted runner; the exe is uploaded as an artifact for SignPath  | Ready                                            |
| Release history                            | Tags v1.0.0 to v1.0.5 (handoff)                                                                  | Ready                                            |
| Proprietary component                      | `vendor/64bit/WebView2Loader.dll` (Microsoft WebView2 loader, closed source) ships in the bundle | Declare it; SignPath decides                     |
| Project-site mention                       | README only; ergopti.fr copy not checked from here                                               | Maintainer checks the site                       |
| Application filed, accepted, variables set | Not in the repository                                                                            | Open, maintainer only                            |

The form answers are in [signpath-foundation-application.md](signpath-foundation-application.md);
they match the README. Do not claim: that the application was submitted or accepted, that the
certificate exists, that MFA is enabled (the maintainer confirms), or any download count.

## 7. Maintainer actions (precisely)

1. Get the SHA-256 of the blocked asset (section 3) and look it up on VirusTotal; note the engine
   and detection names.
2. Submit the file to Microsoft with the section 4 text, and to each named vendor.
3. Ask the tester for the block page text (vendor, detection name) and for a Service Desk ticket
   with the SHA-256 and release URL.
4. Apply to SignPath Foundation with the answers in the SignPath handoff; declare WebView2Loader.dll;
   confirm 2FA on GitHub and SignPath; confirm the ergopti.fr page if SignPath wants the policy
   there.
5. After acceptance, set the secrets and variables and approve the first request (SignPath handoff,
   steps 1 to 7).
6. Have the tester run T1 to T4 (analysis handoff) on a build that contains these changes.
7. Decide the proposals of section 2 (items 1, 3 and 5).
