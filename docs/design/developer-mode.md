<!-- docs/design/developer-mode.md -->

# Developer mode on the three OS

Maintainer requirement (27 October): each Ergopti+ app has a developer mode
that runs the code of a clone with every feature of the built and installed
app (the same native helpers, guardian and agents, AI runtimes, menus and
configuration), reloads a saved source file, and starts with one documented
command. The updater may stay off, with a stated reason.

## The three commands

| OS      | Command (from the clone root)                                                                    | What it runs                                                                                                                      |
| ------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| macOS   | `bash tools/dev/run-macos-dev-app.sh` (`npm run dev:macos-app`)                                  | builds `build/macos/ErgoptiPlus.app` whose launcher points the embedded Hammerspoon at `static/ergopti_plus/macos`, then opens it |
| Linux   | `bash tools/dev/run-linux-dev.sh` (`npm run dev:linux`)                                          | `static/ergopti_plus/linux/install/launch.sh --service --tray`, the packages' entry point, from the clone                         |
| Windows | `powershell -ExecutionPolicy Bypass -File tools\dev\run-windows-dev.ps1` (`npm run dev:windows`) | `AutoHotkey64.exe static\ergopti_plus\windows\ErgoptiPlus.ahk`, the source the exe embeds                                         |

All three hand the clone root to the driver in one variable,
`dev_source.environment` of `_shared/core/text/data/identifiers.json`
(`ERGOPTI_DEV_SOURCE_ROOT`). Each driver accepts it only when it names the very
clone it runs from, and raises otherwise: `infra/dev_source.lua` (macOS and
Linux) and `infra/dev_source.ahk` (Windows).

### Windows: double-click works too

Double-clicking `static\ergopti_plus\windows\ErgoptiPlus.ahk` in a clone, with
AutoHotkey v2 installed, starts the same developer mode. Without the variable, a
source run (`Updater_IsLocalSource()`) derives the root from its own folder: the
driver folder minus `\static\ergopti_plus\windows`. `DevSource_DeriveRoot`
accepts it only when that root holds a `.git` folder (a clone) or `.git` file
(a linked worktree) and `static\ergopti_plus\_shared\core\text\data\identifiers.json`.
The run then takes the same path: `%LOCALAPPDATA%\Ergopti\paths.toml`, the watcher,
and the updater and uninstall off with their reasons.
The startup line names the origin: "Developer source mode; the driver runs from
… (clone root from the script location)", or "(clone root from the developer
variable)" under the PowerShell script.

- The variable wins: when set it is validated exactly as before, and a root
  naming another clone raises even inside a clone.
- A source tree outside a Git checkout (an extracted zip) stays a plain source
  run with `windows\_generated\paths.toml`.
- A compiled exe never derives a root.
- A double-click does not close a running ErgoptiPlus.exe. The
  `#SingleInstance Force` directive only replaces an instance of the same
  script path, and the exe is another one, so the source run meets the
  single-owner mutex (`Local\ErgoptiPlusDriver`) held by the exe, waits
  `DRIVER_MUTEX_WAIT_MS` (3 s), writes "Another instance owns the single-owner
  mutex" as a WARNING to `bootstrap.log` and exits without a tray icon; the exe
  keeps running. A second double-click while a source run is alive replaces
  that run, as before. Quit the exe first, or use the PowerShell script, which
  asks it to close. This is read from `ErgoptiPlus.ahk`'s single-owner gate;
  the [PHYS-W] check in the TODO confirms it on a PC.

Reload in each mode:

- macOS: a saved `.lua` under `macos/` or `_shared` reloads (`hs.reload`);
  the menu's Reload row and AltGr+Backspace do it on demand.
- Linux: a saved `.lua` of the driver or `_shared` (test folders excluded)
  restarts the daemon after the watcher's settle window; the tray's Reload does
  it on demand. Outside a checkout's systemd unit the restart relays
  `tools/dev/run-linux-dev.sh` itself, so the successor is a developer run too.
