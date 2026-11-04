# macOS legacy-folder migration — recovery and locator custody audit

Audited immutable SHA **3a680d9f530a9af686fccc16d3f7611ec7fb034c**, 2026-11-04. Scope is only `macos/adapters/legacy_folder_migration.lua`, shared migration core, and directly relevant init/config-path/launcher dependencies. Production, registered tests and user data remained untouched. Six confirmed local roots are recorded (five initial roots plus the immutable-source MFM-006 supplement below); shared mechanisms require cross-agent/root deduplication. The previous 26-flow audit and TODO were checked: new folder migration was expressly excluded from that campaign, not certified by its dry passes.

Applied adversarial-audit, its Hammerspoon/report references, hammerspoon-driver and false-green-tests. Read AGENTS; routed memory index, shared folder single-resolver/maintainer policy, native directory iterator/permission and absence/lstat watch-list, workflow and one-folder handoff. Parent explicitly authorizes scratch artifacts and custom scope/IDs rather than the legacy skill report location. No native Mac qualification is implied.

## Integration qualification

Canonical MFM-001 is medium severity and uses the additional durable-location/restart-consistency property: initial I/O refusal is warned, later malformed startup may fail loudly, and complete backup bytes remain. It is not an entirely silent G2 failure or irreversible physical data loss. Submitted labels are separately preserved.

## Evidence boundary and execution

`probes/public-flow.lua` loads the **actual macOS public Migration.run, native_ports, shared core, generated AppDirs, shared TOML parser and fresh actual ConfigPaths resolver**. Its hs.fs boundary uses actual LuaFileSystem1.8.0 functions on Linux; `io.open`, os.rename and actual private files remain real. Fault seams refuse one native rename/final write or publish a concurrent destination immediately before actual rename; they do not replace the migration control flow. Partial-write fault physically writes a prefix to canonical file then returns false. Native directory denial is **real chmod000/Permission denied at executed UID1000**, not an invented exception stub. Generic-for retains lfs iterator+state arity.

Fresh ConfigPaths uses its actual bootstrap read/parse/selection flow. Only FileSystem.read_with_status is a native-data port returning bytes/status from real fixture files; its whole source-receipt/permission transaction layer is not claimed executed. A fresh module load establishes destination adoption; full Hammerspoon restart is source-traced, not executed. Malformed bootstrap additionally drives actual ConfigPaths.init to false. Synthetic Logger records diagnostics. No native desktop, clipboard, Keychain, user configuration, external service or logs were accessed.

Commands:

```
python3 /workspace/scratch/parity-recovery/macos-migration/probes/run.py
python3 /workspace/scratch/parity-recovery/macos-migration/probes/run-existing.py
python3 /workspace/scratch/parity-recovery/macos-migration/probes/run-dry-passes.py
```

Each mode runs in a separate real Lua5.4.8 process through `/workspace/scratch/parity-toolchain/ci-bin/lua`, with HOME and ERGOPTI_PATHS_FILE bound to its own `probes/tmp-*` directory. Python TemporaryDirectory removes only its own created fixture. All 12 public modes pass their explicit broken/healthy observations. Six registered modules run separately, **36 cases pass, zero fail**. These 36 are distinct case counts, not multiplied by repeated dry-pass executions. Machine data/logs: `logs/results.json`, `logs/existing-results.json`, each individual mode/module output. `logs/dry-pass-ledger.json` records both final consecutive passes.

## Entry → owner → effect → receipt → restart map

