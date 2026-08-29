--- tests/unit/modules/keymap/test_init_dependency_commit_chain.lua

--- ==============================================================================
--- MODULE: Keymap Dependency Initialization Commit Chain
--- DESCRIPTION:
--- Exercises each nested initialization boundary behaviorally. A parent may
--- publish its own state only after its child returns literal true, and duplicate
--- initialization must never replace the active dependency set.
--- ==============================================================================

local helpers = require("tests.helpers")

local function noop() end

local LOGGER_STUB = {
	start = noop,
	success = noop,
	error = noop,
	warn = noop,
	debug = noop,
	info = noop,
	trace = noop,
	done = noop,
}

--- Loads one fresh target with scoped package overrides and restores every
--- package entry after success or failure.
--- @param target string
--- @param stubs table<string, table>
--- @param callback function
local function with_stubbed_module(target, stubs, callback)
	local saved = { [target] = package.loaded[target] }
	package.loaded[target] = nil
	for name, stub in pairs(stubs or {}) do
		saved[name] = package.loaded[name]
		package.loaded[name] = stub
	end
	local ok, err = xpcall(function()
		callback(require(target))
	end, debug.traceback)
	package.loaded[target] = saved[target]
	for name in pairs(stubs or {}) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end


helpers.describe("registry init: nested commitments and ownership", function()
	helpers.it("refuses to publish Registry state when registry_index.setup refuses", function()
		local group_calls = 0
		local index_calls = 0
		with_stubbed_module("modules.keymap.registry", {
			["modules.keymap.registry_groups"] = {
				init = function()
					group_calls = group_calls + 1
					return true
				end,
			},
			["modules.keymap.registry_index"] = {
				setup = function()
					index_calls = index_calls + 1
					return false
				end,
			},
		}, function(registry)
			local State = require("modules.keymap.state")
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			helpers.assert_eq(registry.init(state), false)
			helpers.assert_eq(group_calls, 1)
			helpers.assert_eq(index_calls, 1)
			registry.add("unpublished", "UNPUBLISHED", { is_case_sensitive = true })
			helpers.assert_eq(#state.mappings, 0,
				"Registry must remain guarded after registry_index.setup refuses")
		end)
	end)

	helpers.it("Registry accepts only the exact active state on duplicate init", function()
		local group_calls = 0
		local index_calls = 0
		with_stubbed_module("modules.keymap.registry", {
			["modules.keymap.registry_groups"] = {
				init = function()
					group_calls = group_calls + 1
					return true
				end,
			},
			["modules.keymap.registry_index"] = {
				setup = function()
					index_calls = index_calls + 1
					return true
				end,
			},
		}, function(registry)
			local State = require("modules.keymap.state")
			local state1 = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			local state2 = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			helpers.assert_eq(registry.init(state1), true)
			helpers.assert_eq(registry.init(state1), true)
			helpers.assert_eq(registry.init(state2), false)
			helpers.assert_eq(group_calls, 1,
				"duplicates must not reinitialize the group dependency")
			helpers.assert_eq(index_calls, 1,
				"duplicates must not reinitialize the index dependency")
			registry.add("owner", "OWNER", { is_case_sensitive = true })
			helpers.assert_eq(#state1.mappings, 1)
			helpers.assert_eq(#state2.mappings, 0,
				"the refused state must never become the registry owner")
		end)
	end)

	helpers.it("registry_groups retains exact active dependencies and refuses replacements", function()
		with_stubbed_module("modules.keymap.registry_groups", {}, function(groups)
			local state1 = {
				groups = {},
				group_post_load_hooks = {},
				SECTION_DELAYS = {},
				recompute_word_timeout = noop,
			}
			local state2 = {
				groups = {},
				group_post_load_hooks = {},
				SECTION_DELAYS = {},
				recompute_word_timeout = noop,
			}
			local callbacks = {
				add = noop,
				sort_mappings = noop,
				is_section_enabled = function() return true end,
				resolve_priority = function() return 0 end,
				rebuild_lookup = noop,
				rebuild_tail_indexes = noop,
				drop_classify_cache = noop,
			}
			local same_callbacks = {}
			for name, fn in pairs(callbacks) do same_callbacks[name] = fn end
			local changed_callbacks = {}
			for name, fn in pairs(callbacks) do changed_callbacks[name] = fn end
			changed_callbacks.add = function() end

			helpers.assert_eq(groups.init(state1, callbacks), true)
			helpers.assert_eq(groups.init(state1, same_callbacks), true,
				"an exact idempotent dependency set remains committed")
			helpers.assert_eq(groups.init(state2, callbacks), false,
				"a different state must not replace the active state")
			helpers.assert_eq(groups.init(state1, changed_callbacks), false,
				"a different callback must not replace the active callback set")
			groups.register_lua_group("owner", "Owner", {})
			helpers.assert_true(state1.groups.owner ~= nil,
				"the original state must remain the mutation owner")
			helpers.assert_nil(state2.groups.owner,
				"the refused replacement state must remain untouched")
		end)
	end)

	helpers.it("registry_index refuses a different state without replacing the first", function()
		with_stubbed_module("modules.keymap.registry_index", {}, function(index)
			local state1 = { groups = { owner = { sections = { "first" } } } }
			local state2 = { groups = { owner = { sections = { "second" } } } }
			helpers.assert_eq(index.setup(state1), true)
			helpers.assert_eq(index.setup(state1), true)
			helpers.assert_eq(index.setup(state2), false)
			helpers.assert_eq(index.get_sections("owner")[1], "first",
				"registry_index must retain its first committed state")
		end)
	end)
end)


helpers.describe("keymap child init: exact dependency commitments", function()
	helpers.it("Expander refuses before publication when TerminatorReplay.init refuses", function()
		local replay_calls = 0
		with_stubbed_module("modules.keymap.expander", {
			["infra.text_utils"] = {},
			["infra.hotstring_engine"] = {},
			["modules.keymap.utils"] = {},
			["infra.logger"] = LOGGER_STUB,
			["modules.keymap.state"] = {},
			["adapters.text_sender"] = {},
			["adapters.synthetic_input"] = {},
			["adapters.tooltip_renderer"] = {},
			["modules.keymap.terminator_replay"] = {
				init = function()
					replay_calls = replay_calls + 1
					return false
				end,
			},
			["modules.keymap.terminators"] = {},
			["modules.keylogger"] = {},
		}, function(expander)
			helpers.assert_eq(expander.init({}, {}, {}), false)
			helpers.assert_eq(replay_calls, 1)
			helpers.assert_eq(expander.try_expand("x", false), false,
				"a refused replay dependency must leave Expander guarded")
		end)
	end)

	helpers.it("LLMBridge refuses before binding guards when prediction_engine.init refuses", function()
		local engine_calls = 0
		local engine_guard_calls = 0
		local tooltip_guard_calls = 0
		with_stubbed_module("modules.keymap.llm_bridge", {
			["modules.keymap.utils"] = {},
			["adapters.event_provenance"] = {},
			["adapters.synthetic_input"] = {
				current_action_epoch = function() return 0 end,
			},
			["infra.text_utils"] = {},
			["modules.llm"] = { DEFAULT_STATE = {} },
			["infra.logger"] = LOGGER_STUB,
			["infra.keycodes"] = { ESCAPE = 53, RETURN = 36, F16_LLM_CHAIN_SIGNAL = 106 },
			["modules.keylogger"] = {},
			["ui.tooltip"] = {
				set_runtime_guard = function() tooltip_guard_calls = tooltip_guard_calls + 1 end,
			},
			["modules.llm.prediction_engine"] = {
				init = function()
					engine_calls = engine_calls + 1
					return false
				end,
				set_runtime_guard = function() engine_guard_calls = engine_guard_calls + 1 end,
			},
			["modules.keymap.registry"] = {},
			["modules.hotstrings.hotstrings_config"] = {},
			["modules.keymap.expander"] = {},
			["adapters.timer_scheduler"] = {},
			["infra.manifest_reader"] = { default_for = function() return "★" end },
			["modules.diagnostics.hid_diagnostic_mailbox"] = {},
		}, function(bridge)
			helpers.assert_eq(bridge.init({ buffer = "", mappings = {} }, {}), false)
			helpers.assert_eq(engine_calls, 1)
			helpers.assert_eq(engine_guard_calls, 0,
				"a refused engine must not receive a live runtime guard")
			helpers.assert_eq(tooltip_guard_calls, 0,
				"a refused engine must not publish the bridge guard to the tooltip")
		end)
	end)
end)


helpers.describe("leaf init ownership: exact dependencies only", function()
	helpers.it("TerminatorReplay refuses a different state", function()
		with_stubbed_module("modules.keymap.terminator_replay", {
			["infra.logger"] = LOGGER_STUB,
			["adapters.text_sender"] = {},
			["adapters.timer_scheduler"] = {},
			["adapters.synthetic_input"] = {},
		}, function(replay)
			local state1 = {}
			local state2 = {}
			helpers.assert_eq(replay.init(state1), true)
			helpers.assert_eq(replay.init(state1), true)
			helpers.assert_eq(replay.init(state2), false)
		end)
	end)

	helpers.it("WarmupController refuses a different dependency set", function()
		with_stubbed_module("modules.llm.warmup_controller", {
			["infra.logger"] = LOGGER_STUB,
			["infra.timings"] = { sec = function() return 0.1 end },
			["adapters.timer_scheduler"] = {},
		}, function(warmup)
			local core1 = {}
			local core2 = {}
			local enabled = function() return true end
			helpers.assert_eq(warmup.init({
				core_llm = core1,
				get_llm_enabled = enabled,
			}), true)
			helpers.assert_eq(warmup.init({
				core_llm = core1,
				get_llm_enabled = enabled,
			}), true)
			helpers.assert_eq(warmup.init({
				core_llm = core2,
				get_llm_enabled = enabled,
			}), false)
		end)
	end)

	helpers.it("StreamingHandler refuses a different dependency set", function()
		with_stubbed_module("modules.llm.streaming_handler", {
			["modules.llm.parser"] = {},
			["infra.logger"] = LOGGER_STUB,
			["infra.timings"] = { sec = function() return 0.1 end },
			["infra.i18n"] = {},
		}, function(streaming)
			local core = {}
			local tooltip1 = {}
			local tooltip2 = {}
			local keylogger = {}
			helpers.assert_eq(streaming.init({
				core_llm = core,
				tooltip = tooltip1,
				keylogger = keylogger,
			}), true)
			helpers.assert_eq(streaming.init({
				core_llm = core,
				tooltip = tooltip1,
				keylogger = keylogger,
			}), true)
			helpers.assert_eq(streaming.init({
				core_llm = core,
				tooltip = tooltip2,
				keylogger = keylogger,
			}), false)
		end)
	end)
end)


--- Exercises one fresh prediction engine against controlled child results.
--- @param warmup_result boolean|function
--- @param streaming_result boolean|function
--- @param callback function
local function with_prediction_results(warmup_result, streaming_result, callback)
	local calls = { warmup = 0, streaming = 0 }
	with_stubbed_module("modules.llm.prediction_engine", {
		["modules.llm"] = {
			DEFAULT_STATE = {},
			get_current_model = function() return "test-model" end,
		},
		["modules.llm.warmup_controller"] = {
			init = function(deps)
				calls.warmup = calls.warmup + 1
				if type(warmup_result) == "function" then
					return warmup_result(deps, calls)
				end
				return warmup_result
			end,
		},
		["modules.llm.prompt_builder"] = {},
		["modules.llm.streaming_handler"] = {
			init = function(deps)
				calls.streaming = calls.streaming + 1
				if type(streaming_result) == "function" then
					return streaming_result(deps, calls)
				end
				return streaming_result
			end,
		},
		["modules.llm.app_filter"] = {},
		["modules.llm.api_common"] = {},
		["infra.logger"] = LOGGER_STUB,
		["infra.timings"] = { sec = function() return 0.1 end },
		["adapters.timer_scheduler"] = {},
		["infra.i18n"] = {},
		["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 },
		["ui.tooltip"] = {
			set_navigate_callback = noop,
			set_enter_validates = noop,
		},
		["modules.keylogger"] = {},
	}, function(engine)
		callback(engine, calls)
	end)
end


helpers.describe("prediction_engine init: child commitments are transitive", function()
	helpers.it("does not call StreamingHandler after WarmupController refuses", function()
		with_prediction_results(false, true, function(engine, calls)
			helpers.assert_eq(engine.init({ mappings = {} }), false)
			helpers.assert_eq(calls.warmup, 1)
			helpers.assert_eq(calls.streaming, 0)
		end)
	end)

	helpers.it("does not publish engine state when StreamingHandler refuses", function()
		with_prediction_results(true, false, function(engine, calls)
			helpers.assert_eq(engine.init({ mappings = {} }), false)
			helpers.assert_eq(calls.warmup, 1)
			helpers.assert_eq(calls.streaming, 1)
		end)
	end)

	helpers.it("returns literal true and does not reinitialize children on duplicate init", function()
		with_prediction_results(true, true, function(engine, calls)
			local state = { mappings = {} }
			helpers.assert_eq(engine.init(state), true)
			helpers.assert_eq(engine.init(state), true,
				"the exact active state is an idempotent success")
			helpers.assert_eq(engine.init({ mappings = {} }), false,
				"a different state object must not inherit the active state's success")
			helpers.assert_eq(calls.warmup, 1)
			helpers.assert_eq(calls.streaming, 1)
		end)
	end)

	helpers.it("retries with the same stable warmup dependency after streaming refuses", function()
		local first_getter = nil
		with_prediction_results(function(deps)
			if not first_getter then first_getter = deps.get_llm_enabled end
			return deps.get_llm_enabled == first_getter
		end, function(_, calls)
			return calls.streaming > 1
		end, function(engine, calls)
			local state = { mappings = {} }
			helpers.assert_eq(engine.init(state), false)
			helpers.assert_eq(engine.init(state), true,
				"a retry must reuse the warmup getter identity and converge")
			helpers.assert_eq(calls.warmup, 2)
			helpers.assert_eq(calls.streaming, 2)
		end)
	end)
end)