- Windows: a saved driver `.ahk` (outside `tests\` and `_generated\`) reloads
  through `ReloadPreservingSuspend`, the tray's Reload path, after one quiet
  one-second poll.

## Inventory: what differs from the built app

Method: every branch on `dev_source`, `is_local_source` / `is_source_run` /
`Updater_IsLocalSource`, `A_IsCompiled`, bundle-relative paths
(`Contents/Resources`, `Contents/MacOS`, `/usr/lib/ergopti`, `_BundleDir`), and
every native helper path, read in `origin/dev` at `bde408f3a6`.

"works" means the developer run takes the same code path as the built app.

### macOS

| Feature                                                                | State                                                                                                                                                                                              |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lua driver, menus, hotstrings, gestures, shortcuts, AI features        | works: the clone's tree is `hs.configdir`                                                                                                                                                          |
| Native logger, instance admission, Karabiner and helper launcher roles | works: the developer app's own launcher (`DevSource.launcher_executable`)                                                                                                                          |
| Remap guardian (launchd agent)                                         | fixed by 6f667b3380 (falls back to the developer build's own agent)                                                                                                                                |
| Native network receiver                                                | fixed by c0e3359a19 (adb2155955 on its branch)                                                                                                                                                     |
| LuaSocket (`socket.core.so`)                                           | works: loaded from the developer app's payload, the only payload module (`DevSource.payload_searcher`)                                                                                             |
| System switcher helper, field checks, login item status                | works: resolved from `ERGOPTI_LAUNCHER_EXECUTABLE`, which the developer launcher exports                                                                                                           |
| Config (`paths.toml`, `~/.config/hammerspoon`)                         | works: the launcher exports the same managed `paths.toml`                                                                                                                                          |
| Ollama and MLX runtimes                                                | works: resolved from the user's Application Support, not the bundle                                                                                                                                |
| Updater, channel switch, in-app installs, Sparkle                      | differs (by design): a source run has no release to update from; the About rows say why                                                                                                            |
| Uninstall                                                              | differs (by design): nothing is installed; the row is greyed with its reason                                                                                                                       |
| Layout catalogue                                                       | works like the release: the published registry, unless the clone's registry folder differs from HEAD, then the clone's (see [Layout catalogue in a source run](#layout-catalogue-in-a-source-run)) |
| Accessibility and Input Monitoring                                     | differs: each ad hoc rebuild is a new code identity and asks again, unless signed with the stable certificate                                                                                      |
| A stock Hammerspoon running the clone                                  | refused (by design, `infra/instance_admission.lua`)                                                                                                                                                |
| Native helpers, Swift launcher, LuaSocket edits                        | differs: need a rebuild (`run-macos-dev-app.sh` without `--open-only`); no Lua reload can load them                                                                                                |

### Linux

| Feature                                                      | State                                                                                                                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Daemon, tray, hotstrings, tap-holds, metrics, AI features    | works: the clone's tree, started through `install/launch.sh` as the packages do                                                                        |
| Input permissions, session lock                              | works: `launch.sh` requests the groups and takes the same lock                                                                                         |
| uinput injection, evdev grab                                 | works: in-process (`modules/hotstrings/injector.lua`); no ydotool or kanata is used by any build                                                       |
| Native archive backend (`libergopti_archive_publication.so`) | fixed by 57a5518ece: the runner builds it from `native/archive_output` when missing or older than its sources (gitignored)                             |
| luv                                                          | works when the distribution's LuaJIT luv is installed; the runner refuses to start without it (install.sh can build its own only into an installation) |
| Config (`~/.config/ergopti`, `paths.toml`)                   | works: the same `infra/config_paths.lua`                                                                                                               |
| Tray Reload                                                  | fixed by 57a5518ece: a checkout had no relaunchable wrapper, so `daemon_restart` refused and Reload failed; it now relays the developer runner         |
| Saved-source auto-reload                                     | fixed by 57a5518ece: the watcher watched only top-level `.lua` and re-read the hotstrings; it now restarts on any driver or `_shared` `.lua`           |
| Updater, Versions window installs, uninstall                 | differs (by design): a checkout is a source run (`infra/installation.lua`)                                                                             |
| Layout catalogue                                             | works like the release, with the same exception as on macOS                                                                                            |
| Start at login                                               | differs: requires an installed application (the row says so)                                                                                           |
| `bin/ergopti-hotstrings` from a clone                        | works: runs the tree it lives in, even when a package is installed; the developer runner does not use it                                               |

### Windows

| Feature                                                                                                                      | State                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Driver, menus, hotstrings, layers, tap-holds, metrics, AI features                                                           | works: the same `.ahk` the exe embeds, interpreted by AutoHotkey v2                                                                                                                                                    |
| Native helpers (`ergopti_nav_owner.dll`, `ergopti_network_pac.exe`, `sqlite3.dll`, `WebView2Loader.dll`, PowerShell workers) | works: tracked in `vendor\`, the same files the exe extracts                                                                                                                                                           |
| Bundle extraction                                                                                                            | works: not needed, `_StaticDir` is the clone (`infra/bundle.ahk` is a no-op)                                                                                                                                           |
| Config (`paths.toml`)                                                                                                        | fixed by 47cdd2fdb8: a source run read `windows\_generated\paths.toml`; a developer run now reads `%LOCALAPPDATA%\Ergopti\paths.toml`, as the exe                                                                      |
| Saved-source auto-reload                                                                                                     | fixed by 47cdd2fdb8: `infra/dev_source.ahk` polls the driver's `.ahk` in a developer run only                                                                                                                          |
| Worker processes (metrics projection, UIA probe, keystats prefetch)                                                          | works: started with `A_AhkPath` and the script, the source-mode form of the same command                                                                                                                               |
| Reload successor                                                                                                             | works: `LifecycleLaunchSuccessor` relaunches the interpreter with the script; the developer variable is inherited, or the root is derived again                                                                        |
| Updater, release installs, uninstall, changelog installs                                                                     | differs (by design): `Updater_IsLocalSource()`                                                                                                                                                                         |
| Layout catalogue                                                                                                             | works like the release, with the same exception as on macOS                                                                                                                                                            |
| Start at login                                                                                                               | changed: registers the interpreter and the clone's script, and that login start derives the root from the script location, so it is a developer run too, as the maintainer decided on 27 October ([PHYS-W] to confirm) |
| Registry cache identity                                                                                                      | differs (harmless): hashes the parser sources instead of the exe                                                                                                                                                       |

## Layout catalogue in a source run

A source run (a clone: the developer mode, or any run of the checkout) reads the
published layout registry like a release, from the branch of its build channel,
with the same cache and ETag. One exception, decided by the maintainer on 31
October: when the clone's registry folder (`static/layouts/registry`, so
`index.json` and the layout files it is generated from) differs from HEAD, the
catalogue shows the clone's folder without HTTP, so a layout under development
is the one listed and installed. Untracked files count as changes.

The check is `git status --porcelain --untracked-files=all` on that folder
(`Catalogue.registry_changes_args`, `_shared/layouts/engine/composer/catalogue.lua`),
started asynchronously by each driver (`ShellRunner.run` on macOS,
`ProcessRunner.run` on Linux, `ShellRunner_SpawnTreeOwned` on Windows) so the keyboard loop never waits; the shared
store (`_shared/layouts/engine/registry/store.lua`) applies
`Catalogue.registry_source`. When git is missing or fails, the catalogue shows
the clone's folder and logs an ERROR naming the git failure: the clone is the
code being run, and reading the published registry instead would hide a local
edit without a word.

## What a physical machine must confirm

- Mac: `run-macos-dev-app.sh` then edit a `.lua`: the driver reloads; the
  guardian and the network receiver run (see the Mac hardware session).
- Linux: `run-linux-dev.sh` on a machine with the package installed: the unit is
  stopped, the tray appears, typing expands, a saved `.lua` restarts the daemon
  (log line `Debounced source reload firing`), and the tray's Reload restarts
  it. The relay's successor writes no terminal output; read the log file.
- Windows [PHYS-W]: see `TODO.md`, the developer-mode line of "To confirm
  on the Windows PC".
