<!-- docs/tooling/one-folder-name-handoff.md -->

# One folder name: handoff

TODO item "One folder name for Ergopti on the three OS", maintainer decision of
2026-11-03: `Ergopti` on macOS and Windows, `ergopti` under every XDG base on
Linux, no "Plus" in folder names, each driver's data under one root named once,
and the old folders migrated once at boot with a backup. Branch
`next/one-folder-name`, rebased on `origin/dev` on 2026-11-04.

## Target layout

All folders come from `_shared/modules/paths/app_dirs.toml`.
`tools/codegen/codegen-app-dirs.cjs` turns it into `_shared/lua/app_dirs.lua`,
`windows/_generated/app_dirs.ahk` and `AppDirs.generated.swift`; Node tools and
tests read it through `tools/test/lib/app-dirs.cjs`; PowerShell and Python
read the TOML itself.

| OS      | Root and purpose folders                                                                                                                                                                                                                                                                      |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS   | `~/Library/Application Support/Ergopti/` (paths.toml, `config/`, `control/`, managed runtimes, locks, LeaseGuardian, pty-sources, RemapRuntime), `~/Library/Logs/Ergopti/`, `~/Library/Caches/Ergopti/`                                                                                       |
| Windows | `%LOCALAPPDATA%\Ergopti\` (paths.toml, `config\`, `logs\`, `cache\`, `control\`, `updater\`, `updates\`, `diagnostics\`, `bundle\`, `_generated\`, `field-run\`, `ollama\`)                                                                                                                   |
| Linux   | `$XDG_CONFIG_HOME/ergopti` (config, storage.json, api_keys.json), `$XDG_STATE_HOME/ergopti` (logs, agent_learning.json, llm_thinking_refused.json), `$XDG_DATA_HOME/ergopti` (metrics, managed Ollama), `$XDG_CACHE_HOME/ergopti` (updater ETags), `$XDG_RUNTIME_DIR/ergopti` (control, lock) |

The Windows managed Ollama runtime is `%LOCALAPPDATA%\Ergopti\ollama` (maintainer
decision, 4 November). `Open-OllamaManagedRoot` creates it with a protected
DACL (the user and SYSTEM only) and admits it only below a direct
LocalApplicationData child that is not a reparse point and grants no write,
delete, re-permission or take-ownership right to any principal but the user,
SYSTEM and Administrators; that parent is held open without DELETE sharing.
`test_ollama_install_files.ps1` weakens each ACL on the real folders and
expects a refusal.

One deliberate exception, documented in the TOML:

- **macOS owned Karabiner runtime** keeps `ErgoptiPlus`
  (`[owned_runtime.macos]`): the root-owned
  `/Library/Application Support/ErgoptiPlus/**` tree and the per-user
  `~/Library/Application Support/ErgoptiPlus/karabiner` are compiled into the
  patched C++ sources (`remap_runtime_patch.py`) and the pending runtime
  artifact (TODO item 31). Rename them in the change that rebuilds the
  runtime; `tools/test/test-legacy-folder-names.cjs` exempts exactly these two
  spellings.

The log file prefixes `ErgoptiPlus_`, the app and script names and the bundle
ids `com.ergoptiplus.*` are not folder names and are unchanged.

## One-time migration

The shared core is `_shared/lua/legacy_folder_migration.lua`, replayed from
`_shared/tests/corpus/paths/legacy_folder_migration_vectors.json` by the Lua
contract (macOS, Linux) and by
`windows/tests/unit/infra/config/migration/test_legacy_folder_migration.ahk`
(on a private tree under `A_Temp`). Rules:

- A move is a rename and never overwrites. An empty destination folder gives
  way. An entry whose destination holds something is renamed into
  `<root>/before-folder-migration/<its old path below its base>` and logged as
  a warning, so every old folder empties and is removed and the next boot has
  nothing to do. Only a taken backup slot or a failed rename keeps an entry in
  place, with a warning naming both paths.
- A paths.toml whose ConfigDirPath or LogsDirPath named an old default folder
  is rewritten, after its previous text is kept as
  `paths.toml.before-folder-migration` (never replaced).
- A custom logs folder whose last name is exactly the old folder name (or its
  application-named subfolder, as the logs owner saves it) becomes the same
  parent's `Ergopti` (`ergopti` on Linux), and the logs written into its
  application-named subfolder move there; the user's own entries of the old
  folder stay, and any other custom folder is kept (decided by the coordinator
  on 2026-11-11 overnight, to review by the maintainer). macOS rewrites
  LogsDirPath, Linux the `paths.logs_dir` setting; Windows has not taken the
  rule yet.
- Every outcome is logged through the central logger.

Drivers:

- **macOS** `adapters/legacy_folder_migration.lua`, from `init.lua` before
  `config_paths`: paths.toml and RemapRuntime of `ErgoptiPlus/`,
  `~/.config/ergopti_plus` to `Ergopti/config`, and every entry of
  `~/Library/Logs/ergopti_plus`, `~/Library/Caches/ergopti_plus` and
  `~/Library/Application Support/ergopti_plus`. The locks, LeaseGuardian and
  pty-sources of `ErgoptiPlus/` stay for a build that may still run until the
  next login, and `ErgoptiPlus/karabiner` is the owned runtime.
- **Linux** `infra/legacy_folder_migration.lua`, from `ergopti_hotstrings.lua`
  before the logger sink: each XDG base's `ergopti_plus` merges into its
  `ergopti`; the backup is `<base>/ergopti/before-folder-migration/`.
- **Windows** `infra/legacy_folder_migration.ahk`, from `boot.ahk` before the
  transition recovery and never under the startup smoke: the Roaming
  `%APPDATA%\Ergopti\paths.toml`, `%USERPROFILE%\.config\ergopti_plus`, every
  entry of `%LOCALAPPDATA%\ergopti_plus`, then `ergopti_plus_ollama` and the
  `Ergopti-ollama` sibling into `%LOCALAPPDATA%\Ergopti\ollama` (the second one
  to the backup when the first already moved).

The migration is for the maintainer's machines only (no published build used
the old folders) and is deleted once they are moved.

## What the maintainer checks on each machine

- **Windows:** after the first boot, `%LOCALAPPDATA%\Ergopti\logs\` holds the
  "Moved legacy folder entry" lines; `%APPDATA%\Ergopti`,
  `%USERPROFILE%\.config\ergopti_plus`, `%LOCALAPPDATA%\ergopti_plus` and
  `ergopti_plus_ollama` and `Ergopti-ollama` are gone; `%LOCALAPPDATA%\Ergopti\config\` holds the
  configuration; anything under `%LOCALAPPDATA%\Ergopti\before-folder-migration\`
  was a clash to look at.
- **macOS:** after the first launch, `~/Library/Application Support/Ergopti/`
  holds `paths.toml`, `config/` and `RemapRuntime/`; the old Logs, Caches and
  `ergopti_plus` support folders are gone; delete the stale `launcher.lock`,
  `write-locks`, `pty-sources` and `LeaseGuardian` in `ErgoptiPlus/` after the
  next login and keep `ErgoptiPlus/karabiner`.
- **Linux:** `~/.config/ergopti_plus`, `~/.local/state/ergopti_plus` and
  `~/.local/share/ergopti_plus` are gone; the daemon log lists each move;
  delete the old ETag files `~/.cache/ergopti_updater_etag_*.txt`.