| Boundary                       | Actual production flow and source                                                                                                                                                                                                | Coverage                                                                                                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Entry/ownership                | Launcher main.swift:65 managedPathsFile and :1005 ERGOPTI_PATHS_FILE -> admitted runtime init.lua:170–175 -> direct Migration.run(Logger). Admission precedes mutation; breadcrumb/config/log reads follow.                      | Source ordering and existing test assertions. Real launcher/native instance admission not executed.                                                      |
| Plan                           | Mac adapter:106–122 moves selected old support entries paths.toml/RemapRuntime, whole legacy config root, and merges logs/cache/control. Other old support runtime entries deliberately stay.                                    | Actual generated plan in all public modes. No separate runtime installation effect.                                                                      |
| Move/empty target/clash/backup | Shared core move_entry:90–115 and apply:129–160; native make_dir follows actual filesystem components; native rename is os.rename. Existing nonempty targets move source to backup; occupied backup keeps original.              | Real normal/clash/occupied-backup/idempotence controls; rename false, newer destination interleaving; symlink observation.                               |
| Locator publication            | Mac run:152–155 always invokes shared rewrite_paths_file after apply; exact old-root rules at :129–140. Shared parser is ad hoc text matching at :188–211, backup+final write at :218–228.                                       | Actual native files, partial/final refusal, valid nested/literal locators, unrelated custom override; actual TOML read/selection.                        |
| Report/next startup            | Core.log_report:243–264 logs moves/kept/backup_refused then returns; no durable phase/recovery journal. Init ignores returned report and continues after ordinary false receipts; thrown list aborts direct call.                | Repeated public run, fresh path resolver and malformed init refusal. Source reboot continuation only, no full native boot.                               |
| Persistence/cancellation       | This migration is synchronous boot work, not a timer/callback owner. No pause/cancel protocol exists. Restart retries remaining source entries, but no phase record correlates completed moves, copied backup and locator state. | Reentry/restart snapshot cases covered. No synthetic timer scenario invented. External concurrent writer treated separately from event-loop concurrency. |

## Confirmed findings

### MFM-001 — Refused bootstrap rewrite leaves a backup that blocks automatic restart recovery

Severity **medium**, confidence **high**. Additional durable-location/restart-recovery consistency property; initial errors may already be loud.

Run probes/run.py modes rewrite-refusal and partial-write: actual public macOS migration moves old config and creates full prior bootstrap backup; native write port then refuses before mutation or after real prefix write. Fresh public run refuses retry due existing backup, or calls malformed prefix unchanged. Actual ConfigPaths resolver keeps old absent folder; malformed control init returns false. All filesystem state is disposable POSIX scratch.

Root: Shared legacy_folder_migration.rewrite_paths_file:218-228 creates backup then writes canonical bootstrap in place without commit/recovery identity; any existing backup prevents retry, and rewrite_paths_text does not parse malformed current bytes. Mac native write:84 opens final path wb and recovery never adopts confirmed prior bytes.

Diagnostics/false-green limit: First run warns backup could not be written even though complete backup exists and final write failed. Restart either repeats that misleading warning or reports unchanged while bootstrap is malformed; actual path init may then loudly refuse. No claim that the initial I/O error is entirely silent.

Regression: Public run+fresh path resolver over actual private files: backup success followed by final open/write/close refusal, partial/truncated/empty current file, process cut after backup, repeated restart; preserve unrelated locator bytes and recover a confirmed old/new pairing without overwriting unrelated existing backups.

### MFM-002 — Refused configuration move still publishes a locator to the absent new folder

Severity **medium**, confidence **high**. No invented G-code; additional property: A migrated bootstrap locator must identify the confirmed configuration location, or publication/boot must refuse truthfully.

Run probes/run.py rename-refusal: real public Migration.run uses real native ports except exact old-config rename returns nil,error. Old config bytes remain at old path; report.kept records refusal, but paths.toml rewrites to new root and fresh actual ConfigPaths module selects nonexistent new config. Healthy move+resolver control selects preserved data.

Root: macOS adapters/legacy_folder_migration.lua:152-154 calls Core.apply then unconditional rewrite_paths_file with static old->new rules; report.kept/backed_up/moved outcomes never authorize the rewritten ConfigDirPath.

Diagnostics/false-green limit: Rename refusal is already WARN, so do not call it globally silent. Subsequent INFO says paths.toml now names new defaults and actual boot resolver adopts an absent location; no receipt connects that publication to failed migration.

Regression: Refuse each physical move/parent create while existing exact old locator is authoritative; fresh loader must continue reading old confirmed bytes or explicitly stop, not select absent new root. Cover later successful retry and distinct occupied-destination backup policy.

### MFM-003 — Valid explicit configuration locators become dangling after their containing folder migrates

Severity **medium**, confidence **high**. Guarantees G2.

Run probes/run.py nested-override and literal-override. Actual mac plan renames full legacy config root. ConfigDirPath pointing to its custom subdirectory, or a valid single-quoted TOML literal naming the exact root, stays unchanged. Actual shared TOML codec+fresh ConfigPaths accepts old value and selects absent old path, while original config exists under migrated root. Outside-root custom override control stays valid.

