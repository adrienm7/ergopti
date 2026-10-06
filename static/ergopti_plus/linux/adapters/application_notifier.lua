--- adapters/application_notifier.lua

--- ==============================================================================
--- MODULE: Application Notifier Adapter (Linux)
--- DESCRIPTION:
--- Binds the shared title policy to the native application dispatch helper.
--- Native urgency decoration stays in the label after the application prefix;
--- the independent generic Notifier port keeps its literal title contract.
--- ==============================================================================

local M = {}




-- ========================================
-- ========================================
-- ======= 1/ Application Notifications ===
-- ========================================
-- ========================================

--- Sends an application notice with a canonical bare options.title label.
--- @param message string Original notification body.
--- @param opts table|nil Native title, level and click options.
--- @return boolean admitted Exact native command admission result.
function M.send(message, opts)
	local notifier = require("application_notifier").new(
		require("adapters.notifier")._send_application, require("window_titles").compose)
	return notifier.send(message, opts)
end

return M
