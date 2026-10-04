--- tests/unit/modules/llm/test_local_model_endpoint_identity.lua

--- ==============================================================================
--- MODULE: Ollama Inventory Endpoint Ownership
--- DESCRIPTION:
--- Drives the actual HTTP adapter through held native callbacks. Independent
--- endpoint, model and private-text sentinels qualify cache publication and
--- private POST admission across the request and menu HTTP owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local MODEL = "owned-endpoint-proof:latest"
local PRIVATE_TEXT = "owned private sentinel"
local ORIGIN_A = "http://127.0.0.1:11470"
local ORIGIN_B = "http://127.0.0.1:11471"

local function upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	error("Missing actual closure owner: " .. target)
end

local function with_world(body)
	return helpers.with_stub_scope({ "modules.llm.api_ollama", "modules.llm.ollama_endpoint", "adapters.http_client",
		"adapters.storage", "infra.logger", "adapters.timer_scheduler", "adapters.json_codec" }, function()
		local Api = helpers.load_with_stubs("modules.llm.api_ollama")
		local Storage = require("adapters.storage")
		local Json = require("json")
		local Logger = require("infra.logger")
		local world = { api = Api, gets = {}, posts = {}, failures = {}, successes = {} }
		world.client = upvalue(Api.request_chat, "_vision_client")
		world.listing = upvalue(Api.refresh_local_models, "_listing_client")
		function world.port(value)
			helpers.assert_true(Storage.set("llm.ollama_port", value))
			helpers.assert_eq(Api.get_base_url(), "http://127.0.0.1:" .. tostring(value), "the actual endpoint owner observes its current storage")
		end
		hs.http.asyncGet = function(url, _, callback)
			world.gets[#world.gets + 1] = { url = url, callback = callback }
			return nil
		end
		hs.http.asyncPost = function(url, encoded, _, callback)
			local decoded = assert(Json.decode(encoded))
			helpers.assert_eq(decoded.messages[1].content, PRIVATE_TEXT)
			world.posts[#world.posts + 1] = { url = url, callback = callback }
			return nil
		end
		function world.request(kind)
			local request = kind == "vision" and Api.request_vision or Api.request_chat
			request({ model = MODEL, messages = { { role = "user", content = PRIVATE_TEXT } } },
				function(text) world.successes[#world.successes + 1] = text end,
				function(reason, detail) world.failures[#world.failures + 1] = { reason = reason, detail = detail } end)
		end
		function world.listed(index, names)
			local rows = {}
			for position, name in ipairs(names) do rows[position] = { name = name } end
			world.gets[index].callback(200, assert(Json.encode({ models = Json.array(rows) })), {})
		end
		function world.answer(index)
			world.posts[index].callback(200, '{"message":{"content":"owned answer"}}', {})
		end
		world.port(11470)
		Api.forget_local_models()
		local old_logging = { info = Logger.info, debug = Logger.debug, error = Logger.error, warn = Logger.warn }
		local ok, failure = xpcall(function() body(world) end, debug.traceback)
		for level, original in pairs(old_logging) do Logger[level] = original end
		helpers.assert_true(world.client.cancel())
		helpers.assert_true(world.listing.cancel())
		if not ok then error(failure, 0) end
	end)
end

local function test(name, body)
	helpers.it(name .. " (ollama-model-endpoint-identity)", function() with_world(body) end)
end

helpers.describe("Ollama inventory endpoint receipts", function()
	for _, kind in ipairs({ "chat", "vision" }) do
		test("admits the unchanged " .. kind .. " endpoint and reuses only its acknowledged cache", function(world)
			world.request(kind)
			helpers.assert_eq(#world.gets, 1)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(world.gets[1].url, ORIGIN_A .. "/api/tags")
			world.listed(1, { MODEL })
			helpers.assert_eq(world.posts[1].url, ORIGIN_A .. "/api/chat")
			world.answer(1)
			world.request(kind)
			helpers.assert_eq(#world.gets, 1)
			helpers.assert_eq(world.posts[2].url, ORIGIN_A .. "/api/chat")
			world.answer(2)
			helpers.assert_eq(world.successes, { "owned answer", "owned answer" })
			helpers.assert_eq(#world.failures, 0)
		end)

		test("treats " .. kind .. " cache from another endpoint as unknown and obtains the new inventory", function(world)
			world.request(kind); world.listed(1, { MODEL }); world.answer(1)
			world.port(11471)
			helpers.assert_nil(world.api.local_model_installed(MODEL))
			world.request(kind)
			helpers.assert_eq(#world.gets, 2, "B must acknowledge its own inventory before receiving private bytes")
			helpers.assert_eq(world.gets[2].url, ORIGIN_B .. "/api/tags")
			helpers.assert_eq(#world.posts, 1)
			world.listed(2, {})
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_eq(world.api.local_model_installed(MODEL), false)
			helpers.assert_eq(world.failures[1].reason, "model_missing")
		end)

		test("refuses held " .. kind .. " inventory after the canonical endpoint changes", function(world)
			world.request(kind)
			world.port(11471)
			world.listed(1, { MODEL })
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_nil(world.api.local_model_installed(MODEL))
			helpers.assert_eq(#world.failures, 1)
			helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
			helpers.assert_nil(world.failures[1].detail, "an endpoint mismatch is not a missing-model offer")
		end)
	end

	test("prevents an older independent menu listing from replacing a newer acknowledged empty inventory", function(world)
		local menu_result, menu_reason
		world.api.refresh_local_models(function(ok, reason) menu_result, menu_reason = ok, reason end)
		world.request()
		world.listed(2, {})
		helpers.assert_eq(world.api.local_model_installed(MODEL), false)
		world.listed(1, { MODEL })
		helpers.assert_eq(world.api.local_model_installed(MODEL), false)
		helpers.assert_eq(menu_result, false)
		helpers.assert_eq(menu_reason, "model_list_unavailable")
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(#world.failures, 1)
		helpers.assert_eq(world.failures[1].reason, "model_missing")
	end)

	test("forgets pending inventory publication as well as already acknowledged model names", function(world)
		world.request()
		world.api.forget_local_models()
		world.listed(1, { MODEL })
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_nil(world.api.local_model_installed(MODEL))
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
		world.request(); world.listed(2, { MODEL }); world.answer(1)
		helpers.assert_eq(world.successes, { "owned answer" })
	end)

	test("preserves the adapter's exact cancelled-generation suppression", function(world)
		world.request()
		helpers.assert_true(world.client.cancel())
		world.listed(1, { MODEL })
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(#world.failures, 0)
		helpers.assert_nil(world.api.local_model_installed(MODEL))
	end)

	test("preserves superseded native callback suppression and the current missing-model receipt", function(world)
		world.request(); world.port(11471); world.request()
		world.listed(1, { MODEL })
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(#world.failures, 0)
		helpers.assert_nil(world.api.local_model_installed(MODEL))
		world.listed(2, {})
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(world.failures[1].reason, "model_missing")
		helpers.assert_eq(world.failures[1].detail.model, MODEL)
	end)

	test("keeps a malformed inventory unknown without admitting a private POST", function(world)
		world.request()
		world.gets[1].callback(200, '{"models":{}}', {})
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(world.failures[1].reason, "unreadable_model_list")
		helpers.assert_nil(world.api.local_model_installed(MODEL))
	end)

	test("rechecks endpoint identity after the last logging boundary before private POST", function(world)
		local Logger = require("infra.logger")
		local info = Logger.info
		Logger.info = function(topic, template, ...)
			if template == "%s request to the local server (model %s, %d byte(s))." then world.port(11471) end
			return info(topic, template, ...)
		end
		world.request(); world.listed(1, { MODEL })
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
		helpers.assert_nil(world.api.local_model_installed(MODEL))
	end)

	test("keeps a response from a replaced endpoint out of current text and missing-model admission", function(world)
		world.request(); world.listed(1, { MODEL })
		world.port(11471); world.answer(1)
		helpers.assert_eq(#world.successes, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
		helpers.assert_nil(world.api.local_model_installed(MODEL))
	end)

	for _, installed in ipairs({ false, true }) do
		test("refuses a verify result invalidated at the final inventory publication: installed=" .. tostring(installed), function(world)
			local Logger = require("infra.logger")
			local debug_log = Logger.debug
			Logger.debug = function(topic, template, ...)
				if template == "The local server returned a readable model list." then world.port(11471) end
				return debug_log(topic, template, ...)
			end
			local invoked, result, reason = false, "not invoked", nil
			world.api.verify_local_model(MODEL, function(value, detail) invoked, result, reason = true, value, detail end)
			world.listed(1, installed and { MODEL } or {})
			helpers.assert_true(invoked)
			helpers.assert_nil(result, "a changed endpoint cannot authorize either installed or missing")
			helpers.assert_eq(reason, "model_list_unavailable")
			helpers.assert_nil(world.api.local_model_installed(MODEL))
			helpers.assert_eq(#world.posts, 0)
		end)
	end

	test("does not offer a missing model after the final list consumer loses its endpoint", function(world)
		local Logger = require("infra.logger")
		local debug_log = Logger.debug
		Logger.debug = function(topic, template, ...)
			if template == "The local server returned a readable model list." then world.port(11471) end
			return debug_log(topic, template, ...)
		end
		world.request(); world.listed(1, {})
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
		helpers.assert_nil(world.failures[1].detail)
	end)

	test("rechecks an empty inventory after the last missing-model logging boundary", function(world)
		local Logger = require("infra.logger")
		local warn = Logger.warn
		Logger.warn = function(topic, template, ...)
			if template == "%s request not sent: the local server does not hold model %s." then world.port(11471) end
			return warn(topic, template, ...)
		end
		world.request(); world.listed(1, {})
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
		helpers.assert_nil(world.failures[1].detail)
	end)

	test("refuses stale text after the final successful response logging boundary", function(world)
		local Logger = require("infra.logger")
		local info = Logger.info
		Logger.info = function(topic, template, ...)
			if template == "%s answer of the local server received in %dms (%d char(s))." then world.port(11471) end
			return info(topic, template, ...)
		end
		world.request(); world.listed(1, { MODEL }); world.answer(1)
		helpers.assert_eq(#world.successes, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
	end)

	test("keeps an old endpoint's missing response from forgetting the newly acknowledged inventory", function(world)
		local Logger = require("infra.logger")
		local error_log = Logger.error
		Logger.error = function(topic, template, ...)
			if template == "%s request to the local server failed in %dms: HTTP %s (%s)." then
				world.port(11471)
				world.api.refresh_local_models()
				world.listed(2, { MODEL })
			end
			return error_log(topic, template, ...)
		end
		world.request(); world.listed(1, { MODEL })
		world.posts[1].callback(404, '{"error":"model \'owned-endpoint-proof:latest\' not found"}', {})
		helpers.assert_eq(#world.successes, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
		helpers.assert_nil(world.failures[1].detail)
		helpers.assert_eq(world.api.local_model_installed(MODEL), true, "B's newer inventory remains acknowledged")
	end)

	test("refuses stale empty-answer publication after its last logging boundary", function(world)
		local Logger = require("infra.logger")
		local warn = Logger.warn
		Logger.warn = function(topic, template, ...)
			if template == "%s answer of the local server holds no text (%dms)." then world.port(11471) end
			return warn(topic, template, ...)
		end
		world.request(); world.listed(1, { MODEL })
		world.posts[1].callback(200, '{"message":{"content":""}}', {})
		helpers.assert_eq(#world.successes, 0)
		helpers.assert_eq(world.failures[1].reason, "model_list_unavailable")
	end)

	test("preserves an admitted response across an independent refresh of the same endpoint", function(world)
		local Logger = require("infra.logger")
		local info = Logger.info
		Logger.info = function(topic, template, ...)
			if template == "%s answer of the local server received in %dms (%d char(s))." then
				world.api.refresh_local_models()
				world.listed(2, {})
			end
			return info(topic, template, ...)
		end
		world.request(); world.listed(1, { MODEL }); world.answer(1)
		helpers.assert_eq(world.successes, { "owned answer" })
		helpers.assert_eq(#world.failures, 0)
		helpers.assert_eq(world.api.local_model_installed(MODEL), false)
	end)
end)
