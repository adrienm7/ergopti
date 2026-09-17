--- adapters/webview_result.lua

--- Interprets WebKit completion errors at the native boundary.
local M = {}

--- Reports every error except the documented nil and the native nil-NSError sentinel.
--- Hammerspoon 1.1.1 unconditionally converts NSError, producing exactly {code=0}
--- when Objective-C receives nil. A real code-zero error still has other fields.
---@param value any Error argument from a WebView JavaScript completion.
---@return boolean failed
function M.is_error(value)
	if value == nil then return false end
	if type(value) ~= "table" or getmetatable(value) ~= nil or value.code ~= 0 then return true end
	for key in pairs(value) do if key ~= "code" then return true end end
	return false
end

return M
