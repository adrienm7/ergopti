# Hotstrings engine publication prerequisite

Frozen patch: `D:/ewt/_scratch/hotstrings-engine.patch`.
SHA256: `bc220b557dde2cd3cff019a5e06e48d1b03f27a5ee5daf863c2554792fa26fb2`.
Exact before/after hashes: `hotstrings-engine.hashes.json`.

Two owned paths only: shared `hotstring_engine/init.lua` and the already registered Linux `tests/unit/meta/test_shared_hotstring_engine.lua`. No generated outputs, preferences, menus, corpus, or platform adapters changed. Root sources remain unchanged; apply only after root Linux V8 finishes.

The previous loader cleared active buckets before validating or compiling the replacement. Invalid arguments therefore erased old rules; row compilation and sorting exceptions could expose a partially built catalogue. The replacement now builds local buckets and publishes only after successful compilation/sorting. `load_mappings(mappings)` returns true on successful publication, false for a non-table argument; compilation exceptions still propagate. `mapping_state()` returns detached generation/mapping/compiled-entry/bucket counts. Successful empty loads explicitly clear the catalogue. Existing row filtering, matching precedence, input buffers, and case rules are unchanged.

## Proof

- `hotstrings-engine-red-luajit.log`: baseline 38 passed, 5 failed. Three failures demonstrate the old mapping disappears on invalid input, compilation exception, and sorting exception; the other two cover acknowledgement/readback and empty clear.
- `hotstrings-engine-green-luajit.log`: 59/59, including existing corpus and current-buffer suites.
- `hotstrings-engine-green-lua5.4.log`: same 59/59.
- `hotstrings-engine-mutation-luajit.log`: early-publication mutation produces 3 failures, preserving the meaningful negative proof.
- `hotstrings-engine-lint.log`: 0 scoped convention violations.
- `git -c core.autocrlf=false apply --check` passed against unchanged root source before hashes.
- All text LF. Tests use private TMPDIR and the real shared engine through a source-loader overlay, without root writes or native input.

Runner: `run-hotstrings-engine.lua`; proposed production/test files live in `hotstrings-engine-proposal`, original bytes in `hotstrings-engine-before`. Broader shared JS/Mac/Linux integration gates remain the root's responsibility; these targeted results are not a full-suite claim.

## Remaining Hotstrings work

This prerequisite does not make Hotstrings Restore/Clear complete. The Linux config owner must consume the acknowledgement and keep its catalogues, paths and metadata unpublished on refusal. Canonical groups/modules still need sparse config.toml reads and writes instead of disabled_categories Storage, plus detached runtime/compensation. Overrides retain a separate TOML file and require conditional, unknown-preserving ownership. MagicKey, PreviewSettings, Dynamic and daemon terminator settings need exact canonical ownership before a complete scope can be published. See `linux-hotstrings-owner-inventory.md`.
