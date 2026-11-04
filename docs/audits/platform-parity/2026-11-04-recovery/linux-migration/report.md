# Linux legacy-folder migration audit

Audited commit: `3a680d9f530a9af686fccc16d3f7611ec7fb034c`. Date: 2026-11-04. Scope: `linux/infra/legacy_folder_migration.lua`, shared `legacy_folder_migration.lua`, and their boot/path/storage/native boundaries. Paths below are relative to `static/ergopti_plus/` unless stated otherwise. Audit only; no production or registered-test edits.

Five actionable findings are confirmed. Actual native POSIX/filesystem probes demonstrate one replacing-rename race, two directory enumeration defects, one stranded configuration locator and one self-alias archival. Existing eight migration unit cases still pass. Two consecutive dry passes after the final discovery found no additional roots. Findings concern this new folder migration, not LCF-001's later legacy alias-key importer.

## Entry, ownership and receipts

`linux/ergopti_hotstrings.lua:103` invokes `session_lock.protect`, then `:125–126` invokes the migration before logger installation (`:151`) or bootstrap storage. The adapter constructs config/state/data merge steps from `app_dirs` at `linux/infra/legacy_folder_migration.lua:86–95`, obtains native ports at `:51–69`, calls shared `Core.apply` at `:105`, then prepares cache at `:108`. The returned report is logged at entry line 161. No migration-specific owner, identity snapshot, rollback or admission receipt gates subsequent boot.

The common launcher already owns its flock. However `linux/infra/session_lock.lua:55–57` explicitly accepts a direct run without an inherited marker; `acquire` is only called inside `main` at entry `:820–826`. Therefore direct AppImage/Nix/manual starts reach migration before they contend for the singleton lock. The full entry was inspected, **not executed**; probes call its actual migration owner using private paths. Neither Lua concurrency nor an impossible second callback is needed for a destination to arrive between two filesystem calls.

Shared `move_entry` (`_shared/lua/legacy_folder_migration.lua:90–115`) checks source/destination names, optionally removes an empty destination directory, routes occupied names to a backup, then calls `rename_into` (`:75–80`). Shared `apply` (`:129–157`) iterates names and removes an emptied source. Native rename is plain `os.rename`; native list is `ls -A` read by lines, with its completion result ignored. Shared `rewrite_paths_file` exists, but Linux `run` never calls it; Linux configuration/log locators live in bootstrap JSON rather than macOS/Windows paths.toml.

## Confirmed findings

### LFM-001 — Concurrent destination arrival is overwritten by a supposedly non-replacing move

Severity **high**; confidence **high**. Violates **G3** and the explicit **never-overwrite migration property**.

Reproduction: prepare legacy `storage.json=LEGACY`, leave current `storage.json` absent. After migration checks the destination, have an external writer create `storage.json=CONCURRENT-NEW` before the native rename. The actual adapter's `os.rename` replaces that newer file, removes the legacy source, and reports one successful move with no backup/kept record. `probes/native.lua race` inserts only the competing filesystem arrival at the rename boundary, then calls the original native port. Both engines reproduce the actual replacement.

Root: shared `move_entry:92,110` separates admission from effect; `rename_into:78` invokes adapter `linux/infra/legacy_folder_migration.lua:66`, whose POSIX replacing rename does not enforce the supposed free-target contract. The in-memory contract's `rename` explicitly refuses existing targets (`_shared/lua/test/legacy_folder_migration_contract.lua:57–58`), hiding the native mismatch. The same race can occur at backup publication after `:97`; no second backup race is needed to establish this root.

Refutations attempted: ordinary launcher serialization limits competing daemon starts, but direct boot order above and independent config writers leave the path reachable. Single-threaded Lua does not serialize other processes. Existing-target positive control correctly preserves the target when it exists _before_ the check; it does not cover an arrival afterwards. No need to claim native full-daemon reproduction or that macOS/Windows are immune.

Required regression: run actual native migration with a destination created between admission and move, for both live and backup destinations; require the newer bytes preserved and old bytes retained/backed up with an honest refusal. Use an atomic no-replace primitive, rather than another name precheck.

### LFM-002 — Legal newline entry names silently fail migration

Severity **medium**; confidence **high**. Violates **G2** and complete migration of admitted POSIX names.

Reproduction: create one actual legacy entry named `line\nbreak` (LF byte). Native `list` returns two names `["line","break"]`; shared `move_entry` finds neither, so report is moved=0, kept=0, removed=0, cache=true. The original entry remains under the obsolete root and repeated migration has the same empty receipt. `probes/native.lua newline` executes real `ls`, both engines reproduce it.

