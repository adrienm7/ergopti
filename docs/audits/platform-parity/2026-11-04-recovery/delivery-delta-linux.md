# Linux delivery delta — immutable Git comparison

Audited base **3a680d9f530a9af686fccc16d3f7611ec7fb034c** → current origin/dev **6d3c8ac5e2993a36c4ee0a1a67dfa3b207318edf**. Date: 2026-11-04. `15` commits compared. This is a read-only delivery delta, not a new audit or native replay. Audit commit 903c66c is to be rebased by the owner; no production files, Git refs or native state were changed here.

## Verdict

All five Linux migration roots **LFM-001 through LFM-005** and updater **LUR-001** remain source-applicable at the compared origin/dev: **no Linux driver source/test changed**, and **no shared Lua migration/updater/budget/path implementation changed**. Current Linux root/path semantics are unchanged. This checks applicability of the exact earlier evidence, not independent replay or closure status.

| Protected subtree                                | Files at audited base | Immutable comparison          |
| ------------------------------------------------ | --------------------: | ----------------------------- |
| `static/ergopti_plus/linux`                      |                  1679 | no changed paths / same blobs |
| `static/ergopti_plus/_shared/lua`                |                   539 | no changed paths / same blobs |
| `static/ergopti_plus/_shared/modules/updater`    |                    11 | no changed paths / same blobs |
| `static/ergopti_plus/_shared/tests/corpus/paths` |                     1 | no changed paths / same blobs |

The complete shared Lua comparison includes legacy_folder_migration.lua, app_dirs.lua, native_path.lua, updater/config_backup{,\_binding}.lua and install_budget.lua/transfer_budget.lua. Updater defaults/channels/signing policy under shared/modules/updater unchanged. Whole Linux comparison includes migration native ls/os.rename ports, ConfigPaths/Storage authority, installer default smoke/owned flow and reload/restarter callers.

## Root applicability

| ID      | Evidence owner checked                                                     | Delivery delta |
| ------- | -------------------------------------------------------------------------- | -------------- |
| LFM-001 | shared migration absent-check/publication + Linux replacing os.rename      | unchanged      |
| LFM-002 | Linux line-framed native ls enumeration + shared nonexistent-entry skip    | unchanged      |
| LFM-003 | Linux migration move + relocated Storage/config_dir locator interpretation | unchanged      |
| LFM-004 | Linux ls close receipt ignored + shared scan/remove result handling        | unchanged      |
| LFM-005 | textual source/destination comparison without physical alias check         | unchanged      |
| LUR-001 | Linux install_owned original synchronous DEFAULT_OPS.smoke/os.execute      | unchanged      |

Opened both existing finding manifests and compared named owners plus broader source trees against immutable commits. No finding reclassified or newly assigned.

## Shared declarations that did change

`_shared/modules/paths/app_dirs.toml` raw file changed, so it was parsed with Python tomllib at both exact commits rather than assumed unchanged. The complete structured value delta is:

- `migration.windows.legacy_ollama_folder`: `ergopti_plus_ollama` → `None`
- `migration.windows.legacy_ollama_folders`: `None` → `['ergopti_plus_ollama', 'Ergopti-ollama']`
- `runtime.windows.managed_ollama_folder_name`: `Ergopti-ollama` → `ollama`

All app.linux_folder_name, defaults.linux, migration.linux, logs/file names, shared purpose folders and other Linux-consumed values are identical. Windows now keeps managed Ollama under its main Ergopti root instead of a protected sibling; its previous legacy name changes to an ordered list. This does not move any Linux config/state/cache/data/runtime base. Generated shared Lua app_dirs.lua is also byte-identical between commits.

All 21 changed shared locale files modify only `menu.tapholds.owned_install`, a macOS remapping-engine retry label. No Linux updater/migration/reload/backup UI locale keys changed. Shared owned_runtimes.json delta adds macOS installer tool metadata only; no Linux runtime row changes. Shared architecture memory similarly changes Windows managed Ollama root text while retaining Linux one-ergopti-folder-per-XDG-base semantics.

Feature inventory/menu-gaps output regenerated upstream and workflow/build/macOS/Windows owners changed; these are not Linux runtime root/receipt fixes. This delta does not qualify the changed macOS/Windows code or feature-generator behavior.

## Commands and limits

Used git rev-parse/log/diff/ls-tree/show at the exact SHAs above; Python subprocess read immutable blobs, tomllib compared every app_dirs value, JSON compared every changed locale key. Assertions require zero diff for each protected subtree and the exact Windows-only app_dirs key delta. No generator, tests, native probes, network, install/reload/systemd or user-state action executed. Original native evidence remains pinned to the audited base; G4 new-host timing was not measured here.
