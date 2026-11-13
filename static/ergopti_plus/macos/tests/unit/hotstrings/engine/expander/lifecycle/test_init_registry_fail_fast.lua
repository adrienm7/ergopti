--- tests/unit/hotstrings/engine/expander/lifecycle/test_init_registry_fail_fast.lua

--- ==============================================================================
--- MODULE: Keymap Registry Startup Fail-Fast
--- DESCRIPTION:
--- Proves that a refused registry initialization aborts the parent keymap load
--- before either downstream consumer can publish state against an uninitialized
--- registry.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads keymap/init.lua against controllable lifecycle commitments.
--- Every package override is restored even when an assertion raises.
--- @param results table Exact results for registry, llm, and expander.
--- @return table outcome Loader result, error, and dependency call counters.
local function load_keymap_with_results(results)
	local outcome = {
		registry_calls = 0,
		llm_calls = 0,
		expander_calls = 0,
	}
	local saved = {}
	local stubs = {
		["core.text.engine.utils"] = {},
		["diagnostics.adapters.event_provenance"] = {},
		["platform.input.synthetic_input"] = {
			current_action_epoch = function() return 0 end,
		},
		["hotstrings.engine.expander.utils"] = {},
		["platform.input.text_sender"] = {},
		["ai.engine.prediction.app_filter"] = {},
		-- The real timing registry, read when the keymap loads, logs its path walk.
		["core.logger.engine.logger"] = helpers.make_logger_stub(),
		["platform.input.keycodes"] = {},
		["menu.engine.manifest_reader"] = {
			default_for = function() return true end,
		},
		["settings.engine.registry"] = {
			is_repeat_feature_enabled = function() return false end,
			set_repeat_feature_enabled = function() end,
			init = function()
				outcome.registry_calls = outcome.registry_calls + 1
				return results.registry
			end,
		},
		["hotstrings.engine.expander.expander"] = {
			init = function()
				outcome.expander_calls = outcome.expander_calls + 1
				return results.expander
			end,
		},
		["ai.engine.bridge"] = {
			init = function()
				outcome.llm_calls = outcome.llm_calls + 1
				return results.llm
			end,
		},
		["hotstrings.engine.expander.state"] = {
			new = function() return {} end,
		},
		["hotstrings.engine.expander.terminator_replay"] = {},
		["layouts.engine.layers.terminators"] = {},
		["core.logger.engine.perf"] = {},
		["infra.hotpath_profiler"] = {},
		["diagnostics.engine.hid_diagnostic_mailbox"] = {},
	}

	saved["hotstrings.engine.expander"] = package.loaded["hotstrings.engine.expander"]
	package.loaded["hotstrings.engine.expander"] = nil
	for name, stub in pairs(stubs) do
		saved[name] = package.loaded[name]
		package.loaded[name] = stub
	end
	outcome.loaded, outcome.load_error = pcall(require, "hotstrings.engine.expander")
	package.loaded["hotstrings.engine.expander"] = saved["hotstrings.engine.expander"]
	for name in pairs(stubs) do package.loaded[name] = saved[name] end
	return outcome
end


helpers.describe("keymap init: dependency commitment is transitive", function()
	helpers.it("aborts before LLMBridge and Expander when Registry.init refuses", function()
		local outcome = load_keymap_with_results({ registry = false, llm = true, expander = true })
		helpers.assert_eq(outcome.loaded, false,
			"a refused registry initialization must abort the parent module load")
		helpers.assert_true(tostring(outcome.load_error):find(
			"Keymap registry initialization did not commit.", 1, true
		) ~= nil, "the fail-fast error must identify the rejected dependency")
		helpers.assert_eq(outcome.registry_calls, 1)
		helpers.assert_eq(outcome.llm_calls, 0,
			"LLMBridge must not observe an uninitialized registry state")
		helpers.assert_eq(outcome.expander_calls, 0,
			"Expander must not observe an uninitialized registry state")
	end)

	helpers.it("aborts before Expander when LLMBridge.init refuses", function()
		local outcome = load_keymap_with_results({ registry = true, llm = false, expander = true })
		helpers.assert_eq(outcome.loaded, false)
		helpers.assert_true(tostring(outcome.load_error):find(
			"Keymap LLM bridge initialization did not commit.", 1, true
		) ~= nil, "the fail-fast error must identify the rejected LLM bridge")
		helpers.assert_eq(outcome.registry_calls, 1)
		helpers.assert_eq(outcome.llm_calls, 1)
		helpers.assert_eq(outcome.expander_calls, 0,
			"Expander must not publish after the LLM bridge refused")
	end)

	helpers.it("aborts the module load when Expander.init refuses", function()
		local outcome = load_keymap_with_results({ registry = true, llm = true, expander = false })
		helpers.assert_eq(outcome.loaded, false)
		helpers.assert_true(tostring(outcome.load_error):find(
			"Keymap expander initialization did not commit.", 1, true
		) ~= nil, "the fail-fast error must identify the rejected expander")
		helpers.assert_eq(outcome.registry_calls, 1)
		helpers.assert_eq(outcome.llm_calls, 1)
		helpers.assert_eq(outcome.expander_calls, 1)
	end)
end)
