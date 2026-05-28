# macOS `_generated/` — Auto-generated Lua files

All files in this directory are **auto-generated** and must not be edited manually.
Run the corresponding npm script to regenerate.

| File | Generator script | Status |
|------|-----------------|--------|
| `features_manifest.lua` | `npm run build:manifest` | ✅ Wired — `require`'d in Hammerspoon `init.lua` |
| `terminators.lua` | `npm run codegen:terminators` | ✅ Wired — loaded by `modules.keymap.terminators` |
| `shortcuts_bindings.lua` | `npm run codegen:shortcuts` | ✅ Wired — loaded by `modules.shortcuts` |
| `registry.lua` | `npm run codegen:registry:hs` | ⏳ Orphaned — generated but not yet `require`'d in the driver |
| `expander.lua` | `npm run codegen:expander:hs` | ⏳ Orphaned — generated but not yet `require`'d in the driver |

## Why no `prompt_builder.lua`?

The Hammerspoon driver uses the shared Lua implementation directly:

```lua
local Shared = require("llm.prompt_builder")  -- shared/lua/llm/prompt_builder.lua
```

No AHK-style code generation is needed because `.lua` files are portable across
all Lua-based drivers. Run `npm run codegen:prompt-builder:hs` to confirm this
(it is a deliberate no-op that documents the design decision).

## Orphaned files

`registry.lua` and `expander.lua` contain a full Lua port of the shared
`Registry.spec.js` / `Expander.spec.js` domain contracts. They are not yet
wired into the main driver.

**Roadmap**: Replace the legacy keymap registry/expander with these generated
adapters once integration tests confirm parity. This is a Batch-9 /
hexagonal-doctrine migration item.
