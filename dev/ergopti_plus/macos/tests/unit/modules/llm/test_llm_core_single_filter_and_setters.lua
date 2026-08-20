--- tests/unit/modules/llm/test_llm_core_single_filter_and_setters.lua

--- ==============================================================================
--- MODULE: Regression — one app filter, and setters that record what they applied
--- DESCRIPTION:
--- core_llm.fetch_llm_prediction carried a SECOND copy of the app-exclusion
--- filter that read hs.settings.get("llm_disabled_apps") — a key nothing in the
--- tree ever writes, because the real setter keeps the list in module state. The
--- copy could therefore never block anything, and had drifted from the live one
--- in app_filter.lua besides.
---
--- ROOT CAUSE ENCODED:
--- Two implementations of "may this application receive a prediction?". The fix
--- deletes one rather than reconciling them, which is the same move the tooltip/
--- engine divergence needed: agreement today is not a guarantee of agreement.
---
--- The runtime LLM gate and the backend setter also logged nothing, leaving the
--- two settings most often blamed in a bug report ("why did it warm up while
--- disabled?") unreadable from the log.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("llm core: exactly one app-exclusion filter", function()

	helpers.it("core_llm no longer reads the settings key nothing writes", function()
		local src = helpers.read_driver_source("fetch_llm_prediction")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the llm core source must be readable or this asserts nothing")
		-- Comments stripped first: the explanatory note left where the dead filter
		-- used to be MENTIONS the key, and a raw search matched that prose. Exactly
		-- the trap this repo keeps recording — a mention is not a call site.
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find('hs.settings.get("llm_disabled_apps")', 1, true) == nil,
			"the duplicate filter read a settings key with no writer, so it could never block "
			.. "anything; the live filter is app_filter.is_blocked, applied by prediction_engine")
	end)

	helpers.it("the live filter still exists", function()
		local AppFilter = require("modules.llm.app_filter")
		helpers.assert_type(AppFilter.is_blocked, "function",
			"deleting the dead copy must not leave the driver with no filter at all")
	end)

end)

helpers.describe("llm core: the gate and the backend setter record what they applied", function()

	helpers.it("set_runtime_llm_enabled logs both transitions", function()
		local logged = {}
		package.loaded["infra.logger"] = {
			debug = function(_l, fmt, ...) table.insert(logged, string.format(fmt, ...)) end,
			info = function() end, warn = function() end, error = function() end,
			trace = function() end, done = function() end, start = function() end,
			success = function() end, pcall = function(_l, fn, ...) return pcall(fn, ...) end,
		}
		package.loaded["modules.llm"] = nil
		local core = helpers.load_with_stubs("modules.llm")

		core.set_runtime_llm_enabled(true)
		core.set_runtime_llm_enabled(false)

		-- Count only the GATE's own lines. Counting every debug call written during
		-- module load passed against a setter that logged nothing at all.
		local gate_lines = 0
		for _, line in ipairs(logged) do
			if line:lower():find("runtime llm gate", 1, true) then gate_lines = gate_lines + 1 end
		end
		helpers.assert_true(gate_lines >= 2,
			"this flag is the one gate that authorises a model load or a warmup; its "
			.. "transitions are exactly what a 'why did it warm up while disabled?' report needs")
	end)

end)
