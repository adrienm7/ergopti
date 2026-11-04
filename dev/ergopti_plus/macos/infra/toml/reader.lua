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

local Reader     = require("toml_codec.reader")
local PhaseStats = require("infra.phase_stats")

-- Every function but parse is the shared reader's own; parse is timed so the
-- phase summary counts config and hotstring reads and their cost.
local M = setmetatable({}, { __index = Reader })

--- Parses one TOML file through the shared reader, recording the `toml.parse`
--- phase. A thrown error still reaches the caller unchanged.
--- @param path string File to parse.
--- @return table document
--- @return boolean committed
function M.parse(path)
	local started = PhaseStats.now()
	local document, committed = Reader.parse(path)
	PhaseStats.stop("toml.parse", started)
	return document, committed
end

return M
