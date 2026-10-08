--- tests/unit/adapters/test_managed_get_redirect_boundaries.lua

--- ==============================================================================
--- MODULE: Redirect Clock and Output Boundary Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

--- Actual shared/coordinator sources, independent owned-child ports.
--- These are causal ownership models, not native GIO/curl acceptance.
local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Json = require("json")
local Managed = require("infra.managed_http")
local Shared = require("network.http_redirect")
local Routing = require("network.proxy_policy")

local function data(relative)
	local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close()); return Json.decode(bytes)
end
local law = assert(Shared.new(data("data/http/redirect_policy.json"), data("data/http/transport_policy.json")))
local routing = assert(Routing.new(data("modules/network/proxy_policy.json")))
local INITIAL, TARGET = "https://updates.example/start?part=one", "https://cdn.example/file?part=two"

local function redirect(target)
	return { ok = false, status = 302, body = "", error = "HTTP 302",
		failure_receipt = { curl_exit = 0, stage = "http", failure_provenance = "verified" },
		redirect_receipt = { format = "curl-single-hop-v1", http_status = 302, curl_exit = 0, num_redirects = 0,
			effective_url = INITIAL, redirect_url = target or TARGET } }
end

-- Independent literal terminal receipt: actual native zero exit/no-follow is
-- required even when the last HTTP response is successful.
local function terminal(body, effective)
	return { ok = true, status = 200, body = body,
		redirect_receipt = { format = "curl-single-hop-v1", http_status = 200, curl_exit = 0, num_redirects = 0,
			effective_url = effective or INITIAL, redirect_url = "" } }
end

