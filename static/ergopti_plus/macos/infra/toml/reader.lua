--- infra/toml/reader.lua

--- ==============================================================================
--- MODULE: TOML Reader — macOS shim
--- DESCRIPTION:
--- Re-exports the canonical TOML reader from the shared Lua library.
--- Callers: require("infra.toml.reader"). The real implementation lives at:
---   static/ergopti_plus/_shared/lua/toml_codec/reader.lua
---
--- RATIONALE:
--- The reader was extracted to _shared/ so all Lua-based drivers (Hammerspoon,
--- future Linux driver) share one implementation. The test runner (tests/run.lua)
--- and the Hammerspoon runtime both inject _shared/lua into package.path before
--- any module is required, so this shim can delegate with a plain require().
--- ==============================================================================

return require("toml_codec.reader")
