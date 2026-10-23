# Ergopti+ — unified configuration schema (v2)

This folder describes the target user-configuration schema after the Scope C refactor. The files under `examples/*.toml` are **reviewable drafts** — no driver reads them. They illustrate a configured file; the neutral first-run state is each driver's generated `config_template.toml`, and the `[layout]` values of the Windows example are held equal to the manifest defaults by `tools/test/test-neutral-installation.cjs`.

## Overview

```
<config dir>/                        # Windows/macOS: the user config folder; Linux: $XDG_CONFIG_HOME/ergopti
├── personal_info.toml               # Universal, read by all three drivers
├── hotstrings_config.toml           # Universal, delay/colour overrides per group
├── autohotkey/                      # Windows only
│  ├── config.toml                   # v2 schema (universal sections)
│  ├── tap_hold.toml                 # Windows tap-hold overrides (merged OVER the shared defaults, key by key)
│  └── logs/
└── hammerspoon/                     # macOS only
   ├── config.toml                   # v2 schema (universal sections)
   ├── tap_hold.toml                 # macOS tap-hold config ([hs_*] always read from the shared file)
   └── config_karabiner.toml         # managed by the karabiner module
```

Linux keeps `config.toml` and `tap_hold.toml` directly in its configuration
folder (`linux/infra/config_paths.lua` owns the location).

And on the repo's shared-resources side:

```
static/ergopti_plus/_shared/
├── core/
│  ├── config_schema/               # THIS FOLDER
│  │  ├── config.schema.json        # Strict JSON Schema (draft 2020-12); the metrics definition is generated
│  │  ├── tap_hold.schema.json      # Sub-schema for tap-hold
│  │  ├── SCHEMA.md                 # This documentation
│  │  └── examples/
│  ├── ports/                       # OS-facing port contracts (SPEC.md + *.spec.js)
│  └── domain/                      # Pure domain modules (SPEC.md + *.spec.js)
├── tap_hold/
│  └── defaults.toml                # Canonical tap-hold defaults, read at runtime (see Tap-hold)
├── modules/
│  ├── features/manifest.toml       # Single source of features
│  ├── actions/actions.toml         # Action catalogue
│  ├── logger/                      # SPEC.md, sub_files.toml, test_vectors.json
│  ├── tooltip/                     # SPEC.md and the visual constants
│  └── llm/                         # defaults, profiles, models, inference
├── data/locales/                    # One JSON per language
└── ui/                              # Shared WebView HTML/JS
```

## Conventions

### Casing — **snake_case everywhere**

All TOML keys are `snake_case`. That is the standard TOML convention.

### Universal vs. platform-specific sections

Which driver reads a section is declared once, in `[sections.*]` and the
per-entry `platforms` of `_shared/modules/features/manifest.toml`; the generated
`config_template.toml` of each driver carries exactly its own sections and keys.
A key that only one driver writes is declared once in the manifest, never in a
driver-prefixed section.

| Section        | Read by                          | Schema                 |
| -------------- | -------------------------------- | ---------------------- |
| `[script]`     | Windows + macOS                  | `$defs.script`         |
| `[hotstrings]` | all three drivers                | `$defs.hotstrings`     |
| `[llm]`        | all three drivers                | `$defs.llm`            |
| `[metrics]`    | all three drivers                | `$defs.metrics`        |
| `[shortcuts]`  | all three drivers                | `$defs.shortcuts`      |
| `[tap_hold.*]` | all three drivers (own tap-hold) | `tap_hold.schema.json` |

`$defs.metrics` is generated from the manifest by
`npm run codegen:config-schema-metrics`; `test-config-schema.cjs` fails when it
drifts and rejects a metrics key the manifest does not declare.

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

## Validation

### At boot

The drivers do not load `config.schema.json`. Each one checks the values it reads
against the feature manifest's own declarations (type, enum, range) and reports an
outdated or malformed entry once, naming the file; the manifest default applies to
an invalid key.

### In CI

`tools/test/test-config-schema.cjs` validates the generated `config_template.toml`
of every driver against `config.schema.json`, and requires each driver to carry
the sections the manifest gives it. Validation of `examples/*.toml` is not
automated, apart from the neutral `[layout]` values of the Windows example
(`tools/test/test-neutral-installation.cjs`).

