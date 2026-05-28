# 003 — Single TOML schema with snake_case keys for all config

| Field | Value |
|---|---|
| **Date** | 2025-09-01 |
| **Status** | Accepted |
| **Deciders** | Core team |

---

## Context

Both the AHK driver and the Hammerspoon driver read user config from `.toml`
files. Early in development these files used a mix of casing conventions:
`PascalCase` keys appeared alongside `snake_case` ones, and the two drivers
sometimes disagreed on the canonical name for the same setting.

This caused silent bugs: a user editing `TapHoldDelay` in one driver's config
would see no effect on the other driver, which read `tap_hold_delay`. Worse,
the divergence was invisible — neither driver errored on unrecognised keys.

Additionally, the codegen step for the features manifest (ADR-002) needed a
single canonical key name to use in every generated output. Having two casing
styles in the source TOML made the build script harder to reason about.

## Decision

All TOML configuration files across all drivers **must use `snake_case` keys
exclusively**. `PascalCase`, `camelCase`, and `kebab-case` keys are forbidden.

This rule applies to:
- User-editable config files (`config.toml`, `tap_hold.toml`, etc.)
- The shared features manifest (`manifest.toml`)
- Any TOML file generated or consumed by a driver

The invariant is enforced mechanically by the meta-test
`tests/meta/test_no_pascal_case_in_toml.lua`, which scans all `.toml` files
reachable from the Hammerspoon driver root and fails if it finds a key that
starts with an uppercase letter.

## Consequences

### Positive

- Config files are portable across drivers: the same key name works in AHK and
  in Hammerspoon without any translation layer.
- The codegen script can emit keys verbatim without a casing transform.
- Users editing config by hand encounter a consistent, predictable convention.
- CI catches regressions automatically.

### Negative / Trade-offs

- Existing TOML files that used PascalCase required a migration pass.
- The migration is documented in `static/ergopti_plus/shared/features/_migration_v1_to_v2.md`.

### Neutral

- TOML's native convention also favours `snake_case` for keys, so this
  decision aligns with the upstream spec.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| `camelCase` | Common in JSON but unusual in TOML; conflicts with Lua field naming |
| `PascalCase` | Already proven to cause cross-driver divergence |
| Allow mixed casing per file | Complicates the codegen step and makes config harder for users |

## Evidence in the codebase

- Enforcement test: `static/ergopti_plus/macos/tests/meta/test_no_pascal_case_in_toml.lua`
- Source manifest (all snake_case): `static/ergopti_plus/shared/features/manifest.toml`
- Migration guide: `static/ergopti_plus/shared/features/_migration_v1_to_v2.md`
