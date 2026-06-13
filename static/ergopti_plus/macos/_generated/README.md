# macOS `_generated/` — Auto-generated Lua files

All files in this directory are **auto-generated** and must not be edited manually.
Run the corresponding npm script to regenerate.

| File                    | Generator script              | Status                                            |
| ----------------------- | ----------------------------- | ------------------------------------------------- |
| `features_manifest.lua` | `npm run build:manifest`      | ✅ Wired — read via `lib/manifest_reader.lua`     |
| `terminators.lua`       | `npm run codegen:terminators` | ✅ Wired — loaded by `modules.keymap.terminators` |

## Why no `prompt_builder.lua`?

The Hammerspoon driver uses the shared Lua implementation directly:

```lua
local Shared = require("llm.prompt_builder")  -- shared/lua/llm/prompt_builder.lua
```

No AHK-style code generation is needed because `.lua` files are portable across
all Lua-based drivers. Run `npm run codegen:prompt-builder:hs` to confirm this
(it is a deliberate no-op that documents the design decision).

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
