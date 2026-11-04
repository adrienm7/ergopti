<!-- docs/tooling/next-release-handoff.md -->

# Next release after 1.0.9: handoff

## Branch `next/owned-karabiner`

### Where this stands (2026-11-04)

Goal (maintainer, TODO.md "Next release after 1.0.9"): the macOS driver uses Ergopti's own bundled Karabiner
runtime, never a Karabiner installed on the Mac.

- **Runtime published:** prerelease
  <https://github.com/adrienm7/ergopti/releases/tag/remap-runtime-v16.3.0-ergopti.2>, not latest; downloaded back on
  2026-11-04 with `gh release download`: sha256 `ad1541f8…2de8e`, 12176523 bytes, identical to the pin.
- **Branch `next/owned-karabiner`:** rebased on `origin/dev` `9701b3f05a` (1.0.9), flip-free: everything on it can
  land on `dev` on its own. Its last commits add WP8 step 1 (the idle Core service in the live helper, proven by an
  unsigned hosted compile, Remap runtime build run 41813372448) and the parity gate mapping of the four owned
  Tap-Holds rows (the Menus job of run 41812126200 refused them).
- **Branch `next/owned-karabiner-flip`:** one commit on top, « feat(macos)!: make Ergopti's own Karabiner runtime
  the default », ported from the pause and finished: the three modules that failed at the pause pass
  (`platform.remap.remove_from_karabiner`, only called by the deleted row, is gone; the remap fixture's stub config
  carries `RUNTIME_DEFAULT`), and the parity gate no longer pins the Configuration recovery route of
  `remap_switch.lua`. Local proof: those modules, the macOS E2E and the menu gates pass; the AHK test of the
  Configuration order passes. Merge it only after WP8 and WP9.

Next steps, in order: the rest of WP8 below (native install), WP9 on a real Mac, then merge the flip branch.

### What this branch does

| Commit                                                                             | What                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fix(build): write the owned runtime pin with LF line ends on every OS`            | `remap_runtime_publish.py` wrote CRLF on Windows (text mode); one `write_json` now writes LF bytes.                                                                                                                                                                                                                                                        |
| `build(macos): pin the owned remap runtime 16.3.0-ergopti.2`                       | The manifest pins the artifact of run 41276215019 (sha256 `ad1541f8…2de8e`, 12176523 bytes, re-verified with `verify_archive`: 31 members). The manifest gate refuses any null field from now on and checks the file and tag naming.                                                                                                                       |
| `fix(macos): remove an earlier build's rules from karabiner.json on an owned boot` | Migration: the README promised it, no code did it. The owned boot runs the marker-exact byte-span removal on `~/.config/karabiner/karabiner.json`.                                                                                                                                                                                                         |
| `feat(macos): say why Ergopti's own remapping runtime does not run`                | Tap-Holds rows for every block the user can act on (not installed, driver absent, user Karabiner running with the consent off, quit refused, download failed) and one notice per launch. 21 locales.                                                                                                                                                       |
| `fix(macos): read no missing artifact receipt and warn on an offline fetch`        | Every first owned start logged an ERROR reading a receipt in a folder not created yet; an offline download is now a WARNING.                                                                                                                                                                                                                               |
| `fix(macos): retarget the editor shortcut after a running source proof settles`    | A second retarget during a running keyboard source proof logged two ERRORs (cleanup debt, « refused: cancelled »); the settled proof retargets.                                                                                                                                                                                                            |
| `fix(macos): save a bulk edit for the owned runtime's admission`                   | Restore recommended before admission reverted its edit behind a blocking dialog; it is now saved and deployed at admission.                                                                                                                                                                                                                                |
| `feat(build): start the idle Core service from the owned runtime's first install`  | The live (daemon-report) helper roster enrolls `OwnedRuntimeIdleServiceEntry` and the `OwnedRuntimeCore*` owners; `InstallerMain.swift` selects that entry under `ERGOPTI_OWNED_IDLE_CORE`. The Remap runtime build workflow compiles that roster unsigned on a hosted Mac (`owned_runtime_helper_compile_check.py`). The builder hash chain is re-pinned. |
| `test(menu): map the owned runtime's Tap-Holds block rows in the parity gate`      | The four owned block rows' menus join `OPENS_SUBMENU`.                                                                                                                                                                                                                                                                                                     |

The flip, « feat(macos)!: make Ergopti's own Karabiner runtime the default », lives on `next/owned-karabiner-flip`:
`RUNTIME_DEFAULT = "owned"`; `runtime = "shared"` stays readable as a hand-written fallback. The Configuration rows
`menu.global.karabiner_integration` and `menu.global.remove_from_karabiner` (`ui/menu/remap_switch.lua`) are deleted
with their strings in 21 locales, with `platform.remap.remove_from_karabiner`. The E2E Mac models the owned fetch
offline; the shared-lease and navigation-layer scenarios keep `runtime = "shared"` explicitly, and a new scenario
restores the recommended preset on a Mac without the runtime.

Every change is macOS only: Karabiner exists only in the macOS driver. Windows is touched in one AHK test that lists
the shared Configuration manifest rows (the two macOS rows left it).

