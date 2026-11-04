# Lifecycle / distribution / native UI parity audit

Audit date: 2026-11-04. Repository `/workspace/ergopti`, read-only audit. This report does not claim native hardware validation. Scope: updater, install/uninstall/startup, onboarding, configuration backups, diagnostics, bundled applications and UI routes that expose these capabilities. Read the cross-driver parity skill, memory routing index, relevant decisions, existing parity report and TODO, then traced production consumers rather than inferring absence from filenames.

## New confirmed capability differences

### 1. In-app diagnostics feature-availability explanation exists only on macOS

`static/ergopti_plus/_shared/modules/diagnostics/schema.json:471` declares the `unavailable` items section (feature, platforms, reason), with `platforms = ["macos"]` at line 475. The page respects platform restrictions (`_shared/ui/healthcheck/model.js:50`). macOS has real collection: `macos/ui/healthcheck/helpers.lua:377` calls `infra.manifest_reader.coverage_gaps()`, includes both explained and unexplained feature gaps, and sorts them. `macos/ui/healthcheck/core.lua:951` publishes it in the diagnostic snapshot.

The Linux snapshot builder and Windows diagnostics collectors do not publish this section. This is a true small user-visible parity gap: Windows/Linux cannot inspect their missing feature explanations in the diagnostics UI. It is also pertinent to the requested automated inventory: an existing production consumer already renders manifest-derived availability on one OS, but its scope covers configuration manifest entries rather than every action/menu/bundled app. A reasonable TODO is to extend this manifest-driven diagnostics section to Windows/Linux and project the canonical broader inventory when suitable; do not duplicate a handwritten feature table.

Reproduce: `rg -n '"id": "unavailable"|"platforms": \["macos"\]' static/ergopti_plus/_shared/modules/diagnostics/schema.json`; `rg -n 'collect_unavailable|unavailable = section' static/ergopti_plus/macos/ui/healthcheck/{helpers,core}.lua`.

### 2. Installing an update during a GitHub API failure has a macOS-only authenticated fallback

All three Versions windows can fetch the public Atom release feed when the GitHub API fails; do not list release listing itself as missing. However, Windows `windows/ui/changelog/init.ahk:940-942` refuses a feed-only install (`no_details`) because the feed has no asset list or digest. Linux `linux/ui/changelog/bridge.lua:406-414` does the same and documents why. macOS `macos/ui/changelog/init.lua:627-670` implements `hand_off_to_updater`: on a feed list it selects only the newest release Sparkle would offer for the subscribed channel and asks the native updater to fetch signed appcast metadata. This does not support arbitrary historical feed-only versions.

This is an intentional security capability boundary, not evidence that Windows/Linux should install unverified feed assets. Suggested TODO: document feed-only installation limitations; evaluate an authenticated update-metadata fallback for Windows/Linux if product parity requires it. Existing signature/checksum enforcement must remain.

Reproduce: `rg -n 'Atom feed carries|no_details|hand_off_to_updater|is_newest' static/ergopti_plus/{windows/ui/changelog/init.ahk,linux/ui/changelog/bridge.lua,macos/ui/changelog/init.lua}`.

## Installation-mode restriction (document separately from missing OS feature)

Linux self-update is supported for owned standalone installs. `linux/modules/updater/manager.lua:1385-1390` explicitly disables automatic checks for package installations because the package manager owns updates. `:1784-1805` refuses archive replacement unless the resolved installation kind is `standalone`; `:1918-1924` exposes this classification. Linux `ui/changelog/bridge.lua:370-374` shows the package-specific refusal reason before installation. This is a distribution ownership contract, not a blanket Linux updater absence. Immutable/unmanaged bundles are not entitled to standalone replacement. A single per-OS boolean cannot fully describe this without installation-mode qualification.

macOS automatic check cadence is implemented in Lua and deliberately disables Sparkle's independent scheduler (`macos/modules/updater/auto_check.lua:6-14`); Sparkle supplies download/install upon user request. Thus different updater engines are OS plumbing, while the channel/frequency/check/version UI is shared capability.

## Backup coverage qualification, not yet a missing product feature claim

All three implement pre-install backups and restore from Versions. Windows real callers: `windows/ui/changelog/init.ahk:904` creates a backup, `:1013` restores it. macOS `macos/ui/changelog/init.lua:551-552` obtains backup owner, `:602` restores it and `:611` requests reload. Linux `linux/ui/changelog/bridge.lua:363-364` resolves its production backup owner. Both Lua drivers use the shared owner `_shared/lua/updater/config_backup.lua`.

There is a concrete scope asymmetry: macOS `modules/updater/config_backup.lua:145-157` backs up only the configuration directory and explicitly excludes native `hs.settings`; Linux `modules/updater/config_backup.lua:149-161` additionally includes its `settings_store` file. Windows uses the configuration directory and shared TOML/JSON inclusion rules (`windows/modules/updater/config_backup.ahk:12-17,46-67`). Native macOS Storage is real persistent namespaced state (`macos/adapters/storage.lua:6-8,204-215`). This does **not** prove ordinary preferences are lost: manifest configuration lives in config.toml, and even locale's header explains that `[script].locale` wins and changes rewrite that row (`macos/infra/i18n.lua:13-16`). Treat this as an explicit backup-scope caveat requiring a separate key-by-key classification before claiming a user setting is unrestorable; caches/runtime counters need not be backed up. Do not indiscriminately export all hs.settings.

