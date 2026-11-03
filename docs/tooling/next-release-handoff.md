<!-- docs/tooling/next-release-handoff.md -->

# Next release after 1.0.9: handoff

## Branch `next/owned-karabiner`

Base: `origin/dev` at `d9b0e6c970`. Goal (maintainer, TODO.md "Next release after 1.0.9"): the macOS driver
uses Ergopti's own bundled Karabiner runtime, never a Karabiner installed on the Mac.

### What this branch does

| Commit                                                                             | What                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fix(build): write the owned runtime pin with LF line ends on every OS`            | `remap_runtime_publish.py` wrote CRLF on Windows (text mode); one `write_json` now writes LF bytes.                                                                                                                                                                                                                                                                                                                                                                             |
| `build(macos): pin the owned remap runtime 16.3.0-ergopti.2`                       | The manifest pins the artifact of run 41276215019 (sha256 `ad1541f8…2de8e`, 12176523 bytes, re-verified with `verify_archive`: 31 members). The manifest gate refuses any null field from now on and checks the file and tag naming.                                                                                                                                                                                                                                            |
| `fix(macos): remove an earlier build's rules from karabiner.json on an owned boot` | Migration: the README promised it, no code did it. The owned boot runs the marker-exact byte-span removal on `~/.config/karabiner/karabiner.json`.                                                                                                                                                                                                                                                                                                                              |
| `feat(macos): say why Ergopti's own remapping runtime does not run`                | Tap-Holds rows for every block the user can act on (not installed, driver absent, user Karabiner running with the consent off, quit refused, download failed) and one notice per launch. 21 locales.                                                                                                                                                                                                                                                                            |
| `fix(macos): read no missing artifact receipt and warn on an offline fetch`        | Every first owned start logged an ERROR reading a receipt in a folder not created yet; an offline download is now a WARNING.                                                                                                                                                                                                                                                                                                                                                    |
| `fix(macos): retarget the editor shortcut after a running source proof settles`    | A second retarget during a running keyboard source proof logged two ERRORs (cleanup debt, « refused: cancelled »); the settled proof retargets.                                                                                                                                                                                                                                                                                                                                 |
| `fix(macos): save a bulk edit for the owned runtime's admission`                   | Restore recommended before admission reverted its edit behind a blocking dialog; it is now saved and deployed at admission.                                                                                                                                                                                                                                                                                                                                                     |
| `feat(macos)!: make Ergopti's own Karabiner runtime the default`                   | `RUNTIME_DEFAULT = "owned"`; `runtime = "shared"` stays readable as a hand-written fallback. The Configuration rows `menu.global.karabiner_integration` and `menu.global.remove_from_karabiner` (`ui/menu/remap_switch.lua`) are deleted with their strings. The E2E Mac models the owned fetch offline; the shared-lease and navigation-layer scenarios keep `runtime = "shared"` explicitly, and a new scenario restores the recommended preset on a Mac without the runtime. |

Every change is macOS only: Karabiner exists only in the macOS driver. Windows is touched in one AHK test that lists
the shared Configuration manifest rows (the two macOS rows left it).

### Do not merge the last commit before the native install exists

The pinned `16.3.0-ergopti.2` helper (`InstallerMain.swift`, `HELPER_SOURCES` of
`tools/build/owned_runtime_product_build.py`) runs `OwnedRuntimeInstallerEntry.runFirstInstallation()`: it publishes
`/Library/Application Support/ErgoptiPlus/Runtime` and nothing else. Nothing in the tree:

1. starts that helper with the administrator prompt for an install (the only launcher role that stages it,
   `--request-virtual-hid-daemon-report`, is a read-only report);
2. writes or bootstraps `com.ergoptiplus.runtime.core` (`OwnedRuntimeCoreProvisionOwner` and
   `OwnedRuntimeIdleServiceEntry` exist in the launcher sources but are not in the helper's roster);
3. writes `com.ergoptiplus.runtime.vhid` (no source writes this LaunchDaemon; only the uninstaller removes it);
4. installs the pqrs VirtualHIDDevice package on a Mac that has none (only the driver-only update of an
   incompatible one exists, `runtime_vhid_update.lua`).

`runtime_owner.lua` requires the files and both jobs, so with the flip a Mac without a hand-installed runtime stops at
`runtime_not_installed` and its tap-holds stay off. The new Tap-Holds row and notice say so; they do not install it.
Native work that remains (WP6 install half and WP8), in this order:

1. Enroll `OwnedRuntimeIdleServiceEntry`, `OwnedRuntimeCoreProvisionOwner` and the `OwnedRuntimeCore*` owners in
   `HELPER_SOURCES`, call `OwnedRuntimeIdleServiceEntry.runFirstInstallation()` from `InstallerMain.swift` (its
   result values differ: update the `OWNED_RUNTIME_INSTALL|1|` line and its reader), and add the
   `com.ergoptiplus.runtime.vhid` LaunchDaemon (the pqrs daemon plist is already a helper resource,
   `VIRTUAL_HID_RESOURCE_NAMES`) and the pkg install when no driver is active.
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

### Proof

The agent ran on the maintainer's Windows PC, not a Linux container: Lua 5.4 and LuaJIT in WSL Debian on a copy of
the tree, Node 22.22.2 (the pinned version, downloaded and checked against its SHASUMS256) on Windows.

- macOS E2E: 181/181 on the final source (179 before; the flip without the fixes failed 38).
- Packager suite 14/14 (Python 3.13 in WSL); `test-remap-runtime-manifest.cjs` passes but for the Windows
  `python3` Store stub, which also fails it on `dev` here.
- The full macOS and Linux unit suites, compared with `origin/dev` on the same host, and the hosted CI runs: see
  the end of this file.
