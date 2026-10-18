--- tests/e2e/boot/webview_policy.lua

--- ==============================================================================
--- MODULE: Installed-Boot WebView Boolean Policies
--- DESCRIPTION:
--- Models boolean getters and fluent setters for native WebView policies at
--- Hammerspoon pin 1469832361b4c3687ec7d589c1b4efe4d3b742ee. The generic boot
--- handle cannot represent a getter: returning self would falsely report that
--- native automatic close or child-window creation remains enabled.
--- ==============================================================================

local M = {}

--- Adds only the native policy contract; native close/GC is not modeled here.
--- @param view table Boot harness WebView handle.
--- @return table view Same exact handle.
function M.bind(view)
	for name, initial in pairs({ deleteOnClose = false, allowNewWindows = true }) do
		local value = initial -- C defaults: libwebview.m:105/287.
		view[name] = function(self, ...)
			local supplied = select("#", ...)
			if supplied == 0 then return value end
			local next_value = ...
			assert(supplied == 1 and type(next_value) == "boolean", name .. " expects an optional boolean")
			value = next_value
			return self
		end
	end
	return view
end

return M