Root: adapter `:57–61` uses line-oriented `ls` output as filename framing. Shared `apply:146–150` trusts those fabricated names; `move_entry:91` silently skips nonexistent entries. This is not shell quoting failure: independent controls preserve single quotes, tabs, Unicode, leading dashes and backslashes. Destination and source commands already quote paths and use `--` appropriately.

Required regression: exact filename-byte enumeration, including LF, must migrate the intended entry or produce a named refusal. Do not “fix” this with another newline-delimited shell listing.

### LFM-003 — Relocated nested configuration keeps its obsolete bootstrap locator

Severity **medium**; confidence **high**. Violates **G2** and migration preservation of active configuration identity.

Reproduction: use a supported absolute config override `<config-base>/ergopti_plus/custom`, containing `config.toml`, and legacy bootstrap JSON `{"paths.config_dir":"<config-base>/ergopti_plus/custom"}`. The actual migration moves `custom/` and `storage.json` to `ergopti/`. Actual `adapters.storage` loads the moved bootstrap bytes; actual `ConfigPaths.config("config.toml")` still resolves the old now-missing path. The configuration bytes exist at the new path but are no longer selected. `probes/native.lua override` executes those real modules with process-local environment lookups directed exclusively to its owned fixture.

Root: Linux adapter's plan/run `:86–108` relocates entries but does not update/reconcile bootstrap locators. `linux/infra/config_paths.lua:127–139` trusts the stored absolute `paths.config_dir`; its ordinary setter admits absolute directories (`:144–160`), including this formerly valid location. Storage now reads only `default_config_dir()/storage.json` (`linux/adapters/storage.lua:76–84`). No migration metadata maps a moved ancestor to dependent locators. Boot continues after success logs; it does not warn that its selected configuration path was displaced.

Scope qualification: this needs an explicit override inside a relocated legacy root; the ordinary default config path was already `ergopti` and is unaffected. Arbitrary external overrides should remain untouched. An old _default_ log override is not an additional finding: the former setter deletes default values rather than saving them, so merely inventing such a stored value is not adequate admission evidence. macOS/Windows rewrite exact old defaults through paths.toml, but this Linux JSON nested-override case is distinct and those paths are not asserted safe.

Required regression: migrate a valid nested override and require the same configuration to remain active, or refuse movement with a clear remediation requirement. Include default and unrelated external-override controls, and restart after migration.

### LFM-004 — Native enumeration refusal is reported as an empty successful scan

Severity **medium**; confidence **high**. Violates **G2**.

Reproduction: under actual uid 1000, create a legacy directory holding `storage.json`, then chmod it to 000. Actual native `ls` is denied; `Migration.run` still returns moved=0, kept=0, backed=0, cache=true. No report entry exists for the refusal, so `log_report` has no warning to emit. Restore permission and rerun: the same actual owner moves storage successfully. `probes/list-permission.lua` and both engines' dry-pass permission receipts reproduce this without root or a fake shell.

Root: native `list:63` drops `pipe:close()`'s exit acknowledgment and returns an empty table. Shared `apply:146` also converts a nil list to `{}`, and its final empty-directory removal failure at `:152–155` is unreported. Data remains in the old root while boot reads the new bootstrap path, permitting neutral/fresh state instead of the old settings without a migration diagnostic. The probe proves absent reporting and later recovery; it does not claim an irreversible store loss or execute subsequent daemon startup.

Required regression: real failed directory enumeration must produce a report refusal identifying the root and prevent an unqualified successful migration receipt. Test absent, truly empty and inaccessible sources separately; retain successful retry after permissions return.

### LFM-005 — A legacy-root symlink to the current root archives active files as their own clashes

Severity **medium**; confidence **high**. Additional physical source/destination identity preservation property; the clash warning is present.

Reproduction: create current `<base>/ergopti/config.toml=ACTIVE`; create a legacy-root symlink `<base>/ergopti_plus → <base>/ergopti`. The native adapter follows that source directory while listing. Each source entry is also its destination's exact physical object. Shared `move_entry` interprets the same config file as an occupied destination and actually moves it into `ergopti/before-folder-migration/ergopti_plus/config.toml`. The default active config path is now absent. Next migration does not restore it; it tries to archive the backup ancestor into its descendant, yielding a kept rename failure. `probes/native.lua alias` reproduces both phases on actual symlinks/renames.

