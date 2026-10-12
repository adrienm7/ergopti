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

--- Controls only default local discovery in a daemon fixture that removes luv
--- for its virtual clock. Other HTTP owners keep their actual adapter. A scripted
--- absent listener is ordinary connection refusal, not unavailable dispatch.
--- @param port table Actual HTTP adapter whose unrelated owners remain intact.
--- @return table port
--- @return table probes Captured software observations, never native receipts.
function M.local_discovery(port)
	local order, servers, published = require("modules.llm.local_server_catalogue").load({})
	assert(published and #order > 0, "fixture local discovery catalogue is unavailable")
	local probes = {}
	local controlled = M.attach({ get = function(url, headers, options, done)
		local id = options.owner:match("^llm_local_server:(.+)$")
		local server = id and servers[id]
		assert(server and url == server.base_url .. "/models", "fixture probe must retain its declared default URL")
		assert(headers.Authorization == nil and options.follow_redirects == false,
			"fixture default probe must preserve keyless no-redirect admission")
		probes[#probes + 1] = { id = id, url = url, owner = options.owner }
		done({ ok = false, status = 0, body = "", error = "scripted loopback listener is absent" })
		return true
	end })
	local actual = assert(port.get_owned, "actual owned HTTP capability is required")
	port.get_owned = function(url, headers, options, done)
		local owner = type(options) == "table" and options.owner or nil
		if type(owner) == "string" and owner:match("^llm_local_server:") then
			return controlled.get_owned(url, headers, options, done)
		end
		return actual(url, headers, options, done)
	end
	return port, probes
end

return M
