--- tests/unit/modules/llm/remote/test_api_remote_error_envelopes.lua

--- ==============================================================================
--- MODULE: Remote Multi-Step Provider Error Envelopes
--- DESCRIPTION:
--- Refuses explicit provider errors before publishing Backboard text, caching an
--- assistant or publishing typed decisions, while retaining healthy retries.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
-- Load actual transitive dependencies before replacing the transport port.
require("modules.llm.api_remote")

local function isolated(body)
	local names = { "modules.llm.api_remote", "adapters.http_client", "logger.shim" }
	local saved, calls = {}, {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	package.loaded["adapters.http_client"] = {
		post = function(url, _, payload, callback)
			calls[#calls + 1] = { url = url, payload = payload, callback = callback }
			return true
		end,
		cancel = function() return true end,
	}
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	local ok, detail = xpcall(function()
		local remote = helpers.load_module("modules.llm.api_remote")
		remote._reset_for_test()
		local function answer(root)
			calls[#calls].callback({ ok = true, status = 200, body = root })
		end
		body(remote, calls, answer)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

local function start(remote, kind, observed)
	local entry = { provider = kind == "decisions" and "typesafe" or "backboard",
		token = "owned-fixture-token", model = "openai/fixture", base_url = "http://127.0.0.1:1234" }
	local function done(value, failure)
		observed[#observed + 1] = { value = value, failure = failure, active = remote.is_active() }
	end
	if kind == "chat" or kind == "creation" then
		return remote.chat(entry, nil, { { role = "user", content = "fixture" } }, {},
			function() observed.chunks = observed.chunks + 1 end, done)
	end
	return remote.decide(entry, "fixture", { answer = { type = "boolean" } }, done)
end

local function valid(kind)
	if kind == "creation" then return '"assistant_id":"owned-assistant"' end
	if kind == "chat" then return '"content":"owned reply"' end
	return '"answers":{"answer":true}'
end

helpers.describe("remote multi-step error envelopes", function()
	for _, kind in ipairs({ "decisions", "backboard-decisions" }) do
		for _, spec in ipairs({
			{ body = '{"answers":null}', expected = '{}' },
			{ body = '{"answers":{"answer":null}}', expected = '{"answer":{}}' },
		}) do
			helpers.it("preserves legacy " .. kind .. " null representation " .. spec.body, function()
				isolated(function(remote, _, answer)
					local observed = { chunks = 0 }
					helpers.assert_true(start(remote, kind, observed))
					if kind == "backboard-decisions" then answer('{"assistant_id":"owned-assistant"}') end
					answer(spec.body)
					helpers.assert_eq(#observed, 1)
					helpers.assert_nil(observed[1].failure)
					helpers.assert_eq(Json.encode(observed[1].value), spec.expected)
				end)
			end)
		end
	end
	for _, spec in ipairs({
		{ body = '{"system_one":{"answers":null}}', expected = '{}' },
		{ body = '{"system_one":{"answers":{"answer":null}}}', expected = '{"answer":{}}' },
	}) do
		helpers.it("preserves legacy Backboard system_one null representation " .. spec.body, function()
			isolated(function(remote, _, answer)
				local observed = { chunks = 0 }
				helpers.assert_true(start(remote, "backboard-decisions", observed))
				answer('{"assistant_id":"owned-assistant"}')
				answer(spec.body)
				helpers.assert_eq(#observed, 1)
				helpers.assert_nil(observed[1].failure)
				helpers.assert_eq(Json.encode(observed[1].value), spec.expected)
			end)
		end)
	end
	for _, kind in ipairs({ "creation", "chat" }) do
		helpers.it("continues refusing a null " .. kind .. " value", function()
			isolated(function(remote, calls, answer)
				local observed = { chunks = 0 }
				helpers.assert_true(start(remote, kind, observed))
				if kind == "chat" then answer('{"assistant_id":"owned-assistant"}') end
				local before = #calls
				answer(kind == "creation" and '{"assistant_id":null}' or '{"content":null}')
				helpers.assert_eq(#calls, before)
				helpers.assert_eq(#observed, 1)
				helpers.assert_true(type(observed[1].failure) == "string")
				helpers.assert_eq(observed.chunks, 0)
			end)
		end)
	end
	for _, phase in ipairs({ "creation", "chat" }) do
		helpers.it("ignores a cancelled " .. phase .. " error before its healthy successor", function()
			isolated(function(remote, calls, answer)
				local original = { chunks = 0 }
				helpers.assert_true(start(remote, phase, original))
				if phase == "chat" then answer('{"assistant_id":"owned-assistant"}') end
				local old = calls[#calls].callback
				helpers.assert_true(remote.cancel())
				local successor = { chunks = 0 }
				helpers.assert_true(start(remote, phase, successor))
				local before = #calls
				old({ ok = true, status = 200, body = '{' .. valid(phase) .. ',"error":null}' })
				helpers.assert_eq(#calls, before)
				helpers.assert_eq(#original, 0)
				helpers.assert_true(remote.is_active())
				if calls[#calls].url:match("/assistants$") then answer('{"assistant_id":"fresh-assistant"}') end
				answer('{"content":"owned reply"}')
				helpers.assert_eq(#successor, 1)
				helpers.assert_eq(successor[1].value, "owned reply")
				helpers.assert_nil(successor[1].failure)
			end)
		end)
	end
	for _, kind in ipairs({ "creation", "chat", "decisions", "backboard-decisions" }) do
		for _, fault in ipairs({ 'false', 'null', '"refused"', '{"message":"refused"}' }) do
			helpers.it("refuses " .. kind .. " with explicit root error " .. fault, function()
				isolated(function(remote, calls, answer)
					local observed = { chunks = 0 }
					helpers.assert_true(start(remote, kind, observed))
					if kind ~= "creation" and kind ~= "decisions" then answer('{"assistant_id":"owned-assistant"}') end
					local before = #calls
					answer('{' .. valid(kind) .. ',"error":' .. fault .. '}')
					helpers.assert_eq(#calls, before, "an error cannot acquire the next request")
					helpers.assert_eq(#observed, 1)
					helpers.assert_true(type(observed[1].failure) == "string")
					helpers.assert_eq(observed[1].active, false)
					helpers.assert_eq(observed.chunks, 0)
					if kind == "creation" then
						local retry = { chunks = 0 }
						helpers.assert_true(start(remote, kind, retry))
						helpers.assert_true(calls[#calls].url:match("/assistants$") ~= nil,
							"refused assistant identity cannot enter the session cache")
						answer('{"assistant_id":"fresh-assistant"}')
						answer('{"content":"owned reply"}')
						helpers.assert_eq(#retry, 1)
						helpers.assert_nil(retry[1].failure)
						helpers.assert_eq(retry[1].value, "owned reply")
					end
				end)
			end)
		end
		for _, metadata in ipairs({ "", ',"metadata":{"error":null}' }) do
			helpers.it("preserves " .. kind .. " with healthy metadata " .. metadata, function()
				isolated(function(remote, _, answer)
					local observed = { chunks = 0 }
					helpers.assert_true(start(remote, kind, observed))
					if kind ~= "creation" and kind ~= "decisions" then answer('{"assistant_id":"owned-assistant"}') end
					answer('{' .. valid(kind) .. metadata .. '}')
					if kind == "creation" then answer('{"content":"owned reply"}') end
					helpers.assert_eq(#observed, 1)
					helpers.assert_nil(observed[1].failure)
					helpers.assert_eq(observed[1].active, false)
					helpers.assert_true(observed[1].value ~= nil)
				end)
			end)
		end
	end
end)
