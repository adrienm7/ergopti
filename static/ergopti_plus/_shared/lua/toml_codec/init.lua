--- drivers/_shared/lua/toml_codec/init.lua

--- ==============================================================================
--- MODULE: TOML Codec — Shared Entry Point
--- DESCRIPTION:
--- Pure-Lua TOML encoder and decoder shared by all Lua-based drivers
--- (Hammerspoon, Linux LuaJIT daemon). This init.lua is the canonical entry
--- point so that `require("toml_codec")` resolves via Lua's `?/init.lua`
--- search pattern and returns the encoder/decoder table.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: the implementation lives in codec.lua; this
---    file is purely a router so both `require("toml_codec")` and
---    `require("toml_codec.codec")` return the same module table.
--- 2. No hs.* dependencies: codec.lua is pure Lua 5.3+ with no Hammerspoon
---    or driver-specific APIs, making it safe for any runtime.
--- 3. Companion sub-modules: toml_codec.reader and toml_codec.writer live
---    alongside this file and handle the hotstrings TOML format specifically.
---    They carry lib.logger / lib.i18n dependencies and are intended for use
---    inside a driver runtime that provides those packages.
--- ==============================================================================

return require("toml_codec.codec")
