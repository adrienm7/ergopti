--- _shared/lua/application_notifier.lua

--- ==============================================================================
--- MODULE: Application Notification Captions
--- DESCRIPTION:
--- Binds the generated shared caption policy to an application notification
--- dispatcher. Generic Notifier ports retain their independent title contract.
--- Native dispatchers retain ownership of payload, urgency and delivery receipts.
--- ==============================================================================

local M = {}





-- =========================================
-- =========================================
-- ======= 1/ Application Dispatcher =======
-- =========================================
-- =========================================

--- Creates a dispatcher with one injected application-caption policy.
--- @param dispatch function Receives the caption callback followed by original arguments.
--- @param compose function Generated shared title composer.
--- @return table notifier Application dispatcher preserving every native return value.
function M.new(dispatch, compose)
	assert(type(dispatch) == "function", "application notification dispatcher is required")
	assert(type(compose) == "function", "application caption composer is required")
	local function caption(label, decoration)
		local bare_label = type(label) == "string" and label or ""
		if type(decoration) == "string" and decoration ~= "" then
			bare_label = decoration .. bare_label
		end
		return compose(bare_label)
	end
	return {
		send = function(...) return dispatch(caption, ...) end,
	}
end

return M