Shared updater defaults include only `.toml` and `.json` in `config_backup.include_extensions`. Programmable source files have `.ahk` or `.lua` extensions under the user config directory (cross-check with hotstrings audit agent; Windows `windows/modules/dynamic_hotstrings/user_code.ahk:28-30`, Lua `_shared/lua/dynamic_hotstrings/user_code_driver.lua` uses Source.filename()). Therefore backup coverage is not a complete archive of all arbitrary user source files on any OS. This is a shared backup completeness issue, not an OS parity gap. The backup should be described precisely as extension-filtered config backup; consider including the owned programmable source explicitly if restoration promises encompass it.

## Existing gaps confirmed, not new

macOS bundles App Cloner and Encryptor. Production app menu has both names (`macos/ui/menu/menu_apps.lua:80-84`) and App Cloner prerequisite handling around `:378`; app bundles contain executable/resource code. No corresponding bundled Windows/Linux application implementation was found. Existing parity report/TODO already records both, so do not add duplicates or conflate Encryptor with shared text/metrics encryption.

## Feature-equivalence refutations and source coverage

- First-use wizard is present on Linux, with absent-config trigger (`linux/ui/onboarding/startup.lua:21-43`) and the shared page bridge (`linux/ui/onboarding/bridge.lua`). It supports locale selection/preview, config folder selection, live metrics path, re-running existing settings, validated batch finish, tap-hold import and recommended navigation layer import. Its gesture system-registration actions intentionally return unsupported because those controls are Windows-only (`:621-623`), not because Linux gesture recognition is absent. Shared number-row capability has a runtime reason when unavailable (`:197-208`). macOS/Windows host counterparts are `macos/ui/onboarding/init.lua` and `windows/ui/onboarding/{core,answers,finish}.ahk`.
- Start at login is exposed in the canonical menu on all OS (`_shared/modules/menu/menu.toml:629-634`). Windows production menu binds ToggleStartAtLogin and StartAtLoginEnabled (`windows/ui/menu/menu_init.ahk:543-563`), Linux calls its owned shell startup helper (`linux/ui/menu/start_at_login.lua:20`, `menu_about.lua:301-302,336-340`), macOS calls its native async login owner (`macos/ui/menu/init.lua:1034-1035`, `menu_about.lua:281-283`). Native registration mechanisms differ intentionally.
- Uninstall is exposed on all OS; source checkouts are intentionally disabled in the common menu (`menu.toml:641-649`). Linux `ui/menu/uninstall.lua:40-57` calls owned uninstall.sh; macOS `ui/menu/uninstall.lua:49-56` confirms then spawns the launcher `--uninstall` role, Windows owns it in `windows/infra/uninstall.ahk` and vendor PowerShell script. Distinct transaction implementations are not absent capability.
- Shared diagnostics page/actions exist on all OS: Linux `ui/healthcheck/bridge.lua` validates actions, owns async probes, snapshot export, day-log opt-in, refresh/cancel/close; macOS `ui/healthcheck/{core,probes,report}.lua`; Windows `ui/healthcheck/{core,probes,report,day_log}.ahk`. Do not mistake macOS-specific permissions/AppleEvents probes or Linux-specific uinput/group fields for missing generic diagnostics.
- Crash report producers exist on all three in `modules/diagnostics/crash_reporter.{lua,ahk}`. Linux explicitly shares document/name/retention policy with macOS (`linux/modules/diagnostics/crash_reporter.lua:11-14`). Native crash/error delivery remains unverified here.

## Verification performed

Passed independently in this audit:

- `node tools/test/test-updater-constants-single-source.cjs`: all scalar/URL/schedule references passed.
- `node tools/test/test-update-channels-contract.cjs`: 292 checks.
- `node tools/test/test-update-schedule-contract.cjs`: 524 checks.
- `node tools/test/test-healthcheck-model.cjs`: 16 sections, 79 fields, 216 labels in 21 locales; synthetic three-driver sharing/summary checks passed. These are schema/shared model tests, not live host collection.
- `node tools/test/test-onboarding-wizard-page.cjs`: shared pages/defaults/manifest paths/re-run/title/folder/consent/keyboard capability controls passed.
- `node tools/test/test-linux-uninstall-sandbox.cjs`: 13 sandbox transaction tests passed; owned uninstall behavior passed.

Limited/unavailable:

- `node tools/test/test-linux-start-at-login.cjs` reached its Lua execution and failed `spawnSync lua ENOENT`; this environment has no Lua. This is an environment failure, not a demonstrated startup defect.
- `node tools/test/test-windows-uninstall.cjs` explicitly skipped execution because PowerShell on Windows is required.
- No native Windows/macOS runtime, Linux desktop input session, actual install/update/reboot/uninstall, signature-key rollout, native accessibility permissions, corporate PAC network, or bundled app interaction was exercised. Presence of tests is not native evidence. macOS backup binding test exists at `macos/tests/unit/modules/updater/test_config_backup_binding.lua`, but was read rather than executed.
- The full repository JS verifier has pre-existing Node 22.22.2 host prerequisites while this host supplies Node 24.22.1; only the above directly executed suites are claimed.

## Automation implications

Configuration/action/menu declarations can generate reviewable inventories, but native lifecycle branches add dimensions (installation mode, API availability, active desktop session). To make claims exhaustive, inventory entries for these capabilities should carry explicit conditional support and evidence references, and tests must ensure each declared host has a production consumer. A generated table alone does not prove all reachable native behavior. The diagnostics schema's OS-restricted sections should also be included in broader inventory coverage or explicitly documented as technical/diagnostic scope.
