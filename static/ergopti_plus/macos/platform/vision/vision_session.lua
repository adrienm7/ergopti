--- platform/vision/vision_session.lua

--- ==============================================================================
--- MODULE: Screen Vision Session (macOS)
--- DESCRIPTION:
--- The one place that starts the screen vision service, for every feature that
--- reads the screen: the auto-clicker and the user workflows. The service
--- refuses a second init, so each feature asks this session for it instead of
--- starting it itself.
---
--- FEATURES & RATIONALE:
--- 1. Started on first use, with the driver's cache folder for the captures,
---    then its availability refreshed once in the launcher.
--- 2. A feature that needs to redraw when the availability is known registers
---    a listener; one registered after the refresh is told at once.
--- ==============================================================================

local M = {}

local AppDirs = require("core.fs.engine.app_dirs")
local Logger = require("core.logger.engine.logger")

local LOG = "platform.vision.vision_session"

local _started = false
local _availability = nil
local _listeners = {}

--- Tells one listener, logging a listener that raises.
local function tell(listener, availability)
	local ok, err = pcall(listener, availability)
	if not ok then Logger.error(LOG, "A screen vision availability listener raised: %s.", tostring(err)) end
end

--- The service's private cache folder, where captures and templates live.
--- @return string
function M.cache_dir()
	return os.getenv("HOME") .. "/" .. AppDirs.macos.cache_relative .. "/vision"
end

--- The started screen vision service.
--- @return table The platform.vision.screen_vision module.
function M.service()
	local Vision = require("platform.vision.screen_vision")
	if not _started then
		_started = true
		Vision.init({ cache_dir = M.cache_dir() })
		Vision.refresh_availability(function(availability)
			_availability = availability
			for _, listener in ipairs(_listeners) do tell(listener, availability) end
		end)
	end
	return Vision
end

--- Whether the service was started.
--- @return boolean
function M.started()
	return _started
end

--- Calls listener(availability) once the availability is known.
--- @param listener function
function M.on_availability(listener)
	assert(type(listener) == "function", "vision_session.on_availability needs a function")
	_listeners[#_listeners + 1] = listener
	if _availability then tell(listener, _availability) end
end

return M