Root: macOS plan:114 moves entire old config tree, but rewrites:132-135 matches exact root spellings only; shared rewrite_paths_text:192 only recognizes double-quoted assignment lines. Valid resolver inputs outside this ad hoc match are not mapped to the confirmed relocated data.

Diagnostics/false-green limit: Migration reports successful move and paths_file unchanged, without identifying that a still-valid authoritative locator now points to missing data. Existing tests cover double-quoted exact defaults and unrelated overrides, not relocated nested/valid alternate TOML inputs.

Regression: Compose actual public migration, shared TOML parser and fresh resolver for nested old-root overrides, supported literal/basic/multiline path strings, trailing separators and unrelated custom roots; selected config must remain byte-preserved/reachable or migration must refuse before moving it.

### MFM-004 — Destination check followed by POSIX rename can overwrite a newer concurrently published file

Severity **high**, confidence **high**. Guarantees G3.

Run probes/run.py destination-race. Actual public run checks new paths.toml absent; recording native rename boundary publishes newer sentinel at destination then invokes real POSIX os.rename. Sentinel is replaced by legacy bootstrap, then rewritten; report records ordinary moved, not conflict/kept. This is deterministic interleaving injection around real POSIX primitive, not a measured native Mac race.

Root: shared move_entry:91-110 tests exists(to) separately from rename_into:75-80; macOS native rename:62 is os.rename, which permits replacement of an existing destination file. No no-replace publication receipt revalidates/adopts the intervening destination.

Diagnostics/false-green limit: The newer file disappears while report calls rename successful. Existing memory_ports.rename refuses an occupied target atomically, unlike actual POSIX os.rename, so vector success does not cover the native contract.

Regression: Actual private filesystem + interleaving boundary: create destination after absent observation, replace an empty destination after its removal, and occupy backup after its check; assert byte-exact newer content survives and conflict/new-owner outcome is truthful. Qualify Darwin native execution separately.

### MFM-005 — Native directory listing refusal escapes migration and aborts driver initialization

Severity **medium**, confidence **high**. Guarantees G1.

Run probes/run.py native-list-denied as unprivileged user (executed UID1000). Actual native_ports uses LuaFileSystem POSIX ports; chmod000 on private legacy support directory lets stat identify directory but lfs.dir raises Permission denied. pcall around real public Migration.run receives error and no report. Production init:175 calls run directly, so later initialization is skipped. No Hammerspoon/macOS startup was executed.

Root: Mac native_ports.list:53-60 executes fs.dir without protected closure; shared apply:146,152 and public run:152 do not contain throws. This bypasses the kept/report/log failure protocol and escapes direct init entry.

Diagnostics/false-green limit: Not claimed completely silent: native/Hammerspoon top-level exception may be visible. Migration report and per-path refusal reason are not emitted and the driver initialization terminates at the unhandled boundary. In-memory tests model successful listings and never exercise native enumeration denial.

Regression: Real macOS native fs.dir permission/missing-after-stat/iterator throw plus public migration and boot containment: return explicit kept/failed path and preserve originals; verify no unhandled startup exception, correct restart retry and faithful iterator/state arity.

## Decisive qualifications and refutations

