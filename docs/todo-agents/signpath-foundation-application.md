<!-- docs/todo-agents/signpath-foundation-application.md -->

# SignPath Foundation application (checklist item 132)

Decision (maintainer, October 22): apply now. This file holds what the application needs, the
answers to give, and the switch-on steps once SignPath accepts the project. The workflow side is
done; nothing signs until the variables below exist.

## Why signing, and not another exe change

A corporate proxy (Netskope-style patient-zero sandboxing) let v1.0.5 through on one PC and
blocked it two hours later on another, while v1.0.2 still passes. The v1.0.4 and v1.0.5 PE
images are identical to v1.0.2 except their resources, and v1.0.5 carries no pattern that v1.0.2
lacks ([analysis](windows-exe-flagged-by-proxy.md)). The verdict follows the hash and its age: an
unsigned exe has no publisher, so each release starts with zero reputation and is detonated as an
unknown. A signature carries reputation across releases.

## Eligibility against the Foundation terms (signpath.org/terms, read October 22)

| Condition                                                        | Status for this repository                                                                                                                                                                                                                                                                                   |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| OSI license, no commercial dual licensing                        | MIT (`LICENSE`), no dual licensing. OK                                                                                                                                                                                                                                                                       |
| No proprietary component                                         | To declare: `vendor/64bit/WebView2Loader.dll` (Microsoft WebView2 SDK redistributable, closed source) and `vendor/sqlite3.dll` (public domain, prebuilt) ship inside the exe. Ask SignPath whether the loader counts as a system library; if not, the WebView2 UI needs the loader-free COM activation path. |
| Released and actively maintained                                 | v1.0.0 to v1.0.5 on GitHub Releases, daily commits. OK                                                                                                                                                                                                                                                       |
| Built from source in a verifiable automated build                | `ci-windows.yml` `package-windows` on `windows-latest`, authenticated Ahk2Exe toolchain. OK                                                                                                                                                                                                                  |
| Only own code signed                                             | Only `ErgoptiPlus.exe`. The committed layout installer `static/ergopti/windows/Ergopti_v*.exe` is not built in CI and is not submitted. OK                                                                                                                                                                   |
| Roles (authors, reviewers, approvers) and MFA on GitHub/SignPath | Single maintainer holds all three. Turn on GitHub 2FA if it is not already on.                                                                                                                                                                                                                               |
| "Code signing policy" on the home page, with roles and privacy   | README section `Code signing policy` (commit `c6db589c76`). If SignPath wants the website, copy it to ergopti.fr.                                                                                                                                                                                            |
| No malware or PUP; no system changes without warning             | Explain the input hooks, the opt-in typing metrics and the elevated touchpad registry write (UAC prompt, user-initiated). Text below.                                                                                                                                                                        |
| Privacy policy and opt-out for data sent out                     | README `Privacy`: update checks (daily, "never" in About), optional AI downloads, bug reports opened in the browser. Nothing else leaves the machine.                                                                                                                                                        |
| Uninstaller matching the installer                               | No installer; the tray menu's Uninstall removes the extracted bundle and settings. OK                                                                                                                                                                                                                        |

## Suggested answers for the form (signpath.org/apply)

The exact field list was not readable without a browser; these cover what applicants report being
asked. Answer in English.

- **Project name:** Ergopti+ (repository `adrienm7/ergopti`, also hosting the Ergopti layout)
- **Repository:** https://github.com/adrienm7/ergopti
- **Home page / download page:** https://ergopti.fr and https://github.com/adrienm7/ergopti/releases
- **License:** MIT, `LICENSE` at the repository root
- **Artifacts to sign:** one Windows PE, `ErgoptiPlus.exe` (a compiled AutoHotkey v2 application),
  built by GitHub Actions on GitHub-hosted runners; about one stable release a week
- **Description:** "Ergopti+ is a free, local-first keyboard productivity suite for Windows, macOS
  and Linux: text expansion (hotstrings), tap-hold keys, layer remapping, trackpad gestures and
  optional local AI completions. It works with any keyboard layout and is the companion of the
  Ergopti ergonomic layout. Like every text expander and remapper (AutoHotkey, Espanso, Kanata)
  it installs a low-level keyboard hook to read and rewrite key presses. Its optional typing
  metrics, off by default and shown with an explicit warning before activation, store keystroke
  statistics locally only, skip password fields, private windows and excluded applications, and
  never upload anything. The project runs no server and collects no telemetry."
- **Why signing:** "Corporate antivirus proxies block each new unsigned release until its hash
  builds reputation; users behind them cannot download or update."
- **Contact:** the maintainer's e-mail.

## After acceptance: switch it on (maintainer, about 15 minutes)

1. In SignPath: link the predefined **GitHub.com trusted build system** to the project; optionally
   install the SignPath GitHub App on `adrienm7/ergopti`.
2. Create the artifact configuration with slug **`ergoptiplus-exe`** and paste
   `.signpath/artifact-configuration.xml`.
3. Note the signing policy slug (for example `release-signing`) and keep manual approval on.
4. Create a CI user, copy its API token, and give it submitter rights on the policy.
5. GitHub repository settings → Secrets and variables → Actions:
   - secret `SIGNPATH_API_TOKEN` (the token);
   - secret `WINDOWS_SIGNER_SUBJECT` = the exact certificate subject SignPath shows (for example
     `CN=SignPath Foundation, O=SignPath Foundation, L=Lewes, S=Delaware, C=US`; copy it, do not
     type it);
   - variables `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG`.
   - Leave `WINDOWS_SIGNING_CERTIFICATE_BASE64` and `_PASSWORD` unset: two signers fail the build.
6. Push the next stable release. The `Build (ErgoptiPlus.exe ...)` job waits (up to 2 h) on the
   SignPath approval: approve it in SignPath, the job verifies the signature and the publisher.
7. Then retire `.github/ci/stable_windows_signing_exception.json` and its exception code in
   `tools/ci/windows-stable-signing.cjs`, and change the README policy from "being prepared" to
   SignPath's wording "Free code signing provided by SignPath.io, certificate by SignPath
   Foundation".

Dev prereleases stay unsigned on purpose: each request needs a human approval.

## Not covered by Foundation signing

- macOS: Apple notarization needs a paid Apple Developer ID (99 USD a year); SignPath does not
  sign for Gatekeeper. The app stays self-signed and the README keeps the quarantine step.
- Linux: no antivirus reputation gate applies to AppImage, deb, rpm or Flatpak downloads; the
  release already publishes SHA-256 sums.
- The nested `vendor/ergopti_network_pac.exe` and `ergopti_nav_owner.dll` are extracted unsigned.
  Signing them needs a second SignPath request before the bundle is zipped (a later step once the
  first one works).
