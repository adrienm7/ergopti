--- tests/unit/modules/llm/test_api_remote_test_request.lua

--- ==============================================================================
--- MODULE: Remote API Test-Request Regression Tests
--- DESCRIPTION:
--- Exercises api_remote.test_request through the production HTTP owner with a
--- captured transport: the shared minimal probe must reach the wire verbatim
--- (prompt, model, sampling), success must surface the reply text, and every
--- failure shape must reach on_fail without leaking the token anywhere.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Returns one named closure upvalue, or nil when the closure does not own it.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value Captured value.
local function get_upvalue(fn, target)
	for index = 1, 128 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end


--- Loads a fresh production backend with a fixture provider + entry.
--- @return table api Remote backend.
--- @return table inference Instrumented HTTP owner.
local function fresh_backend()
	local api = helpers.load_with_stubs("modules.llm.api_remote")
	api.PROVIDERS.fixture = {
		label = "Fixture",
		base_url = "https://fixture.invalid/v1",
		default_model = "fixture-default-model",
		format = "openai",
	}
	api.set_entries({ {
		id = "probe-entry",
		provider = "fixture",
		base_url = "https://fixture.invalid/v1",
		token = "probe-token",
		model = "probe-model",
	} })
	api.set_active_entry_id("probe-entry")
	local inference = get_upvalue(api.cancel_streaming, "_infer_client")
	helpers.assert_true(type(inference) == "table", "remote inference client must be owned")
	return api, inference
end


local SPEC = {
	system_prompt = "You are a connectivity probe. Reply with exactly: OK",
	user_text = "ping",
	temperature = 0,
	max_tokens = 16,
}

local function entry()
	return {
		id = "probe-entry",
		provider = "fixture",
		base_url = "https://fixture.invalid/v1",
		token = "probe-token",
		model = "probe-model",
	}
end

local function stub_parser(api)
	local post_and_parse = get_upvalue(api.test_request, "post_and_parse_resolved")
	helpers.assert_true(type(post_and_parse) == "function",
		"test_request must dispatch through the shared post_and_parse path")
	local parser = get_upvalue(post_and_parse, "Parser")
	helpers.assert_true(type(parser) == "table", "response parser must be reachable")
	local original_strip = parser.strip_thinking
	local original_process = parser.process_prediction
	parser.strip_thinking = function(text) return text end
	parser.process_prediction = function(_, _, text) return { to_type = text } end
	return function()
		parser.strip_thinking = original_strip
		parser.process_prediction = original_process
	end
end


