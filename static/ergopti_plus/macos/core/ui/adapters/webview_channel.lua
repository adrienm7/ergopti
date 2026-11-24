--- core/ui/adapters/webview_channel.lua

--- Creates a window's page message channel and its window style at the native
--- boundary, so a host outside adapters/ names neither hs.webview call.
local M = {}

--- Creates the message channel a page posts to under its bridge name.
---@param name string The bridge name host_bridge.js posts to.
---@return userdata|nil channel The hs.webview.usercontent, nil when refused.
---@return string|nil reason Why it was refused.
function M.new(name)
	assert(type(name) == "string" and name ~= "", "webview channel: a bridge name is required")
	local ok, channel = pcall(hs.webview.usercontent.new, name)
	if not ok or not channel then return nil, tostring(channel) end
	return channel
end

--- The style mask of a titled window that closes and resizes.
---@return number
function M.resizable_style()
	local masks = hs.webview.windowMasks
	return (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8)
end

return M
