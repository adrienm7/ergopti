--- tests/unit/modules/llm/test_ollama_warmup_endpoint_identity.lua

--- ==============================================================================
--- MODULE: Ollama Warmup Endpoint Receipt Regression
--- DESCRIPTION:
--- Drives the real API and HTTP owner with held native response callbacks.
--- These controls prove receipt freshness, never native model/server acceptance.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_world(body)
	return helpers.with_stub_scope({ "modules.llm.api_ollama", "modules.llm.ollama_endpoint",
		"adapters.http_client", "adapters.storage", "infra.logger", "infra.notifications",
		"adapters.timer_scheduler", "adapters.json_codec" }, function()
		local Api = helpers.load_with_stubs("modules.llm.api_ollama")
		local Storage = require("adapters.storage")
		local Notices = require("infra.notifications")
		local world = { api = Api, posts = {}, notices = 0 }
		Notices.notify = function() world.notices = world.notices + 1; return true end
		hs.http.asyncPost = function(url, _, _, callback)
			world.posts[#world.posts + 1] = { url = url, callback = callback }
			return nil
		end
		function world.port(port)
			helpers.assert_true(Storage.set("llm.ollama_port", port))
		end
		function world.answer(index)
			world.posts[index].callback(200, '{"done":true,"message":{"content":""}}', {})
		end
		world.port(11470)
		local ok, err = xpcall(function() body(world) end, debug.traceback)
		helpers.assert_true(Api.stop_warmup())
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Ollama warmup keeps its originating endpoint", function()
	helpers.it("(ollama-warmup-origin) discards a held response after the configured port changes", function()
		with_world(function(world)
			helpers.assert_true(world.api.warmup("model-a"))
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_eq(world.posts[1].url, "http://127.0.0.1:11470/api/chat")
			world.port(11471)
			world.answer(1)
			helpers.assert_eq(world.api.is_ready(), false,
				"a response from the former endpoint cannot qualify the new endpoint")
			helpers.assert_eq(world.notices, 0)
		end)
	end)

	helpers.it("(ollama-warmup-origin) forgets an acknowledged ready endpoint when the port changes", function()
		with_world(function(world)
			helpers.assert_true(world.api.warmup("model-a"))
			world.answer(1)
			helpers.assert_true(world.api.is_ready())
			world.port(11471)
			helpers.assert_eq(world.api.is_ready(), false,
				"a cached readiness receipt cannot survive an endpoint replacement")
			helpers.assert_true(world.api.warmup("model-a"))
			helpers.assert_eq(world.posts[2].url, "http://127.0.0.1:11471/api/chat")
			world.answer(2)
			helpers.assert_true(world.api.is_ready())
			helpers.assert_eq(world.notices, 2, "each endpoint must acknowledge its own warmup")
		end)
	end)
end)
