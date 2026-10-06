--- tests/unit/adapters/test_managed_owned_authorization.lua

--- ==============================================================================
--- MODULE: Owned HTTP Source Admission Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

--- tests/unit/adapters/test_managed_owned_authorization.lua
--- Independent actual public-wrapper/coordinator controls. Curl, GIO, clock and
--- timer retirement are explicit native ports; no native-wire proof is inferred.
local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Json = require("json")
local driver = helpers.driver_root()
local Policy = dofile(assert(Paths.shared("lua/network/proxy_policy.lua")))
local file = assert(io.open(assert(Paths.shared("modules/network/proxy_policy.json")), "rb"))
local policy = assert(Policy.new(Json.decode(assert(file:read("*a")))))
assert(file:close())

local function with_client(config, exercise)
	config = config or {}
	local state = { time = 0, metadata = 0, curls = {}, proxies = {}, timers = {}, reports = {}, chunks = {}, results = {} }
	local names = { "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local client
	local function timer(deadline, expired)
		local token = { started = true, closed = false, listeners = {}, deadline = deadline }
		function token:is_settled() return self.closed end
		function token:on_settled(listener)
			if self.closed then listener() else self.listeners[#self.listeners + 1] = listener end
			return true
		end
		function token:ack()
			if self.closed then return end
			self.closed = true
			for _, listener in ipairs(self.listeners) do listener() end
		end
		function token:cancel()
			self.cancelled = true
			if not config.hold_timer then self:ack() end
			return true
		end
		function token:fire() expired() end
		state.timers[#state.timers + 1] = token
		return token
	end
	local native = { HAS_ASYNC = true, default_timeout_ms = function() return 30000 end }
	function native.preflight(_, headers)
		state.metadata = state.metadata + 1
		-- Explicit caller metadata port, including LuaJIT where pairs itself does
		-- not dispatch __pairs. Core/metatable behavior has its original controls.
		local metadata = getmetatable(headers)
		if metadata and metadata.__pairs then
			local iterator, values, key = metadata.__pairs(headers)
			for _ in iterator, values, key do end
		else for _ in pairs(headers) do end end
		if config.metadata then config.metadata(client, state) end
		return true
	end
	function native.dispatch_owned(url, headers, body, options, chunk, complete)
		if options.authorized and options.authorized() ~= true then
			local rejected = { started = false }
			function rejected:is_settled() return true end
			function rejected:request_cancel() return true end
			function rejected:on_settled(listener) listener(); return true end
			return rejected
		end
		local item = { started = true, settled = false, listeners = {}, url = url, headers = headers, body = body, options = options, chunk = chunk }
		function item:is_settled() return self.settled end
		function item:on_settled(listener)
			if self.settled then listener() else self.listeners[#self.listeners + 1] = listener end
			return true
		end
		function item:request_cancel() self.cancelled = true; return true end
		function item:ack(result)
			assert(not self.settled, "independent native ACK is one-shot")
			self.settled = true
			if result then complete(result) end
			for _, listener in ipairs(self.listeners) do listener() end
		end
		state.curls[#state.curls + 1] = item
		return item
	end
	local proxy = {}
	function proxy.lookup_owned(url, options, complete)
		local item = { url = url, options = options, settled = false, listeners = {} }
		local operation = { started = true }
		function operation.is_settled() return item.settled end
		function operation.on_settled(listener)
			if item.settled then listener() else item.listeners[#item.listeners + 1] = listener end
			return true
		end
		function operation.cancel() item.cancelled = true; return true end
		function item:ack(result)
			assert(not self.settled, "independent proxy ACK is one-shot")
			self.settled = true
			if result then complete(result) end
			for _, listener in ipairs(self.listeners) do listener() end
		end
		state.proxies[#state.proxies + 1] = item
		return operation
	end
	local ok, primary = xpcall(function()
		for _, name in ipairs(names) do package.loaded[name] = nil end
		package.loaded["adapters.curl_http_client"] = native
		package.loaded["adapters.system_proxy"] = proxy
		package.loaded["infra.proxy_policy"] = { load = function()
			if config.initialization_refused then return nil, "proxy-policy-unavailable" end
			return policy
		end,
			environment = function() if config.environment then config.environment(client, state) end; return {} end }
		package.loaded["infra.monotonic"] = { now_ms = function()
			if config.initial_clock_failure then
				state.clock_calls = (state.clock_calls or 0) + 1
				if config.initial_clock_failure == "throw" then error("private native clock refusal") end
				return nil
			end
			if config.clock then config.clock(client, state) end
			return state.time
		end }
		package.loaded["infra.managed_http_deadline"] = { start = timer }
		client = dofile(driver .. "/adapters/http_client.lua")
		exercise(client, state)
	end, debug.traceback)
	-- Exact test-native ports are restored even when import/construction fails.
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(primary, 0) end
end

local function response() return { ok = true, status = 200, body = "independent body" } end
local function options(capability) return { owner = "captured", timeout_ms = 1000, authorized = capability } end
local local_url = "http://127.0.0.1:9000/models"
local system_url = "https://corporate.invalid/private"
local selected = { ok = true, proxies = { "direct://" }, backend = "GProxyResolverGnome", acknowledgement = "native-selection", failure_provenance = "unavailable" }

helpers.describe("managed public captured owned source", function()
	for _, answer in ipairs({ false, 1, "true", {} }) do
		local value = answer
		helpers.it("requires literal source true before metadata: " .. type(value), function()
			with_client(nil, function(client, state)
				local callbacks = 0
				local operation = client.get_owned(local_url, {}, options(function() return value end), function() callbacks = callbacks + 1 end)
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(operation.started, false)
				helpers.assert_eq(state.metadata, 0)
				helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
				helpers.assert_eq(callbacks, 0)
			end)
		end)
	end
	helpers.it("a throwing source cannot reach native preparation", function()
		with_client(nil, function(client, state)
			local operation = client.get_owned(local_url, {}, options(function() error("private source exception") end), function() error("retired source published") end)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(state.metadata, 0)
			helpers.assert_eq(#state.curls, 0)
		end)
	end)
	helpers.it("a refused predecessor successor never probes its source", function()
		with_client(nil, function(client, state)
			local first = client.get_owned(local_url, {}, options(function() return true end), function() end)
			local probes = 0
			local next_owner = client.get_owned(local_url, {}, options(function() probes = probes + 1; return true end), function() error("refused successor published") end)
			helpers.assert_true(first.started and not first:is_settled())
			helpers.assert_true(next_owner:is_settled() and not next_owner.started)
			helpers.assert_eq(probes, 0)
			helpers.assert_eq(#state.curls, 1)
			first:cancel(); state.curls[1]:ack()
			helpers.assert_true(first:is_settled())
		end)
	end)
	helpers.it("captures raw source and bypasses option iteration metamethods", function()
		with_client(nil, function(client, state)
			local probes = 0
			local source = options(function() probes = probes + 1; return true end)
			setmetatable(source, { __pairs = function() error("option iteration outran reservation") end })
			local headers = setmetatable({}, { __pairs = function()
				assert(probes > 0, "header metadata outran literal source admission")
				source.authorized = function() error("replacement source was freshly adopted") end
				return next, {}, nil
			end })
			local operation = client.get_owned(local_url, headers, source, function() end)
			helpers.assert_true(operation.started)
			helpers.assert_eq(#state.curls, 1)
			helpers.assert_true(state.curls[1].options.authorized())
			state.curls[1]:ack(response())
			helpers.assert_true(operation:is_settled())
		end)
	end)
	helpers.it("source withdrawal during metadata permits no new native owner", function()
		local current = true
		with_client({ metadata = function() current = false end }, function(client, state)
			local results = 0
			local operation = client.get_owned(local_url, {}, options(function() return current end), function() results = results + 1 end)
			helpers.assert_true(operation:is_settled() and not operation.started)
			helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
			helpers.assert_eq(results, 0)
		end)
	end)
	helpers.it("metadata reentrant cancellation retires the exact reserved owner", function()
		with_client({ metadata = function(client) helpers.assert_true(client.cancel("captured")) end }, function(client, state)
			local operation = client.get_owned(local_url, {}, options(function() return true end), function() error("cancelled admission published") end)
			helpers.assert_true(operation:is_settled() and not operation.started)
			helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
		end)
	end)
	helpers.it("owned GET without an optional source still fences metadata cancellation", function()
		with_client({ metadata = function(client) client.cancel("captured") end }, function(client, state)
			local operation = client.get_owned(local_url, {}, options(nil), function() error("cancelled implicit admission published") end)
			helpers.assert_true(operation:is_settled() and not operation.started)
			helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
		end)
	end)
	helpers.it("caller metadata spends the original public budget", function()
		with_client({ metadata = function(_, state) state.time = 1001 end }, function(client, state)
			local observed
			local operation = client.get_owned(local_url, {}, options(function() return true end), function(result) observed = result end)
			helpers.assert_true(operation:is_settled() and not operation.started)
			helpers.assert_eq(observed.error, "timeout")
			helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
		end)
	end)
	helpers.it("environment callback withdrawal prevents PAC acquisition", function()
		local current = true
		with_client({ environment = function() current = false end }, function(client, state)
			local operation = client.get_owned(system_url, {}, options(function() return current end), function() error("retired environment published") end)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
		end)
	end)
	helpers.it("PAC retirement rechecks captured authority before Curl admission", function()
		local current = true
		with_client(nil, function(client, state)
			local operation = client.get_owned(system_url, {}, options(function() return current end), function() error("retired PAC source published") end)
			helpers.assert_eq(#state.proxies, 1)
			current = false
			state.proxies[1]:ack(selected)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#state.curls, 0)
		end)
	end)
	helpers.it("owned POST streams through the managed route and retains body identity", function()
		with_client(nil, function(client, state)
			local chunks, results = {}, {}
			local body = "independent request body\nexact suffix"
			local operation = client.post_stream_owned(local_url, {}, body, options(function() return true end), function(bytes) chunks[#chunks + 1] = bytes end, function(result) results[#results + 1] = result end)
			helpers.assert_true(operation.started)
			helpers.assert_eq(state.curls[1].body, body)
			helpers.assert_eq(state.curls[1].options.method, "POST")
			helpers.assert_eq(state.curls[1].options.buffered, false)
			state.curls[1].chunk("independent chunk")
			helpers.assert_eq(chunks[1], "independent chunk")
			state.curls[1]:ack(response())
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#results, 1)
		end)
	end)
	helpers.it("withdrawn streaming source fences bytes but retains physical debt", function()
		local current = true
		with_client({ hold_timer = true }, function(client, state)
			local delivered = 0
			local operation = client.post_stream_owned(local_url, {}, "body", options(function() return current end), function() delivered = delivered + 1 end, function() delivered = delivered + 1 end)
			current = false
			state.curls[1].chunk("private retired bytes")
			helpers.assert_eq(delivered, 0)
			helpers.assert_true(state.curls[1].cancelled and not operation:is_settled())
			state.curls[1]:ack()
			helpers.assert_true(not operation:is_settled())
			state.timers[1]:ack()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(delivered, 0)
		end)
	end)
	helpers.it("final deadline ACK cannot publish after source retirement", function()
		local current = true
		with_client({ hold_timer = true }, function(client, state)
			local delivered = 0
			local operation = client.get_owned(local_url, {}, options(function() return current end), function() delivered = delivered + 1 end)
			state.curls[1]:ack(response())
			helpers.assert_true(not operation:is_settled())
			current = false
			state.timers[1]:ack()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(delivered, 0)
		end)
	end)
	helpers.it("final source probe still spends the original deadline", function()
		with_client({ hold_timer = true }, function(client, state)
			local advance, observed = false, nil
			local operation = client.get_owned(local_url, {}, options(function()
				if advance then state.time = 1001 end
				return true
			end), function(result) observed = result end)
			state.curls[1]:ack(response())
			advance = true
			state.timers[1]:ack()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(observed.error, "timeout")
		end)
	end)
	helpers.it("post-probe clock reentry cannot deliver a retired streamed byte", function()
		local retire = false
		with_client({ clock = function(client)
			if retire then retire = false; client.cancel("captured") end
		end }, function(client, state)
			local bytes = 0
			local operation = client.post_stream_owned(local_url, {}, "body", options(function() return true end), function() bytes = bytes + 1 end, function() error("retired clock source published") end)
			retire = true
			state.curls[1].chunk("retired bytes")
			helpers.assert_eq(bytes, 0)
			helpers.assert_true(not operation:is_settled())
			state.curls[1]:ack()
			helpers.assert_true(operation:is_settled())
		end)
	end)
	helpers.it("late retired chunk cannot target a successor with the same public owner", function()
		with_client(nil, function(client, state)
			local old_bytes, new_bytes = 0, 0
			local old = client.post_stream_owned(local_url, {}, "old body", options(function() return true end), function() old_bytes = old_bytes + 1 end, function() end)
			local retired = state.curls[1]
			retired:ack(response())
			helpers.assert_true(old:is_settled())
			local new = client.post_stream_owned(local_url, {}, "new body", options(function() return true end), function() new_bytes = new_bytes + 1 end, function() end)
			retired.chunk("old late bytes")
			helpers.assert_eq(old_bytes + new_bytes, 0)
			state.curls[2].chunk("new current bytes")
			helpers.assert_eq(new_bytes, 1)
			state.curls[2]:ack(response())
			helpers.assert_true(new:is_settled())
		end)
	end)
	for _, mode in ipairs({ "false", "throw", "reentrant" }) do
		local native_mode = mode
		helpers.it("invalid timeout cannot outrun captured " .. mode .. " source", function()
			with_client(nil, function(client, state)
				local callbacks, probes = 0, 0
				local captured = options(function()
					probes = probes + 1
					if native_mode == "throw" then error("private source failure") end
					if native_mode == "reentrant" then client.cancel("captured"); return true end
					return false
				end)
				captured.timeout_ms = 0
				local operation = client.get_owned(local_url, {}, captured, function() callbacks = callbacks + 1 end)
				helpers.assert_true(operation:is_settled() and not operation.started)
				helpers.assert_eq(probes, 1)
				helpers.assert_eq(callbacks, 0)
				helpers.assert_eq(state.metadata, 0)
				helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
			end)
		end)
	end
	for _, mode in ipairs({ "false", "throw", "reentrant" }) do
		local native_mode = mode
		helpers.it("failed initialization cannot publish before " .. mode .. " source admission", function()
			with_client({ initialization_refused = true }, function(client, state)
				local probes, callbacks = 0, 0
				local operation = client.post_stream_owned(local_url, {}, "body", options(function()
					probes = probes + 1
					if native_mode == "throw" then error("unreserved source was invoked") end
					if native_mode == "reentrant" then client.cancel("captured"); return true end
					return false
				end), function() callbacks = callbacks + 1 end, function() callbacks = callbacks + 1 end)
				helpers.assert_true(operation:is_settled() and not operation.started)
				helpers.assert_eq(probes + callbacks, 0)
				helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
			end)
		end)
	end
	for _, mode in ipairs({ "throw", "nil" }) do
		local native_mode = mode
		helpers.it("initial " .. mode .. " clock refusal does not reenter the failed clock", function()
			with_client({ initial_clock_failure = native_mode }, function(client, state)
				local observed
				local operation = client.get_owned(local_url, {}, options(function() return true end), function(result) observed = result end)
				helpers.assert_true(operation:is_settled() and not operation.started)
				helpers.assert_eq(observed.error, "managed-http-clock-unavailable")
				helpers.assert_eq(state.clock_calls, 1)
				helpers.assert_eq(state.metadata, 0)
				helpers.assert_eq(#state.curls + #state.proxies + #state.timers, 0)
			end)
		end)
	end
end)
return helpers
