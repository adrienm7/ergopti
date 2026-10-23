--- tests/unit/modules/llm/runtime/test_managed_ollama_proxy.lua

--- ==============================================================================
--- MODULE: Test Managed Ollama Proxy Selection
--- DESCRIPTION:
--- Drives the managed Ollama proxy port with the real shared proxy policy and a
--- controlled system lookup: the PAC-only network that refused every pull, the
--- user-exported proxy that must stay untouched, and each refusal.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")

local function it(name, body) helpers.it(name .. " (ollama-proxy)", body) end
local function eq(actual, expected)
	assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function policy()
	local file = assert(io.open(assert(Paths.shared("modules/network/proxy_policy.json")), "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return assert(require("network.proxy_policy").new(require("json").decode(bytes)))
end

--- One port over a scripted lookup; `world.receipt` is what the desktop answers.
local function world(options)
	local w = { rows = { "PATH=/usr/bin" }, authorized = true, remaining = 5000, lookups = 0, results = {} }
	for key, value in pairs(options or {}) do w[key] = value end
	local Proxy = helpers.load_module("modules.llm.managed_ollama_proxy")
	w.module = Proxy
	w.port = Proxy.new({
		policy = policy(), environment = function() return w.rows end, timeout_ms = 3000, owner = "test-owner",
		lookup = function(url, lookup_options, callback)
			w.lookups = w.lookups + 1
			w.url, w.lookup_options, w.callback = url, lookup_options, callback
			if w.dispatch_error then return nil, w.dispatch_error end
			w.child = { settled = false, cancelled = false }
			function w.child.is_settled() return w.child.settled end
			function w.child.on_settled(listener) w.child.listener = listener; return true end
			function w.child.cancel() w.child.cancelled = true; return true end
			if w.receipt then callback(w.receipt) end
			return w.child
		end,
	})
	function w:run()
		local budget = { remaining_ms = function() return w.remaining end }
		self.operation = self.port(budget, function() return w.authorized end, function(result) w.results[#w.results + 1] = result end)
		return self.results[1]
	end
	return w
end

it("a PAC-only network yields the PAC proxy as HTTPS_PROXY", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 1)
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	eq(w.url, w.module.REGISTRY_URL)
	eq(w.lookup_options.owner, "test-owner")
	eq(w.lookup_options.timeout_ms, 3000)
	assert(#w.lookup_options.environment_exclusions > 0, "the lookup must ignore the proxy variables")
end)

it("only the first selection is used and a socks proxy is kept as named", function()
	local w = world({ receipt = { ok = true, proxies = { "socks5://gate.corp.example:1080", "http://other:1" } } })
	eq(w:run().environment[1], "HTTPS_PROXY=socks5://gate.corp.example:1080")
end)

it("DIRECT adds nothing", function()
	local w = world({ receipt = { ok = true, proxies = { "direct://", "http://proxy.corp.example:3128" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 0)
end)

it("a machine without a desktop proxy source adds nothing and does not refuse", function()
	local w = world({ receipt = { ok = false, error = "proxy-backend-unavailable" } })
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 0)
end)

it("a proxy the user exported is left alone and no lookup runs", function()
	for _, row in ipairs({ "HTTPS_PROXY=http://mine:1", "https_proxy=http://mine:1", "ALL_PROXY=socks5://mine:1" }) do
		local w = world({ rows = { "PATH=/usr/bin", row } })
		local result = w:run()
		eq(result.ok, true)
		eq(#result.environment, 0)
		eq(w.lookups, 0)
	end
end)

it("an empty exported variable does not count as a proxy", function()
	local w = world({ rows = { "HTTPS_PROXY=" }, receipt = { ok = true, proxies = { "http://p:1" } } })
	eq(w:run().environment[1], "HTTPS_PROXY=http://p:1")
end)

it("a failed lookup refuses with a classified reason", function()
	for _, receipt in ipairs({
		{ ok = false, error = "proxy-lookup-timeout" },
		{ ok = true, proxies = { "gopher://x:1" } },
		{ ok = true, proxies = {} },
		{ ok = "yes" },
	}) do
		local w = world({ receipt = receipt })
		local result = w:run()
		eq(result.ok, false)
		eq(result.error, "proxy_lookup_failed")
	end
end)

it("a lookup that cannot be dispatched refuses", function()
	local w = world({ dispatch_error = "proxy-owner-busy" })
	eq(w:run().error, "proxy_lookup_unavailable")
end)

it("an exhausted budget refuses before any lookup", function()
	local w = world({ remaining = 0 })
	eq(w:run().error, "proxy_timeout")
	eq(w.lookups, 0)
end)

it("the lookup bound is the smaller of the configured timeout and the budget", function()
	local w = world({ remaining = 1200.4, receipt = { ok = true, proxies = { "direct://" } } })
	w:run()
	eq(w.lookup_options.timeout_ms, 1201)
end)

it("a start withdrawn during the lookup discards its answer", function()
	local w = world()
	w.authorized = true
	w:run()
	w.authorized = false
	w.callback({ ok = true, proxies = { "http://proxy.corp.example:3128" } })
	eq(w.results[1].ok, false)
	eq(w.results[1].error, "proxy_cancelled")
end)

it("the operation reports the lookup child's physical state", function()
	local w = world()
	w:run()
	eq(w.operation:is_settled(), false)
	w.child.settled = true
	eq(w.operation:is_settled(), true)
	eq(w.operation:on_settled(function() end), true)
	eq(w.child.listener ~= nil, true)
	eq(w.operation:cancel(), true)
	eq(w.child.cancelled, true)
end)

it("an operation that never ran a lookup is settled at once", function()
	local w = world({ rows = { "HTTPS_PROXY=http://mine:1" } })
	w:run()
	eq(w.operation:is_settled(), true)
	local fired = false
	eq(w.operation:on_settled(function() fired = true end), true)
	eq(fired, true)
end)

it("the registry URL and the proxy never reach the log", function()
	local seen = {}
	local Logger = require("logger.shim")
	local originals = { info = Logger.info, error = Logger.error }
	for _, level in ipairs({ "info", "error" }) do
		Logger[level] = function(_, message, ...) seen[#seen + 1] = string.format(message, ...) end
	end
	local ok, failure = pcall(function()
		world({ receipt = { ok = true, proxies = { "http://user:secret@proxy.corp.example:3128" } } }):run()
		world({ receipt = { ok = true, proxies = { "gopher://leak.example:1" } } }):run()
	end)
	Logger.info, Logger.error = originals.info, originals.error
	assert(ok, failure)
	assert(#seen >= 2, "the lifecycle must be logged")
	for _, line in ipairs(seen) do
		assert(not line:find("registry", 1, true) and not line:find("proxy.corp", 1, true)
			and not line:find("secret", 1, true) and not line:find("leak", 1, true), line)
	end
end)