Root: plan and `move_entry` compare only textual roots/names; no lstat/realpath/device-inode identity excludes self-migration before enumeration and backup. An actual destination-clash warning is logged, but it inaccurately treats one live object as two independent stores. Preservation in backup does not preserve active behavior. This is narrower than generic symlink-to-external-directory policy: aliasing the already-canonical root means no distinct legacy payload exists to migrate.

Required regression: legacy root symlinked to current root must leave active files in place and remain idempotent. Cover aliases through an intermediate symlink and prevent backup descendants from becoming new migration input. Keep genuine independent-root clash backup behavior.

## Integration qualification

Canonical LFM-005 uses the additional physical-identity/active-configuration preservation property. The native clash warning exists; it is not reclassified as wholly silent G2 failure. The defect is archiving the active object as if it were an independent old copy. Submitted labels remain separately preserved.

## Execution, controls and dry-pass ledger

All native effects stayed under owned temporary directories in `probes/`, which each successful fixture retired. Recorded modules are actual production Lua modules; the only controlled effect in the race proof is creation of a real competing destination immediately before invoking the actual `os.rename` port. No input, clipboard, credentials, real HOME/XDG folders, live application or complete daemon was touched. Source HEAD remained the pinned commit and Git status remained clean.

Commands:

```text
/workspace/scratch/parity-toolchain/ci-bin/luajit /workspace/scratch/parity-recovery/linux-migration/probes/native.lua
python3 /workspace/scratch/parity-recovery/linux-migration/probes/dry-passes.py luajit dry-pass-1
python3 /workspace/scratch/parity-recovery/linux-migration/probes/dry-passes.py lua dry-pass-2
```

The first native discovery sweep confirmed LFM-001/002/003; a real permission-denial probe confirmed LFM-004. The final self-alias countercheck confirmed LFM-005 and reset the dry ledger. Only then:

| Pass  | Checks                                                                                                                                                                                                                                                                                                                                       | Result / new roots                                            |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Dry 1 | 11 isolated real-filesystem cases on LuaJIT: healthy merge/restart, destination arrival, LF name, refused rename/retry, nested override, same-root alias/restart, external symlink observation, occupied-backup retry, unusual-name controls, parent refusal/retry, cache refusal/logging; registered suite; actual permission refusal/retry | All 13 commands passed; registered cases 8/0; **0 new roots** |
| Dry 2 | Same independent cases on Lua 5.4.8, reread boot singleton and exact shared/native contract mismatch, compared narrow macOS/Windows ownership APIs and documented constraints                                                                                                                                                                | All 13 commands passed; registered cases 8/0; **0 new roots** |

`logs/dry-pass-{1,2}.json` list exact command, exit and output paths. These passes intentionally repeat checks and historical findings; they are not 26 unique tests or fresh native desktop evidence. Registered unit vectors execute shared paths.toml rewrite pure/memory contracts; Linux has no production caller of that rewrite API. The migration report contains only 8 registered cases despite many vectors inside them.

A first permission-probe launcher draft attempted unnecessary `chown`/setpriv and was denied; environment inspection showed ordinary uid 1000 already supplies meaningful permission denial. The retained proof simply runs with that uid and passes. This fixture authoring error is not a product finding. Initial mistaken SQLite path lookup belonged to the earlier delivery review and is unrelated to this scope.

## Coverage register, refutations and gaps

| Boundary                                                               | Coverage and practical limit                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Entry/session lock → migration → logger/storage                        | Exact source order inspected; inherited launcher lock distinguished from direct-entry lock acquired later. Full daemon not started.                                                                                                                                                     |
| Config/state/data plan, empty/absent roots, overlap of named XDG bases | Plan source plus existing shared/native healthy cases. Normal roots and repeated boots covered; arbitrary nested XDG-base matrices not exhaustively executed.                                                                                                                           |
| Source/destination/backup byte identity                                | Actual native success, clash, empty-target, occupied backup, concurrent destination arrival, same-root symlink; atomic no-replace gap confirmed. No real process crash/power-loss injection.                                                                                            |
| Native enumeration                                                     | Actual normal and unusual names, LF, real permission refusal. Missing executable/partial output follows the same missing receipt mechanism but was not separately executed. Native file-as-root and FIFO/mount transitions were source observations, not promoted findings.             |
| Effect refusals and recovery                                           | Controlled rename refusal, actual blocking parent, backup occupied, cache mkdir failure; safe successful retry controls. Cross-device EXDEV/ENOSPC and torn filesystems unavailable.                                                                                                    |
| Locator preservation                                                   | Actual relocated storage + config resolver, nested config override. Default resolver source and current default control implicit in healthy setup. Logs custom overrides and CLI `--config` nested under moved roots require further product-specific checks; no extra finding claimed. |
| Shared rewrite owner                                                   | Existing pure/memory vectors for no-change, exact default spelling, previous-text backup and backup refusal. Linux route does not call it; native macOS/Windows rewrite I/O was not executed.                                                                                           |
| Lifecycle/ownership                                                    | Migration runs synchronously once per boot; no pause, reload or cancellation API exists. Restart/idempotence tested in actual owner; no invented cancellation promise.                                                                                                                  |