- **Do not count refusal/recovery twice:** MFM-001 combines final write refusal with/without partial mutation and existing-backup restart dead end. They share one backup/final-publication owner. MFM-002 is different: even a successful canonical write publishes the wrong location when physical move failed. MFM-003 concerns valid locators never recognized at all after a successful move. Root may coordinate these related path/locator mechanisms under a common implementation transaction without counting OS manifestations separately.
- **Initial warnings are loud:** rename-refusal already says kept/rename_failed; rewrite-refusal emits WARN. Their defects concern inconsistent resulting canonical state and inadequate recovery, not absence of every diagnostic. MFM-001 misleadingly says backup could not be written when full backup was written and final write failed; partial prefix can subsequently be labelled unchanged. Actual path init then refuses malformed input loudly.
- **An occupied new destination is an explicit policy:** destination-clash preserves NEWER-CONFIG and backs up old bytes, while occupied-backup preserves both and keeps original old bytes. These controls pass; choosing newer config here is not MFM-002. No all-or-nothing merge is promised for every folder in one boot.
- **Unrelated custom overrides work:** custom-override keeps external fixture config and its bytes unchanged while migrating unused legacy default. MFM-003 is limited to locators whose actual target was moved (nested or valid TOML literal), not every custom folder.
- **No blanket symlink finding:** symlink-source follows the old logs link and moves its target entries into new logs; the link remains. This is a reproduced observation with unknown follow/refuse product policy, **not a confirmed violation** absent a migration root-containment promise. Do not conflate logger's explicit permission/retention no-follow policy with permission to invent one for this new owner. Linked destination/ancestor, aliasing/nesting and dangling-link behavior are source-reviewed but not certified safe by this case.
- **Native rename differs from memory fake:** registered memory_ports.rename checks exists atomically and returns refusal, whereas native os.rename may replace an intervening file. The real POSIX interleaving probe supports MFM-004; actual Darwin race/external process timing remains unexecuted. This is an explicit Never Overwrite contradiction, not a generic demand for kernel CAS on every advisory writer.
- **Directory iterator arity is correct:** the native list uses `for name in fs.dir(dir)` and retains both values. MFM-005 concerns unprotected throwing enumeration, not the historical dropped-state defect. Hammerspoon's documented/memorized fs.dir throwing contract supplies the native Mac bridge; actual lfs EACCES executes the POSIX side. No keyboard lockup/crash is asserted beyond initialization abortion.
- **Backup data is not universally lost:** complete prior bytes are available in MFM-001's backup. The problem is missing automatic adoption/retry and potentially unusable canonical file; manual repair can recover. MFM-002 may recover on a later successful physical move; it is not irreversible data destruction.

## Two consecutive dry passes

Last newly confirmed roots were reopened against native contracts and source before these passes. Ledger timestamps and per-pass independent output snapshots are in `logs/dry-pass-ledger.json`, `D1-results.json`, `D2-results.json`, and corresponding registered result files.

| Pass      | Bounded review                                                                                                                                                                                                                                                                    | Result                                                            |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Discovery | Public run/actual resolver binding, exact config rename refusal, final canonical write/partial prefix, nested/literal accepted locators, real native rename replacement and real directory EACCES                                                                                 | MFM-001 through MFM-005; reset count                              |
| D1        | Revisited every plan step's move/empty target/clash/backup path, parent creation and all native return/throw contracts; bootstrap parse/loader state after interruption and restart. Executed all 12 safe modes plus six fresh registered modules/36 cases.                       | No new confirmed root                                             |
| D2        | Revisited current/default/custom/nested/valid TOML locators, unrelated state preservation, actual target owner and symlink uncertainty; source comparison to Windows/Linux and explicit maintainer/runtime exceptions. Independently reran all 12 modes and six modules/36 cases. | No new confirmed root; two dry passes reached for stated register |

These passes do not certify every macOS native filesystem interleaving. No finding quota was used; new evidence would reset this stop condition.

## Intentional differences and unknown rationale

