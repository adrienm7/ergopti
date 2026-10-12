--- tests/unit/modules/llm/test_backend_detection_endpoint_identity.lua

--- ==============================================================================
--- MODULE: Local Backend Discovery Endpoint Regression
--- DESCRIPTION:
--- Checks configured origins and complete Ollama version receipts through the
--- actual core over deferred native HTTP ports. No native service is qualified.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_world(body)
	return helpers.with_stub_scope({ "modules.llm", "modules.llm.api_ollama", "modules.llm.api_mlx",
		"modules.llm.ollama_endpoint", "adapters.storage", "infra.logger" }, function()
		local Core = helpers.load_with_stubs("modules.llm")
		local Storage = require("adapters.storage")
		local world = { core = Core, probes = {}, completions = {} }
		hs.timer.secondsSinceEpoch = function() return 100 end
		hs.http.asyncGet = function(url, _, callback)
			world.probes[#world.probes + 1] = { url = url, callback = callback }
		end
		function world.port(port) helpers.assert_true(Storage.set("llm.ollama_port", port)) end
		function world.detect()
			Core.auto_detect_backend(function(backend) world.completions[#world.completions + 1] = backend end)
		end
		function world.answer(first, status, receipt)
			world.probes[first].callback(status, receipt)
			world.probes[first + 1].callback(404, "")
		end
		world.port(11470)
		body(world)
	end)
end

helpers.describe("local backend discovery owns the configured endpoint", function()
	helpers.it("(backend-discovery-origin) connection warmup uses the canonical configured origins", function()
		with_world(function(world)
			world.core.warm_up_connections()
			helpers.assert_eq(#world.probes, 2)
			helpers.assert_eq(world.probes[1].url, "http://127.0.0.1:11470/api/version")
			helpers.assert_eq(world.probes[2].url, require("modules.llm.api_mlx").get_base_url() .. "/v1/models")
		end)
	end)

	helpers.it("(backend-discovery-origin) detection reads the configured Ollama version endpoint", function()
		with_world(function(world)
			world.detect()
			helpers.assert_eq(world.probes[1].url, "http://127.0.0.1:11470/api/version")
			world.answer(1, 200, '{"version":"0.24.0"}')
			helpers.assert_eq(world.completions, { "ollama" })
		end)
	end)

	helpers.it("(backend-discovery-origin) malformed and null version tokens are not server receipts", function()
		for _, receipt in ipairs({ 'not JSON "version"', '{"version":null}', '{"version":""}', '[{"version":"0.24.0"}]' }) do
			with_world(function(world)
				world.detect()
				world.answer(1, 200, receipt)
				helpers.assert_eq(world.completions, { "inconnu" }, receipt)
			end)
		end
	end)

	helpers.it("(backend-discovery-origin) a held version response cannot publish after an endpoint change", function()
		with_world(function(world)
			world.detect()
			world.port(11471)
			world.answer(1, 200, '{"version":"0.24.0"}')
			helpers.assert_eq(world.completions, {})
			world.detect()
			helpers.assert_eq(#world.probes, 4, "retry must acquire the new endpoint instead of stale cache")
			helpers.assert_eq(world.probes[3].url, "http://127.0.0.1:11471/api/version")
		end)
	end)

	helpers.it("(backend-discovery-origin) cached discovery is invalidated by a configured endpoint change", function()
		with_world(function(world)
			world.detect()
			world.answer(1, 200, '{"version":"0.24.0"}')
			world.detect()
			helpers.assert_eq(#world.probes, 2, "an unchanged endpoint reuses its recent cache")
			world.port(11471)
			world.detect()
			helpers.assert_eq(#world.probes, 4)
			helpers.assert_eq(world.probes[3].url, "http://127.0.0.1:11471/api/version")
		end)
	end)

	helpers.it("(backend-discovery-origin) an in-flight sweep cannot publish a cached success", function()
		with_world(function(world)
			world.detect()
			world.detect()
			helpers.assert_eq(#world.probes, 4, "a newer request supersedes an unpublished sweep")
			helpers.assert_eq(world.completions, {}, "only a completed sweep can provide a cache receipt")
			world.answer(1, 200, '{"version":"0.24.0"}')
			helpers.assert_eq(world.completions, {}, "the superseded sweep remains unpublished")
			world.answer(3, 200, '{"version":"0.24.0"}')
			helpers.assert_eq(world.completions, { "ollama" })
		end)
	end)
end)