helpers.describe("api_remote.test_request", function()

	helpers.it("posts the shared probe verbatim and surfaces the reply", function()
		local api, inference = fresh_backend()
		local restore_parser = stub_parser(api)
		local posts = {}
		local original_post = inference.post
		inference.post = function(url, headers, body, callback)
			posts[#posts + 1] = { url = url, headers = headers, body = body, callback = callback }
			return true
		end
		local ok, err = xpcall(function()
			local replies, failures = {}, {}
			helpers.assert_true(api.test_request(entry(), SPEC,
				function(text, ms)
					replies[#replies + 1] = { text = text, ms = ms }
				end,
				function(reason) failures[#failures + 1] = reason end))
			helpers.assert_eq(#posts, 1, "exactly one probe request must dispatch")
			helpers.assert_true(posts[1].url:find("https://fixture.invalid/v1/chat/completions", 1, true) == 1,
				"probe must target the provider chat endpoint, got: " .. tostring(posts[1].url))
			helpers.assert_true(posts[1].body:find("probe%-model", 1) ~= nil,
				"probe must carry the entry model id")
			helpers.assert_true(posts[1].body:find("Reply with exactly: OK", 1, true) ~= nil,
				"probe must carry the shared system prompt verbatim")
			helpers.assert_true(posts[1].body:find('"temperature":0', 1, true) ~= nil,
				"probe must carry the shared temperature")
			helpers.assert_true(posts[1].body:find('"max_tokens":16', 1, true) ~= nil,
				"probe must carry the shared token budget")
			helpers.assert_true(posts[1].headers.Authorization == "Bearer probe-token",
				"probe must authenticate with the entry token")
			posts[1].callback({
				ok = true, status = 200,
				body = [[{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":8,"completion_tokens":1,"total_tokens":9}}]],
			})
			helpers.assert_eq(#replies, 1, "a parsed reply must reach on_ok")
			helpers.assert_eq(replies[1].text, "OK")
			helpers.assert_true(type(replies[1].ms) == "number", "latency must travel with the reply")
			helpers.assert_eq(#failures, 0)
		end, debug.traceback)
		inference.post = original_post
		restore_parser()
		if not ok then error(err, 0) end
	end)

	helpers.it("exposes the provider error text for notifications", function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local extract = api.__extract_server_message_for_test
		helpers.assert_true(type(extract) == "function",
			"server message extractor must be exposed for tests")
		helpers.assert_true((extract('{"message":"Payment required to access this resource. Visit your billing tab.","type":"payment_required_error"}') or ""):find("Payment required", 1, true) ~= nil,
			"top-level message (Cerebras error shape) must surface")
		helpers.assert_true((extract('{"error":{"message":"Wrong API Key"}}') or ""):find("Wrong API Key", 1, true) ~= nil,
			"error.message (OpenAI shape) must surface")
		helpers.assert_true(extract('{"error":{"content":"world"}}') == nil,
			"a content decoy is not a message")
		helpers.assert_true(extract('{"choices":[{"message":{"content":"OK"}}]}') == nil,
			"success carries no server message")
	end)

	helpers.it("forwards status and server message on HTTP failure", function()
		local api, inference = fresh_backend()
		local original_post = inference.post
		local reasons = {}
		inference.post = function(_, _, _, callback)
			callback({ ok = false, status = 402,
				body = [[{"message":"Payment required to access this resource. Visit your billing tab.","type":"payment_required_error"}]] })
			return true
		end
		local ok, err = xpcall(function()
			api.test_request(entry(), SPEC,
				function() end,
				function(reason, detail) reasons[#reasons + 1] = { reason = reason, detail = detail } end)
			helpers.assert_eq(#reasons, 1)
			helpers.assert_eq(reasons[1].reason, "request_failed")
			helpers.assert_true(type(reasons[1].detail) == "table",
				"failure must carry the server detail")
			helpers.assert_eq(reasons[1].detail.status, 402)
			helpers.assert_true((reasons[1].detail.message or ""):find("Payment required", 1, true) ~= nil,
				"failure must carry the server message")
		end, debug.traceback)
		inference.post = original_post
		if not ok then error(err, 0) end
	end)

	helpers.it("reports HTTP failure without leaking the token", function()
		local api, inference = fresh_backend()
		local restore_parser = stub_parser(api)
		local original_post = inference.post
		local replies, failures = {}, {}
		inference.post = function(_, _, _, callback)
			callback({ ok = false, status = 401, body = "Unauthorized" })
			return true
		end
		local ok, err = xpcall(function()
			helpers.assert_true(api.test_request(entry(), SPEC,
				function(text) replies[#replies + 1] = text end,
				function(reason) failures[#failures + 1] = reason end))
			helpers.assert_eq(#replies, 0)
			helpers.assert_eq(#failures, 1)
		end, debug.traceback)
		inference.post = original_post
		restore_parser()
		if not ok then error(err, 0) end
	end)

	helpers.it("treats an empty reply as failure", function()
		local api, inference = fresh_backend()
		local post_and_parse = get_upvalue(api.test_request, "post_and_parse_resolved")
		local parser = get_upvalue(post_and_parse, "Parser")
		local original_process = parser.process_prediction
		parser.process_prediction = function(_, _, _) return { to_type = "" } end
		local original_post = inference.post
		local replies, failures = {}, {}
		inference.post = function(_, _, _, callback)
			callback({ ok = true, status = 200, body = [[{"choices":[{"message":{"content":"OK"}}]}]] })
			return true
		end
		local ok, err = xpcall(function()
			helpers.assert_true(api.test_request(entry(), SPEC,
				function(text) replies[#replies + 1] = text end,
				function(reason) failures[#failures + 1] = reason end))
			helpers.assert_eq(#replies, 0, "a prediction with no text proves nothing about the model")
			helpers.assert_eq(#failures, 1)
			helpers.assert_eq(failures[1], "empty_reply")
		end, debug.traceback)
		inference.post = original_post
		parser.process_prediction = original_process
		if not ok then error(err, 0) end
	end)

	helpers.it("reports empty content through the transport verdict", function()
		local api, inference = fresh_backend()
		local restore_parser = stub_parser(api)
		local original_post = inference.post
		local replies, failures = {}, {}
		inference.post = function(_, _, _, callback)
			callback({ ok = true, status = 200, body = [[{"choices":[{"message":{"content":""}}]}]] })
			return true
		end
		local ok, err = xpcall(function()
			helpers.assert_true(api.test_request(entry(), SPEC,
				function(text) replies[#replies + 1] = text end,
				function(reason) failures[#failures + 1] = reason end))
			helpers.assert_eq(#replies, 0)
			helpers.assert_eq(#failures, 1)
			helpers.assert_eq(failures[1], "request_failed")
		end, debug.traceback)
		inference.post = original_post
		restore_parser()
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses invalid entry and spec shapes without dispatching", function()
		local api, inference = fresh_backend()
		local original_post = inference.post
		local posts = 0
		inference.post = function()
			posts = posts + 1
			return true
		end
		local ok, err = xpcall(function()
			local failures = {}
			local function on_fail(reason) failures[#failures + 1] = reason end
			helpers.assert_eq(api.test_request(nil, SPEC, function() end, on_fail), false)
			helpers.assert_eq(api.test_request(entry(), nil, function() end, on_fail), false)
			helpers.assert_eq(api.test_request(entry(),
				{ system_prompt = "", user_text = "ping", temperature = 0, max_tokens = 16 },
				function() end, on_fail), false)
			helpers.assert_eq(posts, 0, "refused probes must never reach the wire")
			helpers.assert_eq(#failures, 3)
		end, debug.traceback)
		inference.post = original_post
		if not ok then error(err, 0) end
	end)

end)
