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
	local previous_probe = package.loaded["modules.llm.local_model_probe"]
	package.loaded["modules.llm.local_model_probe"] = nil
	local transport = { requests = {}, probes = {}, cancel_count = 0, cancel_refused = false }
	package.loaded["adapters.http_client"] = {
		get = function(url, headers, options, on_done)
			transport.probes[#transport.probes + 1] = { url = url, options = options, on_done = on_done }
			return true
		end,
		postStream = function(url, headers, body, options, on_chunk, on_done)
			transport.requests[#transport.requests + 1] = {
				url = url, headers = headers, body = body, options = options,
				on_chunk = on_chunk, on_done = on_done,
			}
			return true
		end,
		cancel = function()
			transport.cancel_count = transport.cancel_count + 1
			return not transport.cancel_refused
		end,
		isActive = function() return #transport.requests > 0 end,
	}
	package.loaded["modules.llm.api_ollama"] = nil
	local api = require("modules.llm.api_ollama")
	return api, transport, function()
		package.loaded["adapters.http_client"] = previous_client
		package.loaded["modules.llm.api_ollama"] = previous_api
		package.loaded["modules.llm.local_model_probe"] = previous_probe
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

helpers.describe("api_ollama: owned missing-model preflight", function()
	helpers.it("does not POST before tags acknowledge the requested model", function()
		local api, transport, restore = subject()
		local terminal = {}
		api.chat("http://127.0.0.1:11434", "QWEN2.5", {}, { verify_local_model = true }, nil,
			function(text, err) terminal[#terminal + 1] = { text = text, err = err } end)
		helpers.assert_eq(#transport.probes, 1)
		helpers.assert_eq(transport.probes[1].url, "http://127.0.0.1:11434/api/tags")
		helpers.assert_eq(#transport.requests, 0, "the slow listing owns the preflight")
		helpers.assert_true(api.is_active())
		transport.probes[1].on_done({ ok = true, status = 200, body = '{"models":[{"model":"qwen2.5:latest"}]}' })
		helpers.assert_eq(#transport.requests, 1)
		transport.requests[1].on_chunk('{"message":{"content":"ready"},"done":true}\n')
		transport.requests[1].on_done({ ok = true, status = 200 })
		helpers.assert_eq(#terminal, 1)
		helpers.assert_eq(terminal[1].text, "ready")
		helpers.assert_nil(terminal[1].err)
		restore()
	end)

	helpers.it("names a genuinely absent model and never sends the private request body", function()
		local api, transport, restore = subject()
		local errors = {}
		api.chat("http://127.0.0.1:11434", "qwen2.5:7b", { { role = "user", content = "private" } },
			{ verify_local_model = true }, nil, function(_, err) errors[#errors + 1] = err end)
		transport.probes[1].on_done({ ok = true, status = 200, body = '{"models":[]}' })
		helpers.assert_eq(#transport.requests, 0)
		helpers.assert_eq(#errors, 1)
		helpers.assert_eq(errors[1].reason, "model_missing")
		helpers.assert_eq(errors[1].model, "qwen2.5:7b")
		helpers.assert_eq(errors[1].base_url, "http://127.0.0.1:11434")
		helpers.assert_true(not api.is_active())
		restore()
	end)

	for _, receipt in ipairs({
		{ ok = false, status = 0, body = "", error = "timeout" },
		{ ok = false, status = 404, body = '{"models":[]}' },
		{ ok = true, status = 200, body = '{"models":{}}' },
		{ ok = true, status = 200, body = "broken" },
	}) do
		helpers.it("does not offer a download for an unknown model-list receipt " .. tostring(receipt.status)
			.. ":" .. receipt.body, function()
			local api, transport, restore = subject()
			local errors = {}
			api.chat("http://127.0.0.1:11434", "qwen2.5:7b", {}, { verify_local_model = true }, nil,
				function(_, err) errors[#errors + 1] = err end)
			transport.probes[1].on_done(receipt)
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(type(errors[1]), "string")
			helpers.assert_eq(#transport.requests, 0)
			helpers.assert_true(not require("llm.local_model_policy").is_missing(errors[1]))
			restore()
		end)
	end

	helpers.it("cancels preflight once and fences late receipts against a newer request", function()
		local api, transport, restore = subject()
		local errors = {}
		api.chat("http://127.0.0.1:11434", "first", {}, { verify_local_model = true }, nil,
			function(_, err) errors[#errors + 1] = err end)
		local first = transport.probes[1]
		helpers.assert_true(api.cancel())
		first.on_done({ ok = true, status = 200, body = '{"models":[{"name":"first"}]}' })
		helpers.assert_eq(#transport.requests, 0)
		helpers.assert_eq(#errors, 1)
		helpers.assert_eq(errors[1], "cancelled")
		api.chat("http://127.0.0.1:11434", "second", {}, { verify_local_model = true }, nil, function() end)
		first.on_done({ ok = true, status = 200, body = '{"models":[]}' })
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(api.is_active())
		transport.probes[2].on_done({ ok = true, status = 200, body = '{"models":[{"name":"second"}]}' })
		helpers.assert_eq(#transport.requests, 1)
		api.cancel()
		restore()
	end)

	helpers.it("keeps the owned preflight when cancellation is refused", function()
		local api, transport, restore = subject()
		local errors = {}
		api.chat("http://127.0.0.1:11434", "first", {}, { verify_local_model = true }, nil,
			function(_, err) errors[#errors + 1] = err end)
		transport.cancel_refused = true
		helpers.assert_eq(api.chat("http://127.0.0.1:11434", "second", {},
			{ verify_local_model = true }, nil, function() end), false)
		helpers.assert_eq(#transport.probes, 1)
		helpers.assert_eq(#errors, 0)
		helpers.assert_true(api.is_active())
		transport.probes[1].on_done({ ok = true, status = 200, body = '{"models":[{"name":"first"}]}' })
		helpers.assert_eq(#transport.requests, 1)
		transport.cancel_refused = false
		api.cancel()
		restore()
	end)

	helpers.it("classifies a model removed after the listing without treating every 404 as missing", function()
		local api, transport, restore = subject()
		local errors = {}
		api.chat("http://127.0.0.1:11434", "qwen2.5:7b", {}, { verify_local_model = true }, nil,
			function(_, err) errors[#errors + 1] = err end)
		transport.probes[1].on_done({ ok = true, status = 200, body = '{"models":[{"name":"qwen2.5:7b"}]}' })
		transport.requests[1].on_done({ ok = false, status = 404,
			error_body = '{"error":"model \'qwen2.5:7b\' not found"}' })
		helpers.assert_eq(#errors, 1)
		helpers.assert_eq(errors[1].reason, "model_missing")
		restore()
	end)
end)

helpers.describe("local model presence: independent shared corpus", function()
	helpers.it("replays normalization, exact model errors and strict listing receipts", function()
		local Policy = require("llm.local_model_policy")
		local Json = require("json")
		local fh = assert(io.open(require("infra.paths").shared("tests/corpus/llm/local_model_presence.json"), "rb"))
		local corpus = assert(Json.decode_lossless(fh:read("*a")))
		fh:close()
		for _, vector in ipairs(corpus.normalization) do
			local expected = not Json.is_null(vector.expected) and vector.expected or nil
			helpers.assert_eq(Policy.normalize(vector.name), expected, vector.name)
		end
		for _, vector in ipairs(corpus.missing_responses) do
			local expected = not Json.is_null(vector.expected) and vector.expected or nil
			helpers.assert_eq(Policy.missing_model(vector.status, vector.error), expected, vector.error)
		end
		for _, vector in ipairs(corpus.lists) do
			local names, reason = Policy.list_receipt(vector)
			helpers.assert_eq(reason, vector.reason, vector.body)
			if vector.reason then helpers.assert_nil(names) else
				local count = 0
				for _ in pairs(names) do count = count + 1 end
				helpers.assert_eq(count, #vector.names)
				for _, name in ipairs(vector.names) do helpers.assert_true(names[name]) end
			end
		end
	end)
end)

helpers.describe("local model presence: native consent and download owner", function()
	local function with_offer(deps, body)
		local name = "modules.llm.local_model_offer"
		local previous = package.loaded[name]
		package.loaded[name] = nil
		local Offer = require(name)
		Offer._reset_for_test(deps)
		local ok, err = xpcall(function() body(Offer) end, debug.traceback)
		Offer._reset_for_test()
		package.loaded[name] = previous
		if not ok then error(err, 0) end
	end

	helpers.it("never installs without an explicit affirmative confirmation", function()
		for _, choice in ipairs({ "cancel", "unavailable", "throws" }) do
			local confirmations, installations, notifications = 0, 0, 0
			with_offer({
				confirm = function()
					confirmations = confirmations + 1
					if choice == "throws" then error("native dialog failed") end
					if choice == "cancel" then return false end
					return nil
				end,
				install = function() installations = installations + 1; return true end,
				notify = function() notifications = notifications + 1; return true end,
			}, function(Offer)
				helpers.assert_true(Offer.handle(require("llm.local_model_policy").failure("qwen2.5:7b", "http://localhost:11434")))
			end)
			helpers.assert_eq(confirmations, 1)
			helpers.assert_eq(installations, 0)
			helpers.assert_eq(notifications, choice == "cancel" and 0 or 1)
		end
	end)

	helpers.it("delegates the exact model and origin only after user consent", function()
		local seen, notices, confirmations = nil, 0, 0
		with_offer({
			confirm = function() confirmations = confirmations + 1; return true end,
			install = function(base_url, model, callback)
				seen = { base_url = base_url, model = model, callback = callback }
				return true
			end,
			notify = function() notices = notices + 1; return true end,
		}, function(Offer)
			helpers.assert_true(Offer.handle(require("llm.local_model_policy").failure("qwen2.5vl:3b", "http://localhost:11435")))
			helpers.assert_eq(confirmations, 1)
			helpers.assert_eq(seen.base_url, "http://localhost:11435")
			helpers.assert_eq(seen.model, "qwen2.5vl:3b")
			helpers.assert_eq(type(seen.callback), "function")
			helpers.assert_eq(notices, 0)
		end)
	end)

	helpers.it("post-modal current owner refuses stale affirmative consent", function()
		local installs, current = 0, true
		with_offer({
			confirm = function() current = false; return true end,
			install = function() installs = installs + 1; return true end,
			notify = function() return true end,
		}, function(Offer)
			Offer.handle(require("llm.local_model_policy").failure("qwen2.5:7b", "http://localhost:11434"),
				{ current = function() return current end })
		end)
		helpers.assert_eq(installs, 0, "affirmative UI result cannot bypass a revoked requesting owner")
	end)

	helpers.it("automatic failures never open a dialog or pull and retry a refused notification", function()
		local posted, confirmed, installed, accepted, notice_text = 0, 0, 0, false, nil
		with_offer({
			confirm = function() confirmed = confirmed + 1; return true end,
			install = function() installed = installed + 1; return true end,
			notify = function(text)
				posted = posted + 1
				notice_text = text
				return accepted
			end,
		}, function(Offer)
			local Policy = require("llm.local_model_policy")
			Offer.handle(Policy.failure("Qwen2.5", "http://localhost:11434"), { automatic = true })
			accepted = true
			Offer.handle(Policy.failure("qwen2.5:latest", "http://localhost:11434"), { automatic = true })
			Offer.handle(Policy.failure("QWEN2.5", "http://localhost:11434"), { automatic = true })
		end)
		helpers.assert_eq(posted, 2)
		helpers.assert_eq(confirmed, 0)
		helpers.assert_eq(installed, 0)
		helpers.assert_true(not notice_text:find("Click", 1, true), "no unsupported click promise")
	end)

	helpers.it("a generic transport failure creates no download affordance", function()
		local effects = 0
		with_offer({
			confirm = function() effects = effects + 1 end,
			install = function() effects = effects + 1 end,
			notify = function() effects = effects + 1 end,
		}, function(Offer)
			helpers.assert_eq(Offer.handle("HTTP 404"), false)
			helpers.assert_eq(Offer.handle({ reason = "model_missing", model = "", base_url = "http://localhost:11434" }), false)
		end)
		helpers.assert_eq(effects, 0)
	end)
end)