| Behavior                                 | User effect / counterpart                                                                                                                                                                                                  | Rationale provenance                                                                                                                                                                                                   |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One root name, native purpose paths      | Mac Application Support/Ergopti, Logs/Ergopti, Caches/Ergopti vs Windows LOCALAPPDATA/Ergopti and Linux per-XDG ergopti.                                                                                                   | **Explicit maintainer decision**, shared app_dirs.toml and one-folder handoff; Console/Caches/XDG convention constraints.                                                                                              |
| Migration limited to maintainer machines | Runs at boot over known legacy roots, intended to be removed after maintainer conversion; no perpetual compatibility layer promised.                                                                                       | **Explicit source/header and handoff**, no published build used old folders. This limits deployment population, not native failure contracts.                                                                          |
| Older/newer clash                        | Existing nonempty target wins; old entry goes to backup, or remains if backup occupied.                                                                                                                                    | **Explicit shared Never Overwrite policy**, actual controls pass absent concurrent publication; same vector policy on Windows/Linux.                                                                                   |
| Mac paths.toml rewrite                   | Moves old managed bootstrap and rewrites only specified default locators; Linux uses storage/other XDG ownership and does not call rewrite_paths_file in its migration. Windows has its own matching rewrite/backup owner. | **Explicit architecture**, adapter plans and Windows LegacyFolderRewritePathsFile source. Does not justify dangling locators or failed recovery.                                                                       |
| Shared vs Windows native primitives      | Mac/Linux use os.rename; Windows LegacyFolderRenameInto uses DirMove/FSMove with its own no-overwrite adapter and caught errors. Windows rewrite uses verified copy plus FSWrite.                                          | **Native mechanism**, no native PC execution here. Shared core findings require dedup; do not claim all Windows primitive behavior matches POSIX.                                                                      |
| Compiled owned Karabiner runtime         | `/Library/Application Support/ErgoptiPlus/Runtime` and per-user `ErgoptiPlus/karabiner` remain; downloaded RemapRuntime moves to Ergopti root.                                                                             | **Explicit compiled-artifact constraint**, `[owned_runtime.macos]` and handoff. Rename requires runtime rebuild/pin.                                                                                                   |
| Old live locks/guardian/PTY data stay    | Old support runtime state may remain until next login while a previous build may run.                                                                                                                                      | **Explicit native lifecycle decision**, Mac adapter header; retained state is not failed migration. Concurrent new file publication is nevertheless compatible with this environment and must respect Never Overwrite. |
| Symlink follow/refuse and nested aliases | Observed source link drains referent entries; source configuration link would move link itself; make_dir follows ancestor links.                                                                                           | **Unknown intended policy** for migration, no new finding inferred from logger rules. Native destination aliases/mounts require qualification.                                                                         |
| Locator/outcome and partial final write  | Existing implementation has no common confirmed location/publication phase or write recovery.                                                                                                                              | **Observed defect mechanism**, no authorizing intentional exception found. No claim of full migration transaction beyond concrete path/boot invariants.                                                                |

## Verification and remaining boundaries

Registered modules (fresh processes): test_legacy_folder_migration9; test_config_paths_managed_bootstrap6; paths.test_bootstrap_toml8; test_config_paths_first_launch1; test_config_paths_home_fallback5; test_config_paths_write_transaction7. Total **36/0**. Their memory setup deliberately lacks the newly composed native contract/seam cases; green existing tests do not refute these findings. False-green mechanical scan completed within baseline (log `logs/false-greens.txt`); it does not detect missing real primitive contracts.

Memory watch-list: native fs.dir iterator-state retained; actual throw containment missing as reported; absence uses lstat at final component but ancestor alias semantics remain qualified; unrelated config/source bytes and occupied destinations asserted preserved by controls; synchronous boot IO is not placed on an eventtap callback. **G4 unmeasured**: no live log, timing, native folder count or latency claim. No task/callback/GC ownership claims are invented for this synchronous module.

Excluded: full packaged native Mac startup, LaunchServices/TCC/ACLs/APFS-specific rename and symlink behavior, actual user folder migration, simultaneous independently running old/new builds, power-loss/fsync durability, cross-volume real rename failure (exact false receipt covered synthetically), hostile noncooperating native process (controlled interleaving only), native root/ancestor mount topology, every TOML spelling/nesting combination, all GUI reload/cleanup effects. Windows/Linux are narrow source comparators, not OS-native validations. This report covers the register above and makes no global exhaustive parity or zero-defects claim.

Structural manifest check passed all five IDs/required fields/severity-confidence/G-code-or-explicit-property and both dry-ledger records. Legacy canonical validator was attempted; it rejects the parent-authorized scratch location (`report must be inside the repository`), captured in `logs/legacy-validator.txt`; no production tooling was changed.

## Supplemental MFM-006 — same physical legacy/current log-root identity

This precise counterpart was requested after the original scope completed. It **resets** the prior dry count. The five earlier findings and their native/policy qualifications are unchanged. The general external symlink-follow observation above remains policy-unknown; this finding is a narrower, proven **same physical source/destination** error with the explicit active-current preservation property.

Severity **medium**, confidence **high**, `guarantees: []`; additional property is physical identity / active-current preservation. No invented G2 code: the ordinary clash WARN is present. Shared source header says the _destination stays as it is_ when old/new clash. Here there are not two physical entries to arbitrate: both directory routes and both active.log routes resolve to the same dev+ino.

