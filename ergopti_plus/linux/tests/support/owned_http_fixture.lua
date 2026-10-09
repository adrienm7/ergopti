--- tests/support/owned_http_fixture.lua

--- ==============================================================================
--- MODULE: Controlled Owned HTTP Fixture Ports
--- DESCRIPTION:
--- Gives existing scripted HTTP scenarios the mandatory operation contract.
--- Cancellation acceptance and physical settlement are separately controlled;
--- no native process, group, descriptor or close callback is proven here.
--- ==============================================================================

local M = {}

--- Extends scripted HTTP effects with exact retained operation capabilities.
--- @param port table Scripted get/postStream/cancel callbacks.
--- @param controls table|nil { settled?: boolean, during_create?: function }.
--- @return table Same fixture port, with get_owned/post_stream_owned.
function M.attach(port, controls)
	controls = controls or {}
	local get, post, cancel = port.get, port.postStream, port.cancel
	local operations = {}
	controls.operations = operations
	local function owned(dispatch, options, chunk, done)
		options = options or {}
		local authorized = options.authorized
		local operation = { started = false, closed = false, cancelled = false, listeners = {} }
		operations[#operations + 1] = operation
		local function allowed()
			local value = true
			if authorized ~= nil then
				local ok, result = pcall(authorized)
				value = ok and result == true
			end
			return value and not operation.cancelled
		end
		function operation:is_settled() return self.closed end
		function operation:on_settled(observer)
			if self.closed then observer() else self.listeners[#self.listeners + 1] = observer end
			return true
		end
		function operation:acknowledge()
			if self.closed then return true end
			self.closed = true
			local listeners = self.listeners
			self.listeners = {}
			for _, listener in ipairs(listeners) do listener() end
			return true
		end
		function operation:cancel()
			self.cancelled = true
			if self.closed then return true end
			local accepted = type(cancel) ~= "function" or cancel(options.owner) == true
			if accepted and controls.settled ~= false then self:acknowledge() end
			return self.closed
		end
		if controls.during_create then controls.during_create(operation) end
		if not allowed() then operation:acknowledge(); return operation end
		operation.started = dispatch(function(value)
			if type(chunk) == "function" and allowed() then chunk(value) end
		end, function(value)
			if controls.settled ~= false then operation:acknowledge() end
			if allowed() and type(done) == "function" then done(value) end
		end) == true
		-- Refusal normally acquired no resources. An independent allocation
		-- control explicitly retains partial native constructor cleanup.
		if not operation.started and controls.refused_dispatch_acquired ~= true then operation:acknowledge() end
		return operation
	end
	function port.get_owned(url, headers, options, done)
		return owned(function(_, terminal)
			return type(get) == "function" and get(url, headers, options, terminal) == true
		end, options, nil, done)
	end
	function port.post_stream_owned(url, headers, body, options, chunk, done)
		return owned(function(progress, terminal)
			return type(post) == "function" and post(url, headers, body, options, progress, terminal) == true
		end, options, chunk, done)
	end
	return port
end

return M
