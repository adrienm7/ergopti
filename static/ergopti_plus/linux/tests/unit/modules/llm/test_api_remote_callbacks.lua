--- tests/unit/modules/llm/test_api_remote_callbacks.lua

--- ==============================================================================
--- MODULE: Remote Provider Callback Diagnostic Regression Tests
--- DESCRIPTION:
--- Scripted HTTP settlement pins terminal callback isolation, safe caught-error
--- descriptions and successor ownership. Native TLS coverage lives separately;
--- these tests do not claim hardware or real transport validation.
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

--- Runs one isolated public callback case over explicitly scripted HTTP.
--- @param test function Receives the provider, queued requests and logger records.
local function isolated(test)
	local saved = {}
	for _, name in ipairs({ "adapters.http_client", "modules.llm.api_remote", "logger.shim" }) do
		saved[name] = package.loaded[name]
	end
	local calls, logs = {}, {}
	package.loaded["adapters.http_client"] = {
		post = function(url, headers, body, callback, options)
			calls[#calls + 1] = { callback = callback, options = options }
			return true
		end,
		cancel = function() error("a settled callback must not cancel its successor") end,
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
	for name, value in pairs(saved) do package.loaded[name] = value end
	for _, name in ipairs({ "adapters.http_client", "modules.llm.api_remote", "logger.shim" }) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	if not ok then error(err, 0) end
end

local replies = {
	openai = '{"choices":[{"message":{"content":"valid reply"}}]}',
	anthropic = '{"content":[{"type":"text","text":"valid reply"}]}',
	gemini = '{"candidates":[{"content":{"parts":[{"text":"valid reply"}]}}]}',
}

--- Starts a genuine public provider call over the explicitly scripted adapter.
--- @param remote table Loaded provider module.
--- @param format string Provider response format.
--- @param chunk function|nil Chunk callback.
--- @param done function Terminal callback.
--- @return boolean admitted
local function start(remote, format, chunk, done)
	local deliveries = observed_requests[remote]
	local delivered = { chunks = {}, terminal = {} }
	deliveries[#deliveries + 1] = delivered
	chunk = observe_callback(remote, delivered.chunks, chunk)
	done = observe_callback(remote, delivered.terminal, done)
	return remote.chat({ provider = format == "openai" and "openai_compat" or format,
		base_url = "https://example.invalid/v1", token = "owned-fixture-token", model = "fixture-model" },
		nil, { { role = "user", content = "fixture prompt" } },
		{ temperature = 0.25, max_tokens = 40 }, chunk, done)
end

--- Checks the unchanged diagnostic owner and log format.
--- @param log table Captured terminal error record.
--- @param detail string Expected diagnostic description.
local function check_log(log, detail)
	helpers.assert_eq(log.owner, "modules.llm.api_remote")
	helpers.assert_eq(log.message, "Terminal callback raised — %s")
	helpers.assert_eq(log.detail, detail)
end

--- Checks the actual returned delivery outside every protected callback.
--- @param delivered table Captured caller behavior, not the HTTP callback return.
--- @param chunks boolean Whether this request has a chunk callback.
--- @param text string Independently expected caller text.
--- @param reason string|nil Independently expected caller error.
local function check_delivery(delivered, chunks, text, reason)
	helpers.assert_eq(delivered, {
		chunks = chunks and { { args = { n = 1, text }, active = true } } or {},
		terminal = { { args = { n = 2, text, reason }, active = false } },
	})
end

helpers.describe("api_remote_callbacks: safe reporting and callback ownership", function()
	local cases = { "healthy", "chunk-string", "chunk-object", "terminal-string",
		"terminal-object", "terminal-throwing-object", "reentry-object", "reentry-throwing-object" }
	for _, format in ipairs({ "openai", "anthropic", "gemini" }) do
		for _, case in ipairs(cases) do
			helpers.it("api_remote_callbacks: " .. format .. " " .. case, function()
				isolated(function(remote, calls, logs)
					local chunks, terminals, formatter_calls, successors = 0, 0, 0, 0
					local failure = setmetatable({}, { __tostring = function()
						formatter_calls = formatter_calls + 1
						if case == "chunk-object" or case:find("throwing", 1, true) then
							error("owned formatter failure", 0)
						end
						return "owned error description"
					end })
					assert(start(remote, format, function(text)
						chunks = chunks + 1
						assert(text == "valid reply")
						if case == "chunk-string" then error("owned chunk failure", 0) end
						if case == "chunk-object" then error(failure, 0) end
					end, function(text, err)
						terminals = terminals + 1
						assert(text == "valid reply" and err == nil and not remote.is_active())
						if case:find("reentry", 1, true) then
							assert(start(remote, format, nil, function(next_text, next_err)
								successors = successors + 1
								assert(next_text == "valid reply" and next_err == nil and not remote.is_active())
							end))
							assert(remote.is_active())
						end
						if case == "terminal-string" then error("owned terminal failure", 0) end
						if case:find("object", 1, true) and case ~= "chunk-object" then error(failure, 0) end
					end))
					local ok, delivered = pcall(function()
						calls[1].callback({ ok = true, status = 200, body = replies[format] })
						return observed_requests[remote][1]
					end)
					helpers.assert_eq(delivered.terminal[1].args.n, 2)
					check_delivery(delivered, true, "valid reply", nil)
					helpers.assert_eq(formatter_calls, 0, "caught error reporting must not invoke foreign formatting")
					helpers.assert_true(ok, "protected callback must not escape through diagnostic formatting")
					helpers.assert_eq(chunks, 1)
					helpers.assert_eq(terminals, 1)
					-- A repeated native completion cannot deliver an old terminal callback twice.
					calls[1].callback({ ok = true, status = 200, body = replies[format] })
					helpers.assert_eq(terminals, 1)
					if case:find("reentry", 1, true) then
						helpers.assert_true(remote.is_active(), "old completion cannot withdraw successor ownership")
						calls[2].callback({ ok = true, status = 200, body = replies[format] })
						check_delivery(observed_requests[remote][2], false, "valid reply", nil)
						helpers.assert_eq(successors, 1)
					end
					helpers.assert_eq(remote.is_active(), false)
					if case == "terminal-string" then helpers.assert_eq(#logs, 1); check_log(logs[1], "owned terminal failure")
					elseif case:find("object", 1, true) and case ~= "chunk-object" then
						helpers.assert_eq(#logs, 1); check_log(logs[1], "error object (table)")
					else helpers.assert_eq(#logs, 0) end
					local retries = 0
					assert(start(remote, format, nil, function(text, err)
						retries = retries + 1; assert(text == "valid reply" and err == nil)
					end))
					calls[#calls].callback({ ok = true, status = 200, body = replies[format] })
					check_delivery(observed_requests[remote][#calls], false, "valid reply", nil)
					helpers.assert_eq(retries, 1)
					helpers.assert_eq(remote.is_active(), false)
				end)
			end)
		end
	end
	for _, case in ipairs({ { name = "empty reply", result = { ok = true, status = 200, body = "{}" }, expected = "empty reply" },
		{ name = "HTTP refusal", result = { ok = false, status = 401, body = "", error_body = '{"error":{"message":"ordinary refusal"}}' }, expected = "HTTP 401: ordinary refusal" },
		{ name = "transport failure", result = { ok = false, status = 0, error = "ordinary transport failure" }, expected = "ordinary transport failure" } }) do
		for _, format in ipairs({ "openai", "anthropic", "gemini" }) do
			helpers.it("api_remote_callbacks: " .. format .. " " .. case.name .. " safely describes terminal objects", function()
				isolated(function(remote, calls, logs)
					local count, formatter_calls = 0, 0
					local failure = setmetatable({}, { __tostring = function()
						formatter_calls = formatter_calls + 1; error("owned formatter failure", 0)
					end })
					assert(start(remote, format, nil, function(text, err)
						count = count + 1; assert(text == "" and err == case.expected and not remote.is_active())
						error(failure, 0)
					end))
					local ok, delivered = pcall(function()
						calls[1].callback(case.result)
						return observed_requests[remote][1]
					end)
					helpers.assert_eq(delivered.terminal[1].args.n, 2)
					check_delivery(delivered, false, "", case.expected)
					helpers.assert_eq(formatter_calls, 0)
					helpers.assert_true(ok)
					helpers.assert_eq(count, 1)
					helpers.assert_eq(remote.is_active(), false)
					helpers.assert_eq(#logs, 1); check_log(logs[1], "error object (table)")
				end)
			end)
		end
	end
	for _, case in ipairs({ { name = "empty string", value = "", expected = "" },
		{ name = "number", value = 42, expected = "42" }, { name = "false", value = false, expected = "false" },
		{ name = "function", value = function() error("must not be called") end, expected = "error object (function)" },
		{ name = "thread", value = coroutine.create(function() error("must not resume") end), expected = "error object (thread)" } }) do
		helpers.it("api_remote_callbacks: safely describes " .. case.name .. " terminal failure", function()
			isolated(function(remote, calls, logs)
				assert(start(remote, "openai", nil, function() error(case.value, 0) end))
				calls[1].callback({ ok = true, status = 200, body = replies.openai })
				check_delivery(observed_requests[remote][1], false, "valid reply", nil)
				helpers.assert_eq(remote.is_active(), false)
				helpers.assert_eq(#logs, 1); check_log(logs[1], case.expected)
			end)
		end)
	end
end)
