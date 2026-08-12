--- tests/unit/modules/keymap/test_llm_bridge_action_epoch_quarantine.lua

--- ==============================================================================
--- MODULE: Keymap LLM bridge action-epoch quarantine behavioural regressions
--- DESCRIPTION:
--- Verifies two bridge-only contracts: an older reset cannot reopen the LLM
--- runtime after a newer action token appears, and closing the LLM runtime does
--- not suppress the independent hotstring preview promised by the keymap engine.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture(reset_result)
	helpers.load_with_stubs("infra.logger")

	local initial = { id = "initial" }
	local current_token = initial
	local scheduled = {}
	local effects = {
		engine_reset = 0,
		engine_stop = 0,
		engine_start = 0,
		hide = 0,
		stacked = 0,
		stacked_rows = nil,
	}
	local engine_guard
	local tooltip_guard
	local reset_hook

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.synthetic_input"] = {
		current_action_epoch = function() return current_token end,
	}
	package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local handle = { delay = delay, callback = callback, timer = {} }
				scheduled[#scheduled + 1] = handle
				return handle, true
			end,
	}
	package.loaded["modules.keymap.utils"] = {
		plain_text = function(value) return tostring(value or "") end,
		tokens_from_repl = function(value) return value end,
		resolve_prediction_overlap = function(_buffer, deletes, text) return deletes, text end,
	}
	package.loaded["infra.text_utils"] = {
		is_letter_char = function() return false end,
		trig_lower = function(value) return tostring(value or ""):lower() end,
		conform_replacement = function(value) return value end,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = {
			llm_after_hotstring = false,
			llm_reset_on_nav = false,
		},
		check_modifiers = function() return false end,
	}
	package.loaded["infra.keycodes"] = {
		ESCAPE = 53,
		RETURN = 36,
		F16_LLM_CHAIN_SIGNAL = 106,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		set_buffer = function() end,
	}

	local tooltip = {
		set_runtime_guard = function(guard) tooltip_guard = guard end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		show_stacked = function(rows)
			effects.stacked = effects.stacked + 1
			effects.stacked_rows = rows
			return true
		end,
		hide = function() effects.hide = effects.hide + 1; return true end,
		hide_forced = function() effects.hide = effects.hide + 1; return true end,
		hide_forced_silent = function() effects.hide = effects.hide + 1; return true end,
		is_visible = function() return false end,
		tint = function() return nil end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
	}
	package.loaded["ui.tooltip"] = tooltip

	local engine = setmetatable({
		set_runtime_guard = function(guard) engine_guard = guard end,
		init = function() end,
		get_llm_enabled = function() return true end,
		stop_timer = function() effects.engine_stop = effects.engine_stop + 1; return true end,
		start_timer = function() effects.engine_start = effects.engine_start + 1 end,
		start_timer_word_end = function() effects.engine_start = effects.engine_start + 1 end,
		reset = function()
			effects.engine_reset = effects.engine_reset + 1
			if reset_hook then reset_hook() end
			if type(reset_result) == "function" then return reset_result() end
			if reset_result ~= nil then return reset_result end
			return true
		end,
	}, {
		__index = function()
			return function() end
		end,
	})
	package.loaded["modules.llm.prediction_engine"] = engine
	package.loaded["modules.keymap.registry"] = {
		mappings_for_tail = function() return nil end,
		mappings_for_star_tail = function() return nil end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
	}
	package.loaded["modules.keymap.expander"] = {
		would_fire = function() return nil end,
		resolve_magic_action = function() return nil end,
		perform_text_replacement = function() return false end,
	}
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "*" end,
	}

	package.loaded["modules.keymap.llm_bridge"] = nil
	local Bridge = require("modules.keymap.llm_bridge")
	Bridge.init({
		buffer = "",
		mappings = {},
		preview_providers = {
			function(buffer)
				if buffer == "sig" then return "expanded value" end
				return nil
			end,
		},
		groups = {},
		DELAYS = { dynamichotstrings = 0, llm_prediction = 0 },
		magic_key = "*",
		no_rescan_until = 0,
		is_repeat_feature_enabled = function() return false end,
	}, {
		preview_star_enabled = true,
		preview_autocorrect_enabled = true,
	})

	local function publish(id)
		current_token = { id = id }
		return current_token
	end
	local function set_reset_hook(callback) reset_hook = callback end
	local function fire_scheduled()
		local snapshot = scheduled
		scheduled = {}
		for _, handle in ipairs(snapshot) do handle.callback() end
	end
	return Bridge, effects, publish, set_reset_hook, fire_scheduled,
		function() return engine_guard end,
		function() return tooltip_guard end
end


