# 009 — Config versioning and deprecation policy

| Field        | Value      |
| ------------ | ---------- |
| **Date**     | 2026-09-24 |
| **Status**   | Accepted   |
| **Deciders** | Core team  |

---

## Context

`config.toml` had no version any driver read. Windows stamped
`[_meta] schema_version = 2` on every full save and nothing consumed it; macOS
and Linux never stamped. A key could therefore not be renamed, moved, retyped
or removed without one of two losses: the user's value vanished (the new
spelling started from its default), or the old spelling stayed on disk and was
reported as an unknown key on every boot until the unused-key cleanup deleted
it — value included. Each driver had grown ad-hoc repairs instead (legacy
`0`/`1` booleans, the dropped `[ahk.*]` silo, `[linux.gestures]`), none of them
shared, none of them tested against the others.

A downgrade had the opposite problem: an older build that met a file written by
a newer one parsed what it understood and then saved its whole in-memory state
over the file, destroying the settings it did not know.

## Decision

`config.toml` carries its version in `[_meta] schema_version`. One data file,
`_shared/core/config_schema/migrations.toml`, is the only registry of versions
and of the steps between them; every driver reads it at runtime (Windows with
`windows/infra/config_migrate.ahk`, macOS and Linux with
`_shared/lua/config_migrate.lua`). A step is `[steps.v<N>_to_v<N+1>]` with the
drivers whose files it changes and an ordered list of ops drawn from a closed,
data-only set: `rename`, `move_section`, `merge_into`, `map_value`, `delete`,
`set_if_absent`. There is no code in a step, so the three interpreters cannot
disagree about what a step means without the shared corpus
(`_shared/tests/corpus/config_migrations/`, replayed by all three suites and by
`tools/test/test-config-migrations.cjs`) failing. Nor can they disagree about
which registry is valid: `_shared/tests/corpus/config_migration_registries/`
holds a control every loader accepts and the defects every loader rejects.

At boot, before anything applies or saves the file, each driver classifies it:

- **older** (or unstamped, which counts as the registry's `unstamped_version`):
  write a byte-exact backup `<name>.pre-v<N>-<stamp>.toml` next to it, read it
  back, run every step for this driver in order, set the stamp last, and
  replace the file in one atomic publication that refuses if the file changed
  since it was read;
- **current**: nothing is written;
- **newer**, **invalid** stamp, unreadable or unparsable file, or any failure
  of the above: the file is never written. Every later write to it is refused
  for the session and one ERROR is logged.

A file this build creates carries this build's version: the Lua writer adds
the stamp when it creates the file, the macOS preferences save stamps a file it
creates, and the Windows first-run wizard stamps the file it creates. A later
boot therefore never mistakes a new file for an old one. A writer never stamps
a file that already exists: only the boot migration moves an existing stamp,
after running the steps the file still needs. The one exception is the Windows
full save, which rewrites the whole file and always writes the registry's
current version. It is safe only because it runs after the boot migration has
made the file current, and a read-only session never runs it; a Windows path
that switched config.toml without that boot migration would skip its steps.

An explicit user reset is not a migration: it replaces the file with a
placeholder stamped with the current version.

### Deprecation policy

- **Rename or move a key**: add a `rename`, `move_section` or `merge_into` op to
  a new step **in the same commit** that renames it. Readers drop the old
  spelling at once: no runtime alias, no fallback read of the old name.
- **Remove a feature or a key**: add a `delete` op in the same commit,
  except when the retired entry is reported by the explicit outdated-key
  cleanup. Such entries remain on disk until the user invokes that cleanup;
  boot migrations and ordinary saves must preserve them. Readers still drop
  the retired spelling immediately, without a runtime alias. The existing
  retirement-only steps remain in the version chain with empty ops, so older
  files advance their stamp without discarding the user's entries. This
  exception does not remove the generic `delete` opcode or its interpreter
  contract.
- **Change a value's domain** (an enum renamed, `0`/`1` turned into booleans):
  add a `map_value` op; its `from` and `to` sets are disjoint so a replay
  changes nothing.
- **Change a default** while existing files must keep the old behaviour: add a
  `set_if_absent` op that writes the previous effective value into files that
  never set it.
- **Bump** `current_version` by exactly one per step; steps form a gap-free
  chain from `unstamped_version`. Every new op kind needs a corpus case, and a
  step naming a driver needs a case that driver replays.

## Consequences

### Positive

- Keys can be renamed, moved, retyped and removed without losing a user's
  value, and without a compatibility shim living forever in a reader.
- A downgrade can no longer destroy a newer file: the older build runs
  read-only and says why.
- The three drivers share one registry and one corpus, so a migration cannot
  ship on one driver and silently differ on another.

### Negative / Trade-offs

- Two TOML stacks (the AHK reader/writer and `toml_codec`) implement the same
  op semantics; only the corpus keeps them equal.
- The Lua engine preserves every byte no op touches; the Windows engine
  renders the migrated file with the canonical writer every Windows save
  already uses, so comments are not kept on Windows (they never survived a
  Windows save either).
- A session that meets a newer file cannot persist any setting until the user
  runs the newer build or restores a backup.

### Neutral

- The registry is read at runtime instead of generated per driver: there is no
  codegen step and no drift guard, but each driver parses one small file at
  boot.
- `[manifest] version` in the features manifest stays the manifest's own
  version; it is not the config schema version.

## Alternatives considered

| Alternative                                        | Why rejected                                                                                                    |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Runtime aliases (readers accept old and new names) | Every renamed key would stay in a reader forever, and the old spelling stays on disk and in the unused-key list |
| Per-driver migration code                          | The drivers already diverged this way; nothing proves two drivers migrate the same file the same way            |
| Code in steps (a Lua/AHK function per step)        | Two implementations per step with no shared proof; a data-only op set can be replayed by all three suites       |
| Generate the registry into each driver             | Adds a generator and drift guard for a file every driver can read directly at boot                              |

## Evidence in the codebase

- Registry: `static/ergopti_plus/_shared/core/config_schema/migrations.toml`
- Interpreters: `static/ergopti_plus/_shared/lua/config_migrate.lua`,
  `static/ergopti_plus/windows/infra/config_migrate.ahk`
- Corpus: `static/ergopti_plus/_shared/tests/corpus/config_migrations/`,
  `static/ergopti_plus/_shared/tests/corpus/config_migration_registries/`
- Gates: `tools/test/test-config-migrations.cjs` (registry shape, closed op set,
  reference replay, interpreter wiring),
  `static/ergopti_plus/windows/tests/unit/test_config_migrate.ahk`,
  `static/ergopti_plus/macos/tests/unit/infra/test_config_migrate.lua`,
  `static/ergopti_plus/linux/tests/unit/infra/test_config_migrate.lua`
