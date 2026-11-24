--- core/ui/ui/reading_views.lua

--- ==============================================================================
--- MODULE: Open Windows of the Reading Preferences (macOS)
--- DESCRIPTION:
--- The windows that show a built page, so a reading choice saved while they
--- are open reaches them at once (core/ui/ui/builder.lua
--- push_reading_preferences). The webview factory tracks each window it shows;
--- the diagnostics and the error window, which create their own webview, track
--- theirs beside their page load.
---
--- FEATURES & RATIONALE:
--- 1. Weak keys: a closed window is collected with its webview, never kept
---    alive by this table.
--- 2. A deleted webview refuses every call: the push drops it, which is not an
---    error.
--- ==============================================================================

local M = {}

local _views = setmetatable({}, { __mode = "k" })

--- Keeps a window that shows a built page.
--- @param wv userdata The window's hs.webview.
function M.track(wv)
	if wv ~= nil then _views[wv] = true end
end

--- Runs a script in every tracked window still open.
--- @param script string JavaScript source.
--- @return number reached Windows the script was handed to.
function M.push(script)
	local reached = 0
	for wv in pairs(_views) do
		local ok = pcall(function() wv:evaluateJavaScript(script) end)
		if ok then reached = reached + 1 else _views[wv] = nil end
	end
	return reached
end

return M
