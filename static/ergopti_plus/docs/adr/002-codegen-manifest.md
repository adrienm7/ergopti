# 002 — Features manifest generated from TOML

| Field | Value |
|---|---|
| **Date** | 2025-09-01 |
| **Status** | Accepted |
| **Deciders** | Core team |

---

## Context

Ergopti exposes ~200 user-configurable features (hotstring expansions, tap-hold
overrides, layout toggles, LLM settings, etc.). Before this decision, each
driver maintained its own hardcoded feature registry. This meant:

- A feature added to the AHK driver might not exist in Hammerspoon, or vice
  versa, with no automated check.
- Default values were duplicated across `autohotkey/`, `hammerspoon/`, and
  the UI's `static/` layer — three copies that could silently drift.
- Onboarding a new driver required manually transcribing hundreds of feature
  entries into a new format.

The user-facing config files (`.toml`) that end users edit also had to match
the driver's internal registry exactly, creating a fourth source of truth.

## Decision

Maintain a **single authoritative TOML manifest** at
`static/ergopti_plus/shared/features/manifest.toml` and generate all
driver-specific feature registries from it at build time.

The build script (`tools/build/build-features-manifest.js`, exposed as
`npm run build:manifest`) reads `manifest.toml` (and
`static/ergopti_plus/windows/data/tap_hold/defaults.toml`) and emits:

- `static/ergopti_plus/windows/_generated/features_manifest.ahk` — AHK `Map`
- `static/ergopti_plus/macos/_generated/features_manifest.lua` — Lua table
- Per-driver `_generated/config_template.toml` — ready-to-copy user config
- Per-driver `_generated/tap_hold_template.toml`

Files under `_generated/` are never edited by hand; they are committed to the
repository so drivers can boot without running the build step.

## Consequences

### Positive

- All drivers are guaranteed to have identical feature sets and defaults.
- Adding a feature requires a single edit in `manifest.toml`; all drivers
  update on the next `npm run build:manifest`.
- The generated files are human-readable (comments preserved), so developers
  can inspect the output without running a build.
- User config templates are always in sync with the actual manifest.

### Negative / Trade-offs

- The build step must be run after any manifest change; forgetting to commit
  the regenerated files causes a stale-output inconsistency.
- TOML has limited type expressiveness; complex conditional defaults require
  post-processing logic in the build script.

### Neutral

- The `_generated/` directory is committed, not gitignored, so the generated
  output is auditable in code review.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Shared runtime-loaded JSON | Requires each driver to bundle a JSON parser; AHK has no native JSON |
| Per-driver TOML + CI diff check | Drift is caught only at CI time, not prevented |
| Hardcoded constants in each driver | Proven to diverge in practice; too expensive to maintain |

## Evidence in the codebase

- Source manifest: `static/ergopti_plus/shared/features/manifest.toml`
- Schema: `static/ergopti_plus/shared/features/manifest.schema.json`
- Build script: `tools/build/build-features-manifest.js`
- npm script: `package.json` → `"build:manifest"`
- Generated AHK output: `static/ergopti_plus/windows/_generated/features_manifest.ahk`
- Generated Lua output: `static/ergopti_plus/macos/_generated/features_manifest.lua`
