# macOS delivery delta and applicability — bounded read-only review

Immutable audit baseline: `213d65af24d2aa4845ba47743c9bab6787b61964`. Root integration comparison base: `1fa4c28f318258dd1af31920b1a55b8bb4c33de1`. Reviewed fetched delivery target: `89d477dcc06b85b71071e6d5f1fe8d701bf51649` (`origin/dev` at review). Worktree HEAD remained audit baseline; no checkout, production edits, native effects or commits performed.

## Result

The ten recorded macOS findings retain their source mechanisms at this delivery target. **24 directly affected owner/caller blobs compared byte-identical** between the audit baseline and delivery target (register below). The delta changes folder declarations, path resolvers/consumers and adds a boot migration; it does not repair clipboard borrowing, transform destination receipts, secret transport, Keychain rollback, envelope admission or timer committed-ACK consumption. Applicability is source-only beyond the original safe probes; the full campaign was not rerun against delivery dependencies and native macOS remains unexecuted.

| Findings          | Delivery applicability                                                                                                                                                                                                                                                                                                                                     |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MCF-001           | Standalone i18n file-first publication/false receipt and shared authority mechanism unchanged. Its canonical file now ordinarily resides under the new config root; boot migration can move old config before the unchanged locale owner reads it. Original fixed-path scratch evidence remains evidence at its pinned SHA, not a native migration replay. |
| MCP-001           | Apps unconditional stale all-type restore/retry unchanged. Folder migration neither joins native clipboard counts nor adds an Apps restore receipt.                                                                                                                                                                                                        |
| MCP-002           | Text/Apps independent borrower admission unchanged. Changed keymap/init.lua is a comment replacing an old literal config path; no common clipboard admission was added.                                                                                                                                                                                    |
| MCP-003           | Ordinary Text transform callers/optional continuation/global paste route unchanged. Boot/path changes do not introduce destination authority.                                                                                                                                                                                                              |
| MCR-001 / MCR-002 | Encryptor AppleScript source unchanged, including approved overwrite/direct final output/error cleanup and password-bearing shell command. Compiled droplet/native delivery qualification remains.                                                                                                                                                         |
| MCR-003           | Shared cipher/envelope marker, raw SQL ingress and source fail-closed policy unchanged. Root still shared with other OS manifestations.                                                                                                                                                                                                                    |
| MCR-004           | HF token script/TaskLifecycle argument forwarding unchanged; dependency/runtime folder names changed elsewhere, without replacing token-bearing native bash argv. Native observer visibility remains unmeasured.                                                                                                                                           |
| MCR-005           | UI stable entry id, actual coordinator/TokenCrypto and Swift SecItemUpdate owner unchanged. New folders do not version the Keychain account or restore prior secret bytes on metadata rollback.                                                                                                                                                            |
| MCR-006           | Shared migration driver, mac wrapper, actual TimerScheduler and menu caller unchanged. Metrics cache default changes location, but timer acquisition dual ACK still discarded. Initial-refusal idle pass is conditional on that refusal; restart/manual recovery remains possible.                                                                         |

macOS desktop flow had no confirmed finding. Its system-actions owner is unchanged; new folder-migration effects were not included in that earlier desktop coverage.

## New path policy and explicit rationale

Declaration: `_shared/modules/paths/app_dirs.toml`; generated Lua `app_dirs.lua` and Swift `AppDirs.generated.swift` change together. Exact delivery behavior visible in source:

- Root/bootstrap: `~/Library/Application Support/Ergopti/paths.toml`; default config `~/Library/Application Support/Ergopti/config/` replaces `~/.config/ergopti_plus/`.
- Logs: `~/Library/Logs/Ergopti/`; caches: `~/Library/Caches/Ergopti/` (metrics underneath). Launcher logs remain in native default log root independently of LogsDirPath. LogsDirPath normalization appends `Ergopti` when needed.
- Managed support, downloaded RemapRuntime artifacts, locks, PTY sources and reload/control consumers adopt the new support root as declared by their changed owners.
- **Intentional compiled-runtime exception**: root-owned `/Library/Application Support/ErgoptiPlus/Runtime` and per-user `~/Library/Application Support/ErgoptiPlus/karabiner` remain. `[owned_runtime.macos]` explicitly says the patched C++ runtime/artifact pins require rebuilding before this rename; `ke_paths.lua` preserves these values and only moves downloaded artifact home. Do not claim every Plus-named folder disappears.
- Explicit cross-OS policy is `Ergopti` on macOS/Windows, `ergopti` under Linux XDG roots. Native purpose locations remain OS-specific (Console-compatible macOS Logs and purgeable Caches). `docs/tooling/one-folder-name-handoff.md` records the maintainer decision, Windows protected managed-Ollama sibling and Mac compiled-runtime exception.

