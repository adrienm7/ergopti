--- tests/unit/modules/llm/prediction/test_fetch_strategy_follows_shared_batching.lua

--- ==============================================================================
--- MODULE: Regression — the fetch strategy follows the shared batching rule
--- DESCRIPTION:
--- core_llm.fetch_llm_prediction took the batch path for every batch profile,
--- even when one prediction was asked. The shared prompt selector builds a batch
--- prompt only above one prediction (a single one gets the plain prompt), and
--- Windows and Linux make one plain call for it, so macOS asked for a batch
--- parse of a prompt that never asked for a batch.
---
--- ROOT CAUSE ENCODED:
--- The rule "a batch profile is a batch only above one prediction" was decided
--- separately by each driver. It now comes from _shared/lua/llm/request_plan/
--- batching.lua, replayed by the shared contract on both drivers; this case pins
--- that macOS dispatch obeys it.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm"] = nil
local core = helpers.load_with_stubs("modules.llm")
local ApiOllama = require("modules.llm.api_ollama")

--- Dispatches one request with the given profile and count against recorders.
--- @param profile table The profile to run.
--- @param count number The predictions asked for.
--- @param sequential_mode boolean|nil The menu's sequential switch.
--- @return string|nil strategy "batch", "parallel" or "sequential"; nil when nothing was dispatched.
local function dispatch(profile, count, sequential_mode)
	local saved = {
		fetch_batch = ApiOllama.fetch_batch,
		fetch_parallel = ApiOllama.fetch_parallel,
		fetch_sequential = ApiOllama.fetch_sequential,
	}
	local strategy
	ApiOllama.fetch_batch = function() strategy = "batch" end
	ApiOllama.fetch_parallel = function() strategy = "parallel" end
	ApiOllama.fetch_sequential = function() strategy = "sequential" end
	local ok, err = pcall(core.fetch_llm_prediction, "context", "tail", "model", 0.1, 20, count,
		function() end, function() end, sequential_mode, false, nil, nil, profile)
	for name, fn in pairs(saved) do ApiOllama[name] = fn end
	assert(ok, err)
	return strategy
end

helpers.describe("llm core: the fetch strategy of a prediction request", function()
	helpers.it("a batch profile asks once for several predictions", function()
		helpers.assert_eq(dispatch({ id = "b", batch = true }, 3), "batch")
	end)

	helpers.it("a batch profile with one prediction makes one plain call", function()
		helpers.assert_eq(dispatch({ id = "b", batch = true }, 1), "sequential")
	end)

	helpers.it("a plain profile asks once per variant", function()
		helpers.assert_eq(dispatch({ id = "p", batch = false }, 3), "parallel")
		helpers.assert_eq(dispatch({ id = "p", batch = false }, 3, true), "sequential")
		helpers.assert_eq(dispatch({ id = "p", batch = false }, 1), "sequential")
	end)
end)

return true