Generic source-root symlink to an unrelated external directory was executed as a policy observation: native listing follows it and moves its contents into the new root, leaving the symlink. The migration's policy on draining such shared external directories is **unknown**; it was not promoted merely because symlinks exist. LFM-005 instead proves same-object archival of current state. No additional issue was inferred from legitimate backup warnings, preserved old data on native refusal, or arbitrary externally malformed files.

## Intentional differences and policy

| Difference                                                                   | Evidence and intent category                                                                                              | User effect / counterpart                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Temporary maintainer-only migration                                          | Explicit shared header `:24–27`, Linux adapter `:19–21`, and repository handoff `docs/tooling/one-folder-name-handoff.md` | No published Linux build used the old folders. Risk population is maintainer installs; this limits exposure, not the never-overwrite/active-state contract. Migration is intended for deletion after those machines move. |
| One name but OS-specific purpose folders                                     | Explicit `_shared/modules/paths/app_dirs.toml`                                                                            | Linux keeps per-XDG config/state/data/cache/runtime `ergopti`; macOS/Windows use `Ergopti` and their own conventions. This is an intentional locator difference.                                                          |
| Linux merges config/state/data entries and prepares cache; runtime recreated | Explicit adapter plan `:86–108` and app_dirs migration table                                                              | Cached/runtime state is not promised durable migration. macOS plan (`macos/adapters/legacy_folder_migration.lua:106–122`) moves selected support entries, config, logs, cache and control; Windows uses its own roots.    |
| Rename rather than copying runtimes                                          | Explicit shared header `:18–21`                                                                                           | Fast same-base move and preservation on ordinary rename refusal. Cross-volume errors should be reported, not treated as a reason to invent copying. Native replacing-target race is not an explicit exception.            |
| Keep existing current entry; back up old conflicting entry                   | Explicit shared header `:12–17` and shared vectors                                                                        | Intended precedence. Positive native clash controls pass. Same-object alias is not two conflicting entries; independent-arrival overwrite violates precedence.                                                            |
| Rewrite default locators                                                     | Explicit macOS `M.rewrites/run:129–154`; Windows `LegacyFolderRewritePathsFile`; Linux has no rewrite call                | Linux ordinary default config already points to `ergopti`; no general rewrite is necessary for that default. There is **no explicit decision** authorizing displacement of a valid nested override.                       |
| Native enumeration and move APIs                                             | Actual Linux `ls`/`os.rename`; macOS `hs.fs.dir`/`os.rename`; Windows native loop/move                                    | API choice is observed implementation, not evidence that byte loss/refusal swallowing is intentional. No macOS/Windows native safety or immunity claim made.                                                              |

## Memory, performance and duplicate provenance

Read AGENTS, routed memory index, relevant Linux native replacement memory (`project-linux-a-corrupt-store-moves-aside-without-replacing`), shared folder-single-source memory, maintainer decisions, and `adversarial-audit`, `linux-driver`, `cross-driver-parity` instructions. They informed atomic-effect, exact-byte, receipt and OS qualification checks; they were not treated as evidence that this code was already correct. Existing `2026-11-04-flows` finding manifests/TODO were searched: legacy alias retirement and crypto migration are different owners; none of the five roots is an existing folder-migration finding there.

G4 is **unmeasured**: no full boot latency/memory benchmark or desktop log was collected. Shell-process count and sync ordering are source observations only. Memory watch-list: the report/list tables grow with legacy entry count; no leak or unbounded retained owner was proven. The actual port closes its listing pipe but ignores exit receipt; that is LFM-004, not evidence of a descriptor leak. Native crash consistency, adversarial multi-process alias swaps and unrestricted pathname matrices remain honest coverage gaps.

Manifest validation: JSON required fields, unique IDs, severity/confidence enums and both 13-command receipts were checked (`logs/manifest-validation.txt`). The repository audit-workflow CLI refuses reports outside the repository before schema validation. This task explicitly requires scratch-only artifacts, so no repository copy was made to bypass that location rule.
