# Linux Hotstrings W1 — exact owner inventory and first vertical delivery

Root sources inspected read-only during the integrated Linux freeze. No shared menu row has been added.

| Runtime owner | Actual persisted/read source today | Required terminal ownership |
| --- | --- | --- |
| `modules/hotstrings/hotstrings_config.lua:95,119,681` | `Storage[hotstrings.disabled_categories]`, CSV mixing category-off, section-off and `+category.section` opt-in markers; `_disabled_groups` cached at init | Existing manifest dynamic `hotstrings.groups.<runtime-group>` and `hotstrings.modules.<runtime-group>.<section>`, default false. Enumerate actual loaded catalogues/extensions and their sections; preserve unknown identities. Stop reading the old store, without importing or migrating it. Desired group and section choices remain separate from effective filtering. |
| Same owner `:264,342,498,577` | `hotstrings_overrides.toml`, category/section fields delay/color/show_tooltip/priority plus `_global`; full rewrite currently discards unrelated fields | Exact section identities through the existing TOML key renderer; preserve unknown fields and content. Detached override candidate and conditional file publication before terminal completion. This is a second file, so a single-file scope is insufficient for the complete Hotstrings command. |
| Same owner `:800,864` + Loader | Bundled, language, personal and extension TOML content; last-known-good catalogue; extra mappings provider from personal information | These are corpus inputs, not preference files to erase. Retain current source/loader formats. Build a candidate without publishing manager fields or engine buckets; source refusal must not look like success via the old mapping count. |
| Shared `hotstring_engine/init.lua:452` | In-memory buckets; `load_mappings` clears old buckets before validation and returns void | Bounded shared prerequisite authorized by root: build local buckets, publish after successful preparation, explicit acknowledgment and detached readback. Actual matching tests must prove old mappings survive refusal and thrown compilation errors. |
| `modules/hotstrings/repeat_key.lua:60,70` | Legacy Storage, plus hardcoded default true contradicting canonical false | **First vertical packet delivered below:** real config.toml reader, sparse conditional writer, cached input-path value, explicit refresh, cleanup ownership. |
| `modules/hotstrings/magic_key.lua:75,133,146` | Legacy Storage `hotstrings.trigger_char`; callback rebuilds catalogue and dynamic mappings | Canonical existing scalar leaf, actual key validator, retained admission through whole callback/rebuild. A setter callback failure must not leave file and runtime claiming different keys. |
| `modules/hotstrings/preview_settings.lua:110,146,181` | Four legacy Storage booleans; separate `ui.tooltip.preview` runtime copies | Existing canonical four manifest leaves plus real preview acknowledgment/rollback; no generic boolean-prefix purge. |
| `modules/dynamic_hotstrings/manager.lua:74,321,828,847` | Desired master only in memory; family preferences in Storage `hotstrings.dynamic.<section>`, while manifest names `<family-id>.enabled` | Map with the existing family descriptor, not string aliases. Preserve `personal_info.toml` user content. Prepare actual dynamic rules/provider from existing inputs, and make canonical master/families durable and sparse. |
| `ergopti_hotstrings.lua:1273–1345` | Legacy Storage `hotstrings.terminator_state` and `hotstrings.custom_terminators`; daemon-local serializer and active terminators module | No corresponding scalar leaf declaration found in current manifest. Needs explicit owner mapping/contract before a complete Hotstrings/global command can claim to reset these settings. Do not invent a namespace-wide deletion. |

## First completed vertical: repeat key

`D:/ewt/_scratch/hotstrings-repeat.patch`
SHA256 `88079e894f04717a6de5e4f211504c5c1d240663e064e2a9618b8194a2a1c8d7`
Hashes: `hotstrings-repeat.hashes.json`; exact before/after directories: `hotstrings-repeat-before`, `hotstrings-repeat-proposal`.

Three paths: actual repeat owner, actual unused-key collector, already-registered repeat test file. All before bytes match root, apply check passes, no source outside scratch changed.

The current default true and legacy state import are removed. Absence resolves through Manifest.default_for. A setter validates actual canonical source, uses Manifest.sparse_operation and Writer.batch_write with exact-source precondition, then publishes its boolean runtime cache. Failure leaves source and runtime intact; unknown neighbors survive. There is no new preference or format. Input-path queries do not perform repeated file IO. `refresh()` is the explicit owner port for a future terminal publication and acknowledges only validated reload, keeping the previous runtime on refusal. This is a leaf prerequisite, not a completed global Hotstrings transaction.

Evidence: `hotstrings-repeat-red-v2.log` **8 passed / 11 failed**; `hotstrings-repeat-green-v2.log` **41/41 green** including menu dispatch and canonical URL/cleanup regression. The new 12 cases cover old legacy true, canonical false, true restart, sparse false/clear, write refusal, concurrent external edit, malformed source, wrong setter type, actual clear candidate + explicit refresh, rejected refresh, no repeated input-path IO, and real cleanup ownership. Seven original pure repeat-rule cases remain. Exact convention checks: zero violations. Dedicated TMPDIR is `hotstrings-repeat-private`.

No native compensation is fabricated for this scalar: the sole runtime publication is a boolean assignment after acknowledged persistence, with no external side effect that can refuse afterward. Whole-engine lifecycle/compensation belongs to the subsequent group/section and multi-file terminal packets.

## Bounded continuation

1. Deliver the shared engine construct-before-publish acknowledgment/readback prerequisite separately, with real invalid-input/partial-compilation error tests. No planner change is needed for category/section canonical paths already declared.
2. Replace the mixed disabled cache with a canonical runtime-owned choice projection, sparse writes and detached catalogue preparation. Add actual category/section setter, clear/reload and unknown-identity regressions; retain transaction debt if runtime compensation refuses.
3. Bring overrides, dynamic families/master, preview and magic key under their exact owners, preserving corpus/personal content. Complete the terminator declaration mapping before claiming a whole-domain reset.
4. Only once all files and active runtime owners can participate atomically, compose the existing coordinator with justified multi-file publication support and publish Hotstrings Restore/Clear menu rows. Do not split one user command into independent successful writes.
