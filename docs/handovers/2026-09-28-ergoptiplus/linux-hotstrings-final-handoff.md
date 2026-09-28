# Final Linux Hotstrings handoff

Implementation stopped at the parent's explicit closure request. No repository source, index, commit, or branch was modified by this lane. This note is UTF-8 LF. All paths below are under `D:/ewt/_scratch/`.

## Exact unintegrated packets

A fresh SHA comparison at closure found **every affected root path still equal to its BEFORE hash** for all three packets below. None is integrated. The previously delivered Ctrl+G29 and Shortcuts-terminal10 packets have no path still matching their original BEFORE hashes; they are not part of this pending Hotstrings delivery.

### 1. Repeat3: canonical sparse repeat preference

- Patch: `hotstrings-repeat.patch`
- SHA256: `88079e894f04717a6de5e4f211504c5c1d240663e064e2a9618b8194a2a1c8d7`
- Exact path hashes: `hotstrings-repeat.hashes.json`
- Before/after trees: `hotstrings-repeat-before/`, `hotstrings-repeat-proposal/`
- Inventory and explanation: `linux-hotstrings-owner-inventory.md`
- Paths: Linux `modules/hotstrings/repeat_key.lua`, `ui/menu/unused_keys_cleanup.lua`, `tests/unit/modules/hotstrings/test_repeat_key.lua` (already registered).
- Independent of engine2/catalogue7. Existing shared manifest defaults, sparse writer and canonical config ports are prerequisites already present in the root baseline.
- Proof: `hotstrings-repeat-red-v2.log` = 8 passed/11 failed against old code; `hotstrings-repeat-green-v2.log` = 41/41 across repeat and actual consumer/cleanup suites. Scoped conventions zero; apply-check passed.
- Removes the Storage/default-true reader. Absence resolves to the manifest's false value. Exact-source conditional persistence precedes cache publication. Explicit refresh reconsumes a Clear candidate; failed refresh retains the old cache. No per-keystroke preference IO.
- Limitation: this fixes one canonical leaf, not the complete Hotstrings terminal or an automatic daemon-wide config reload.

### 2. Engine2: construct then publish

- Patch: `hotstrings-engine.patch`
- SHA256: `bc220b557dde2cd3cff019a5e06e48d1b03f27a5ee5daf863c2554792fa26fb2`
- Exact path hashes: `hotstrings-engine.hashes.json`
- Handoff: `hotstrings-engine-HANDOFF.md`
- Before/after trees: `hotstrings-engine-before/`, `hotstrings-engine-proposal/`
- Paths: shared `lua/hotstring_engine/init.lua`; Linux `tests/unit/meta/test_shared_hotstring_engine.lua` (already registered).
- Builds local buckets before replacing the effective catalogue. `load_mappings` returns literal true after publication, false for non-table input; compilation exceptions propagate. Detached `mapping_state()` reports generation and mapping/entry/bucket counts.
- Proof: `hotstrings-engine-red-luajit.log` = 38/43 baseline; `hotstrings-engine-green-luajit.log` and `hotstrings-engine-green-lua5.4.log` = 59/59 each. `hotstrings-engine-mutation-luajit.log` = 3 failures when early publication is reintroduced. Scoped conventions zero; apply-check passed.
- Existing matching rules, buffer behavior and corpus are unchanged. No hardware claim; full shared JS/Mac/Linux gates remain necessary after integration.

### 3. Catalogue7: consume real engine acknowledgement

- Patch: `hotstrings-catalogue.patch`
- SHA256: `591501da64ff4693f841d1f65455fbb8e76fbe3dd06875ec45f41840fe0bc2d6`
- Exact path hashes: `hotstrings-catalogue.hashes.json`
- Handoff: `hotstrings-catalogue-HANDOFF.md`
- Before/after trees: `hotstrings-catalogue-before/`, `hotstrings-catalogue-proposal/`
- Production: Linux `modules/hotstrings/hotstrings_config.lua`.
- Six test modules: `unit/meta/test_hotstrings_config.lua`, `unit/meta/test_corpus_hotstrings_config_resolve.lua`, `unit/modules/hotstrings/test_catalogue_last_known_good.lua`, `test_magic_key_catalogue.lua`, `test_prefix_expansions.lua`, `test_section_opt_in_defaults.lua`. All already registered.
- **Requires engine2 first.** Repeat3 is independent.
- `load_all/reload` keep their numeric first return and add `(committed, reason)`. Failed provider or engine publication retains the previous catalogue and menu metadata. Source paths publish after acknowledgement. Parse-error count intentionally remains diagnostic information from the latest attempted read.
- Proof: `hotstrings-catalogue-red.log` = 2 passed/5 failed baseline; `hotstrings-catalogue-green-final.log` and `hotstrings-catalogue-green-lua54.log` = 53/53 each. `hotstrings-catalogue-mutation.log` = 2 failures when metadata publishes before the engine receipt. Scoped conventions zero; apply-check passed.
- Existing recorder fixtures now acknowledge publication. The old provider test now checks a real refusal and no partial publication. The corpus test now distinguishes discovery from explicit activation, instead of assuming a non-neutral fixture state.
- **Still incomplete:** existing category setters persist the legacy Storage set before reload. This packet does not claim canonical category persistence or full rollback for those setters.

