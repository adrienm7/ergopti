--- tests/unit/ai/engine/streaming/test_stream_retry_withdraws_partial.lua

--- ==============================================================================
--- MODULE: Stream Retry Withdraws Its Failed Partial
--- DESCRIPTION:
--- A sequential local variant streams its first attempt token by token, and a
--- failed attempt gets one quick retry inside the backend. The streaming
--- handler never learned that the streamed attempt had failed: its rows stayed
--- on offer during the retry, so Tab typed a completion the model had abandoned
--- (AIM-001). The backends now withdraw a failed stream through on_partial, and
--- the handler drops its rows. This replay drives the real engine, the real
--- streaming handler and the real backend sequential fetch; only the transport
--- is a double, which streams a partial, fails, and holds the retry
--- (stream-retry-withdraw).
--- ==============================================================================

local helpers = require("tests.helpers")
local load_fixture = require("tests.support.ai.prediction_pipeline").load

local PARTIAL = " and goodbye"
local RETRY = " see you soon"

--- Replaces one named upvalue of a function.
--- @param fn function Function owning the upvalue.
--- @param target string Upvalue name.
--- @param value any Replacement value.
--- @return boolean replaced
local function set_upvalue(fn, target, value)
	for index = 1, 80 do
		local name = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then
			debug.setupvalue(fn, index, value)
			return true
		end
	end
	return false
end

local BACKENDS = {
	{
		name = "Ollama",
		module_name = "ai.engine.api.ollama",
		configure = function(module, plain, stream)
			local fetch = module.fetch_sequential
			helpers.assert_true(set_upvalue(fetch, "post_and_parse", plain))
			helpers.assert_true(set_upvalue(fetch, "post_and_parse_streaming", stream))
		end,
	},
	{
		name = "MLX",
		module_name = "ai.engine.api.mlx_fetch",
		configure = function(module, plain, stream)
			module.init({ post_and_parse = plain, post_and_parse_streaming = stream, dedup_enabled = false })
		end,
	},
}

--- What Tab would type now: the selected row while the tooltip is on offer.
--- @param engine table The real prediction engine.
--- @return string|nil to_type
local function tab_would_type(engine)
	if not engine.is_visible() then return nil end
	local row = engine.get_predictions()[1]
	return row and row.to_type or nil
end

--- Replays one streamed, failed then retried variant through the real pipeline.
--- @param backend table BACKENDS entry.
--- @param during function Receives the fixture while the retry is in flight.
--- @return table fixture
local function replay(backend, during)
	local fixture = load_fixture({ render_success = true, streaming_multi = true })
	fixture.engine.perform_check(true)
	helpers.assert_eq(fixture.fetches, 1, "the real engine dispatches")
	helpers.assert_eq(type(fixture.on_partial), "function", "streaming multi hands the backend a partial port")
	local held
	helpers.with_stub_scope({ backend.module_name, "ai.engine.settings.profiles", "core.network.adapters.http_client",
		"core.events.timer_scheduler", "core.process.adapters.shell_runner" }, function()
		local module = helpers.load_with_stubs(backend.module_name, {
			application = { frontmostApplication = function()
				return { title = function() return "FixtureApp" end }
			end },
		})
		helpers.assert_true(set_upvalue(module.fetch_sequential, "Profiles",
			{ resolve_system_prompt = function() return "system" end }))
		backend.configure(module,
			function(...)
				local args = { ... }
				held = args[9]
			end,
			function(...)
				local args = { ... }
				args[12](PARTIAL)
				helpers.assert_eq(tab_would_type(fixture.engine), PARTIAL, "the partial is on offer while it streams")
				args[10]({ reason = "transport" })
			end)
		module.fetch_sequential("hello world", "", "test-model", 0.5, 20, 1, {},
			fixture.on_success, fixture.on_fail, function() return 1 end, true, fixture.on_partial)
		helpers.assert_eq(type(held), "function", "the failed stream got its quick retry")
		during(fixture)
		held({ { to_type = RETRY, deletes = 0, chunks = { { type = "insert", text = RETRY } }, nw = "" } })
	end)
	return fixture
end

helpers.describe("stream retry withdraws its failed partial (stream-retry-withdraw)", function()
	for _, backend in ipairs(BACKENDS) do
		helpers.it("(stream-retry-withdraw) " .. backend.name .. ": Tab during the retry never types the partial", function()
			local fixture = replay(backend, function(f)
				helpers.assert_true(tab_would_type(f.engine) ~= PARTIAL, "the abandoned completion is off offer")
				helpers.assert_eq(f.engine.is_visible(), false, "nothing is on offer until the retry answers")
			end)
			helpers.assert_eq(tab_would_type(fixture.engine), RETRY, "the retry's completion is offered")
		end)
	end
end)

return true
