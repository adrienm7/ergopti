--- tests/unit/modules/llm/runtime/test_managed_ollama_proxy.lua

--- ==============================================================================
--- MODULE: Test Managed Ollama Proxy Selection
--- DESCRIPTION:
--- Drives the managed Ollama proxy port with the real shared proxy policy, the
--- real shared route plan and origin inventory, and a controlled system lookup:
--- the PAC-only network that refused every pull, the blob host a PAC sends
--- direct, two relays the daemon cannot hold, the user-exported proxy that must
--- stay untouched, the user's proxy override (through the real policy binding)
--- and each refusal.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")

local function it(name, body) helpers.it(name .. " (ollama-proxy)", body) end
local function eq(actual, expected)
	assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function policy()
	local file = assert(io.open(assert(Paths.shared("core/network/data/proxy_policy.json")), "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return assert(require("core.network.engine.proxy_policy_core").new(require("core.text.engine.json").decode(bytes)))
end

local function relay_policy()
	local file = assert(io.open(assert(Paths.shared("core/network/data/proxy_auth_relay.json")), "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return assert(require("core.network.engine.proxy_auth_relay_core").new(require("core.text.engine.json").decode(bytes)))
end

local ORIGINS = assert(require("infra.route_origins").client("ollama"))
local BLOB = ORIGINS[2]

--- One port over a scripted lookup. `world.receipt` is what the desktop answers
--- for every origin; `world.receipts[url]` overrides it for one origin.
local function world(options)
	-- `probe_answer` is what the relay probe answers ({ answer, reason });
	-- by default the proxy demands no sign-in.
	local w = { rows = { "PATH=/usr/bin" }, authorized = true, remaining = 5000, lookups = 0, results = {},
		urls = {}, receipts = {}, probes = {}, probe_answer = { { status = "not_needed" } } }
	for key, value in pairs(options or {}) do w[key] = value end
	local Proxy = helpers.load_module("modules.llm.managed_ollama_proxy")
	w.module = Proxy
	w.port = Proxy.new({
		policy = w.policy or policy(), environment = function() return w.rows end, timeout_ms = 3000, owner = "test-owner",
		origins = w.origins or ORIGINS,
		probe_timeout_ms = 1000, relay_address = require("adapters.tcp_probe").relay_address,
		probe = function(host, port, timeout_ms, callback)
			w.tcp_probes = w.tcp_probes or {}
			w.tcp_probes[#w.tcp_probes + 1] = { host = host, port = port, timeout_ms = timeout_ms }
			if w.on_tcp_probe then w.on_tcp_probe(w, host, port) end
			local probe_child = { settled = false }
			function probe_child.is_settled() return probe_child.settled end
			function probe_child.on_settled(listener) probe_child.listener = listener; return true end
			function probe_child.cancel() return true end
			local answer = w.reachable and w.reachable[host .. ":" .. port]
			probe_child.settled = true
			callback(answer == true, answer == true and nil or "timeout")
			return probe_child
		end,
		lookup = function(url, lookup_options, callback)
			w.lookups = w.lookups + 1
			w.urls[#w.urls + 1] = url
			w.url, w.lookup_options, w.callback = url, lookup_options, callback
			if w.dispatch_error then return nil, w.dispatch_error end
			w.child = { settled = false, cancelled = false }
			function w.child.is_settled() return w.child.settled end
			function w.child.on_settled(listener) w.child.listener = listener; return true end
			function w.child.cancel() w.child.cancelled = true; return true end
			local receipt = w.receipts[url] or w.receipt
			if receipt then callback(receipt) end
			return w.child
		end,
		relay = { policy = relay_policy(), timeout_ms = 4000,
			probe = function(upstream, authority, probe_options, callback)
				w.probes[#w.probes + 1] = { upstream = upstream, authority = authority, options = probe_options }
				w.probe_callback = callback
				if w.probe_error then return nil, w.probe_error end
				local child = { settled = true }
				function child.is_settled() return child.settled end
				function child.on_settled(listener) listener(); return true end
				function child.cancel() return true end
				if w.probe_answer then callback(w.probe_answer[1], w.probe_answer[2]) end
				return child
			end },
	})
	function w:run()
		local budget = { remaining_ms = function() return w.remaining end }
		self.operation = self.port(budget, function() return w.authorized end, function(result) w.results[#w.results + 1] = result end)
		return self.results[1]
	end
	return w
end

it("the shipped inventory starts with the registry and names its blob host", function()
	eq(ORIGINS[1], require("ai.engine.ollama.registry").URL)
	assert(#ORIGINS >= 2, "the blob redirect host must be looked up too")
end)

it("a PAC-only network yields the PAC proxy as HTTPS_PROXY", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 1)
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	eq(w.lookups, #ORIGINS)
	for index, origin in ipairs(ORIGINS) do eq(w.urls[index], origin) end
	eq(w.lookup_options.owner, "test-owner")
	eq(w.lookup_options.timeout_ms, 3000)
	assert(#w.lookup_options.environment_exclusions > 0, "the lookup must ignore the proxy variables")
end)

it("a reachable first selection wins over the later ones and a socks proxy is kept as named", function()
	local w = world({ receipt = { ok = true, proxies = { "socks5://gate.corp.example:1080", "http://other:1" } },
		reachable = { ["gate.corp.example:1080"] = true } })
	eq(w:run().environment[1], "HTTPS_PROXY=socks5://gate.corp.example:1080")
end)

it("a blob host the PAC sends direct joins NO_PROXY after the user's own entries", function()
	local w = world({ rows = { "PATH=/usr/bin", "no_proxy=intranet.example" },
		receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	w.receipts[BLOB] = { ok = true, proxies = { "direct://" } }
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 3)
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	local host = BLOB:gsub("^https://", "")
	eq(result.environment[2], "NO_PROXY=intranet.example," .. host)
	eq(result.environment[3], "no_proxy=intranet.example," .. host)
end)

it("a registry the PAC sends direct is bypassed while the blob host keeps the relay", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	w.receipts[ORIGINS[1]] = { ok = true, proxies = { "direct://" } }
	local result = w:run()
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	eq(result.environment[2], "NO_PROXY=" .. ORIGINS[1]:gsub("^https://", ""))
end)

it("two different relays for the registry and the blob host refuse the start", function()
	local w = world({ receipt = { ok = true, proxies = { "http://relay-a.corp.example:3128" } } })
	w.receipts[BLOB] = { ok = true, proxies = { "http://relay-b.corp.example:3128" } }
	local result = w:run()
	eq(result.ok, false)
	eq(result.error, "proxy_route_plan_refused")
end)

it("a relay the daemon cannot export refuses the start instead of being passed on", function()
	for _, proxy in ipairs({ "socks4://gate.corp.example:1080", "http://proxy.corp.example" }) do
		local w = world({ receipt = { ok = true, proxies = { proxy } } })
		local result = w:run()
		eq(result.ok, false)
		eq(result.error, "proxy_route_plan_refused")
	end
end)

it("an authenticated desktop relay keeps its credentials", function()
	local w = world({ receipt = { ok = true, proxies = { "http://user:pw@proxy.corp.example:3128" } } })
	eq(w:run().environment[1], "HTTPS_PROXY=http://user:pw@proxy.corp.example:3128")
end)

-- (pac-unavailable-fallback) A lookup GIO could not answer is an unusable PAC:
-- that origin goes direct, the other keeps the relay its PAC named.
it("(pac-unavailable-fallback) an unusable lookup of the blob host sends only that host direct", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	w.receipts[BLOB] = { ok = false, error = "proxy-lookup-timeout" }
	local result = w:run()
	eq(result.ok, true)
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	eq(result.environment[2], "NO_PROXY=" .. BLOB:gsub("^https://", ""))
	eq(result.direct_fallback, "native_proxy_budget")
end)

it("an inventory that does not start with the registry is refused at construction", function()
	local ok = pcall(world, { origins = { BLOB, ORIGINS[1] } })
	eq(ok, false)
	eq(pcall(world, { origins = {} }), false)
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

it("(linux-pac-evaluation) a missing PAC engine refuses the start instead of guessing a route", function()
	local result = world({ receipt = { ok = false, error = "proxy-pac-engine-unavailable" } }):run()
	eq(result.ok, false)
	eq(result.error, "proxy_lookup_failed")
end)

it("(linux-pac-evaluation) a dead first relay of the evaluated PAC list falls to DIRECT", function()
	local w = world({ receipt = { ok = true, proxies = { "http://127.0.0.1:9", "direct://" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 0)
	eq(w.tcp_probes[1].host, "127.0.0.1")
	eq(w.tcp_probes[1].port, 9)
end)

it("(pac-unavailable-fallback) an unusable desktop configuration sends the daemon direct", function()
	for receipt_error, stage in pairs({ ["proxy-lookup-failed"] = "native_proxy_lookup",
		["proxy-lookup-timeout"] = "native_proxy_budget",
		-- (linux-pac-evaluation) a PAC the lookup child ran and that raised.
		["proxy-pac-evaluation-failed"] = "native_pac_evaluation" }) do
		local warnings = {}
		local Logger = require("core.logger.engine.shim")
		local original = Logger.warn
		Logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
		local ok, result = pcall(function()
			return world({ receipt = { ok = false, error = receipt_error } }):run()
		end)
		Logger.warn = original
		assert(ok, result)
		eq(result.ok, true)
		eq(#result.environment, 0)
		eq(result.direct_fallback, stage)
		eq(#warnings, #ORIGINS)
		assert(warnings[1]:find(stage, 1, true), warnings[1])
	end
end)

-- (pac-download-direct) GIO answers DIRECT, with no error, for a PAC it could
-- not download; the lookup child names that stage beside the DIRECT answer.
-- The WARNING was never logged on Linux before (container proof 2026-11-10).
it("(pac-download-direct) a DIRECT answer for an undownloadable PAC warns and records the stage", function()
	local warnings = {}
	local Logger = require("core.logger.engine.shim")
	local original = Logger.warn
	Logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
	local ok, result = pcall(function()
		local w = world({ receipt = { ok = true, proxies = { "direct://" }, pac_unavailable = "native_pac_download" } })
		local answer = w:run()
		-- The child downloads the PAC under the whole lookup's bound.
		eq(w.lookup_options.pac_check_timeout_ms, w.lookup_options.timeout_ms)
		eq(w.lookup_options.timeout_ms, 3000)
		return answer
	end)
	Logger.warn = original
	assert(ok, result)
	eq(result.ok, true)
	eq(#result.environment, 0)
	eq(result.direct_fallback, "native_pac_download")
	eq(#warnings, #ORIGINS)
	assert(warnings[1]:find("unusable at native_pac_download", 1, true), warnings[1])
end)

it("(pac-download-direct) a PAC that answered DIRECT itself warns nothing", function()
	local warnings = {}
	local Logger = require("core.logger.engine.shim")
	local original = Logger.warn
	Logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
	local ok, result = pcall(function() return world({ receipt = { ok = true, proxies = { "direct://" } } }):run() end)
	Logger.warn = original
	assert(ok, result)
	eq(result.direct_fallback, nil)
	eq(#warnings, 0)
end)

it("(pac-unavailable-fallback) each fallback stage is one the shared policy lists", function()
	local active = policy()
	local Proxy = helpers.load_module("modules.llm.managed_ollama_proxy")
	for _, stage in pairs(Proxy.LOOKUP_STAGES) do assert(active.falls_back_direct(stage), stage) end
end)

it("(pac-unavailable-fallback) an exported relay never reaches the lookup, so never falls back", function()
	local w = world({ rows = { "PATH=/usr/bin", "HTTPS_PROXY=http://mine:1" },
		receipt = { ok = false, error = "proxy-lookup-failed" } })
	local result = w:run()
	eq(w.lookups, 0)
	eq(result.ok, true)
	eq(#result.environment, 0)
	eq(result.direct_fallback, nil)
end)

it("a failed lookup refuses with a classified reason", function()
	for _, receipt in ipairs({
		{ ok = false, error = "proxy-child-failed" },
		{ ok = false, error = "proxy-receipt-invalid" },
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

it("a budget spent by the registry lookup refuses before the blob lookup", function()
	local w = world()
	w:run()
	eq(w.lookups, 1)
	w.remaining = 0
	w.callback({ ok = true, proxies = { "direct://" } })
	eq(w.lookups, 1)
	eq(w.results[1].error, "proxy_timeout")
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
	local fired = false
	eq(w.operation:on_settled(function() fired = true end), true)
	w.child.settled = false
	eq(w.operation:cancel(), true)
	eq(w.child.cancelled, true)
	eq(fired, false)
	w.child.settled = true
	w.child.listener()
	eq(fired, true)
end)

it("the operation settles with the last lookup child, not the first", function()
	local w = world()
	w:run()
	local first = w.child
	w.callback({ ok = true, proxies = { "direct://" } })
	local last = w.child
	assert(first ~= last, "the blob host must be looked up by a second child")
	first.settled = true
	local fired = false
	eq(w.operation:on_settled(function() fired = true end), true)
	eq(fired, false)
	w.callback({ ok = true, proxies = { "direct://" } })
	eq(w.results[1].ok, true)
	eq(w.operation:is_settled(), false)
	last.settled = true
	last.listener()
	eq(fired, true)
	eq(w.operation:is_settled(), true)
end)

it("an operation that never ran a lookup is settled at once", function()
	local w = world({ rows = { "HTTPS_PROXY=http://mine:1" } })
	w:run()
	eq(w.operation:is_settled(), true)
	local fired = false
	eq(w.operation:on_settled(function() fired = true end), true)
	eq(fired, true)
end)

it("no origin URL and no proxy ever reach the log", function()
	local seen = {}
	local Logger = require("core.logger.engine.shim")
	local originals = { info = Logger.info, error = Logger.error, warn = Logger.warn }
	for _, level in ipairs({ "info", "error", "warn" }) do
		Logger[level] = function(_, message, ...) seen[#seen + 1] = string.format(message, ...) end
	end
	local ok, failure = pcall(function()
		world({ receipt = { ok = true, proxies = { "http://user:secret@proxy.corp.example:3128" } } }):run()
		world({ receipt = { ok = true, proxies = { "gopher://leak.example:1" } } }):run()
		local fallback = world({ receipt = { ok = true, proxies = { "http://user:secret@proxy.corp.example:3128" } } })
		fallback.receipts[BLOB] = { ok = false, error = "proxy-lookup-failed" }
		fallback:run()
	end)
	Logger.info, Logger.error, Logger.warn = originals.info, originals.error, originals.warn
	assert(ok, failure)
	assert(#seen >= 2, "the lifecycle must be logged")
	for _, line in ipairs(seen) do
		assert(not line:find("registry", 1, true) and not line:find("proxy.corp", 1, true)
			and not line:find("secret", 1, true) and not line:find("leak", 1, true)
			and not line:find(BLOB:gsub("^https://", ""), 1, true), line)
	end
end)

-- ========== Sign-in relay (docs/design/proxy-auth-relay.md) ==========

local REGISTRY_AUTHORITY = ORIGINS[1]:gsub("^https://", "") .. ":443"

it("(proxy-auth-relay) a plain http relay is probed once for the registry and needs no relay", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(result.relay, nil)
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	eq(#w.probes, 1)
	eq(w.probes[1].upstream, "http://proxy.corp.example:3128")
	eq(w.probes[1].authority, REGISTRY_AUTHORITY)
	eq(w.probes[1].options.owner, "test-owner-relay")
	eq(w.probes[1].options.timeout_ms, 4000)
end)

it("(proxy-auth-relay) a proxy that demands Negotiate starts the daemon under the relay", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } },
		probe_answer = { { status = "required", scheme = "negotiate" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(result.relay.upstream, "http://proxy.corp.example:3128")
	eq(result.relay.scheme, "negotiate")
	-- The plan's own rows stay: the relay replaces HTTPS_PROXY in the child only.
	eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
end)

it("(proxy-auth-relay) a refused sign-in starts without the proxy and carries the relay's reason", function()
	for _, reason in ipairs({ "sign_in_unavailable", "ntlm_requires_windows", "sign_in_rejected", "relay_unavailable" }) do
		local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } },
			probe_answer = { nil, reason } })
		local result = w:run()
		eq(result.ok, true)
		eq(result.relay, nil)
		eq(result.relay_refusal, reason)
		-- No relay row, and a bypass of any relay the daemon would inherit.
		eq(#result.environment, 2)
		eq(result.environment[1], "NO_PROXY=*")
		eq(result.environment[2], "no_proxy=*")
	end
end)

it("(proxy-auth-relay) a relay that is not installed keeps the proxy as named, with a warning", function()
	local Logger = require("core.logger.engine.shim")
	local warned = {}
	local original = Logger.warn
	Logger.warn = function(_, message) warned[#warned + 1] = message end
	local ok, failure = pcall(function()
		local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } },
			probe_answer = { { status = "not_installed" } } })
		local result = w:run()
		eq(result.ok, true)
		eq(result.relay, nil)
		eq(result.environment[1], "HTTPS_PROXY=http://proxy.corp.example:3128")
	end)
	Logger.warn = original
	assert(ok, failure)
	eq(#warned, 1)
	assert(warned[1]:find("not installed", 1, true), warned[1])
end)

it("(proxy-auth-relay) a probe that cannot start is the named relay_unavailable", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } },
		probe_error = "proxy-auth-relay-probe-unavailable" })
	local result = w:run()
	eq(result.ok, true)
	eq(result.environment[1], "NO_PROXY=*")
	eq(result.relay_refusal, "relay_unavailable")
end)

it("(proxy-auth-relay) Basic credentials, socks and direct routes are never probed", function()
	for _, proxy in ipairs({ "http://user:pw@proxy.corp.example:3128", "socks5://gate.corp.example:1080", "direct://" }) do
		local w = world({ receipt = { ok = true, proxies = { proxy } } })
		eq(w:run().ok, true)
		eq(#w.probes, 0)
	end
end)

it("(proxy-auth-relay) the probe bound is the smaller of its timeout and the budget left", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } }, remaining = 1500 })
	w:run()
	eq(w.probes[1].options.timeout_ms, 1500)
	local spent = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } } })
	local lookups = 0
	spent.remaining = 5000
	local original = spent.port
	spent.receipts[BLOB] = { ok = true, proxies = { "http://proxy.corp.example:3128" } }
	-- The budget runs out between the last lookup and the probe.
	local budget = { remaining_ms = function() lookups = lookups + 1; return lookups > #ORIGINS and 0 or 5000 end }
	original(budget, function() return true end, function(result) spent.results[#spent.results + 1] = result end)
	eq(spent.results[1].error, "proxy_timeout")
	eq(#spent.probes, 0)
end)

it("(proxy-auth-relay) a start withdrawn during the probe discards its answer", function()
	local w = world({ receipt = { ok = true, proxies = { "http://proxy.corp.example:3128" } },
		probe_answer = false })
	w:run()
	eq(#w.results, 0)
	eq(#w.probes, 1)
	w.authorized = false
	w.probe_callback({ status = "required", scheme = "ntlm" })
	eq(#w.results, 1)
	eq(w.results[1].ok, false)
	eq(w.results[1].error, "proxy_cancelled")
end)

--- The real Linux policy binding over a stubbed storage holding `stored`.
local function bound_policy(stored)
	local saved = { storage = package.loaded["adapters.storage"], binding = package.loaded["infra.proxy_policy"] }
	package.loaded["adapters.storage"] = { get = function(key, default)
		if key == "network.proxy_override" then return stored end
		return default
	end }
	package.loaded["infra.proxy_policy"] = nil
	local active = assert(require("infra.proxy_policy").load())
	return active, function()
		package.loaded["adapters.storage"], package.loaded["infra.proxy_policy"] = saved.storage, saved.binding
	end
end

it("a relay override becomes the daemon relay, over an exported one, with no lookup", function()
	local active, restore = bound_policy("http://override.corp.example:8080")
	local ok, failure = pcall(function()
		local w = world({ policy = active, rows = { "PATH=/usr/bin", "HTTPS_PROXY=http://exported.example:3128" },
			receipt = { ok = true, proxies = { "http://pac.corp.example:3128" } } })
		local result = w:run()
		eq(result.ok, true)
		eq(#result.environment, 1)
		eq(result.environment[1], "HTTPS_PROXY=http://override.corp.example:8080")
		eq(w.lookups, 0)
	end)
	restore()
	assert(ok, failure)
end)

it("a direct override bypasses every inherited relay, with no lookup", function()
	local active, restore = bound_policy("direct")
	local ok, failure = pcall(function()
		local w = world({ policy = active, rows = { "PATH=/usr/bin", "HTTPS_PROXY=http://exported.example:3128" } })
		local result = w:run()
		eq(result.ok, true)
		eq(table.concat(result.environment, " "), "NO_PROXY=* no_proxy=*")
		eq(w.lookups, 0)
	end)
	restore()
	assert(ok, failure)
end)

it("an automatic override keeps the PAC lookup, and an invalid one refuses the start", function()
	local active, restore = bound_policy("")
	local ok, failure = pcall(function()
		local w = world({ policy = active, receipt = { ok = true, proxies = { "http://pac.corp.example:3128" } } })
		eq(w:run().environment[1], "HTTPS_PROXY=http://pac.corp.example:3128")
		eq(w.lookups, #ORIGINS)
	end)
	restore()
	assert(ok, failure)
	active, restore = bound_policy("proxy.corp.example:3128")
	ok, failure = pcall(function()
		local w = world({ policy = active })
		local result = w:run()
		eq(result.ok, false)
		eq(result.error, "proxy_route_invalid")
		eq(w.lookups, 0)
	end)
	restore()
	assert(ok, failure)
end)

it("a relay override that demands Negotiate still gets the sign-in relay, probed once", function()
	local active, restore = bound_policy("http://override.corp.example:8080")
	local ok, failure = pcall(function()
		local w = world({ policy = active, probe_answer = { { status = "required", scheme = "negotiate" } } })
		local result = w:run()
		eq(result.ok, true)
		eq(result.relay.upstream, "http://override.corp.example:8080")
		eq(result.environment[1], "HTTPS_PROXY=http://override.corp.example:8080")
		eq(w.lookups, 0)
		eq(#w.probes, 1)
	end)
	restore()
	assert(ok, failure)
end)

it("a direct override bypasses the sign-in relay: no probe, no relay", function()
	local active, restore = bound_policy("direct")
	local ok, failure = pcall(function()
		local w = world({ policy = active, rows = { "PATH=/usr/bin", "HTTPS_PROXY=http://ntlm.corp.example:3128" } })
		local result = w:run()
		eq(result.ok, true)
		eq(result.relay, nil)
		eq(w.probes == nil or #w.probes == 0, true)
	end)
	restore()
	assert(ok, failure)
end)

it("a PAC list whose first relay is unreachable falls through to DIRECT, probed once with the shared deadline", function()
	local w = world({ receipt = { ok = true, proxies = { "http://down.corp.example:3128", "direct://" } } })
	local result = w:run()
	eq(result.ok, true)
	eq(#result.environment, 0)
	eq(#w.tcp_probes, #ORIGINS)
	eq(w.tcp_probes[1].host, "down.corp.example")
	eq(w.tcp_probes[1].port, 3128)
	eq(w.tcp_probes[1].timeout_ms, 1000)
end)

it("a reachable first relay is kept, and a relay with nothing after it is never probed", function()
	local w = world({ receipt = { ok = true, proxies = { "http://up.corp.example:3128", "direct://" } },
		reachable = { ["up.corp.example:3128"] = true } })
	eq(w:run().environment[1], "HTTPS_PROXY=http://up.corp.example:3128")
	local single = world({ receipt = { ok = true, proxies = { "http://only.corp.example:3128" } } })
	eq(single:run().environment[1], "HTTPS_PROXY=http://only.corp.example:3128")
	eq(single.tcp_probes, nil)
end)

it("an unreachable relay moves to the next relay, not straight to DIRECT", function()
	local w = world({ receipt = { ok = true, proxies = { "http://down.corp.example:3128",
		"http://up.corp.example:8080", "direct://" } }, reachable = { ["up.corp.example:8080"] = true } })
	eq(w:run().environment[1], "HTTPS_PROXY=http://up.corp.example:8080")
end)

it("the shared probe deadline is the timings registry's one second", function()
	local Timings = require("infra.timings")
	eq(Timings.ms("llm", "managed_proxy_probe_timeout_ms"), 1000)
end)

it("bounds PAC probes by the remaining startup budget (pac-probe-budget)", function()
	local w = world({ remaining = 75, receipt = { ok = true,
		proxies = { "http://down.corp.example:3128", "direct://" } } })
	assert(w:run().ok)
	eq(w.tcp_probes[1].timeout_ms, 75)
end)

it("does not try another PAC relay once startup expires (pac-probe-budget)", function()
	local w = world({ receipt = { ok = true, proxies = {
		"http://down.corp.example:3128", "http://other.corp.example:3128", "direct://" } },
		on_tcp_probe = function(state) state.remaining = 0; state.authorized = false end })
	local result = w:run()
	eq(#w.tcp_probes, 1)
	eq(result.ok, false)
end)

it("does not launch a PAC probe when reading the budget revokes its owner (pac-probe-budget)", function()
	local w = world()
	local revoke, operation, results = false, nil, {}
	local budget = { remaining_ms = function()
		if revoke then operation:cancel(); return 0 end
		return 1000
	end }
	operation = w.port(budget, function() return true end, function(result) results[#results + 1] = result end)
	revoke = true
	w.callback({ ok = true, proxies = { "http://down.corp.example:3128", "direct://" } })
	eq(w.tcp_probes, nil)
	eq(#results, 0, "the revoked owner must not publish")
	eq(w.child.cancelled, true)
	eq(operation:is_settled(), false, "the original lookup still owns its retirement")
end)

it("retains one settlement observer while a cancelled lookup is still owned (pac-observer-bound)", function()
	local w = world()
	w:run()
	local observers, delivered = {}, 0
	w.child.on_settled = function(listener) observers[#observers + 1] = listener; return true end
	w.operation:on_settled(function() error("controlled listener failure") end)
	w.operation:on_settled(function() delivered = delivered + 1 end)
	for _ = 1, 1000 do w.operation:cancel() end
	eq(#observers, 1)
	eq(delivered, 0)
	eq(w.operation:is_settled(), false)
	w.child.settled = true
	assert(pcall(observers[1]), "one failing listener cannot abort native settlement")
	helpers.assert_eq(delivered, 1)
	eq(w.operation:is_settled(), true)
end)

it("retries an explicitly refused settlement subscription without duplicating an admitted one (pac-observer-bound)", function()
	local w = world()
	w:run()
	local calls, observer, delivered = 0, nil, 0
	w.child.on_settled = function(listener)
		calls = calls + 1
		if calls == 1 then return false end
		observer = listener
		return true
	end
	w.operation:on_settled(function() delivered = delivered + 1 end)
	w.operation:cancel()
	w.operation:cancel()
	w.operation:cancel()
	eq(calls, 2)
	eq(delivered, 0)
	w.child.settled = true
	observer()
	eq(delivered, 1)
end)

it("retires a PAC result even when its result observer throws (pac-observer-bound)", function()
	local w = world({ origins = { ORIGINS[1] } })
	local op = w.port({ remaining_ms = function() return 1000 end }, function() return true end,
		function() error("controlled result observer failure") end)
	local settled = 0
	op:on_settled(function() settled = settled + 1 end)
	w.child.settled = true
	assert(pcall(w.callback, { ok = true, proxies = { "direct://" } }), "result observer cannot escape")
	helpers.assert_eq(op:is_settled(), true)
	eq(settled, 1)
end)

it("handles inline settlement and an uncertain observer registration without duplicates (pac-observer-bound)", function()
	local inline = world()
	inline:run()
	local delivered = 0
	inline.operation:on_settled(function() delivered = delivered + 1 end)
	inline.child.on_settled = function(listener) inline.child.settled = true; listener(); return true end
	inline.operation:cancel()
	eq(delivered, 1)
	eq(inline.operation:is_settled(), true)

	local uncertain = world()
	uncertain:run()
	local calls, retained = 0, nil
	uncertain.child.on_settled = function(listener)
		calls = calls + 1; retained = listener; error("registration outcome unknown")
	end
	uncertain.operation:cancel()
	uncertain.operation:cancel()
	eq(calls, 1, "an unknown registration cannot safely be duplicated")
	eq(uncertain.operation:is_settled(), false)
	uncertain.child.settled = true
	retained()
	eq(uncertain.operation:is_settled(), true)
end)

it("retires real native handles when both observers and diagnostics throw (pac-observer-logger)", function()
	local logger, uv = require("core.logger.engine.shim"), require("luv")
	local old_error = logger.error
	logger.error = function() error("controlled logger failure") end
	local tested, reason = pcall(function()
		local function native_child(w)
			local handle, listener = assert(uv.new_timer()), nil
			w.child.on_settled = function(fn) listener = fn; return true end
			local function close()
				uv.close(handle, function()
					w.child.settled = true
					if listener then listener() end
				end)
				return true
			end
			w.child.cancel = close
			return close
		end
		local function pump(done)
			local until_ns = uv.hrtime() + 2000000000
			while not done() and uv.hrtime() < until_ns do uv.run("once") end
			assert(done(), "native close did not retire")
		end
		local cancelled = world(); cancelled:run(); native_child(cancelled)
		local notified = 0
		cancelled.operation:on_settled(function() error("controlled observer failure") end)
		cancelled.operation:on_settled(function() notified = notified + 1 end)
		cancelled.operation:cancel()
		pump(function() return cancelled.operation:is_settled() end)
		eq(notified, 1, "one failed observer cannot suppress the next")
		local finished = world({ origins = { ORIGINS[1] } })
		local op = finished.port({ remaining_ms = function() return 1000 end }, function() return true end,
			function() error("controlled result failure") end)
		local close = native_child(finished)
		local retired = 0; op:on_settled(function() retired = retired + 1 end)
		assert(pcall(finished.callback, { ok = true, proxies = { "direct://" } }))
		close()
		pump(function() return op:is_settled() end)
		helpers.assert_eq(retired, 1, "failed result diagnostics must not skip physical retirement")
	end)
	logger.error = old_error
	assert(tested, reason)
end)
