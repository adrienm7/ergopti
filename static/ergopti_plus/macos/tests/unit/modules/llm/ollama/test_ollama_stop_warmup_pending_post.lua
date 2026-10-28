--- tests/unit/modules/llm/ollama/test_ollama_stop_warmup_pending_post.lua

--- ==============================================================================
--- MODULE: Ollama Warmup Stop With A Held POST Regression
--- DESCRIPTION:
--- hs.http.asyncPost returns no cancellable task, so a warmup POST still in
--- flight can only be revoked logically: its late answer is fenced by the
--- generation. stop_warmup() reported that as "could not retire its HTTP owner"
--- and the settlement 'Ollama warmup stop' did not commit (field session
--- 2026-10-27, when the startup declined the model download). The revocation
--- has happened, so the stop commits; the late answer still changes nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_world(body)
	return helpers.with_stub_scope({ "modules.llm.api_ollama", "modules.llm.ollama_endpoint",
		"adapters.http_client", "adapters.storage", "infra.logger", "infra.notifications",
		"adapters.timer_scheduler", "adapters.json_codec" }, function()
		local Api = helpers.load_with_stubs("modules.llm.api_ollama")
		local Storage = require("adapters.storage")
		local Logger = require("infra.logger")
		local world = { api = Api, posts = {}, errors = {} }
		local original_error = Logger.error
		Logger.error = function(_, fmt, ...)
			world.errors[#world.errors + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		end
		hs.http.asyncPost = function(url, _, _, callback)
			world.posts[#world.posts + 1] = { url = url, callback = callback }
			return nil
		end
		helpers.assert_true(Storage.set("llm.ollama_owned_port", 11470))
		local ok, err = xpcall(function() body(world) end, debug.traceback)
		Logger.error = original_error
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Ollama warmup stop with a held POST", function()
	helpers.it("commits the stop of a taskless in-flight warmup and fences its answer", function()
		with_world(function(world)
			helpers.assert_true(world.api.warmup("model-a"))
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_true(world.api.stop_warmup(),
				"a logically revoked taskless POST is a committed stop")
			helpers.assert_eq(#world.errors, 0, "no ERROR for an ordinary stop: " .. table.concat(world.errors, " | "))
			world.posts[1].callback(200, '{"done":true,"message":{"content":""}}', {})
			helpers.assert_eq(world.api.is_ready(), false, "the revoked answer cannot mark the model ready")
			helpers.assert_true(world.api.stop_warmup(), "the stop stays committed once the POST answered")
		end)
	end)
end)
