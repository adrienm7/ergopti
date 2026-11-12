--- _shared/lua/shortcuts/physical_editor_menu.lua

--- Binds one declared editor command to native readiness and retained scope.
--- A pause does not close it: a pause stops typing, not configuration (EDD-1,
--- maintainer decision 2026-11-12).
local M = {}

--- Creates command/getter ports without opening a window or capturing input.
--- @param options table scope, host, gestures and refusal notification.
--- @return table ports Ready query and native window opener.
function M.new(options)
	assert(type(options) == "table" and type(options.scope) == "function"
		and type(options.refused) == "function")
	local ports, busy = {}, false
	local function inspect()
		local host = options.host()
		if type(host) ~= "table" or type(host.native_available) ~= "function" or type(host.open) ~= "function"
			or type(host.physical_delivery_available) ~= "function" or host.physical_delivery_available() ~= true
			or host.native_available() ~= true then return nil end
		return host
	end
	function ports.ready()
		if busy then return false end
		busy = true
		local called, host = pcall(inspect)
		busy = false
		return called and host ~= nil
	end
	function ports.open()
		if busy then return false end
		busy = true
		local called, accepted = pcall(function()
			local host = inspect()
			if not host then return false end
			local scope = options.scope()
			if type(host.available) ~= "function" or host.available(scope) ~= true then return false end
			return host.open({ scope = scope, gestures = options.gestures }) == true
		end)
		busy = false
		if not called or accepted ~= true then options.refused(); return false end
		return true
	end
	return ports
end
return M
