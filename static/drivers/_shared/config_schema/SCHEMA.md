# Ergopti+ — unified configuration schema (v2)

This folder describes the target user-configuration schema after the Scope C refactor. The files under `examples/*.toml` are **reviewable drafts** — no driver reads them yet.

## Overview

```
config/ergopti_plus/
├── personal_info.toml              # Universal, read by AHK + HS
├── hotstrings_config.toml          # Universal, delay/colour overrides per group
├── ahk/
│  ├── config.toml                  # v2 schema (universal sections + [ahk.*])
│  ├── tap_hold.toml                # Complete AHK tap-hold config (no runtime merge)
│  └── logs/
└── hammerspoon/
   ├── config.toml                  # v2 schema (universal sections + [hs.*])
   ├── tap_hold.toml                # Complete HS tap-hold config (no runtime merge)
   └── config_karabiner.toml        # HS-only, managed by the karabiner module
```

And on the repo's shared-resources side:

```
static/drivers/_shared/
├── config_schema/                  # THIS FOLDER
│  ├── config.schema.json           # Strict JSON Schema (draft 2020-12)
│  ├── tap_hold.schema.json         # Sub-schema for tap-hold
│  ├── SCHEMA.md                    # This documentation
│  └── examples/
│     ├── ahk_config.example.toml
│     ├── hs_config.example.toml
│     ├── ahk_tap_hold.example.toml
│     └── hs_tap_hold.example.toml
├── tap_hold/
│  └── defaults.toml                # Canonical defaults — used only as the
│                                   # one-shot generation source at first boot
├── features/
│  └── manifest.toml                # Single source of features (Scope C2)
├── llm/
│  ├── defaults.json
│  ├── profiles.json
│  ├── models.json
│  └── inference.json
├── schema/                          # SQLite keylogger (unchanged)
└── ui/                              # Shared WebView HTML/JS (unchanged)
```

## Conventions

### Casing — **snake_case everywhere**

All TOML keys are `snake_case`. That is the standard TOML convention.

### Universal vs. platform-specific sections

| Section | Read by | Schema |
|---|---|---|
| `[script]` | AHK + HS | `$defs.script` |
| `[hotstrings]` | AHK + HS | `$defs.hotstrings` |
| `[llm]` | AHK + HS | `$defs.llm` |
| `[metrics]` | AHK + HS | `$defs.metrics` |
| `[shortcuts]` | AHK + HS | `$defs.shortcuts` |
| `[ahk.*]` | AHK only | `$defs.ahk_specific` |
| `[hs.*]` | HS only | `$defs.hs_specific` |
| `[tap_hold.*]` | AHK + HS (via Karabiner) | `tap_hold.schema.json` |

If a `[hs.*]` section appears in the AHK config, the driver emits a **warn** at boot (or crashes in dev mode). Same for `[ahk.*]` on the HS side.

### Feature toggles with a delay

Every feature that can carry an activation delay is modelled as an **explicit sub-section**:

```toml
[hotstrings.autocorrection.accents]
enabled = true
time_activation_seconds = 0.5

[hotstrings.autocorrection.caps]
enabled = true
# omitting time_activation_seconds = instant activation
```

Rather than the old AHK pattern:

```toml
# ❌ Old (v1) — do not use anymore
[Hotstrings.Autocorrection]
Accents = true
Accents_TimeActivationSeconds = 0.5
Caps = true
Caps_TimeActivationSeconds = true   # bool or number? ambiguous!
```

### `ahk.` and `hs.` prefixes

For strictly platform-specific sections:

```toml
[ahk.layout]                  # AHK only — the layout layer is handled by Karabiner on Mac
ergopti_base = true

[hs.gestures.modes]           # HS only — Mac trackpad gesture vocabulary
swipe_3_left = "incremental"
```

## Validation

### At boot

Each driver loads its own `config.toml`, parses it, then validates against `config.schema.json`.

- **Dev mode** (`ERGOPTI_DEV=1` in the env): any validation error = **crash** with a stack trace pointing at the offending TOML line.
- **Production mode** (default): **warn** in the logs with the offending line; the driver continues with the default from the features manifest for the invalid key.

### In CI

A `scripts/validate-config-schema.js` script runs validation on every `examples/*.toml` in the repo. Wired up as a pre-commit hook via husky.

A companion `scripts/audit-banner-alignment.js` enforces the CLAUDE.md banner-comment alignment in every `*.toml`. Run it manually with `--fix` to auto-correct, or in pre-commit without it to detect regressions.

## Initial generation at first boot

