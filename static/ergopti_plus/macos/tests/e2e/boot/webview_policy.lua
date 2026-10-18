--- tests/e2e/boot/webview_policy.lua

--- ==============================================================================
--- MODULE: Installed-Boot WebView Close Policy
--- DESCRIPTION:
--- Models the boolean getter and fluent setter from webview_deleteOnClose at
--- Hammerspoon pin 1469832361b4c3687ec7d589c1b4efe4d3b742ee. The generic boot
--- handle cannot represent a getter: returning self would falsely report that
--- the factory's safe native close policy remains enabled.
--- ==============================================================================

local M = {}

--- Adds only the native policy contract; native close/GC is not modeled here.
--- @param view table Boot harness WebView handle.
--- @return table view Same exact handle.
function M.bind(view)
	local delete_on_close = false
	function view:deleteOnClose(...)
		local supplied = select("#", ...)
		if supplied == 0 then return delete_on_close end
		local value = ...
		assert(supplied == 1 and type(value) == "boolean", "deleteOnClose expects an optional boolean")
		delete_on_close = value
		return self
	end
	return view
end

return M