### Do not merge the flip before the native install exists

The pinned `16.3.0-ergopti.2` helper runs `OwnedRuntimeInstallerEntry.runFirstInstallation()`: it publishes
`/Library/Application Support/ErgoptiPlus/Runtime` and nothing else. The source on this branch now also provisions
and starts `com.ergoptiplus.runtime.core` (WP8 step 1, not in a published artifact yet). Nothing in the tree:

1. starts that helper with the administrator prompt for an install (the only launcher role that stages it,
   `--request-virtual-hid-daemon-report`, is a read-only report);
2. writes `com.ergoptiplus.runtime.vhid` (no source writes this LaunchDaemon; only the uninstaller removes it);
3. installs the pqrs VirtualHIDDevice package on a Mac that has none (only the driver-only update of an
   incompatible one exists, `runtime_vhid_update.lua`);
4. reads the helper's `OWNED_RUNTIME_INSTALL|1|<result>` line (the live values are now
   `files-published-idle-core-observed-staging-retired` and `files-published-service-cleanup-pending`).

`runtime_owner.lua` requires the files and both jobs, so with the flip a Mac without a hand-installed runtime stops at
`runtime_not_installed` and its tap-holds stay off. The new Tap-Holds row and notice say so; they do not install it.
Native work that remains (WP8), in this order:

1. Done 2026-11-04: the idle Core service in the live helper (above). Left in the helper: the
   `com.ergoptiplus.runtime.vhid` LaunchDaemon (the pqrs daemon plist is already a helper resource,
   `VIRTUAL_HID_RESOURCE_NAMES`) and the pkg install when no driver is active; prove each roster change with
   `owned_runtime_helper_compile_check.py` (dispatch "Remap runtime build" without the artifact input).
2. A launcher role `--request-owned-runtime-install` modelled on `OwnedVirtualHIDDaemonReportMainOperation`: same
   `OwnedRuntimeDownloadedHelper.current()` source, same staging program, last line
   `… --owned-install-first` instead of the report worker; a Lua port that calls it after the user confirms, from the
   `owned_not_installed` row.
3. Bump `RUNTIME_VERSION` to `16.3.0-ergopti.3`, dispatch "Remap runtime build" on a branch, then publish and pin
   that artifact as below. `16.3.0-ergopti.2`, published now, already lets the fetch, digest and receipt path run on
   a real Mac.
4. WP8 hosted acceptance on `macos-15`, `macos-15-intel`, `macos-26`: install with `sudo` (the hosted runner has
   passwordless sudo; the AppleScript prompt does not exist there), boot the driver owned, `field_owned_runtime`,
   `field_owned_start`, `field_owned_pause`, and the coexistence inputs `none`, `ke_idle`, `ke_running` of the plan.

### Publishing the runtime artifact (done 2026-11-03)

