--- tests/unit/modules/llm/test_api_remote_callback_siblings.lua

--- ==============================================================================
--- MODULE: Remote Models And Probe Callback Diagnostic Regression Tests
--- DESCRIPTION:
--- Public models and connectivity callbacks inherit the shared terminal owner.
--- Scripted adapters isolate diagnostics, callback tuples and successor ownership;
--- real transport coverage belongs to the companion native verified TLS fixture.
--- ==============================================================================

local helpers = require("tests.helpers")

local observed_requests = setmetatable({}, { __mode = "k" })

--- Records actual callback arguments before any protected caller assertion.
--- @param remote table Production owner whose active state is captured.
--- @param bucket table Per-request callback observations.
--- @param callback function|nil Original caller callback, forwarded unchanged.
--- @return function|nil observed Callback wrapper, or nil when no caller exists.
local function observe_callback(remote, bucket, callback)
	if callback == nil then return nil end
	return function(...)
		local args = { n = select("#", ...), ... }
		if type(args[1]) == "table" then
			local copy = {}
			for key, value in pairs(args[1]) do copy[key] = value end
			args[1] = copy
		end
		bucket[#bucket + 1] = { args = args, active = remote.is_active() }
		return callback(...)
	end
end

--- Isolates only the scripted HTTP and logging seams, restoring them on failure.
--- @param test function Receives the remote module, requests and diagnostics.
local function isolated(test)
	local names = { "adapters.http_client", "modules.llm.api_remote", "logger.shim" }
	local saved, calls, logs = {}, {}, {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local function queue(method, url, headers, body, callback, options)
		calls[#calls + 1] = { method = method, url = url, headers = headers,
			body = body, callback = callback, options = options }
		return true
	end
	package.loaded["adapters.http_client"] = {
		get = function(url, headers, options, callback)
			return queue("GET", url, headers, nil, callback, options)
		end,
		post = function(url, headers, body, callback, options)
			return queue("POST", url, headers, body, callback, options)
		end,
		cancel = function() error("a terminal callback must not cancel its successor") end,
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(owner, message, detail)
		logs[#logs + 1] = { owner = owner, message = message, detail = detail }
	end
	package.loaded["logger.shim"] = logger
	local ok, err = pcall(function()
		local remote = helpers.load_module("modules.llm.api_remote")
		remote._reset_for_test()
		observed_requests[remote] = {}
		test(remote, calls, logs)
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

local SPECS = {
	{ owner = "models", provider = "lmstudio", format = "openai", token = "" },
	{ owner = "models", provider = "openai_compat", format = "openai", token = "owned-fixture-token" },
	{ owner = "test", provider = "openai_compat", format = "openai", token = "owned-fixture-token" },
	{ owner = "test", provider = "anthropic", format = "anthropic", token = "owned-fixture-token" },
	{ owner = "test", provider = "gemini", format = "gemini", token = "owned-fixture-token" },
}
local REPLIES = {
	openai = '{"choices":[{"message":{"content":"valid reply"}}]}',
	anthropic = '{"content":[{"type":"text","text":"valid reply"}]}',
	gemini = '{"candidates":[{"content":{"parts":[{"text":"valid reply"}]}}]}',
}

--- Dispatches the public owner, without catalogue or persistence writes.
--- @param remote table Loaded production module.
--- @param spec table Provider identity and public owner.
--- @param callback function Actual public callback.
--- @return boolean admitted
local function start(remote, spec, callback)
	local deliveries = observed_requests[remote]
	local delivered = { terminal = {} }
	deliveries[#deliveries + 1] = delivered
	callback = observe_callback(remote, delivered.terminal, callback)
	local entry = { id = "owned-sibling", provider = spec.provider, model = "fixture-model",
		token = spec.token, base_url = "https://example.invalid/v1" }
	if spec.owner == "models" then return remote.models(entry, callback) end
	return remote.test(entry, callback)
end

--- Declares an independent successful response for the public owner's tuple.
--- @param spec table Owner and provider format.
--- @return table result Scripted complete HTTP receipt.
local function response(spec)
	return { ok = true, status = 200,
		body = spec.owner == "models" and '{"data":[{"id":"fixture-model"}]}' or REPLIES[spec.format] }
end

--- Pins the documented callback tuple before the deliberate caller exception.
--- @param remote table Loaded remote module.
--- @param spec table Public owner.
--- @param a any First callback argument.
--- @param b any Second callback argument.
--- @param c any Third callback argument.
local function check_tuple(remote, spec, a, b, c)
	assert(not remote.is_active(), "owner is cleared before the caller callback")
	if spec.owner == "models" then
		assert(type(a) == "table" and #a == 1 and a[1] == "fixture-model" and b == nil and c == nil)
	else
		assert(a == true and b == "valid reply" and type(c) == "number" and c >= 0)
	end
end

--- Checks the unchanged owner, format string and explicit diagnostic text.
--- @param log table Captured terminal logger call.
--- @param detail string Independent primitive or shared stable-type text.
local function check_log(log, detail)
	helpers.assert_eq(log.owner, "modules.llm.api_remote")
	helpers.assert_eq(log.message, "Terminal callback raised — %s")
	helpers.assert_eq(log.detail, detail)
end

--- Checks public model/probe behavior outside the protected caller callback.
--- @param delivered table Actual captured delivery returned by the invocation.
--- @param owner string Public models or connectivity owner.
--- @param expected any Expected model IDs or probe success flag.
--- @param reason string|nil Expected model reason or probe reply/detail.
local function check_delivery(delivered, owner, expected, reason)
	helpers.assert_eq(#delivered.terminal, 1)
	local actual = delivered.terminal[1]
	helpers.assert_eq(actual.active, false)
	if owner == "models" then
		helpers.assert_eq(actual.args, { n = 2, expected, reason })
	else
		helpers.assert_eq(actual.args.n, 3)
		helpers.assert_eq(actual.args[1], expected)
		helpers.assert_eq(actual.args[2], reason)
		helpers.assert_true(type(actual.args[3]) == "number" and actual.args[3] >= 0 and actual.args[3] < math.huge,
			"the actual elapsed-ms result must be finite and nonnegative")
	end
end

--- Keeps nil model reasons separate from the successful probe reply.
--- @param delivered table Actual successful public callback record.
--- @param owner string Models or connectivity owner.
local function check_success_delivery(delivered, owner)
	if owner == "models" then check_delivery(delivered, owner, { "fixture-model" }, nil)
	else check_delivery(delivered, owner, true, "valid reply") end
end

--- Keeps refused model IDs genuinely nil and probe failure genuinely false.
--- @param delivered table Actual empty/refused public callback record.
--- @param outcome table Independently declared expected result.
local function check_outcome_delivery(delivered, outcome)
	if outcome.owner == "models" then check_delivery(delivered, outcome.owner, outcome.ids, outcome.reason)
	else check_delivery(delivered, outcome.owner, false, outcome.reason) end
end

helpers.describe("api_remote_callback_siblings: protected public wrappers", function()
	for _, spec in ipairs(SPECS) do
		for _, case in ipairs({ "healthy", "string", "object", "throwing-object", "reentry-object", "reentry-throwing-object" }) do
			helpers.it("api_remote_callback_siblings: " .. spec.owner .. " " .. spec.provider .. " " .. case, function()
				isolated(function(remote, calls, logs)
					local count, formatter_calls, successors = 0, 0, 0
					local failure = setmetatable({}, { __tostring = function()
						formatter_calls = formatter_calls + 1
						if case:find("throwing", 1, true) then error("owned formatter failure", 0) end
						return "owned formatter result"
					end })
					assert(start(remote, spec, function(a, b, c)
						count = count + 1
						check_tuple(remote, spec, a, b, c)
						if case:find("reentry", 1, true) then
							assert(start(remote, spec, function(x, y, z)
								successors = successors + 1; check_tuple(remote, spec, x, y, z)
							end))
							assert(remote.is_active(), "successor acquired the cleared owner")
						end
						if case == "string" then error("owned ordinary wrapper failure", 0) end
						if case:find("object", 1, true) then error(failure, 0) end
					end))
					local ok, delivered = pcall(function()
						calls[1].callback(response(spec))
						return observed_requests[remote][1]
					end)
					helpers.assert_eq(delivered.terminal[1].args.n, spec.owner == "models" and 2 or 3)
					check_success_delivery(delivered, spec.owner)
					helpers.assert_eq(formatter_calls, 0, "reporting cannot invoke another caller formatter")
					helpers.assert_true(ok, "diagnostic reporting cannot escape callback protection")
					helpers.assert_eq(count, 1)
					helpers.assert_eq(calls[1].method, spec.owner == "models" and "GET" or "POST")
					helpers.assert_eq(calls[1].options.owner, "llm_remote")
					if spec.owner == "models" then helpers.assert_eq(calls[1].options.follow_redirects, false) end
					if case:find("reentry", 1, true) then
						helpers.assert_true(remote.is_active())
						-- The first callback may be delivered again by a scripted adapter;
						-- its old epoch must not settle the newly admitted successor.
						calls[1].callback(response(spec))
						helpers.assert_eq(count, 1)
						helpers.assert_true(remote.is_active())
						calls[2].callback(response(spec))
						check_success_delivery(observed_requests[remote][2], spec.owner)
						helpers.assert_eq(successors, 1)
					else helpers.assert_eq(successors, 0) end
					helpers.assert_eq(remote.is_active(), false)
					if case == "healthy" then helpers.assert_eq(#logs, 0)
					else
						helpers.assert_eq(#logs, 1)
						check_log(logs[1], case == "string" and "owned ordinary wrapper failure" or "error object (table)")
					end
					local retries = 0
					assert(start(remote, spec, function(a, b, c)
						retries = retries + 1; check_tuple(remote, spec, a, b, c)
					end))
					calls[#calls].callback(response(spec))
					check_success_delivery(observed_requests[remote][#calls], spec.owner)
					helpers.assert_eq(retries, 1)
					helpers.assert_eq(remote.is_active(), false)
				end)
			end)
		end
	end
	local outcomes = {
		{ name = "empty models", owner = "models", result = { ok = true, status = 200, body = '{"data":[]}' }, ids = {} },
		{ name = "HTTP models refusal", owner = "models", result = { ok = false, status = 401, body = "" }, reason = "http_failure" },
		{ name = "typed models refusal", owner = "models", result = { ok = true, status = 200, body = '{"data":{}}' }, reason = "invalid_models" },
		{ name = "empty probe reply", owner = "test", result = { ok = true, status = 200, body = "{}" }, reason = "empty reply" },
		{ name = "HTTP probe refusal", owner = "test", result = { ok = false, status = 401, body = "", error_body = '{"error":{"message":"ordinary refusal"}}' }, reason = "HTTP 401: ordinary refusal" },
	}
	for _, outcome in ipairs(outcomes) do
		for _, throwing in ipairs({ false, true }) do
			helpers.it("api_remote_callback_siblings: " .. outcome.name .. " safely reports " .. (throwing and "throwing" or "successful") .. " error objects", function()
				isolated(function(remote, calls, logs)
					local count, formatter_calls = 0, 0
					local failure = setmetatable({}, { __tostring = function()
						formatter_calls = formatter_calls + 1
						if throwing then error("owned formatter failure", 0) end
						return "owned formatter result"
					end })
					local spec = { owner = outcome.owner, provider = "openai_compat", format = "openai", token = "owned-fixture-token" }
					assert(start(remote, spec, function(a, b, c)
						count = count + 1; assert(not remote.is_active())
						if outcome.owner == "models" then
							helpers.assert_eq(a, outcome.ids); assert(b == outcome.reason and c == nil)
						else assert(a == false and b == outcome.reason and type(c) == "number" and c >= 0) end
						error(failure, 0)
					end))
					local ok, delivered = pcall(function()
						calls[1].callback(outcome.result)
						return observed_requests[remote][1]
					end)
					helpers.assert_eq(delivered.terminal[1].args.n, outcome.owner == "models" and 2 or 3)
					check_outcome_delivery(delivered, outcome)
					helpers.assert_eq(formatter_calls, 0)
					helpers.assert_true(ok)
					helpers.assert_eq(count, 1)
					helpers.assert_eq(remote.is_active(), false)
					helpers.assert_eq(#logs, 1); check_log(logs[1], "error object (table)")
				end)
			end)
		end
	end
end)
