# macOS `_generated/` — Auto-generated Lua files

All files in this directory are **auto-generated** and must not be edited manually.
Run the corresponding npm script to regenerate.

| File                    | Generator script         | Status                                        |
| ----------------------- | ------------------------ | --------------------------------------------- |
| `features_manifest.lua` | `npm run build:manifest` | ✅ Wired — read via `lib/manifest_reader.lua` |
| `config_template.toml`  | `npm run build:manifest` | ⚠️ **No macOS runtime reader** — generated, schema-validated and shipped inside every `.app`, read by nothing. Only Windows copies a template on first boot (`windows/lib/first_boot.ahk`) |

There is **no** `terminators.lua` here. The terminator catalogue is generated once,
shared, at `_shared/lua/keymap/terminators_catalogue.lua`, and this driver reaches it
through the hand-written shim `modules/keymap/terminators.lua` (which adds the i18n
labels). The AHK side gets its own generated copy at `windows/_generated/terminators.ahk`.

### `features_manifest.lua` — `description_key` is AHK-only consumed

Every entry (section and feature) carries a `description_key` field, but no
Lua module on macOS reads `entry.description_key` today — `lib/manifest_reader.lua`
only exposes per-path default lookups. The AHK driver genuinely resolves every
`description_key` via its menu builder. The field is still emitted on the Lua
side for structural parity with the AHK twin (`features_manifest.ahk`) and
because `tools/test/test-manifest-parity.cjs` cross-checks it between the two
generated files — its regex parsers require the field to be present to match a
section/feature block at all, so removing it here would break that shared
parity-testing path. See the generator's own comment in
`tools/build/build-features-manifest.js` (`renderLuaManifest`) for the same
rationale (F-LOW-15).

## Why no `prompt_builder.lua`?

The Hammerspoon driver uses the shared Lua implementation directly:

```lua
local Shared = require("llm.prompt_builder")  -- shared/lua/llm/prompt_builder.lua
```

No AHK-style code generation is needed because `.lua` files are portable across
all Lua-based drivers. AutoHotkey cannot `require` a `.lua` file, which is why
`codegen-prompt-builder-ahk.cjs` translates the same algorithm into AHK v2 and
writes `windows/_generated/prompt_builder.ahk` — the asymmetry is between the
two languages, not between the two drivers.

There used to be a `codegen:prompt-builder:hs` task alongside it. It generated
nothing: its own docstring said it existed "only to document the asymmetry and
give the developer a consistent npm task that always succeeds". A task that
cannot fail teaches nobody anything, so the explanation lives here instead.

## Why no `registry.lua` / `expander.lua` / `shortcuts_bindings.lua`?

They used to be generated here as a planned "hexagonal migration" (consume the
shared `Registry.spec.js` / `Expander.spec.js` adapters from both drivers), but
the migration never happened: the hand-written `modules/keymap/registry.lua`
(~1126 lines) and `expander.lua` diverged far past the generated pure-logic
contract — TOML loading, `hs.settings`, the priority cascade, case-variant
generation and i18n live only in the hand-written modules. The generated
adapters were never `require`'d, never tested, and could not replace the
hand-written ones without losing features. They (and `codegen-{expander,registry}-hs`,
`codegen-shortcuts`) were removed (2026-06-13) as dead code. The shared specs
remain canonical and are still validated on the AHK side via its tested adapters.
