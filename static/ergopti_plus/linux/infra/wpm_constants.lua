--- infra/wpm_constants.lua

--- ==============================================================================
--- MODULE: WPM Readout Canon Loader (Linux)
--- DESCRIPTION:
--- Reads _shared/modules/wpm_widget/constants.toml once, through the shared
--- model's loader, which checks every key the readouts draw with.
---
--- FEATURES & RATIONALE:
--- 1. Read, never restated. The floating widget and the tray readout both draw
---    from this one table; neither holds a colour or a size of its own.
--- 2. Fail fast. A missing or mistyped key refuses the whole canon — the
---    readouts then stay off and say why, rather than draw with a guess.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Codec  = require("toml_codec")
local Paths  = require("infra.paths")
local Model  = require("wpm_widget.model")

local LOG = "infra.wpm_constants"

-- The canon once read; nil until then or when it could not be read.
local _constants = nil

--- The checked canon, or nil when it cannot be read.
--- @return table|nil
function M.load()
	if _constants ~= nil then return _constants end
	local path = Paths.shared("modules/wpm_widget/constants.toml")
	local canon, err = Model.load(path, Codec.decode)
	if not canon then
		Logger.error(LOG, "The WPM readout canon is unusable (%s) — the readouts cannot draw.", tostring(err))
		return nil
	end
	_constants = canon
	Logger.info(LOG, "WPM readout canon loaded from the shared constants.")
	return _constants
end

--- Clears the cached canon. Tests only.
function M._reset()
	_constants = nil
end

return M
