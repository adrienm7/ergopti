# Windows `_generated/` — Auto-generated AHK files

All files in this directory are **auto-generated** and must not be edited manually.
Run the corresponding npm script to regenerate.

| File                     | Generator script                             | Status                                                            |
| ------------------------ | -------------------------------------------- | ----------------------------------------------------------------- |
| `features_manifest.ahk`  | `npm run build:manifest`                     | ✅ Wired — `#Include`'d in `ErgoptiPlus.ahk`                      |
| `terminators.ahk`        | `npm run codegen:terminators`                | ✅ Wired — `#Include`'d in `ErgoptiPlus.ahk`                      |
| `personal_shortcuts.ahk` | generated at runtime by `PersonalTomlEditor` | ✅ Wired — loaded dynamically                                     |
| `prompt_builder.ahk`     | `npm run codegen:prompt-builder:ahk`         | ✅ Wired — `#Include`'d in tests, used by `prediction_engine.ahk` |
| `llm_profiles_data.ahk`  | `npm run codegen:llm-profiles-data:ahk`      | ✅ Wired — `#Include`'d in `ErgoptiPlus.ahk` before `modules/llm/profiles.ahk` (DL-2/DL-3) |

> **Removed (audit 2026-06-26, GEN-1/2):** `registry.ahk` and `expander.ahk` were
> orphaned codegen ports of the `Registry.spec.js` / `Expander.spec.js` domain
> contracts — never `#Include`'d, never instantiated. The production hotstring
> path uses the hand-written `HSE_*` engine (`lib/hotstrings/hotstring_engine_main.ahk`),
> and `test_domain_registry.ahk` / `test_domain_expander.ahk` exercise that live
> engine against the shared specs — not the generated classes. The files, their
> `codegen-{registry,expander}-ahk.cjs` generators, and the `codegen:registry` /
> `codegen:expander:ahk` npm scripts were deleted.