local function boundary_fixture(options, config)
	config = config or {}
	local state = { now = 0, proxies = {}, curls = {}, timers = {}, results = {}, reports = {}, loads = 0, environments = 0, addresses = 0, transitions = 0, clocks = 0 }
	local proxy = {}
	function proxy.lookup_owned(url, admitted, done)
		local child = { started = true, url = url, options = admitted, done = done, listeners = {} }
		function child.is_settled() return child.settled == true end
		function child.on_settled(listener) child.listeners[#child.listeners + 1] = listener; return true end
		function child.cancel() child.cancelled = true; return true end
		state.proxies[#state.proxies + 1] = child
		return child
	end
	local function curl(url, headers, body, admitted, _, done)
		local child = { started = true, url = url, headers = headers, body = body, options = admitted, done = done, listeners = {} }
		function child:is_settled() return self.settled == true end
		function child:on_settled(listener) self.listeners[#self.listeners + 1] = listener; return true end
		function child:request_cancel() self.cancelled = true; return not config.signal_refusal end
		state.curls[#state.curls + 1] = child
		return child
	end
	local function deadline(at, expired)
		local token = { started = true, at = at, expired = expired, listeners = {} }
		function token:is_settled() return self.settled == true end
		function token:on_settled(listener) self.listeners[#self.listeners + 1] = listener; return true end
		function token:cancel()
			if self.settled then return true end
			self.settled = true; for _, listener in ipairs(self.listeners) do listener() end; return true
		end
		state.timers[#state.timers + 1] = token
		return token
	end
	local coordinator = assert(Managed.new({ policy = routing, proxy = proxy, curl = curl, deadline = deadline,
		clock = function()
			state.clocks = state.clocks + 1
			if config.clock_hook then config.clock_hook(state) end
			return state.now
		end,
		environment = function()
			state.environments = state.environments + 1
			if config.environment_hook and state.environments == 2 then config.environment_hook(state) end
			return {}
		end,
		redirect = function()
			state.loads = state.loads + 1
			if config.loader_hook then config.loader_hook(state) end
			return {
				address = function(url)
					state.addresses = state.addresses + 1
					return law.address(url)
				end,
				transition = function(input)
					state.transitions = state.transitions + 1
					local result = law.transition(input)
					if config.transition_hook then config.transition_hook(state) end
					return result
				end,
			}
		end,
		report = function(message) state.reports[#state.reports + 1] = message end,
	}))
	state.coordinator = coordinator
	function state.ack_proxy(index, relay)
		local child = assert(state.proxies[index]); child.settled = true
		child.done({ ok = true, proxies = config.relays or { relay or "http://proxy-a.invalid:81" }, backend = "GProxyResolverGnome",
			acknowledgement = "native-selection", failure_provenance = "unavailable" })
		for _, listener in ipairs(child.listeners) do listener() end
	end
	function state.terminal(index, result)
		local child = assert(state.curls[index]); child.result = result
		child.options.on_native_terminal(result)
	end
	function state.ack_curl(index)
		local child = assert(state.curls[index]); child.settled = true; child.done(assert(child.result))
		for _, listener in ipairs(child.listeners) do listener() end
	end
	function state.drain()
		for index, child in ipairs(state.curls) do
			if not child.settled then child.result = child.result or { ok = false, status = 0, body = "", error = "cancelled" }; state.ack_curl(index) end
		end
		for _, timer in ipairs(state.timers) do helpers.assert_true(timer:is_settled()) end
	end
	local request = { owner = "per-hop", method = "GET", buffered = true, follow_redirects = true, timeout_ms = 1000, owned_api = false }
	for name, value in pairs(options or {}) do request[name] = value end
	local admission
	if config.owned_admission then
		admission = { prepare = function() return request end }
	end
	state.operation = coordinator.start(config.url or INITIAL, { ["X-Api-Key"] = "dummy-secret", Accept = "application/json" },
		config.body, request, nil, function(result) state.results[#state.results + 1] = result end, admission)
	return state
end

helpers.describe("redirect clock reentry and retained-output exclusions", function()
	helpers.it("owned policy-loader clock cancellation refuses address and preparation continuation", function()
		local state = boundary_fixture({ owned_api = true }, {
			owned_admission = true,
			loader_hook = function(current) current.arm_clock = true end,
			clock_hook = function(current)
				if current.arm_clock then
					current.arm_clock = false
					current.clock_cancellations = (current.clock_cancellations or 0) + 1
					current.coordinator.cancel("per-hop")
				end
			end,
		})
		helpers.assert_eq(state.clock_cancellations, 1)
		helpers.assert_eq(state.loads, 1); helpers.assert_eq(state.addresses, 0)
		helpers.assert_eq(state.environments, 0); helpers.assert_eq(#state.proxies, 0); helpers.assert_eq(#state.curls, 0)
		helpers.assert_eq(#state.results, 0); helpers.assert_eq(state.operation.started, false)
		helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
	helpers.it("transition clock cancellation cannot mutate a retired hop or invoke the new environment", function()
		local state = boundary_fixture({ owned_api = true }, {
			transition_hook = function(current) current.arm_clock = true end,
			clock_hook = function(current)
				if current.arm_clock then
					current.arm_clock = false
					current.clock_cancellations = (current.clock_cancellations or 0) + 1
					current.coordinator.cancel("per-hop")
				end
			end,
		})
		state.ack_proxy(1); state.terminal(1, redirect()); state.ack_curl(1)
		helpers.assert_eq(state.clock_cancellations, 1); helpers.assert_eq(state.transitions, 1)
		helpers.assert_eq(state.environments, 1); helpers.assert_eq(#state.proxies, 1); helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(#state.results, 0); helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
	helpers.it("new route clock cancellation cannot acquire a successor lookup", function()
		local state = boundary_fixture({ owned_api = true }, {
			environment_hook = function(current) current.arm_clock = true end,
			clock_hook = function(current)
				if current.arm_clock then
					current.arm_clock = false
					current.clock_cancellations = (current.clock_cancellations or 0) + 1
					current.coordinator.cancel("per-hop")
				end
			end,
		})
		state.ack_proxy(1); state.terminal(1, redirect()); state.ack_curl(1)
		helpers.assert_eq(state.clock_cancellations, 1); helpers.assert_eq(state.environments, 2)
		helpers.assert_eq(#state.proxies, 1); helpers.assert_eq(#state.curls, 1); helpers.assert_eq(#state.results, 0)
		helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
	helpers.it("ordinary boolean admission still prepares before reserving its owner", function()
		local state = boundary_fixture()
		helpers.assert_true(state.operation.started); helpers.assert_eq(state.loads, 1); helpers.assert_eq(state.addresses, 1)
		helpers.assert_eq(#state.proxies, 1); state.ack_proxy(1)
		state.terminal(1, terminal("literal buffered GET")); state.ack_curl(1)
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].body, "literal buffered GET")
		helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
	helpers.it("retained output target never enters buffered manual hop admission", function()
		local target = { independent_target = true }
		local state = boundary_fixture({ output_target = target }); state.ack_proxy(1)
		helpers.assert_eq(state.loads, 0); helpers.assert_eq(state.addresses, 0)
		helpers.assert_nil(state.curls[1].options.single_hop_redirect)
		helpers.assert_eq(state.curls[1].options.output_target, target)
		state.terminal(1, { ok = false, status = 302, body = "", error = "HTTP 302" }); state.ack_curl(1); state.drain()
	end)
	helpers.it("retained output target cannot use the old zero-argument path retry authority", function()
		local retry_calls = 0
		local state = boundary_fixture({ output_target = { independent_target = true }, buffered = false,
			proxy_retry_admit = function() retry_calls = retry_calls + 1; return true end },
			{ relays = { "http://proxy-a.invalid:81", "http://proxy-b.invalid:82" } })
		state.ack_proxy(1)
		state.terminal(1, { ok = false, status = 0, body = "", error = "proxy connect failed", proxy_used = true,
			failure_receipt = { backend = "curl", curl_exit = 7, http_status = 0, proxy_connect_status = 0,
				stage = "proxy_connect", failure_provenance = "verified" } })
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].error, "proxy connect failed")
		helpers.assert_true(not state.operation:is_settled()); helpers.assert_eq(#state.curls, 1)
		state.ack_curl(1)
		helpers.assert_eq(retry_calls, 0); helpers.assert_eq(#state.curls, 1); helpers.assert_eq(#state.proxies, 1)
		helpers.assert_eq(#state.results, 1); helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
end)
