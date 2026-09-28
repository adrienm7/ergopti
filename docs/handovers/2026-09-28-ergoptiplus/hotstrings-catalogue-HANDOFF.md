# Linux catalogue publication owner

Patch: `hotstrings-catalogue.patch`.
SHA256: `591501da64ff4693f841d1f65455fbb8e76fbe3dd06875ec45f41840fe0bc2d6`.
Exact hashes: `hotstrings-catalogue.hashes.json`.

Apply after `hotstrings-engine.patch` (SHA bc220b557dde2cd3cff019a5e06e48d1b03f27a5ee5daf863c2554792fa26fb2). Repeat3 is independent. Seven paths: one production owner and six registered test modules. Before bytes are preserved in `hotstrings-catalogue-before`; proposed bytes in `hotstrings-catalogue-proposal`. Root was not modified.

`load_all()`/`reload()` preserve their first numeric return and add `(committed, reason)`. The owner stages discovered paths and mappings, refuses an incomplete personal-provider result, and requires an explicit true receipt from the engine before publishing catalogue/menu metadata. A thrown engine refusal is surfaced as count,false,reason. Previously the owner ignored engine refusal and could advertise rules that never became effective. Provider failures previously removed the provider's old rules from a newly published partial aggregate.

`parse_error_count()` intentionally remains the diagnostic count from the last attempted parse, including rejected source reads; existing last-known-good behavior and its regression remain intact. Engine buffers and overrides are unchanged. This is runtime publication ownership, not a disk transaction or a completed Hotstrings scope.

## Proof

- `hotstrings-catalogue-red.log`: baseline with engine prerequisite, 2 passed/5 failed, one for each new behavioral case.
- `hotstrings-catalogue-green-final.log`: 53/53 LuaJIT across all six touched test modules.
- `hotstrings-catalogue-green-lua54.log`: 53/53 Lua5.4.
- `hotstrings-catalogue-mutation.log`: candidate metadata published before the engine receipt causes 2 failures on actual retained old categories.
- Scoped conventions zero; LF verified; root apply-check passed.
- Six existing recorder fixtures now return the actual engine receipt or true after recording, respecting the stricter contract.
- Existing prefix-provider exception test now asserts no engine publication, false and the exact refusal reason; the earlier type-of-table check could pass without detecting the incomplete aggregate.

The old bundled-corpus test expected effective mapping count >0 without enabling its neutral sections. It failed in isolated WSL but passed in the parent's Windows full suite, where earlier fixture state could enable sections. It now independently proves mappings are discovered (`mapping_count()>0`), explicitly activates them via the real owner, and proves they reach the real engine recorder. No defaults or production gate state were weakened.

## Isolation caveat preserved

The first expanded run `hotstrings-catalogue-green.log` was 52/53 with only TMPDIR isolated; legacy fixtures could touch `/home/adrien/.config/ergopti_plus/storage.json`. No restoration was attempted without a baseline. Root confirmed Linux V8 finished before this run, so there was no temporal overlap with that full suite. Every final replay uses exclusive TMPDIR, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME and HOME under `hotstrings-catalogue-private`. A durable common-runner isolation improvement is a separate follow-up, not part of this patch.

## Next bounded work

Canonical group/module gates must replace the disabled_categories Storage reader/writer, using declared dynamic defaults and quoted key paths. Their persistence must stage detached engine state before conditional publication, compensate exact old state, retain refusal debt if compensation fails, and preserve unknown config keys. This patch establishes the required truthful engine acknowledgement, but the current group setters still persist the old Storage set before reload; they are not yet a usable Restore/Clear terminal. Hotstrings shared menu rows remain on hold.
