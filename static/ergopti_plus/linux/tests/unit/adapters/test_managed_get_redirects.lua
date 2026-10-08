--- tests/unit/adapters/test_managed_get_redirects.lua

--- ==============================================================================
--- MODULE: Owned Buffered GET Redirect Controls
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

local function fixture(options, config)
	config = config or {}
	local state = { now = 0, proxies = {}, curls = {}, timers = {}, results = {}, reports = {}, loads = 0, environments = 0 }
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
		clock = function() return state.now end,
		environment = function()
			state.environments = state.environments + 1
			if config.environment_hook and state.environments == 2 then config.environment_hook(state) end
			return {}
		end,
		redirect = function() state.loads = state.loads + 1; return law end,
		report = function(message) state.reports[#state.reports + 1] = message end,
	}))
	state.coordinator = coordinator
	function state.ack_proxy(index, relay)
		local child = assert(state.proxies[index]); child.settled = true
		child.done({ ok = true, proxies = { relay or "http://proxy-a.invalid:81" }, backend = "GProxyResolverGnome",
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
	state.operation = coordinator.start(config.url or INITIAL, { ["X-Api-Key"] = "dummy-secret", Accept = "application/json" },
		config.body, request, nil, function(result) state.results[#state.results + 1] = result end)
	return state
end

helpers.describe("parent ownership across buffered GET redirects", function()
	helpers.it("waits for exact old child ACK then resolves the new complete path/query and proxy", function()
		local state = fixture(); state.ack_proxy(1)
		helpers.assert_true(state.curls[1].options.single_hop_redirect)
		helpers.assert_eq(state.curls[1].options.follow_redirects, false)
		state.terminal(1, redirect())
		helpers.assert_eq(#state.proxies, 1); helpers.assert_eq(#state.results, 0)
		helpers.assert_true(not state.operation:is_settled())
		state.ack_curl(1)
		helpers.assert_eq(#state.proxies, 2); helpers.assert_eq(state.proxies[2].url, TARGET)
		helpers.assert_eq(#state.curls, 1)
		state.ack_proxy(2, "http://proxy-b.invalid:82")
		helpers.assert_eq(state.curls[2].options.proxy_selection.proxy, "http://proxy-b.invalid:82")
		helpers.assert_nil(state.curls[2].headers["X-Api-Key"])
		helpers.assert_eq(state.curls[2].headers.Accept, "application/json")
		state.terminal(2, terminal("final bytes", TARGET))
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].body, "final bytes")
		helpers.assert_nil(state.results[1].redirect_receipt)
		helpers.assert_true(not state.operation:is_settled())
		state.ack_curl(2); helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
	helpers.it("uses one original deadline with shrinking lookup/curl budgets", function()
		local state = fixture(); state.ack_proxy(1); state.now = 300; state.terminal(1, redirect()); state.ack_curl(1)
		helpers.assert_eq(state.proxies[2].options.timeout_ms, 700)
		state.now = 500; state.ack_proxy(2)
		helpers.assert_eq(state.curls[2].options.timeout_ms, 500)
		helpers.assert_eq(#state.timers, 1); helpers.assert_eq(state.timers[1].at, 1000)
		state.terminal(2, terminal("within original budget", TARGET)); state.ack_curl(2); state.drain()
	end)
	helpers.it("cancel during old close debt never starts the redirected child", function()
		local state = fixture(); state.ack_proxy(1); state.terminal(1, redirect())
		helpers.assert_eq(state.operation:cancel(), false); helpers.assert_true(not state.operation:is_settled())
		state.ack_curl(1); helpers.assert_eq(#state.proxies, 1); helpers.assert_eq(#state.results, 0); state.drain()
	end)
	helpers.it("timeout while close ACK is withheld publishes once and retains debt", function()
		local state = fixture(); state.ack_proxy(1); state.terminal(1, redirect()); state.now = 1001; state.timers[1].expired()
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].error, "timeout")
		helpers.assert_true(not state.operation:is_settled()); helpers.assert_eq(#state.proxies, 1)
		state.ack_curl(1); helpers.assert_eq(#state.results, 1); state.drain()
	end)
	helpers.it("late native success cannot beat an unprocessed absolute deadline", function()
		local state = fixture(); state.ack_proxy(1); state.now = 1001
		state.terminal(1, terminal("late success"))
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].error, "timeout")
		helpers.assert_true(not state.operation:is_settled()); state.ack_curl(1); state.drain()
	end)
	helpers.it("reentrant cancellation during next environment admission fences lookup", function()
		local state = fixture(nil, { environment_hook = function(current) current.operation:cancel() end })
		state.ack_proxy(1); state.terminal(1, redirect()); state.ack_curl(1)
		helpers.assert_eq(#state.proxies, 1); helpers.assert_eq(#state.results, 0); state.drain()
	end)
	helpers.it("stale predecessor terminals cannot publish or advance a successor hop", function()
		local state = fixture(); state.ack_proxy(1); state.terminal(1, redirect()); state.ack_curl(1); state.ack_proxy(2)
		state.terminal(1, terminal("stale")); state.ack_curl(1)
		helpers.assert_eq(#state.results, 0); helpers.assert_eq(#state.proxies, 2)
		state.terminal(2, terminal("current", TARGET)); state.ack_curl(2)
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].body, "current"); state.drain()
	end)
	helpers.it("missing private receipt refuses with empty body and no footer exposure", function()
		local state = fixture(); state.ack_proxy(1)
		state.terminal(1, { ok = false, status = 302, body = "", error_body = "dummy-private-footer", error = "raw dummy-private-footer" })
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].error, "HTTP redirect receipt refused")
		helpers.assert_eq(state.results[1].body, ""); helpers.assert_nil(state.results[1].error_body)
		helpers.assert_eq(#state.proxies, 1); state.ack_curl(1); state.drain()
	end)
	helpers.it("successful terminal without native footer refuses before publishing payload", function()
		local state = fixture(); state.ack_proxy(1)
		state.terminal(1, { ok = true, status = 200, body = "dummy-private-footer", error_body = "dummy-private-footer" })
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].ok, false)
		helpers.assert_eq(state.results[1].error, "HTTP redirect receipt refused")
		helpers.assert_eq(state.results[1].body, ""); helpers.assert_nil(state.results[1].error_body)
		helpers.assert_eq(#state.proxies, 1); helpers.assert_true(not state.operation:is_settled())
		state.ack_curl(1); helpers.assert_true(state.operation:is_settled()); state.drain()
	end)
	helpers.it("successful terminal with malformed native footer refuses without metadata exposure", function()
		local state = fixture(); state.ack_proxy(1)
		state.terminal(1, { ok = true, status = 200, body = "unadmitted bytes",
			redirect_receipt = { private = "dummy-private-footer" } })
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].ok, false)
		helpers.assert_eq(state.results[1].error, "HTTP redirect receipt refused")
		helpers.assert_eq(state.results[1].body, ""); helpers.assert_nil(state.results[1].redirect_receipt)
		helpers.assert_true(not state.operation:is_settled()); state.ack_curl(1); state.drain()
	end)
	helpers.it("killed code-zero native child cannot publish successful terminal bytes", function()
		local Receipt = require("infra.http_redirect_receipt")
		local state = fixture(); state.ack_proxy(1)
		local tail = '\nERGOPTI_GET_REDIRECT_JSON:\nhttps://updates.example/start?part=one\n\n'
			.. '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start?part=one","redirect_url":""}\n'
		local value = Receipt.attach({ single_hop_redirect = true, single_hop_receipt_bytes = 32768, single_hop_url_bytes = 8192,
			exited = true, stdout_eof = true, stderr_eof = true, exit_code = 0, exit_signal = 15, stderr_tail = tail },
			{ ok = true, status = 200, body = "killed payload" })
		helpers.assert_nil(value.redirect_receipt)
		state.terminal(1, value)
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].ok, false)
		helpers.assert_eq(state.results[1].error, "HTTP redirect receipt refused"); helpers.assert_eq(state.results[1].body, "")
		helpers.assert_true(not state.operation:is_settled()); state.ack_curl(1); state.drain()
	end)
	helpers.it("primary native transport failure keeps its receipt when no single-hop footer exists", function()
		local state = fixture(); state.ack_proxy(1)
		local receipt = { curl_exit = 7, stage = "transport", failure_provenance = "unavailable" }
		state.terminal(1, { ok = false, status = 302, body = "", error = "native transport failed", failure_receipt = receipt })
		helpers.assert_eq(#state.results, 1); helpers.assert_eq(state.results[1].error, "native transport failed")
		helpers.assert_eq(state.results[1].failure_receipt, receipt); helpers.assert_eq(#state.proxies, 1)
		state.ack_curl(1); state.drain()
	end)
	helpers.it("owned cancellation signal refusal retains original live-owner ABI", function()
		local state = fixture({ owned_api = true }, { signal_refusal = true }); state.ack_proxy(1)
		helpers.assert_eq(state.operation:cancel(), false); helpers.assert_true(not state.operation:is_settled())
		helpers.assert_true(state.coordinator.is_active("per-hop"))
		state.curls[1].result = terminal("suppressed"); state.ack_curl(1)
		helpers.assert_eq(#state.results, 0); state.drain()
	end)
	for _, option in ipairs({ { follow_redirects = false }, { etag_compare = "/independent/cache/etag" },
		{ etag_save = "/independent/cache/etag" }, { output_path = "/independent/output" }, { method = "POST" }, { buffered = false } }) do
		local fixed = option
		helpers.it("excluded scope preserves its existing native option path", function()
			local state = fixture(fixed); state.ack_proxy(1)
			helpers.assert_eq(state.loads, 0); helpers.assert_nil(state.curls[1].options.single_hop_redirect)
			for key, value in pairs(fixed) do helpers.assert_eq(state.curls[1].options[key], value) end
			state.terminal(1, { ok = false, status = 302, body = "", error = "HTTP 302" }); state.ack_curl(1); state.drain()
		end)
	end
	helpers.it("origin URL credentials remain outside manual following", function()
		local state = fixture(nil, { url = "https://dummy:dummy@updates.example/start" }); state.ack_proxy(1)
		helpers.assert_eq(state.loads, 0); helpers.assert_nil(state.curls[1].options.single_hop_redirect)
		state.terminal(1, { ok = true, status = 200, body = "ordinary" }); state.ack_curl(1); state.drain()
	end)
end)
