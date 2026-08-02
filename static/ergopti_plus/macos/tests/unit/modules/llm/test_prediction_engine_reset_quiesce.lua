--- tests/unit/modules/llm/test_prediction_engine_reset_quiesce.lua

--- ==============================================================================
--- MODULE: Regression — reset() fully quiesces stream + deferred state
--- DESCRIPTION:
--- Audit findings F-L11 and F-L12.
---   F-L11: reset() gated core_llm.cancel_streaming() behind is_streaming_enabled,
---          so toggling streaming OFF while a stream was in flight left the curl
---          task running (and on MLX held the single-request connection). Cancel
---          must be UNCONDITIONAL (it is a null-safe no-op when nothing streams).
---   F-L12: reset() never cleared _deferred_profile_name, so a rate-limit deferral
---          torn down by reset() leaked a stale profile label into the NEXT
---          unrelated prediction's info bar. reset() must clear it.
--- reset() needs the full engine + core_llm stub stack to drive; both fixes are
--- single statements inside M.reset(), pinned here at source.
--- ==============================================================================

local helpers = require("tests.helpers")

local function reset_body()
	-- Selected by a declaration unique to modules/llm/prediction_engine.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function compute_adaptive_debounce")
	helpers.assert_true(src ~= nil, "modules/llm/prediction_engine.lua source must be locatable")
	local s = src:find("function M.reset()", 1, true)
	helpers.assert_true(s ~= nil, "prediction_engine must define M.reset()")
	local e = src:find("\nend", s, true)
	return src:sub(s, e or (s + 2000))
end

helpers.describe("prediction_engine.reset() quiesces stream + deferred state", function()
	helpers.it("F-L11: cancels streaming UNCONDITIONALLY (not gated on is_streaming_enabled)", function()
		local body = reset_body()
		helpers.assert_true(body:find("pcall(core_llm.cancel_streaming)", 1, true) ~= nil,
			"reset() must call pcall(core_llm.cancel_streaming) unconditionally")
		helpers.assert_true(body:find("if is_streaming_enabled then pcall(core_llm.cancel_streaming)", 1, true) == nil,
			"reset() must NOT gate cancel_streaming behind is_streaming_enabled (leaks the in-flight curl)")
	end)

	helpers.it("F-L12: clears _deferred_profile_name", function()
		local body = reset_body()
		helpers.assert_true(body:find("_deferred_profile_name", 1, true) ~= nil
			and body:find("_deferred_profile_name%s*=%s*nil") ~= nil,
			"reset() must clear _deferred_profile_name so a torn-down deferral cannot mislabel the next prediction")
	end)
end)
