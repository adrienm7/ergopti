# features (shared)

## Purpose

Single source of truth for every feature toggle and its default value across both drivers. `manifest.toml` is processed by `npm run codegen` to generate `windows/_generated/features_manifest.ahk` and, for macOS and Linux together, `_shared/lua/features/manifest_data.lua` (each driver's `_generated/features_manifest.lua` projects it). Neither driver edits the generated files by hand. Feature state is read at runtime via `Features["section"]["id"]` (AHK) or `Manifest.feat_enabled("section.id")` (macOS).

## Editing rules

1. Add a new feature → add one entry in `manifest.toml` under the appropriate `[section]` table, with its `requires` (below).
2. Run `npm run build:domain` to regenerate and validate — the drift gate fails CI if the generated files are out of sync.
3. Never read `_generated/` directly; always go through the `Features` map or `Manifest` accessor.

## Requirements per OS

Every feature declares what it needs outside its driver, per OS it is available on: `requires = { macos = ["karabiner"], linux = ["evdev", "uinput"], windows = [] }`. An empty list means nothing external; an OS the feature is not on is absent (its `platforms` and `reason_key` say why). The ids form one closed vocabulary in `requirements.toml`.

The declarations are checked, not trusted: `npm run test:feature-requirements` derives them and fails in both directions, per OS, naming the evidence.

- macOS `karabiner` comes from `macos/platform/remap/generator.lua`: `M.REQUIREMENT_STATE_FEATURES` maps each state field the generator reads to the features it feeds, and `M.REQUIREMENT_FACADE_FEATURES` lists each module reaching Karabiner without it (the `_karabiner` facade, `platform.remap.ke_variables`, the physical key ledger). A new `state.<field>` read, or a new facade caller, fails until it is mapped there.
- Every other id comes from a source signature of `requirements.toml` (the grab ioctl, a spawned program, an owner module named for its runtime). Each file it finds is an owner of named features or plumbing with a reason; an unclassified file, or an owner or plumbing entry that finds nothing, fails.

After changing a declaration or the vocabulary, run `npm run codegen:feature-requirements` to regenerate `docs/design/feature-requirements.md`.

## Key files

| File                | Description                                                                  |
| ------------------- | ---------------------------------------------------------------------------- |
| `manifest.toml`     | Master feature registry with `default`, `label`, `section`, `id`, `requires` |
| `requirements.toml` | Closed vocabulary of `requires` ids and the per-OS rules that derive them    |

## References

- ADR 002 (`docs/adr/002-codegen-manifest.md`) — codegen contract.
- ADR 003 (`docs/adr/003-single-toml-schema.md`) — single-TOML schema rule.
- `test:feature-read-sites` (`tools/test/test-feature-read-sites.js`) — CI gate asserting every `Features[…]` call resolves against the manifest.
