--- tests/unit/meta/test_api_ollama_stream_parse.lua

--- ==============================================================================
--- MODULE: Ollama Async Streaming Lifecycle
--- DESCRIPTION:
--- Drives api_ollama through a deferred HttpClient double. Chunks are split at
--- arbitrary byte boundaries to prove NDJSON framing, cancellation is terminal,
--- and stale transport completion cannot publish into a newer request.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads api_ollama with a controllable asynchronous transport.
--- @return table api, table transport, function restore
local function subject()
	local previous_client = package.loaded["adapters.http_client"]
	local previous_api = package.loaded["modules.llm.api_ollama"]
	local transport = { requests = {}, cancel_count = 0 }
	package.loaded["adapters.http_client"] = {
		postStream = function(url, headers, body, options, on_chunk, on_done)
			transport.requests[#transport.requests + 1] = {
				url = url, headers = headers, body = body, options = options,
				on_chunk = on_chunk, on_done = on_done,
			}
			return true
		end,
		cancel = function()
			transport.cancel_count = transport.cancel_count + 1
			return true
		end,
		isActive = function() return #transport.requests > 0 end,
	}
	package.loaded["modules.llm.api_ollama"] = nil
	local api = require("modules.llm.api_ollama")
	return api, transport, function()
		package.loaded["adapters.http_client"] = previous_client
		package.loaded["modules.llm.api_ollama"] = previous_api
	end
end

helpers.describe("api_ollama: asynchronous streaming", function()
	helpers.it("returns before a slow response and frames split NDJSON chunks", function()
		local api, transport, restore = subject()
		local chunks = {}
		local done_count = 0
		local final_text = nil
		api.chat("http://127.0.0.1:11434", "test-model",
			{ { role = "user", content = "hi" } }, { stream = true },
			function(delta) chunks[#chunks + 1] = delta end,
			function(text, err)
				done_count = done_count + 1
				final_text = text
				helpers.assert_nil(err)
			end)

		helpers.assert_eq(#transport.requests, 1, "chat dispatches and returns immediately")
		helpers.assert_true(api.is_active(), "the slow request remains owned asynchronously")
		local request = transport.requests[1]
		helpers.assert_eq(request.url, "http://127.0.0.1:11434/api/chat")
		request.on_chunk('{"message":{"content":"Hel')
		request.on_chunk('lo"},"done":false}\n{"message":{"content":" world"},')
		request.on_chunk('"done":false}\n{"message":{"content":""},"done":true}')
		helpers.assert_eq(table.concat(chunks), "Hello world")
		helpers.assert_eq(done_count, 0, "transport completion owns the terminal callback")
		request.on_done({ ok = true, status = 200 })
		helpers.assert_eq(done_count, 1)
		helpers.assert_eq(final_text, "Hello world")
		helpers.assert_true(not api.is_active())
		restore()
	end)

	helpers.it("cancel fires once and makes late chunks and completion inert", function()
		local api, transport, restore = subject()
		local terminals = {}
		api.chat("http://127.0.0.1:11434", "test-model", {}, {}, function() end,
			function(text, err) terminals[#terminals + 1] = { text = text, err = err } end)
		local stale = transport.requests[1]
		helpers.assert_true(api.cancel())
		helpers.assert_eq(transport.cancel_count, 1)
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].err, "cancelled")
		stale.on_chunk('{"message":{"content":"stale"}}\n')
		stale.on_done({ ok = true, status = 200 })
		helpers.assert_eq(#terminals, 1, "stale callbacks must not publish twice")
		restore()
	end)

	helpers.it("a superseded request cannot publish into its successor", function()
		local api, transport, restore = subject()
		local first_done = 0
		local second_text = nil
		api.chat("http://127.0.0.1:11434", "first", {}, {}, function() end,
			function() first_done = first_done + 1 end)
		local first = transport.requests[1]
		api.chat("http://127.0.0.1:11434", "second", {}, {}, function() end,
			function(text, err) if not err then second_text = text end end)
		helpers.assert_eq(first_done, 1, "superseding a request terminates it as cancelled")
		first.on_chunk('{"message":{"content":"wrong"}}\n')
		first.on_done({ ok = true, status = 200 })
		local second = transport.requests[2]
		second.on_chunk('{"message":{"content":"right"},"done":true}\n')
		second.on_done({ ok = true, status = 200 })
		helpers.assert_eq(second_text, "right")
		helpers.assert_eq(first_done, 1)
		restore()
	end)
end)
