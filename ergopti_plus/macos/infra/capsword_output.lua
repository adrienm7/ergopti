--- infra/capsword_output.lua

--- ==============================================================================
--- MODULE: CapsWord Driver-Output Relay
--- DESCRIPTION:
--- Tells the running CapsWord watcher of the text the driver itself types: a
--- hotstring expansion, a replayed delimiter, an accepted prediction, a paste.
--- A key event the driver posts is not guaranteed to cross the watcher's
--- eventtap (a callback's returned events skip the taps before it, a paste is
--- one Cmd+V), yet a delimiter must end CapsWord as typed output whatever
--- produced it. Holds no settings, so the text producers depend on nothing else.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG = "capsword"

-- The watcher of the running Karabiner lease; nil while none runs.
local _observer = nil

--- Installs or clears the observer (platform/remap/watchers.lua's).
--- @param observer function|nil fn(text) called for each text the driver types.
--- @return boolean installed
function M.set_observer(observer)
	if observer ~= nil and type(observer) ~= "function" then
		Logger.error(LOG, "CapsWord output observer must be a function or nil.")
		return false
	end
	_observer = observer
	return true
end

--- Reports text the driver typed; anything but a non-empty string is ignored.
--- @param text any Typed text.
function M.report(text)
	if _observer == nil or type(text) ~= "string" or text == "" then return end
	local ok, err = pcall(_observer, text)
	if not ok then Logger.error(LOG, "CapsWord output observer raised: %s.", tostring(err)) end
end

return M