Published by the agent with the maintainer's go-ahead as the prerelease
[`remap-runtime-v16.3.0-ergopti.2`](https://github.com/adrienm7/ergopti/releases/tag/remap-runtime-v16.3.0-ergopti.2),
not marked latest (latest stays `v1.0.8`). The asset at the pinned `source_url` was downloaded back: sha256
`ad1541f8…2de8e`, 12176523 bytes. The commands, for the next artifact (`16.3.0-ergopti.3`, with its own run):

```sh
mkdir runtime-artifact && cd runtime-artifact
gh run download 41276215019 --repo adrienm7/ergopti -n owned-remap-runtime
shasum -a 256 ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.2.tar.gz
# expect ad1541f838a9d3d8c4d6aaa45cda82fddb36c34c381e866d0b69391cae42de8e, 12176523 bytes
gh release create remap-runtime-v16.3.0-ergopti.2 ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.2.tar.gz \
  --repo adrienm7/ergopti --target 639f3e3d1e097bf7ad3c8cc466d6a0245c5d297f \
  --title "Remap runtime 16.3.0-ergopti.2" --prerelease --latest=false \
  --notes "Ergopti's owned Karabiner runtime (ADR 011): the signed installer helper of run 41276215019."
```

`--prerelease --latest=false` keeps the application's update check on the app releases. `639f3e3d1e` is the
commit the artifact was built from; it is on GitHub but no longer an ancestor of `dev`, and the tag keeps it
reachable. Then `python3 tools/build/remap_runtime_publish.py apply runtime-pin.json` writes the pin (done on this
branch for `.2`), and the downloaded-back asset must match the pin's digest and size.

### Only a real Mac can prove

- The fetch of the published asset into `~/Library/Application Support/ErgoptiPlus/RemapRuntime/16.3.0-ergopti.2/`
  and its receipt (`field_owned_runtime`).
- The administrator install, both LaunchDaemons loaded, the DriverKit approval once, Input Monitoring and
  Accessibility for the owned Console, Login Items entries (WP9).
- Closing a running Karabiner-Elements through its own quit, the notice, and its restore on pause and quit; a crash
  then restore from the marker; a resume reloading the driver.
- The migration: an upgraded Mac whose `~/.config/karabiner/karabiner.json` holds rules of a shared-mode build loses
  exactly those, with personal rules byte-identical.
- An older VirtualHIDDevice: the update row, admin prompt and activation (3ebab93a17).
- Typing: tap-holds, chords and the navigation layer on the internal keyboard with fn/globe, autorepeat, sleep and
  wake, reload and crash returning the keyboard to native input, uninstall leaving no Ergopti job.
- The heatmap counting physical keys from the stream (ADR 011 decisions 6 and 7).

### WP9: the real-Mac acceptance

The maintainer's Mac takes no copy-paste, so each pass is one command typed in the clone; the field-report collector
runs every Debug field check in the developer app, then commits and pushes the evidence to a `field/mac-…` branch the
agent reads (`docs/field-reports/`).

Now (baseline, before the install exists), on the shared default:

```sh
git switch next/owned-karabiner && bash tools/dev/collect-macos-field-report.sh
```

It proves what `field_owned_runtime` reports on that Mac today: the owned runtime dormant, which stock Karabiner and
VirtualHIDDevice are installed or running, and whether the owner would accept that driver.

After WP8 (install role, `16.3.0-ergopti.3` pinned), the same command on `next/owned-karabiner-flip`
(`git switch next/owned-karabiner-flip && bash tools/dev/collect-macos-field-report.sh`), with the checklist:

1. Tap-Holds shows « not installed »; its row installs with one administrator prompt; `field_owned_runtime` reads
   the receipt of `16.3.0-ergopti.3` and both jobs loaded.
2. The DriverKit approval in System Settings (once), Input Monitoring and Accessibility for the owned Console, the
   Login Items entries.
3. `field_owned_start` passes; a running Karabiner-Elements is closed with the notice, and reopens on pause and on
   quit; `field_owned_pause` passes; the next run's `field_owned_start` proves close-on-resume.
4. Typing (the maintainer, by hand): tap-holds, chords and the navigation layer on the internal keyboard with
   fn/globe, autorepeat, sleep and wake; a reload and a crash return the keyboard to native input.
5. A shared-mode `karabiner.json` loses exactly Ergopti's rules; personal rules stay byte-identical.
6. Uninstall leaves no Ergopti job.

When the six hold, merge `next/owned-karabiner-flip` (rebase, fast-forward) and start the shared-mode deletion.

### Proof

2026-11-04 (this host, Windows with WSL Debian, Lua 5.4.7, Node 22.16 because the pinned 22.22.2 is not installed
here, so the full JS gate ran only in CI):

- Rebased branch, macOS lane run 41812126200: every macOS unit group green; Common « Menus » red on the four
  unmapped owned rows, fixed by the parity commit (gate green locally).
- WP8 step 1: product build tests 25/25 in WSL, Remap runtime build run 41813372448 green (11 unsigned compile
  commands, both architectures). The SDK test's « unavailable live source » case fails in WSL on `HEAD` too (it
  needs Darwin).
- Flip branch, locally: the three modules of the pause, `test_configuration_menu`, `test_tray_every_submenu_populated`,
  `test_runtime_dormant`, `test_config_runtime_key` and the macOS E2E pass; menu parity, native menu rows and census
  pass; the AHK `(menu-configuration)` test passes. Hosted macOS lanes: run 41819929221 (flip) against 41819945934
  (this branch, same hour).

2026-11-03: the agent ran on the maintainer's Windows PC, not a Linux container: Lua 5.4 and LuaJIT in WSL Debian on a copy of
the tree, Node 22.22.2 (the pinned version, downloaded and checked against its SHASUMS256) on Windows.

- macOS E2E: 181/181 on the final source (179 before; the flip without the fixes failed 38).
- Packager suite 14/14 (Python 3.13 in WSL); `test-remap-runtime-manifest.cjs` passes but for the Windows
  `python3` Store stub, which also fails it on `dev` here.
- macOS unit suite on `origin/dev` on this host: 26808 passed, 217 failed (host-only: tooltip renderer corpus,
  French label punctuation and others). The same run on this branch was killed twice by the host (WSL, 3 GB), so
  the hosted lanes are the comparison.
- `dev` is red on hosted CI today (menu parity « language owner », `llm.indentation` choices, the 1.0.9 work in
  flight), so each lane is judged by the failures it adds over a `dev` run of the same day, by test name:
  - Linux lane, run 41625820152 (this branch) against 41619212552 (`dev`, through `next/linux-todo`): no failure added.
  - Common jobs: the menu-row ratchet and the native-menu census refused the retired `remap_switch.lua`; both now
    admit its retirement only while no macOS UI source requires it and no compiled row carries its ids.
  - macOS lane, run 41625808937 against 41625799247: 48 remap and shortcut modules failed only here. Their fixtures
    model a Mac on the shared runtime without saying so, which the owned default no longer implies; they now state
    `runtime = "shared"`. Rerun: see the agent's report (run 41638220479 against 41638225996).
- The editor-shortcut contract test `test_magic_editor_source_owner_native` pinned `refresh() == false` for a
  deferred retarget; it now pins `true`, and `stop()` still reports a refused cancel.