If `config/ergopti_plus/<driver>/config.toml` does not exist at first boot:

1. The driver reads `static/drivers/_shared/features/manifest.toml` (the single source of truth).
2. It filters entries whose `platforms` includes the current driver.
3. It renders a clean `config.toml` with:
   - Section banners (CLAUDE.md `# =====` format).
   - Description comments resolved via `description_key` from the manifest against `static/locales/<locale>.json`.
   - Explicit defaults for every feature.
4. It writes the file and continues its normal boot.

The same mechanism applies to `tap_hold.toml`: at first boot the driver renders `_shared/tap_hold/defaults.toml` into `config/ergopti_plus/<driver>/tap_hold.toml`. After that, the per-driver file IS the config — there is no runtime merge with the shared defaults, and the two drivers may diverge freely.

## Tap-hold

`_shared/tap_hold/defaults.toml` is a **generation template only** — it is read once at first boot to produce each driver's `tap_hold.toml`. After that, the per-driver file is the complete config; the shared file is never read again at runtime.

This means:

- There is no per-key fallback to the shared defaults — if a key is missing from the per-driver file, that key simply has no tap-hold behaviour.
- The two drivers' `tap_hold.toml` files can diverge entirely.
- Editing `_shared/tap_hold/defaults.toml` only affects **new installs** (or users who delete their per-driver file and let it regenerate).

### Semantics of a tap-hold key

Each `[tap_hold.keys.<name>]` entry may declare:

| Field | Type | Required | Description |
|---|---|---|---|
| `time_activation_seconds` | number | yes | Tap vs hold threshold |
| `tap_action` | string | no | Action emitted on short tap (ref `_shared/actions.toml`) |
| `hold_layer` | string | no | Layer activated on hold (ref `tap_hold.layers.<name>`) |
| `hold_modifier` | enum | no | Modifier emitted on hold (mutex with `hold_layer`) |
| `enabled` | bool | no | Default `true`. Set `false` to disable this entry without deleting it |

`hold_layer` and `hold_modifier` are **mutually exclusive** (the schema enforces it).

## v1 → v2 mapping (reference)

Since we're going clean-state with no backward compatibility, this mapping is **informative only** — it documents what every v1 key becomes in v2, to make diffs easier to read in the AHK/HS code refactor.

| v1 (PascalCase / mixed) | v2 (unified snake_case) | Notes |
|---|---|---|
| `[Hotstrings] MagicKey` | `[hotstrings] trigger_char` | Semantic rename |
| `[Hotstrings.Autocorrection] Accents = true` + `Accents_TimeActivationSeconds = 0.5` | `[hotstrings.autocorrection.accents] enabled = true; time_activation_seconds = 0.5` | Modelling α |
| `[LLM] ctx_chars` | `[llm.generation] context_length` | Adopts HS naming |
| `[LLM] model` | `[llm.models] selected` + `[llm.models] ollama = "..."` | Explicit multi-backend |
| `[Layout] ErgoptiBase` | `[ahk.layout] ergopti_base` | AHK-only, prefixed |
| `[TapHolds.CapsLock]` (AHK) | `[tap_hold.keys.caps_lock]` (per-driver tap_hold.toml) | Dedicated file |
| `[Shortcuts] AGrave = true` + `AGrave_Letter = "v"` | `[shortcuts.a_grave] enabled = true; letter = "v"` | Modelling α extended |
| `[Shortcuts.AltGrCapsLock]` | `[ahk.shortcuts.alt_gr_caps_lock]` | AHK-only |
| `[Gestures]` (AHK, limited vocab) | `[ahk.gestures]` | Prefixed (Win vocab) |
| `[gestures]` (HS, rich vocab) | `[hs.gestures]` + `[hs.gestures.modes]` + `[hs.gestures.sensitivities]` | Prefixed (Mac vocab) |
| `[Script] Locale` (PascalCase) | `[script] locale` | Casing |
| `[Script] WpmWidget*` | moved under `[hs.metrics.float]` / dropped from AHK | Semantic re-centering |
| `personal_info.toml` `[info] FirstName` | `[info] first_name` | Casing |
| `personal_info.toml` `[letters] a = "StreetAddress"` | `[letters] a = "street_address"` | Casing also applied to values |

## References

- [JSON Schema draft 2020-12](https://json-schema.org/draft/2020-12)
- [TOML 1.0 spec](https://toml.io/en/v1.0.0)
- [examples/](./examples/) — Concrete AHK and HS examples
- [_shared/tap_hold/defaults.toml](../tap_hold/defaults.toml) — Shared tap-hold generation template
