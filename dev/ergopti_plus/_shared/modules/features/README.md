# features (shared)

## Purpose

Single source of truth for every feature toggle and its default value across both drivers. `manifest.toml` is processed by `npm run codegen` to generate `windows/_generated/features_manifest.ahk` and `macos/_generated/features_manifest.lua`. Neither driver edits the generated files by hand. Feature state is read at runtime via `Features["section"]["id"]` (AHK) or `Manifest.feat_enabled("section.id")` (macOS).

## Editing rules

1. Add a new feature → add one entry in `manifest.toml` under the appropriate `[section]` table.
2. Run `npm run build:domain` to regenerate and validate — the drift gate fails CI if the generated files are out of sync.
3. Never read `_generated/` directly; always go through the `Features` map or `Manifest` accessor.

## Key files

| File            | Description                                                          |
| --------------- | -------------------------------------------------------------------- |
| `manifest.toml` | Master feature registry with `default`, `label`, `section`, `id`    |

## References

- ADR 002 (`docs/adr/002-codegen-manifest.md`) — codegen contract.
- ADR 003 (`docs/adr/003-single-toml-schema.md`) — single-TOML schema rule.
- `test:feature-read-sites` (`tools/test/test-feature-read-sites.js`) — CI gate asserting every `Features[…]` call resolves against the manifest.
