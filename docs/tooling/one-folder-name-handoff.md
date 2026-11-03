<!-- docs/tooling/one-folder-name-handoff.md -->

# One folder name: handoff (paused, work in progress)

TODO item "One folder name for Ergopti on the three OS", maintainer decision of
2026-11-03: `Ergopti` on macOS and Windows, `ergopti` under every XDG base on
Linux, no "Plus" in folder names. Branch `next/one-folder-name`, from
`origin/dev` at f03b6c5bce. The run was paused on the coordinator's request
because it ran on the maintainer's PC (low disk) instead of a cloud container.
It resumes after 1.0.9.

**State: one WIP commit. It is not verified.** No suite was run green. The
Windows test runners do not yet include the new AHK files, so the AHK suite
will not load. Do not merge as is.

## Target layout

All folders come from `_shared/modules/paths/app_dirs.toml`.
`tools/codegen/codegen-app-dirs.cjs` turns it into `_shared/lua/app_dirs.lua`,
`windows/_generated/app_dirs.ahk` and `AppDirs.generated.swift`.

| OS      | Root and purpose folders                                                                                                                                                                                                                                                                      |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS   | `~/Library/Application Support/Ergopti/` (paths.toml, `config/`, `control/`, managed runtimes, locks, LeaseGuardian, pty-sources, RemapRuntime), `~/Library/Logs/Ergopti/`, `~/Library/Caches/Ergopti/`                                                                                       |
| Windows | `%LOCALAPPDATA%\Ergopti\` (paths.toml, `config\`, `logs\`, `cache\`, `control\`, `updater\`, `updates\`, `diagnostics\`, `bundle\`, `_generated\`, `field-run\`)                                                                                                                              |
| Linux   | `$XDG_CONFIG_HOME/ergopti` (config, storage.json, api_keys.json), `$XDG_STATE_HOME/ergopti` (logs, agent_learning.json, llm_thinking_refused.json), `$XDG_DATA_HOME/ergopti` (metrics, managed Ollama), `$XDG_CACHE_HOME/ergopti` (updater ETags), `$XDG_RUNTIME_DIR/ergopti` (control, lock) |

There are two deliberate exceptions, each documented in the TOML:

1. **Windows managed Ollama** goes to `%LOCALAPPDATA%\Ergopti-ollama`, a
   sibling of the root and no longer `ergopti_plus_ollama`. The reason is that
   `ollama_managed_files.ps1` `Open-OllamaManagedRoot` admits only a direct
   LocalApplicationData child and gives it a protected DACL. The end-to-end
   test profiles depend on the same rule. Moving it inside the root needs a
   change to that admission. **Maintainer question:** accept the sibling, or
   change the admission?
2. **macOS owned Karabiner runtime** keeps `ErgoptiPlus`
   (`[owned_runtime.macos]`). This covers the root-owned
   `/Library/Application Support/ErgoptiPlus/**` tree and the per-user
   `~/Library/Application Support/ErgoptiPlus/karabiner`, which the compiled
   core reads (`tools/build/InstalledUserConfiguration.hpp`). These paths are
   compiled into the patched C++ sources (`remap_runtime_patch.py`, which also
   checks socket path lengths) and into the pending runtime artifact
   `ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.2` (TODO item 31). Renaming them
   needs a rebuild and a new artifact pin. Do this in the same change that
   rebuilds the runtime. `ke_paths.lua` now builds these paths from
   `AppDirs.owned_runtime`. About 13 Swift files still spell the system path
   by hand.

The log file prefixes `ErgoptiPlus_` and the bundle ids `com.ergoptiplus.*`
are not folder names and are unchanged.

## Done in the WIP commit

- **Shared table:** `app_dirs.toml` is rewritten with the `[support.*]`,
  `[cache.*]`, `[config.windows]`, `[xdg.linux]`, `[owned_runtime.macos]` and
  `[migration.*]` tables. The codegen validates them: one root per OS, the
  Linux name is the lower-case app name, and a legacy name differs from the
  new one. The three generated files are regenerated. The Lua top-level
  `folder_name` is removed; use `macos.folder_name` or `linux.folder_name`.
- **Linux:**
  - `config_paths` builds every XDG base from `AppDirs.linux`, with the new
    `cache_home()`, `cache(rel)` and `state(rel)`.
  - storage.json and api_keys.json moved to `default_config_dir()`.
  - agent_learning and api_remote use `state()`.
  - The hotstrings and personal_info defaults now honour `XDG_CONFIG_HOME`.
  - The updater ETag moved to `cache()`.
  - driver_control uses `linux.folder_name`.
  - The Ollama install policy reads `linux.folder_name`.
- **macOS Lua:**
  - The logs leaf, metrics cache, TOML cache, proxy relay receipt, Karabiner
    download cache, write-locks, managed Ollama, MLX and native-python paths
    all come from `AppDirs.macos.*`.
  - `field_check_checks` reads `KePaths.OWNED.RUNTIME_DIR`.
  - Comments updated.
- **macOS Swift:** the launcher.lock, pty-sources, LeaseGuardian,
  RemapRuntime, managed Ollama and sessions paths now use
  `kMacOSSupportHomeRelativePath`.
- **Windows:**
  - New `infra/app_folders.ahk` resolver (root, default config, paths.toml,
    cache).
  - `boot.ahk` uses it for paths.toml (now in `%LOCALAPPDATA%`) and for the
    default config.
  - The updater state and staging, the migration cache, the diagnostics
    folder and the personal shortcuts stub are all under the root.
  - The old bundle `paths.toml` copy in `toml_helpers.ahk` is removed.
- **Migration** (minimal, for the maintainer's machines only; project memory
  says no users and no back-compat):
  - The shared core is `_shared/lua/legacy_folder_migration.lua`. It moves an
    entry only when the destination is free and otherwise keeps it and logs a
    warning. It removes an emptied old folder. Before rewriting a paths.toml
    that names an old default folder, it keeps the old text as
    `paths.toml.before-folder-migration`.
  - Vectors: `_shared/tests/corpus/paths/legacy_folder_migration_vectors.json`.
    The contract is `_shared/lua/test/legacy_folder_migration_contract.lua`.
  - Drivers:
    - macOS `adapters/legacy_folder_migration.lua`, run from `init.lua` before
      `config_paths`.
    - Linux `infra/legacy_folder_migration.lua`, run from
      `ergopti_hotstrings.lua` before the logger sink.
    - Windows `infra/legacy_folder_migration.ahk`, run from `boot.ahk` before
      the transition recovery, and never under the startup smoke.
  - Tests: `macos/tests/unit/adapters/test_legacy_folder_migration.lua` and
    `linux/tests/unit/infra/config/test_legacy_folder_migration.lua` (added to
    the Linux manifest).

## Next steps

1. **Windows runners:** add `#Include ../infra/app_folders.ahk` and
   `legacy_folder_migration.ahk` next to `_generated/app_dirs.ahk` in
   `tests/run_all.ahk`, `run_e2e.ahk`, `run_llm_menu_persistence.ahk`,
   `run_native_desktop.ahk` and `support/feature_state_boot_smoke.ahk`. Do the
   same in every runner or generated-source test that includes
   `toml_helpers`, `config_migrate`, `updater` or `healthcheck/collection`:
   `run_llm_model_browser.ahk`, `fixtures/paths_toml_early_owner.ahk`,
   `test_config_migrate.ahk`, `test_feature_state_boot.ahk` and
   `test_toml_build_updated_content.ahk`. `run_llm_model_browser.ahk`
   overrides `AppDirsWindowsManagedOllamaFolderName()`, which is why the two
   Ollama sites still call `EnvGet("LOCALAPPDATA")` directly. Then write an
   AHK test replaying the `paths_text` vectors through
   `LegacyFolderRewritePathsText`.
2. **Update expectations in the remaining old spellings** (about 250 files,
   mostly tests and docs). The scan prototype is a Node script that greps for
   the spellings listed below.
   - Linux tests: `test_logs_dir`, `test_storage_*`, `test_paths_editor_*`,
     `test_log_openers`, `test_error_dialog_bridge`, `win_compat.lua` and the
     fakes.
   - macOS tests: `test_config_paths_*`, `test_logger_logs_dir`,
     `boot_scenarios`, `world.lua`, healthcheck, `test_write_lock_*` and
     `runtime_owner_*`.
   - Swift tests: `LauncherLogTests`, `LauncherEnvironmentTests`,
     `ManagedPTYWorkerTests`, `OwnedRuntimeDownloadedHelperTests`.
   - Windows tests: `test_logs_dir_resolver`, `test_paths_editor_logs_dir`,
     `test_healthcheck_report_issue`, `test_bundle_exclusions`.
   - JS: `test-log-file-names-single-source.cjs`, which pins
     `ergopti_plus_ollama`.
   - Corpora: `redaction_vectors.json`, `day_log_vectors.json`,
     `open_target_vectors.json`.
   - `field_run_protocol.json` segments: Linux `ergopti`, Windows `Ergopti`.
3. **Tools:**
   - `tools/control/request_driver_reload.sh` and `.ps1`: derive from
     `driver_control.json` plus `app_dirs`.
   - `collect-windows-field-report.ps1`: the paths.toml location and the
     config default.
   - `macos_launch_gate.py`, `macos-release-launch.py`, `scan-log-leaks.cjs`,
     `windows-live-checks*.cjs`, `homebrew-cask.cjs` (zap list),
     `run-macos-dev-app.sh`, `test-ahk-full-startup-smoke.cjs`.
   - `.github/workflows/ci-release.yml` release notes.
   - `video/scripts/record-screen.ps1`.
4. **Locale:** rewrite `paths_editor.hint_logs_dir` in all 21 locales through
   the `i18n` skill. It currently says "an ergopti_plus subfolder". Use wording
   that does not name the folder.
5. **Gate:** add `tools/test/test-legacy-folder-names.cjs`. It scans
   `static/ergopti_plus`, `tools`, `.github`, the skills and the docs for
   these spellings:
   - `.config/ergopti_plus`
   - `Logs/ergopti_plus` and `Caches/ergopti_plus`
   - `Application Support/{ErgoptiPlus,ergopti_plus}`
   - `ergopti_plus_ollama`
   - Roaming `APPDATA…Ergopti`
   - `ergopti_plus` as a path component, skipping `static/ergopti_plus` and
     the layout variant `ergopti_plus`

   It allows only the `[migration]` table, the generated owners, the three
   migration modules, this handoff and a baseline for the deferred owned
   runtime files. It also pins that the shell, Python and Go helpers that
   spell `Application Support/Ergopti` by hand match the generated
   `support_relative`. Those helpers are `ensure-*.sh`,
   `native_python_bootstrap.sh`, `managed_ollama_runtime.py`,
   `managed_ollama_hint.py` and `network_bootstrap_posix.go`. Then make
   `test-log-file-names-single-source.cjs` read the folder name per OS.

6. **Docs:**
   - `docs/memory` entry `project-logs-folder-single-resolver` (shared
     architecture), plus `macos-hammerspoon.md` and `linux-web-release.md`.
   - The READMEs, logger `SPEC.md`, `keystats_spec.md` and the skills under
     `.agents/skills` (regenerate the `.claude` mirror).
   - Close the TODO item.
7. **Gates:**
   - Run `npm run test:js` with Node 22.22.2.
   - Run the macOS and Linux Lua suites on a Linux or macOS host. On WSL
     Debian, LuaJIT and Lua 5.4 have luv, but the shell runs as root, which
     the host check refuses.
   - Run the full AHK suite and the boot checks on the PC.
   - `origin/dev` already fails one Linux LuaJIT load, unrelated to this
     work: `_shared/lua/llm/test_prediction.lua:76` has an unexpected symbol
     near `/`.

## What the maintainer checks on each machine (after the branch is finished)

- **Windows:** after the first boot, open `%LOCALAPPDATA%\Ergopti\logs\` and
  find the "Moved legacy folder entry" lines.
  - `%APPDATA%\Ergopti`, `%USERPROFILE%\.config\ergopti_plus`,
    `%LOCALAPPDATA%\ergopti_plus` and `ergopti_plus_ollama` should be gone.
  - `%LOCALAPPDATA%\Ergopti\config\` should hold the configuration and the
    metrics database.
  - `paths.toml.before-folder-migration` should sit beside the new paths.toml.
  - A "Kept legacy folder entry" warning names a clash to resolve by hand.
- **macOS:** after the first launch, `~/Library/Application Support/Ergopti/`
  should hold `paths.toml`, `config/` (formerly `~/.config/ergopti_plus`) and
  `RemapRuntime/`.
  - Delete by hand `~/Library/Logs/ergopti_plus`,
    `~/Library/Caches/ergopti_plus`,
    `~/Library/Application Support/ergopti_plus`, and the old `launcher.lock`,
    `write-locks`, `pty-sources` and `LeaseGuardian` in `ErgoptiPlus/`. Keep
    `ErgoptiPlus/karabiner` (owned runtime).
  - Restart the session once: a lease guardian started by the old build still
    uses the old LeaseGuardian folder.
- **Linux:** `~/.config/ergopti_plus`, `~/.local/state/ergopti_plus` and
  `~/.local/share/ergopti_plus` should have merged into the `ergopti` folders.
  The daemon log lists each move. `~/.cache/ergopti/` should exist. Delete the
  old ETag files `~/.cache/ergopti_updater_etag_*.txt`.
