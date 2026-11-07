--- modules/keystats/roi_policy.lua

--- ==============================================================================
--- MODULE: Trigger ROI Text Admission
--- DESCRIPTION:
--- New candidate and last-use text require both requested and effective cipher
--- states to be known off. Input uses the collector's admitted RAM preference;
--- persistence may re-read the canonical owner before acquiring new source.
--- ==============================================================================

local M = {}
local Cipher = require("modules.keystats.text_cipher")
local Preferences = require("infra.metrics_preferences")

--- Admits text only for a known-off preference and effective cipher.
--- @param requested boolean|nil Collector's admitted requested state.
--- @return boolean
function M.text_enabled(requested)
	if requested ~= false then return false end
	local called, enabled = pcall(Cipher.is_enabled)
	return called and enabled == false
end

--- Rechecks the canonical preference outside the input callback.
--- @return boolean
function M.current()
	local called, requested = pcall(Preferences.get, "metrics.encrypt", true)
	return called and M.text_enabled(requested)
end

return M
