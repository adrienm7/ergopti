--- modules/keylogger/privacy_context.lua

--- Applies the same privacy policy to live and retained keylogger contexts.
local M = {}
local SYSTEM_AUTH_BUNDLE_IDS = {
	["com.apple.SecurityAgent"] = true,
	["com.apple.CoreAuthUI"] = true,
}

--- Evaluates an observed context without querying native state or mutating it.
---@param state table Keylogger context and filter configuration.
---@return boolean allowed
function M.allows_logging(state)
	if state.private_filter_enabled and state.is_private_window then return false end
	if state.secure_field_filter_enabled and state.is_secure_field then return false end
	if state.system_auth_filter_enabled and state.active_app_bundle
		and SYSTEM_AUTH_BUNDLE_IDS[state.active_app_bundle] then
		return false
	end
	if state.disabled_apps and #state.disabled_apps > 0 then
		for _, disabled in ipairs(state.disabled_apps) do
			if (disabled.bundleID and disabled.bundleID == state.active_app_bundle)
				or (disabled.appPath and disabled.appPath == state.active_app_path) then
				return false
			end
		end
	end
	return true
end

return M
