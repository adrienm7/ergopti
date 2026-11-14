--- tests/unit/infra/network/test_proxy_auth_relay.lua

--- ==============================================================================
--- MODULE: Test Proxy Sign-In Relay Policy
--- DESCRIPTION:
--- Drives the shared relay policy (core/network/engine/proxy_auth_relay_core.lua) with the
--- shipped contract and the probe-line vectors the Go relay is pinned to, and
--- the Linux binding's refusal when the relay is not installed.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("core.fs.engine.paths")
local Json = require("core.text.engine.json")

local function it(name, body) helpers.it(name .. " (proxy-auth-relay)", body) end
local function eq(actual, expected, label)
	assert(actual == expected, (label or "") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function read_json(relative)
	local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return Json.decode(bytes)
end

local CONTRACT = read_json("core/network/data/proxy_auth_relay.json")
local Relay = require("core.network.engine.proxy_auth_relay_core")
local policy = assert(Relay.new(CONTRACT))
local TIMINGS = { dial_ms = 10, handshake_ms = 20, idle_ms = 30 }

it("the probe line is read as the Go relay emits it, and anything else is relay_unavailable", function()
	local vectors = read_json("tests/corpus/network/proxy_auth_relay_probe_vectors.json").vectors
	assert(#vectors >= 10, "the shared probe vectors are missing")
	for _, vector in ipairs(vectors) do
		local answer, reason = policy.read_probe(vector.exit_code, vector.stdout)
		if vector.result then
			assert(answer, vector.id .. " refused: " .. tostring(reason))
			eq(answer.status, vector.result.status, vector.id)
			eq(answer.scheme, vector.result.scheme, vector.id)
		else
			eq(answer, nil, vector.id)
			eq(reason, vector.reason, vector.id)
		end
	end
	eq(select(2, policy.read_probe(nil, "")), "relay_unavailable", "no exit code")
	eq(select(2, policy.read_probe(0, nil)), "relay_unavailable", "no output")
end)

it("only a plain http relay without credentials can need the relay", function()
	eq(policy.upstream("http://proxy.corp.example:3128"), "http://proxy.corp.example:3128")
	eq(policy.upstream("http://Proxy.Corp.Example:3128/"), "http://proxy.corp.example:3128")
	eq(policy.upstream("http://10.0.0.1:8080"), "http://10.0.0.1:8080")
	for _, proxy in ipairs({ "http://user:pw@proxy:3128", "https://proxy:3128", "socks5://proxy:1080",
		"http://proxy", "http://proxy:0", "http://proxy:70000", "direct", "http://[::1]:3128", false }) do
		eq(policy.upstream(proxy), nil, tostring(proxy))
	end
	eq(policy.authority("https://registry.ollama.ai"), "registry.ollama.ai:443")
	eq(policy.authority("http://registry.ollama.ai"), nil)
	eq(policy.authority("https://user@registry.ollama.ai"), nil)
end)

it("the probe and run vectors carry every deadline and the child after --", function()
	eq(table.concat(policy.probe_args("http://proxy:3128", "registry.ollama.ai:443", TIMINGS), " "),
		"probe --upstream http://proxy:3128 --authority registry.ollama.ai:443 --dial-timeout-ms 10 --handshake-timeout-ms 20")
	eq(table.concat(policy.run_args("http://proxy:3128", { "HTTPS_PROXY" }, TIMINGS, "/opt/ollama", { "serve" }), " "),
		"run --upstream http://proxy:3128 --variable HTTPS_PROXY --dial-timeout-ms 10 --handshake-timeout-ms 20"
		.. " --idle-timeout-ms 30 -- /opt/ollama serve")
	eq(policy.probe_args("http://user:pw@proxy:3128", "a:443", TIMINGS), nil, "credentials")
	eq(policy.probe_args("http://proxy:3128", "a:443", { dial_ms = 10 }), nil, "missing deadline")
	eq(policy.probe_args("http://proxy:3128", "a:443", { dial_ms = 0, handshake_ms = 1 }), nil, "zero deadline")
	eq(policy.run_args("http://proxy:3128", { "HTTPS_PROXY" }, { dial_ms = 1, handshake_ms = 1 }, "/x", {}), nil, "idle")
	eq(policy.run_args("http://proxy:3128", {}, TIMINGS, "/x", {}), nil, "no variable")
	eq(policy.run_args("http://proxy:3128", { "BAD=NAME" }, TIMINGS, "/x", {}), nil, "bad variable")
end)

it("every refusal names a localized message, and an unknown one the generic failure", function()
	local en = read_json("core/i18n/data/locales/en.json")
	for reason, key in pairs(CONTRACT.refusals) do
		eq(policy.message_key(reason), key, reason)
		assert(type(en[key]) == "string" and en[key] ~= "", key .. " is not in en.json")
		eq(policy.is_refusal(reason), true, reason)
	end
	eq(policy.message_key("proxy.corp.example"), CONTRACT.refusals.relay_unavailable)
	eq(policy.is_refusal("proxy.corp.example"), false)
end)

it("an invalid contract is refused", function()
	for _, contract in ipairs({ {}, { schema_version = 2 }, false }) do
		eq(Relay.new(contract), nil)
	end
	local broken = read_json("core/network/data/proxy_auth_relay.json")
	broken.refusals.relay_unavailable = nil
	eq(Relay.new(broken), nil, "the caller-side refusal is required")
end)

it("a relay that is not installed answers not_installed without a child", function()
	local Binding = helpers.load_module("infra.proxy_auth_relay")
	assert(Binding.load(), "the shipped contract must load")
	local timings = Binding.timings()
	for _, name in ipairs({ "dial_ms", "handshake_ms", "idle_ms", "probe_ms" }) do
		assert(type(timings[name]) == "number" and timings[name] > 0, name .. " comes from the timings registry")
	end
	local original = Binding.executable
	Binding.executable = function() return nil end
	local answers = {}
	local ok, operation = pcall(Binding.probe, "http://proxy:3128", "registry.ollama.ai:443",
		{ owner = "test", timeout_ms = 100, authorized = function() return true end },
		function(answer, reason) answers[#answers + 1] = { answer = answer, reason = reason } end)
	Binding.executable = original
	assert(ok, operation)
	eq(#answers, 1)
	eq(answers[1].answer.status, Relay.NOT_INSTALLED)
	eq(answers[1].reason, nil)
	-- The Go relay never prints it: a probe line claiming it is off contract.
	eq(select(2, policy.read_probe(0, '{"schema":1,"status":"not_installed"}\n')), "relay_unavailable")
	eq(operation.is_settled(), true)
end)

it("a synchronous native dispatch refusal cannot deliver a callback and a refusal", function()
	local Binding = helpers.load_module("infra.proxy_auth_relay")
	local original = Binding.executable
	Binding.executable = function() return "/bin/true" end
	local answers = 0
	local ok, operation, reason = pcall(Binding.probe, "http://proxy:3128", "registry.ollama.ai:443",
		{ owner = "", timeout_ms = 100, authorized = function() return true end },
		function() answers = answers + 1 end)
	Binding.executable = original
	assert(ok, operation)
	eq(operation, nil)
	eq(reason, "proxy-auth-relay-probe-unavailable")
	eq(answers, 0, "a dispatch refusal must not also deliver completion")
end)

it("a refused start retains pending native cleanup until its completion", function()
	local Binding = helpers.load_module("infra.proxy_auth_relay")
	local original_executable, original_process = Binding.executable, package.loaded["adapters.owned_process"]
	local complete, settled = nil, false
	Binding.executable = function() return "/bin/true" end
	package.loaded["adapters.owned_process"] = { start = function(_, _, _, callback)
		complete = callback
		return { started = false, is_settled = function() return settled end,
			on_settled = function() return true end, cancel = function() return false end }
	end }
	local answers = 0
	local ok, err = pcall(function()
		local operation, reason = Binding.probe("http://proxy:3128", "registry.ollama.ai:443",
			{ owner = "relay-cleanup-test", timeout_ms = 100 }, function() answers = answers + 1 end)
		assert(operation and not reason, "pending native cleanup must retain its operation")
		eq(operation.is_settled(), false)
		eq(answers, 0)
		settled = true
		complete({ exit_code = -1, stdout = "" })
		eq(answers, 1)
		eq(operation.is_settled(), true)
	end)
	Binding.executable, package.loaded["adapters.owned_process"] = original_executable, original_process
	assert(ok, err)
end)