`macos/init.lua` now invokes `adapters.legacy_folder_migration.run(Logger)` after instance admission and before breadcrumb/log/config reads. Adapter header documents this as **maintainer-machines-only**, no published build having used the old folders, and temporary until those machines migrate. It moves old paths.toml and RemapRuntime, old default config, logs/cache/control entries; occupied destinations go to the new support root's `before-folder-migration` backup path. Prior paths.toml text is backed up and only old default locators rewritten. Old live locks/LeaseGuardian/PTY state remain for an older build until next login; owned karabiner remains by design.

These are source-described policies, **not independently verified migration correctness**. New shared/native migration is a material added owner and is excluded from the original audit's two-dry-pass stop condition. No native old/new build overlap, permission/rename/clash/symlink failure or first-launch migration was executed in this delta review. Existing pinned reports and line references must remain immutable; delivery note should identify changed default user paths instead of rewriting historical evidence as though run on this target.

## Byte-identical owner register

`git rev-parse <sha>:<path>` compared these Git blob identities at baseline and delivery; all matched:

| Owner path (below static/ergopti_plus)                                 | Git blob                                   |
| ---------------------------------------------------------------------- | ------------------------------------------ |
| `macos/infra/i18n.lua`                                                 | `b4def084613831edf030b11b0ee346de4d63c5cb` |
| `macos/modules/shortcuts/actions/apps.lua`                             | `921882f7e745dbe4c7eef4962f9c843ccc490d95` |
| `macos/modules/shortcuts/actions/text.lua`                             | `1243fcb88160cd57495e10f127486a81be3b1879` |
| `macos/modules/shortcuts/actions/text_continuation.lua`                | `294c5322e4cc542c0c7bd64176d9787cf4c10620` |
| `macos/modules/gestures/actions.lua`                                   | `3f4d1ca80532e0aaa1732a6dc07efc735e0c5bbf` |
| `macos/adapters/synthetic_input.lua`                                   | `d19211772c1afe9554778e2254cc57128310a56f` |
| `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.applescript` | `5ce896fae8afd61b97c08a6e2a3179f238f18c39` |
| `_shared/lua/keystats/text_cipher.lua`                                 | `181518555194fc0aad82405a2b4e4060a4c76caa` |
| `_shared/lua/keystats/text_crypto.lua`                                 | `9f5fec572146a01cd3468f56e8650e24d70d6ad3` |
| `macos/modules/keystats/sqlite_writer.lua`                             | `2a8e7f10d94eb641b93dcc18d3085f487a4de69b` |
| `macos/ui/menu/menu_llm/models_manager_mlx_hf.lua`                     | `159c9ff7caeb1ee917a75175c386c27f814fac58` |
| `macos/adapters/task_lifecycle.lua`                                    | `0281a1f2bd659bcf2d6221e9886236b1b700c869` |
| `macos/ui/menu/menu_llm/local_server_panel.lua`                        | `c0420293aee52803b78efb64d1636f5ff7679562` |
| `macos/ui/menu/menu_llm/api_panel.lua`                                 | `d31ccc298927996eb120963eaa0b3e94b94a2d75` |
| `macos/modules/llm/init.lua`                                           | `024836d4ca4da05b93cba8a77ea4fd08a26593c5` |
| `macos/modules/llm/api_token_crypto.lua`                               | `6101dd54d06fc1fb9a7af3b05ae62a04019ebf8f` |
| `macos/launcher/Sources/ErgoptiPlus/KeychainTokenWorker.swift`         | `2e169aa9017f2f43fb44784ddd95652cdc9ad16a` |
| `_shared/lua/keystats/text_migration_driver.lua`                       | `9152ae229cc20816e5cdf0e12b11263193a1a4fb` |
| `_shared/lua/keystats/text_migration_runner.lua`                       | `1b731aa059f0ab78c353d15402a5be1422df7cca` |
| `macos/modules/keystats/text_migration.lua`                            | `45a7f64c7fd1d63193044e687aae4009b1f12010` |
| `macos/adapters/timer_scheduler.lua`                                   | `b231208ffcbc4643d42058f202c5532eddb2daf5` |
| `macos/ui/menu/menu_metrics.lua`                                       | `4a0ff88b2ae6ad3ab57029096f31df5543011163` |
| `macos/modules/gestures/system_actions.lua`                            | `8252a53de5abf161b5357369d4fd6aff466fd57d` |

| `_shared/lua/script_config_authority.lua` | `d82b97943dab3285908430ea12375273063e0e9d` |

Commands inspected immutable git diff/name-status for 1fa4c28..89d477d, then checked finding owners directly across 213d65a..89d477d; new migration and path policy were read with git show without executing them. No comprehensive latest-target regression or new exhaustive audit is claimed.
