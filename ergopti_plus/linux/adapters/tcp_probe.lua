--- adapters/tcp_probe.lua

--- ==============================================================================
--- MODULE: TCP Reachability Probe (Linux)
--- DESCRIPTION:
--- Answers one question with no byte sent: does a TCP connect to host:port
--- complete within a deadline. The managed Ollama proxy selection asks it of a
--- relay a PAC names before a later entry ("PROXY a; DIRECT"), the way a browser
--- tries the next entry when a relay does not answer.
---
--- FEATURES & RATIONALE:
--- 1. One answer, exactly once: the deadline, a resolver failure, a refused or
---    completed connect, or a cancel; later native callbacks are ignored.
--- 2. Owned like every native child: is_settled() turns true only once the
---    timer and socket are closed and the resolver request has returned, so the
---    caller's operation never outlives a handle it started.
--- 3. The answer names a closed reason ("timeout", "resolve", "connect",
---    "cancelled"), never the host.
--- ==============================================================================

local M = {}

local NativeTimer = require("infra.native_timer")

--- Starts one probe.
--- @param host string Host name or address (brackets already removed).
--- @param port integer TCP port.
--- @param timeout_ms number Deadline of the whole probe.
--- @param callback function Called once as callback(reachable, reason).
--- @param luv table|nil Native backend (tests pass the real one explicitly).
--- @return table|nil child { cancel, is_settled, on_settled }, string|nil err
function M.probe(host, port, timeout_ms, callback, luv)
	if type(host) ~= "string" or host == "" or type(port) ~= "number" or port < 1 or port > 65535
		or port % 1 ~= 0 or type(timeout_ms) ~= "number" or timeout_ms <= 0 or type(callback) ~= "function" then
		return nil, "tcp probe arguments are invalid"
	end
	luv = luv or require("luv")
	local answered, cancelled, settled = false, false, false
	local open_handles, resolving, listeners = 0, false, {}
	local timer, tcp, request

	local function settle()
		if settled or not answered or resolving or open_handles > 0 then return end
		settled = true
		local pending = listeners
		listeners = {}
		for _, listener in ipairs(pending) do listener() end
	end

	local function close(handle)
		if handle == nil or handle:is_closing() then return end
		open_handles = open_handles + 1
		handle:close(function()
			open_handles = open_handles - 1
			settle()
		end)
	end

	local function answer(reachable, reason)
		if answered then return end
		answered = true
		if resolving and request then pcall(luv.cancel, request) end
		close(timer)
		close(tcp)
		if not cancelled then callback(reachable, reason) end
		settle()
	end

	timer = luv.new_timer()
	if not timer then return nil, "tcp probe timer unavailable" end
	local armed, arm_error = NativeTimer.start(luv, timer, timeout_ms, 0, function() answer(false, "timeout") end)
	if not armed then
		timer:close()
		return nil, "tcp probe timer refused: " .. tostring(arm_error)
	end
	resolving = true
	request = luv.getaddrinfo(host, tostring(port), { socktype = "stream" }, function(err, addresses)
		resolving = false
		if answered then settle(); return end
		local first = type(addresses) == "table" and addresses[1] or nil
		if err or not first then answer(false, "resolve"); return end
		tcp = luv.new_tcp()
		if not tcp then answer(false, "connect"); return end
		local started = tcp:connect(first.addr, first.port, function(connect_error)
			answer(connect_error == nil, connect_error and "connect" or nil)
		end)
		if not started then answer(false, "connect") end
	end)
	if not request then
		resolving = false
		answer(false, "resolve")
	end

	local child = {}
	function child.cancel()
		cancelled = true
		answer(false, "cancelled")
		return true
	end
	function child.is_settled() return settled end
	function child.on_settled(listener)
		if type(listener) ~= "function" then return false end
		if settled then listener() else listeners[#listeners + 1] = listener end
		return true
	end
	return child, nil
end

--- Splits a relay URL into the host and port a probe connects to.
--- @param relay string "scheme://[user@]host:port" as the proxy policy admits it.
--- @return string|nil host, integer|nil port
function M.relay_address(relay)
	if type(relay) ~= "string" then return nil, nil end
	local authority = relay:match("^%l[%l%d]*://([^/]+)$")
	if not authority then return nil, nil end
	authority = authority:gsub("^.*@", "")
	local host, port = authority:match("^%[([%x:]+)%]:(%d+)$")
	if not host then host, port = authority:match("^([^:]+):(%d+)$") end
	port = tonumber(port)
	if not host or not port or port < 1 or port > 65535 then return nil, nil end
	return host, port
end

return M
