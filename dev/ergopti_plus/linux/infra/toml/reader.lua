--- infra/toml/reader.lua

--- ==============================================================================
--- MODULE: Timed TOML Reader (Linux)
--- DESCRIPTION:
--- The shared toml_codec.reader with `parse` timed as the `toml.parse` phase, the
--- phase the macOS driver records (infra/toml/reader.lua there), so the phase
--- summary counts config and hotstring reads and their cost on both systems.
--- Every other function is the shared reader's own.
--- ==============================================================================

local PhaseStats = require("infra.phase_stats")

-- The shared reader is resolved at every use, not captured: a caller that
-- replaces it (a test, a reload) is honoured, as when it was required directly.
local M = setmetatable({}, { __index = function(_, key) return require("toml_codec.reader")[key] end })

--- Parses one TOML file through the shared reader, recording the `toml.parse`
--- phase. A thrown error still reaches the caller unchanged.
--- @param path string File to parse.
--- @return table document
--- @return boolean committed
function M.parse(path)
	local started = PhaseStats.now()
	local document, committed = require("toml_codec.reader").parse(path)
	PhaseStats.stop("toml.parse", started)
	return document, committed
end

return M
