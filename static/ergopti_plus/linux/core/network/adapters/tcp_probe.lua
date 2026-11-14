--- core/network/adapters/tcp_probe.lua

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
local Logger = require("core.logger.engine.shim")
local LOG = "core.network.adapters.tcp_probe"
local function diagnostic(message) pcall(Logger.error, LOG, message) end

--- Starts one probe.
--- @param host string Host name or address (brackets already removed).
--- @param port integer TCP port.
--- @param timeout_ms number Deadline of the whole probe.
--- @param callback function Called once as callback(reachable, reason).
--- @param luv table|nil Native backend (tests pass the real one explicitly).
--- @return table|nil child { cancel, is_settled, on_settled }, string|nil err
function M.probe(host, port, timeout_ms, callback, luv)
	if type(host) ~= "string" or host == "" or host:find("\0", 1, true) or type(port) ~= "number" or port < 1 or port > 65535
		or port % 1 ~= 0 or type(timeout_ms) ~= "number" or timeout_ms <= 0 or type(callback) ~= "function" then
		return nil, "tcp probe arguments are invalid"
	end
	luv = luv or require("luv")
	local answered, cancelled, settled, closing_batch = false, false, false, false
	local open_handles, resolving, listeners = 0, false, {}
	local retiring = {}
	local timer, tcp, request, result

	local function settle()
		if settled or not answered or resolving or closing_batch or open_handles > 0 then return end
		settled = true
		local pending = listeners
		listeners = {}
		-- A successor may replace this child as soon as it receives the answer.
		-- Publish only after the resolver and both exact handles have retired.
		if not cancelled then
			local ok = pcall(callback, result.reachable, result.reason)
			if not ok then diagnostic("TCP probe completion callback raised.") end
		end
		for _, listener in ipairs(pending) do
			local ok = pcall(listener)
			if not ok then diagnostic("TCP probe settlement callback raised.") end
		end
	end

	local function close(handle)
		if handle == nil then return end
		local entry = retiring[handle]
		if not entry then
			entry = { closing = false, closed = false }
			retiring[handle] = entry
			open_handles = open_handles + 1
		end
		if entry.closed or entry.closing then return end
		local inspected, closing = pcall(handle.is_closing, handle)
		if not inspected then
			diagnostic("TCP probe handle inspection failed; retirement remains pending.")
			return
		end
		if closing ~= false then
			if closing ~= true then diagnostic("TCP probe handle inspection was inconclusive.") end
			return
		end
		entry.closing = true
		local called, ack, detail = pcall(handle.close, handle, function()
			if entry.closed then return end
			entry.closed = true
			retiring[handle] = nil
			open_handles = open_handles - 1
			settle()
		end)
		if not entry.closed and (not called or ack == false or detail ~= nil) then
			diagnostic("TCP probe handle close was refused; retirement remains pending.")
			local observed, scheduled = pcall(handle.is_closing, handle)
			-- A close that may already be scheduled is never issued twice.
			if observed and scheduled == false then entry.closing = false end
		end
	end

	local function answer(reachable, reason)
		if answered then return end
		answered = true
		result = { reachable = reachable, reason = reason }
		if resolving and request then pcall(luv.cancel, request) end
		-- A callback may run synchronously in a native adapter: account for the
		-- entire batch before allowing either close to settle the operation.
		closing_batch = true
		close(timer)
		close(tcp)
		closing_batch = false
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
		if err or type(addresses) ~= "table" or not addresses[1] then answer(false, "resolve"); return end
		local index = 0
		local function try_next()
			if answered then return end
			index = index + 1
			local address = addresses[index]
			if not address then answer(false, "connect"); return end
			tcp = luv.new_tcp()
			if not tcp then answer(false, "connect"); return end
			local candidate = tcp
			-- luv's getaddrinfo result exposes the numeric address but omits
			-- sin6_scope_id. Retain the originating literal's interface zone.
			local zone = host:match("^[%x:%.]+(%%[%w_.%-]+)$")
			local destination = address.addr
			if zone and address.family == "inet6" and type(destination) == "string"
				and not destination:find("%", 1, true) then destination = destination .. zone end
			local function failed()
				close(candidate)
				if tcp == candidate then tcp = nil end
				try_next()
			end
			local started = candidate:connect(destination, address.port, function(connect_error)
				if answered then return end
				if connect_error then failed() else answer(true) end
			end)
			if not started then failed() end
		end
		try_next()
	end)
	if not request then
		resolving = false
		answer(false, "resolve")
	end

	local child = {}
	function child.cancel()
		cancelled = true
		if not answered then answer(false, "cancelled")
		else
			closing_batch = true
			for handle in pairs(retiring) do close(handle) end
			closing_batch = false
			settle()
		end
		return true
	end
	function child.is_settled() return settled end
	function child.on_settled(listener)
		if type(listener) ~= "function" then return false end
		if settled then
			local ok = pcall(listener)
			if not ok then diagnostic("TCP probe settlement callback raised.") end
		else listeners[#listeners + 1] = listener end
		return true
	end
	return child, nil
end

--- Splits a relay URL into the host and port a probe connects to.
--- @param relay string "scheme://[user@]host:port" as the proxy policy admits it.
--- @return string|nil host, integer|nil port
function M.relay_address(relay)
	if type(relay) ~= "string" then return nil, nil end
	-- Policy and curl both use the URL authority, independently of its suffix.
	local scheme, authority = relay:match("^(%a[%w+%.%-]*)://([^/?#]+)")
	if not authority then return nil, nil end
	scheme = scheme:lower()
	authority = authority:gsub("^.*@", "")
	-- IPv4-mapped IPv6 addresses may contain a dotted decimal suffix.
	local host, port = authority:match("^%[([^%]]+)%]:(%d+)$")
	if not host then host, port = authority:match("^([^:]+):(%d+)$") end
	if not host then
		host = authority:match("^%[([^%]]+)%]$") or authority:match("^([^:%[%]]+)$")
		if host then port = scheme == "https" and 443 or 1080 end -- libcurl proxy defaults.
	end
	port = tonumber(port)
	if not host or not port or port < 1 or port > 65535 then return nil, nil end
	-- Curl resolves percent-encoded hostname bytes before connecting; the
	-- reachability probe must contact that same host, including IPv6 zones.
	host = host:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
	if host:find("\0", 1, true) then return nil, nil end
	return host, port
end

return M