Reachability: public Mac plan merges `~/Library/Logs/ergopti_plus` into `~/Library/Logs/Ergopti`. In the private fixture the former is a symlink to the latter. Actual public Migration.run -> actual shared apply enumerates the alias -> move_entry sees the same active.log at its lexical from and to -> decides to preserve newer destination by archiving supposed old source. Actual POSIX os.rename instead removes **the current active destination inode/path** and places it in `before-folder-migration/Library/Logs/ergopti_plus/active.log`. The backup inode matches the original current inode; report records backed_up1/kept0. Next public run leaves active path absent and does not recover. Source/evidence lines: Mac adapter:116; shared apply:146–150 and move_entry:90–105. This is the same physical-root identity cause as Linux LFM-005, requiring root deduplication.

Controls executed in separate fresh interpreters:

- Distinct legacy/current roots with equal `active.log` filenames: actual current CURRENT sentinel stays, distinct OLD sentinel is archived. This verifies the ordinary explicit clash policy rather than rejecting it.
- No legacy root: active current file stays byte-exact and no backup is created.
- Alias case: both directory and file physical identities match before run; current path disappears; exact current inode is in backup; next public run does not restore it. Symlink itself remains.

No arbitrary external symlink policy, data erasure, native log worker/open-fd behavior, config whole-link move behavior, or every cache/control alias is claimed. Only this publicly reachable legacy/current **logs** merge counterpart was executed. Archive bytes survive and can be manually restored; current-path continuity is broken. Actual macOS/APFS native behavior remains unexecuted.

### Immutable source custody during shared checkout validation

The root warned that a concurrent full JavaScript suite may temporarily mutate the checkout. This supplement therefore **does not load any live checkout production module, generated input or registered test**. `probes/create-immutable-bundle.py` runs exact `git show 3a680d9f530a9af686fccc16d3f7611ec7fb034c:<path>` as bytes for just four modules: Mac adapter, shared migration core, generated app_dirs and native_path. `logs/immutable-bundle-provenance.json` records Git blobs and SHA256. Loader package.path is restricted to `probes/immutable-bundle`; only native installed lfs/system Lua modules come from outside. Each replay verifies all bundle SHA256 before running. Four direct caller/declaration sources (init.lua, config_paths.lua, launcher main.swift and app_dirs.toml) are separately captured via git show under logs/immutable-source-joins with SHA256 metadata, read for the source sweeps and never loaded/executed. No full checkout/copy or native/user files are used.

Exact safe rebuild and replay:

```
python3 /workspace/scratch/parity-recovery/macos-migration/probes/create-immutable-bundle.py
python3 /workspace/scratch/parity-recovery/macos-migration/probes/run-same-root-alias.py
python3 /workspace/scratch/parity-recovery/macos-migration/probes/run-alias-dry-passes.py
```

All script bodies are committed only to scratch evidence. Each fixture HOME is a new `probes/tmp-alias-*` tree, removed by its own TemporaryDirectory owner. The builder reads immutable objects only; it does not modify the shared repository. Logs/proofs: `logs/same-root-alias.txt`, `same-root-distinct.txt`, `same-root-absent.txt`, `same-root-results.json` and immutable bundle provenance. All three modes exit0 after exact assertions.

### Post-finding bounded dry passes D3 and D4

The prior D1/D2 ledger is preserved as `logs/dry-pass-ledger-before-MFM006.json`. Current `logs/dry-pass-ledger.json` appends D3/D4 with `reset_after: MFM-006` and exact source/fixture scope. Each post-finding source pass rechecks the full original bounded migration facade/native ports/plan/core, locator rewrite/refusal/recovery and direct launcher/environment/init/ConfigPaths adoption joins from immutable snapshots. D3 follows entry→moves→locator→restart; D4 reverses current/backup custody through source ownership and boot adoption. Existing MFM-001 through MFM-005 remain confirmed; no additional root beyond MFM-006 emerged. Executable validation during these passes is deliberately restricted to the alias and distinct/absent controls, all three modes in fresh interpreters. Both consecutive passes found **zero additional confirmed roots**. Their independent output snapshots are `D3-immutable-alias-results.json` and `D4-immutable-alias-results.json`.

Original registered-test counts remain **36 distinct earlier cases**; none was rerun against mutable checkout during this supplement. D3/D4 have **zero registered cases**, three fresh public modes each. The post-finding source stop condition covers the original bounded migration module/direct joins; it does not claim the earlier 12 executable modes or registered tests were freshly rerun during the shared JavaScript suite, nor a full-campaign/native-Mac certification. No production/test changes or commits were made.
