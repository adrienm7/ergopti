--- tests/unit/modules/llm/test_context_length_effective.lua

--- ==============================================================================
--- MODULE: Regression — llm_context_length setting is no longer a silent no-op (M-8)
--- DESCRIPTION:
--- Before M-8, prediction_engine stored the user-configured context_window_chars
--- but never forwarded it to PromptBuilder.build_params(). cap_context() therefore
--- ignored it and used the max_words*40 heuristic regardless of the setting.
---
--- Fix: context_window_chars is threaded from perform_check → PromptBuilder.build
--- (HS shim) → Shared.build_params() → cap_context(). When context_window_chars>0
--- it overrides the heuristic and becomes the hard char cap on the context sent.
---
--- Tests:
---   1. Shared build_params: context_window_chars=200 caps a 2000-char buffer.
---   2. Shared build_params: context_window_chars=0 falls back to max_words heuristic.
---   3. HS shim M.build: context_window_chars forwarded from config.
---   4. Source check: prediction_engine passes context_window_chars to PromptBuilder.build.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Inject the _shared/lua/ path so the shared prompt_builder can be required
local _shared_lua = helpers.shared("lua")
local _entry = _shared_lua .. "/?.lua"
if not package.path:find(_entry, 1, true) then
	package.path = _entry .. ";" .. package.path
end

-- Load the shared module under its canonical path
local ok_shared, SharedPB = pcall(require, "llm.prompt_builder")

local LONG_BUFFER = ("x "):rep(1000)  -- 2000 chars, well over any heuristic cap





-- ===============================================================================
-- ===============================================================================
-- ======= 1/ Shared build_params: context_window_chars caps context (M-8) =======
-- ===============================================================================
-- ===============================================================================

helpers.describe("M-8: context_window_chars is honoured in build_params", function()

	helpers.it("shared module is loadable", function()
		helpers.assert_true(ok_shared,
			"_shared/lua/llm/prompt_builder.lua must be loadable — check path: " .. _shared_lua)
	end)

	helpers.it("context_window_chars=200 caps a 2000-char buffer to ≤200 chars", function()
		if not ok_shared then return end
		local p = SharedPB.build_params(LONG_BUFFER, {
			max_words            = 0,
			context_window_chars = 200,
		})
		helpers.assert_true(type(p.context) == "string",
			"build_params must return a context string")
		helpers.assert_true(#p.context <= 200,
			string.format("context must be ≤200 chars when context_window_chars=200, got %d", #p.context))
	end)

	helpers.it("context_window_chars=0 with max_words=0 returns the full buffer", function()
		if not ok_shared then return end
		local short = "hello world"
		local p = SharedPB.build_params(short, {
			max_words            = 0,
			context_window_chars = 0,
		})
		helpers.assert_eq(p.context, short,
			"with max_words=0 and no char cap the full buffer must be returned unchanged")
	end)

	helpers.it("context_window_chars=0 still applies the max_words heuristic", function()
		if not ok_shared then return end
		-- max_words=2 → heuristic cap = max(100, 2*40)=100; buffer is 2000 chars
		local p = SharedPB.build_params(LONG_BUFFER, {
			max_words            = 2,
			context_window_chars = 0,
		})
		helpers.assert_true(#p.context <= 100,
			string.format("max_words=2 heuristic cap must still apply when context_window_chars=0, got %d", #p.context))
	end)
end)





-- ==================================================================================
-- ==================================================================================
-- ======= 2/ HS shim M.build forwards context_window_chars from config (M-8) =======
-- ==================================================================================
-- ==================================================================================

helpers.describe("M-8: HS prompt_builder shim threads context_window_chars", function()

	helpers.it("M.build with context_window_chars=200 returns context ≤200 chars", function()
		if not ok_shared then return end
		-- Load the HS shim with the real shared module (not a stub)
		package.loaded["modules.llm.prompt_builder"] = nil
		-- The shim requires "llm.prompt_builder" which is already in package.loaded from above
		helpers.load_with_stubs("infra.logger")
		local ok_shim, ShimPB = pcall(require, "modules.llm.prompt_builder")
		helpers.assert_true(ok_shim, "modules.llm.prompt_builder shim must be loadable")

		local result, skip, _sig = ShimPB.build(LONG_BUFFER, {
			max_words            = 0,
			min_words            = 1,
			num_predictions      = 1,
			temperature          = 0.1,
			auto_raise_temperature = false,
			context_window_chars = 200,
		}, nil, true)  -- force_trigger=true to bypass freshness guard

		helpers.assert_true(result ~= nil, "shim M.build must not return nil when force_trigger=true")
		helpers.assert_true(#result.context_buffer <= 200,
			string.format("context_buffer must be ≤200 chars when context_window_chars=200, got %d",
				#(result and result.context_buffer or "")))
	end)
end)





-- ===============================================================================================
-- ===============================================================================================
-- ======= 3/ Source: prediction_engine passes context_window_chars to PromptBuilder (M-8) =======
-- ===============================================================================================
-- ===============================================================================================

helpers.describe("M-8: prediction_engine wires context_window_chars (source)", function()

	helpers.it("prediction_engine.lua passes context_window_chars in PromptBuilder.build config", function()
		-- Selected by a declaration unique to modules/llm/prediction_engine.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function compute_adaptive_debounce")
		helpers.assert_true(src ~= nil, "modules/llm/prediction_engine.lua source must be locatable")
		helpers.assert_true(src:find("context_window_chars", 1, true) ~= nil,
			"prediction_engine.lua must pass context_window_chars into PromptBuilder.build so the user setting takes effect (M-8)")
	end)
end)
