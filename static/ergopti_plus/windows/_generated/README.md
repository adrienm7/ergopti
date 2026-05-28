# Windows `_generated/` — Auto-generated AHK files

All files in this directory are **auto-generated** and must not be edited manually.
Run the corresponding npm script to regenerate.

| File | Generator script | Status |
|------|-----------------|--------|
| `features_manifest.ahk` | `npm run build:manifest` | ✅ Wired — `#Include`'d in `ErgoptiPlus.ahk` |
| `terminators.ahk` | `npm run codegen:terminators` | ✅ Wired — `#Include`'d in `ErgoptiPlus.ahk` |
| `shortcuts_bindings.ahk` | `npm run codegen:shortcuts` | ✅ Wired — `#Include`'d in `ErgoptiPlus.ahk` |
| `personal_shortcuts.ahk` | generated at runtime by `PersonalTomlEditor` | ✅ Wired — loaded dynamically |
| `prompt_builder.ahk` | `npm run codegen:prompt-builder:ahk` | ✅ Wired — `#Include`'d in tests, used by `prediction_engine.ahk` |
| `registry.ahk` | `npm run codegen:registry` | ⏳ Orphaned — generated but not yet `#Include`'d in the driver |
| `expander.ahk` | `npm run codegen:expander:ahk` | ⏳ Orphaned — generated but not yet `#Include`'d in the driver |

## Orphaned files

`registry.ahk` and `expander.ahk` contain a full AHK v2 port of the shared
`Registry.spec.js` / `Expander.spec.js` domain contracts. They are tested
indirectly via `tests/test_domain_registry.ahk` and `tests/test_domain_expander.ahk`
but the main driver (`ErgoptiPlus.ahk`) still uses the legacy registry/expander
implementation directly.

**Roadmap**: Replace the legacy implementations with these generated adapters
once integration tests confirm parity. This is a Batch-9 / hexagonal-doctrine
migration item.
