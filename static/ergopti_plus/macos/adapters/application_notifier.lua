--- adapters/application_notifier.lua

--- ==============================================================================
--- MODULE: Application Notifier Adapter (Hammerspoon)
--- DESCRIPTION:
--- Composes application captions through the shared policy while retaining the
--- generic native port's body, urgency, refusal and receipt behavior.
--- ==============================================================================

local M = {}




-- ========================================
-- ========================================
-- ======= 1/ Application Notifications ===
-- ========================================
-- ========================================

--- Sends an application notice through the generic native port.
--- @param label string|nil Canonical bare application label.
--- @param opts table|nil Native body and kind options.
--- @return boolean accepted Exact generic native dispatch result.
function M.send(label, opts)
	local notifier = require("application_notifier").new(function(caption, title, options)
		return require("adapters.notifier").send(caption(title), options)
	end, require("window_titles").compose)
	return notifier.send(label, opts)
end

--- Constructs an application notice with its owner's exact native lifecycle.
--- @param callback function|nil Native click callback.
--- @param properties table Native notification properties with a canonical bare title.
--- @return any notification Exact hs.notify.new result.
function M.new(callback, properties)
	local notifier = require("application_notifier").new(function(caption, action, options)
		local titled = {}
		for key, value in pairs(options) do titled[key] = value end
		titled.title = caption(options.title)
		return hs.notify.new(action, titled)
	end, require("window_titles").compose)
	return notifier.send(callback, properties)
end

return M