helpers.describe("llm_bridge: exact action-token quarantine", function()
	helpers.it("token A cannot reopen the runtime when token B arrives during A's reset", function()
		local Bridge, effects, publish, set_reset_hook, _, get_engine_guard, get_tooltip_guard = load_fixture()
		local token_a = publish("A")
		helpers.assert_true(Bridge.observe_action_epoch(token_a))
		helpers.assert_eq(Bridge.is_runtime_available(), false)

		local token_b
		set_reset_hook(function() token_b = publish("B") end)
		helpers.assert_eq(Bridge.reset_for_action_epoch(token_a), false,
			"A must fail its final token check after B is published inside engine.reset")
		helpers.assert_not_nil(token_b, "the interleaving must really have published B")
		helpers.assert_eq(effects.engine_reset, 1)
		helpers.assert_eq(Bridge.is_runtime_available(), false,
			"A must not mark itself safe after B became current")
		helpers.assert_eq(get_engine_guard()(), false)
		helpers.assert_eq(get_tooltip_guard()(), false)

		set_reset_hook(nil)
		helpers.assert_true(Bridge.reset_for_action_epoch(token_b),
			"only an exact reset of the latest token may reopen the runtime")
		helpers.assert_eq(effects.engine_reset, 2)
		helpers.assert_true(Bridge.is_runtime_available())
		helpers.assert_true(get_engine_guard()())
		helpers.assert_true(get_tooltip_guard()())
	end)


	helpers.it("hotstring preview still renders while only the LLM runtime is quarantined", function()
		local Bridge, effects, publish, _, fire_scheduled, get_engine_guard, get_tooltip_guard = load_fixture()
		local token = publish("quarantined")
		helpers.assert_true(Bridge.observe_action_epoch(token))
		helpers.assert_eq(Bridge.is_runtime_available(), false)
		helpers.assert_eq(get_engine_guard()(), false)
		helpers.assert_eq(get_tooltip_guard()(), false)

		Bridge.update_preview("sig")
		helpers.assert_eq(effects.engine_reset, 0,
			"the eventtap-side quarantine path must not run the full engine reset")
		helpers.assert_eq(effects.engine_stop, 0,
			"closed LLM timers must not be touched on the physical typing path")
		helpers.assert_eq(effects.engine_start, 0,
			"a hotstring preview must not accidentally re-arm LLM work while closed")

		-- The bridge queues the quarantine hide first and the hotstring paint second.
		-- Firing both in FIFO order models the next Hammerspoon run-loop tick: the
		-- authoritative LLM hide runs, then the independent hotstring surface wins.
		fire_scheduled()
		helpers.assert_eq(effects.hide, 1)
		helpers.assert_eq(effects.stacked, 1,
			"LLM quarantine must not remove hotstring output from the user")
		helpers.assert_not_nil(effects.stacked_rows)
		helpers.assert_eq(#effects.stacked_rows, 1)
		helpers.assert_eq(effects.stacked_rows[1].text, "expanded value")
		helpers.assert_eq(Bridge.is_runtime_available(), false,
			"rendering a hotstring must not reopen the quarantined LLM runtime")
	end)

	helpers.it("force-full teardown commits while runtime quarantine stays closed", function()
		local Bridge, effects, publish = load_fixture()
		local token = publish("teardown")
		helpers.assert_true(Bridge.observe_action_epoch(token))
		helpers.assert_eq(Bridge.is_runtime_available(), false)

		helpers.assert_eq(Bridge.reset_for_teardown(), true,
			"teardown cannot wait for a listener that is itself being removed")
		helpers.assert_eq(effects.engine_reset, 1)
		helpers.assert_eq(Bridge.is_runtime_available(), false,
			"resource teardown must not reopen an interaction gate")
	end)

	helpers.it("keeps a failed teardown reset retryable under quarantine", function()
		local attempts = 0
		local Bridge, effects, publish = load_fixture(function()
			attempts = attempts + 1
			return attempts > 1
		end)
		local token = publish("teardown-retry")
		Bridge.observe_action_epoch(token)

		helpers.assert_eq(Bridge.reset_for_teardown(), false)
		helpers.assert_eq(Bridge.reset_for_teardown(), true)
		helpers.assert_eq(effects.engine_reset, 2)
		helpers.assert_eq(Bridge.is_runtime_available(), false)
	end)

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "throw", value = function() error("engine reset failed") end },
	}) do
		helpers.it("keeps every quarantine closed when engine reset returns " .. case.name, function()
			local Bridge, _, publish = load_fixture(case.value)
			local token = publish("failed-reset")
			helpers.assert_true(Bridge.observe_action_epoch(token))

			local ok, result = pcall(Bridge.reset_for_action_epoch, token)
			helpers.assert_true(ok, "the reset failure must be contained: " .. tostring(result))
			helpers.assert_eq(result, false)
			helpers.assert_eq(Bridge.is_runtime_available(), false,
				"a failed action-epoch reset must not mark the token safe")

			ok, result = pcall(Bridge.reconcile_observation_gap)
			helpers.assert_true(ok, "reconciliation must contain the same failure: " .. tostring(result))
			helpers.assert_eq(result, false)
			helpers.assert_eq(Bridge.is_runtime_available(), false,
				"failed reconciliation must not reopen the runtime")

			ok, result = pcall(Bridge.reset_predictions, false)
			helpers.assert_true(ok, "ordinary reset must contain the same failure: " .. tostring(result))
			helpers.assert_eq(result, false)
		end)
	end
end)
