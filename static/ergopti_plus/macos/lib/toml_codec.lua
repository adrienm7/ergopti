--- lib/toml_codec.lua

--- ==============================================================================
--- MODULE: TOML Codec — Compatibility Shim
--- DESCRIPTION:
--- Re-exports the canonical TOML codec from the shared Lua library so that
--- existing callers using require("lib.toml_codec") continue to work without
--- modification. The real implementation lives at:
---   static/ergopti_plus/shared/lua/toml_codec/codec.lua
---
--- RATIONALE:
--- The codec was extracted to shared/ so all Lua-based drivers (Hammerspoon,
--- future Linux driver) share one implementation. The test runner (tests/run.lua)
--- and the Hammerspoon runtime both inject shared/lua into package.path before
--- any module is required, so this shim can delegate with a plain require().
--- ==============================================================================

return require("toml_codec")
