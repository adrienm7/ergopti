--- platform/vision/vision_session.lua

--- ==============================================================================
--- MODULE: Screen Vision Session (Linux)
--- DESCRIPTION:
--- The one place that starts the screen vision service, for every feature that
--- reads the screen: the auto-clicker and the user workflows. The service
--- refuses a second init, so each feature asks this session for it instead of
--- starting it itself.
--- ==============================================================================

local M = {}

local _started = false

--- The started screen vision service.
--- @return table The platform.vision.screen_vision module.
function M.service()
	local Vision = require("platform.vision.screen_vision")
	if not _started then
		_started = true
		Vision.init()
	end
	return Vision
end

--- Whether the service was started.
--- @return boolean
function M.started()
	return _started
end

return M
