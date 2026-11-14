--- ui/reload_refusal.lua

--- Shows the error after a reload request is refused.
local M = {}

--- Sends the localized reload-refusal notification.
--- @return boolean accepted Whether the notifier accepted the notification.
function M.notify()
	local I18n = require("core.i18n.engine.i18n")
	return require("adapters.notifier").send(I18n.get("init.reload_refused_body"), {
		title = I18n.get("init.reload_refused_title"), level = "error",
	})
end

return M
