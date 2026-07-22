--- lib/toml/writer.lua

--- ==============================================================================
--- MODULE: TOML Writer — macOS shim
--- DESCRIPTION:
--- Re-exports the canonical TOML writer from the shared Lua library.
--- Callers: require("lib.toml.writer"). The real implementation lives at:
---   static/ergopti_plus/_shared/lua/toml_codec/writer.lua
---
--- RATIONALE:
--- The writer was extracted to _shared/ so all Lua-based drivers (Hammerspoon,
--- future Linux driver) share one implementation. The test runner (tests/run.lua)
--- and the Hammerspoon runtime both inject _shared/lua into package.path before
--- any module is required, so this shim can delegate with a plain require().
--- ==============================================================================

return require("toml_codec.writer")
