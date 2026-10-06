--- _shared/lua/shortcuts/physical_editor_menu.lua

--- Binds one declared editor command to native readiness and retained scope.
local M = {}

--- Creates command/getter ports without opening a window or capturing input.
--- @param options table scope, host, paused, gestures and refusal notification.
--- @return table ports Ready query and native window opener.
function M.new(options)
	assert(type(options) == "table" and type(options.scope) == "function"
		and type(options.paused) == "function" and type(options.refused) == "function")
	local ports, busy = {}, false
	local function inspect()
		if options.paused() ~= false then return nil end
		local host = options.host()
		if type(host) ~= "table" or type(host.native_available) ~= "function" or type(host.open) ~= "function"
			or type(host.physical_delivery_available) ~= "function" or host.physical_delivery_available() ~= true
			or host.native_available() ~= true or options.paused() ~= false then return nil end
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
			if type(host.available) ~= "function" or host.available(scope) ~= true or options.paused() ~= false then return false end
			return host.open({ scope = scope, gestures = options.gestures, is_paused = options.paused }) == true
		end)
		busy = false
		if not called or accepted ~= true then options.refused(); return false end
		return true
	end
	return ports
end
return M
