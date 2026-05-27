# dynamic_hotstrings

## Purpose

Orchestrates dynamic text expansions that cannot be stored as static hotstring triggers. Couples two engines: `personal_info.lua` handles `@`-tag substitutions (name, phone, IBAN, SSN) loaded from the user's personal info file, and `rules_engine.lua` generates real-time prefixes and handles date/suffix-based expansions (e.g. `td` → today's date in multiple formats).

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `FileSystem` | Reading the personal info TOML/JSON config file |
| `TextSender` | Injecting expanded text via the keymap expander |
| `TimerScheduler` | Debounce between trigger detection and expansion firing |

## Domain module (`_shared/domain/`)

- `HotstringMatcher.spec.js` — the rules engine exposes match callbacks consumed by the keymap's Registry under this contract

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize with the shared core state table |
| `M.get_matchers()` | Return the list of dynamic matcher objects for the keymap Registry |
| `M.reload_personal_info()` | Re-read the personal info file and rebuild `@`-tag mappings |
| `M.set_enabled(key, value)` | Toggle an individual dynamic expansion category |

## Init pattern

```lua
local DynHS = require("modules.dynamic_hotstrings")
DynHS.init(shared_state)
-- keymap/registry.lua calls DynHS.get_matchers() to register dynamic triggers
```

`M.DEFAULT_STATE` lists all toggleable categories (`dynamichotstrings_datefr`, `dynamichotstrings_phoneprefixes`, etc.) and is the canonical source for menu defaults. Personal info data flows from `personal_info.lua` directly into the rules engine so the main `init.lua` never manages that coupling itself.