## Unfinished groups/modules fragments: DO NOT APPLY

The interrupted next tranche has no assembled production source and no tests, patch, lint, syntax, or runtime proof. `hotstrings-groups-proposal/` contains directories only, no files. `hotstrings-groups-before/static/ergopti_plus/linux/modules/hotstrings/hotstrings_config.lua` is a 49,244-byte projected baseline copied from catalogue7's AFTER version, not root current state.

Useful draft files:

- `hotstring_preferences.lua` (5,333 bytes, SHA256 `c52d0e5643d461b05c23240527a3ed09026c4a6e3ec3acc691646139bbc553fd`): proposed canonical category/section reader and specific owner delegating point updates to existing `config_scope_transaction`. Resolves manifest defaults, exact-source prepare, known-identity validation, pending compensation and retry. Not connected to the runtime or cleanup.
- `hotstrings-groups-helpers.lua` (2,203 bytes, SHA256 `e4d46d6c7fce58286079b0b0e600be0b88521dad45dc0e052f9f94914fccb00c`): proposed inventory/filter/publish/admission helpers. Refers to state/imports that have NOT been added to hotstrings_config.
- `hotstrings-groups-api.lua` (5,342 bytes, SHA256 `960f941b4385fe901ac207f0ef336239b99f51033c947b5b8e7ce3190c59d382`): proposed replacement group/section public APIs. Not spliced into production. Requires construction of `_preferences`, detached runtime snapshots, `_choice_document` and `_filtered_mappings`, exact initialization/reload integration and fencing other mutations.
- `prepare-hotstrings-groups.py` (372 bytes): only creates the draft directories and projected before image.

These fragments are design material, not an accepted implementation. In particular: dense-list validation and unknown identity cases need review; snapshot detach/restore is not implemented; input-buffer cancellation/admission is not connected; setters/override mutations/reload need consistent retained-debt fencing; canonical cleanup registration is missing; old fixtures still use Storage assumptions and require behavioral replacement. Do not count any groups/modules functionality as delivered.

## Remaining exact ownership problems

The fuller inventory is in `linux-hotstrings-owner-inventory.md`.

1. `hotstrings_config` still reads/writes `Storage.hotstrings.disabled_categories`; absence enables groups, contrary to canonical dynamic defaults. Runtime desired groups/modules must use declared `hotstrings.groups.<runtime-group>` and `hotstrings.modules.<runtime-group>.<section>` with quoted TOML segments where required. Enumerate actual loaded identities; preserve unknown neighbouring entries. Child choices must remain independent of group effective state.
2. Overrides use separate `hotstrings_overrides.toml`, currently whole-file serialization and no exact-source cohort; unknown fields can be lost. It needs its own conditional owner before multi-file Clear is truthful.
3. MagicKey still uses Storage and publishes before its rebuild callback without acknowledgement. PreviewSettings has four Storage booleans and cached preview state.
4. Dynamic families still use Storage forms distinct from canonical family descriptor paths; reuse actual descriptors, no alias or migration system. Personal source content remains user-owned.
5. Daemon terminator state/custom terminators still use Storage serialized values with no corresponding declared canonical scalar contract found. An exact ownership declaration is needed before claiming full Hotstrings Clear.
6. Shared `config_scope_transaction` is a single-config-file coordinator. Whole Hotstrings/global must compose the separate owned files atomically, not split into independent successful writes.
7. No common Hotstrings menu row may be published until its complete terminal works across hosts. This lane changed no shared UI declarations or locales.

## Isolation record and minimal restart

- The first expanded catalogue replay used exclusive TMPDIR but not private XDG/HOME. Existing fixtures could write `/home/adrien/.config/ergopti_plus/storage.json`; no snapshot existed, so it was not restored. Parent confirmed Linux V8 finished before that replay, excluding concurrent interference with that run. Preserve this caveat.
- Final catalogue replays use exclusive TMPDIR, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME and HOME in `hotstrings-catalogue-private/`. All future diagnostics must do likewise. Durable common-runner isolation is a separate follow-up.
- No tests or implementation are running from this lane at closure.
- Resume by reviewing exact patch/hashes, integrating repeat3 and engine2 -> catalogue7 atomically, then rerunning the selected receipts plus the covering root shared gates.
- Rebase the unassembled groups/modules design on that integrated source. Implement one coherent vertical owner: canonical read, effective engine selection, exact conditional save, source-conflict/native refusal compensation, retained-debt admission and explicit retry. Prove absence OFF, desired children preserved while group OFF, unknown neighbours, quoted extension groups, restart, Clear/reload, and inverse refusal. Only then extend to override/magic/preview/dynamic/terminator ownership and multi-file scope.
- Nothing should be cherry-picked from the unassembled groups draft; it has no commit or ready patch. Parent is responsible for preserving these artifacts in the repository/GitHub handoff; this lane did not write the repository.