A companion `tools/lint/audit-banner-alignment.js` enforces the CLAUDE.md banner-comment alignment in every `*.toml`. Run it manually with `--fix` to auto-correct, or in pre-commit without it to detect regressions.

## Codegen pipeline

`_shared/modules/features/manifest.toml` is **not** parsed by the drivers directly. A Node script runs at build time:

```
npm run build:manifest
```

It calls [`tools/build/build-features-manifest.js`](../../../../tools/build/build-features-manifest.js), which:

1. Pre-processes the manifest source — every `[[features.X.Y.Z]]` header is rewritten in memory to `[[entries]]` with a synthetic `path_prefix = "X.Y.Z"` field, so the TOML parser sees a single flat array-of-tables instead of nested AoTs (which TOML would otherwise interpret as sub-arrays of the parent entry).
2. Flattens features, inherits `platforms` from ancestor sections when absent, resolves `default_per_platform` to the active platform.
3. Validates entries (id pattern, exactly one of `default` / `default_per_platform`, `enum_values` required when `type = "enum"`).
4. Emits the per-driver artifacts into the tracked `_generated/` folders:
   - `windows/_generated/features_manifest.ahk` — AHK Map literal consumed at boot.
   - `windows/_generated/config_template.toml` — default user config copied at first boot.
   - `macos/_generated/features_manifest.lua` and `linux/_generated/features_manifest.lua` — Lua tables consumed at boot.
   - `macos/_generated/config_template.toml` and `linux/_generated/config_template.toml` — same purpose, filtered per driver.

   The tap-hold template is **not** generated: `first_boot.ahk` reads
   `static/ergopti_plus/_shared/tap_hold/defaults.toml` directly, eliminating the
   redundant generated copy.

`_generated/` is tracked; never hand-edit it. Run `npm run build:manifest` after editing the manifest, and `npm run gen:check` proves the committed output is current.

## Initial generation at first boot

If the driver's `config.toml` does not exist at first boot:

1. The driver reads `static/ergopti_plus/_shared/modules/features/manifest.toml` (the single source of truth).
2. It filters entries whose `platforms` includes the current driver.
3. It renders a clean `config.toml` with:
   - Section banners (CLAUDE.md `# =====` format).
   - Description comments resolved via `description_key` from the manifest against `static/ergopti_plus/_shared/data/locales/<locale>.json`.
   - Explicit defaults for every feature.
4. It writes the file and continues its normal boot.

`tap_hold.toml` does **not** follow that mechanism, despite three places in this
document having said it did. Every driver reads `_shared/tap_hold/defaults.toml`
at runtime, on every boot — and each reads it differently. See
[Tap-hold](#tap-hold) below for what each one actually does.

## Tap-hold

`_shared/tap_hold/defaults.toml` is read **at runtime, on every boot, by all
three drivers**. It was documented here as a first-boot generation template whose
output is thereafter complete — "the shared file is never read again at runtime"
— and that was wrong in three separate places. The three loaders do not even
agree with each other, and each one's own comments claim it matches the others:

| Driver  | Sections read                                   | Lifecycle                                                                                                                                                                                                                                                                                                                                                                              |
| ------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows | `[tap_hold.*]`                                  | Parses the shared defaults **first**, then merges the user file **on top, per key**. A key absent from the user file inherits the shared default, so editing `defaults.toml` changes existing installs on the next reload. `lib/tap_hold/tap_hold_loader.ahk` says so explicitly: "editing `defaults.toml` takes effect on every reload even when the user file exists".               |
| Linux   | `[tap_hold.*]`                                  | `platform/remap/tap_hold_loader.lua` applies the Windows rules to the same files, with one switch: with `[tap_hold] inherit_defaults = true` the user file is laid over the shared defaults key by key and field by field; without it the user file starts from no shipped key at all (an empty file is the keyboard's own behaviour). The scope restore writes the preset explicitly. |
| macOS   | `[hs_timeouts]`, `[hs_tap_hold]`, `[hs_combos]` | `platform/remap/defaults.lua` reads the shared file in its **module body**, at require time, unconditionally — there is no user file for these sections at all, so an edit always applies.                                                                                                                                                                                             |

The two namespaces in that one file describe the **same seven physical keys**
under different ids (`left_ctrl`/`left_control`, `left_alt`/`left_option`), with
different thresholds (0.2–0.35 s per key vs a flat 1000 ms global) and, in
places, different actions — `caps_lock` holds `ctrl` under `[tap_hold.*]` and
`cmd` under `[hs_tap_hold]`. Unifying them is Lot 8(7); this section documents
what is true today so nobody edits the file believing it cannot reach a shipped
install.

This means:

- On Windows a key missing from the per-driver file inherits the shared default; on Linux that inheritance applies only when the user file sets `[tap_hold] inherit_defaults = true`.
- On macOS the `[hs_*]` sections are not user-editable: an edit of `defaults.toml` always applies.
- The hold thresholds differ on purpose between the namespaces (per key 0.20-0.35 s on Windows and Linux, a global value plus a per-key override on macOS).

### Semantics of a tap-hold key

Each `[tap_hold.keys.<name>]` entry may declare:

| Field                     | Type   | Required | Description                                                              |
| ------------------------- | ------ | -------- | ------------------------------------------------------------------------ |
| `time_activation_seconds` | number | yes      | Tap vs hold threshold                                                    |
| `tap_action`              | string | no       | Action emitted on short tap (ref `_shared/modules/actions/actions.toml`) |
| `hold_layer`              | string | no       | Layer activated on hold (an id from `[tap_hold.hold_picker].layers`)     |
| `hold_modifier`           | enum   | no       | Modifier emitted on hold (mutex with `hold_layer`)                       |
| `enabled`                 | bool   | no       | Default `true`. Set `false` to disable this entry without deleting it    |

`hold_layer` and `hold_modifier` are **mutually exclusive** (the schema enforces it).

## v1 → v2 mapping (reference)

Since we're going clean-state with no backward compatibility, this mapping is **informative only** — it documents what every v1 key becomes in v2, to make diffs easier to read in the AHK/HS code refactor.

| v1 (PascalCase / mixed)                                                              | v2 (unified snake_case)                                                             | Notes                         |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- | ----------------------------- |
| `[Hotstrings] MagicKey`                                                              | `[hotstrings] trigger_char`                                                         | Semantic rename               |
| `[Hotstrings.Autocorrection] Accents = true` + `Accents_TimeActivationSeconds = 0.5` | `[hotstrings.autocorrection.accents] enabled = true; time_activation_seconds = 0.5` | Modelling α                   |
| `[LLM] ctx_chars`                                                                    | `[llm.generation] context_length`                                                   | Adopts HS naming              |
| `[LLM] model`                                                                        | `[llm.models] selected` + `[llm.models] ollama = "..."`                             | Explicit multi-backend        |
| `[Layout] ErgoptiBase`                                                               | `[ahk.layout] ergopti_base`                                                         | AHK-only, prefixed            |
| `[TapHolds.CapsLock]` (AHK)                                                          | `[tap_hold.keys.caps_lock]` (per-driver tap_hold.toml)                              | Dedicated file                |
| `[Shortcuts] AGrave = true` + `AGrave_Letter = "v"`                                  | `[shortcuts.a_grave] enabled = true; letter = "v"`                                  | Modelling α extended          |
| `[Shortcuts.AltGrCapsLock]`                                                          | `[shortcuts.key_combination_taps] alt_gr_then_caps_lock`                            | AHK-only                      |
| `[Gestures]` (AHK, limited vocab)                                                    | `[ahk.gestures]`                                                                    | Prefixed (Win vocab)          |
| `[gestures]` (HS, rich vocab)                                                        | `[hs.gestures]` + `[hs.gestures.modes]` + `[hs.gestures.sensitivities]`             | Prefixed (Mac vocab)          |
| `[Script] Locale` (PascalCase)                                                       | `[script] locale`                                                                   | Casing                        |
| `[Script] WpmWidget*`                                                                | moved under `[hs.metrics.float]` / dropped from AHK                                 | Semantic re-centering         |
| `personal_info.toml` `[info] FirstName`                                              | `[info] first_name`                                                                 | Casing                        |
| `personal_info.toml` `[letters] a = "StreetAddress"`                                 | `[letters] a = "street_address"`                                                    | Casing also applied to values |

## References

- [JSON Schema draft 2020-12](https://json-schema.org/draft/2020-12)
- [TOML 1.0 spec](https://toml.io/en/v1.0.0)
- [examples/](./examples/) — Concrete Windows and macOS examples
- [\_shared/tap_hold/defaults.toml](../../tap_hold/defaults.toml) — shared tap-hold defaults
