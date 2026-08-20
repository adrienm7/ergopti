--- tests/unit/modules/keymap/test_escape_invalidates_hotstring_buffer.lua

--- ==============================================================================
--- REGRESSION: Escape dismissal invalidates the authoritative hotstring context
--- ==============================================================================

local helpers = require("tests.helpers")

local STUBBED_MODULES = {
	"infra.logger",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
	"modules.keymap.utils",
	"infra.text_utils",
	"modules.llm",
	"infra.keycodes",
	"modules.keylogger",
	"ui.tooltip",
	"modules.llm.prediction_engine",
	"modules.keymap.registry",
	"modules.hotstrings.hotstrings_config",
	"modules.keymap.expander",
	"infra.manifest_reader",
	"modules.keymap.llm_bridge",
}

local ABSENT = {}

local function escape_event()
	return {
		getKeyCode = function() return 53 end,
		getProperty = function() return 0 end,
	}
end


local function load_fixture(options)
	options = options or {}
	local prior_modules = {}
	for _, name in ipairs(STUBBED_MODULES) do
		prior_modules[name] = package.loaded[name] == nil and ABSENT or package.loaded[name]
	end
	helpers.load_with_stubs("infra.logger")

	local epoch = {}
	local deferred = {}
	local show_callback
	local trap_callback
	local engine_resets = 0
	local hides = 0

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "physical", nil end,
	}
	package.loaded["adapters.synthetic_input"] = {
		current_action_epoch = function() return epoch end,
		defer_after_callback = function(_label, callback)
			if options.defer_throws then error("DEFER_THROW") end
			if options.defer_refuses then return false end
			deferred[#deferred + 1] = callback
			return true
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, callback)
			deferred[#deferred + 1] = callback
			return {}, true
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
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = false },
		check_modifiers = function() return false end,
	}
	package.loaded["infra.keycodes"] = {
		ESCAPE = 53,
		RETURN = 36,
		F16_LLM_CHAIN_SIGNAL = 106,
	}
	package.loaded["modules.keylogger"] = setmetatable({}, {
		__index = function() return function() end end,
	})

	local tooltip = {
		set_on_show_callback = function(callback) show_callback = callback end,
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		is_visible = function() return options.visible == true end,
		is_hotstring_visible = function() return options.hotstring_visible == true end,
		hide_forced = function() hides = hides + 1; return true end,
		hide_forced_silent = function() hides = hides + 1; return true end,
		tint = function() return nil end,
	}
	package.loaded["ui.tooltip"] = tooltip

	package.loaded["modules.llm.prediction_engine"] = setmetatable({
		init = function() return true end,
		set_runtime_guard = function() end,
		reset = function() engine_resets = engine_resets + 1; return true end,
		get_llm_enabled = function() return true end,
	}, {
		__index = function() return function() end end,
	})
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
	local state = {
		buffer = "agé",
		start_is_word_boundary = true,
		mappings = {},
		preview_providers = {},
		groups = {},
		DELAYS = { dynamichotstrings = 0, llm_prediction = 0 },
		magic_key = "*",
		no_rescan_until = 0,
		is_repeat_feature_enabled = function() return false end,
	}
	helpers.assert_true(Bridge.init(state, {
		preview_star_enabled = true,
		preview_autocorrect_enabled = true,
	}))

	local original_new = hs.eventtap.new
	hs.eventtap.new = function(_types, callback)
		trap_callback = callback
		local enabled = false
		return {
			start = function(self) enabled = true; return self end,
			stop = function(self) enabled = false; return self end,
			isEnabled = function() return enabled end,
		}
	end
	helpers.assert_eq(type(show_callback), "function")
	helpers.assert_true(show_callback())
	helpers.assert_eq(type(trap_callback), "function")
	if options.quarantined then Bridge.set_runtime_quarantined(true) end

	local function cleanup()
		Bridge.stop()
		hs.eventtap.new = original_new
		for _, name in ipairs(STUBBED_MODULES) do
			local prior = prior_modules[name]
			package.loaded[name] = prior == ABSENT and nil or prior
		end
	end

	return Bridge, state, trap_callback, deferred,
		function() return engine_resets end,
		function() return hides end,
		cleanup
end


helpers.describe("Escape invalidates hotstring context", function()
	helpers.it("Escape invalidates hotstring context in runtime and hotstring-only modes", function()
		for _, case in ipairs({
			{ visible = true, expected_resets = 1 },
			{ quarantined = true, hotstring_visible = true, expected_hides = 1 },
		}) do
			local Bridge, state, trap, deferred, get_resets, get_hides, cleanup =
				load_fixture(case)
			local ok, err = xpcall(function()
				local consumed = trap(escape_event())
				helpers.assert_eq(consumed, true)
				helpers.assert_eq(state.buffer, "",
					"a consumed Escape must synchronously revoke magic-key eligibility")
				helpers.assert_eq(state.start_is_word_boundary, false)
				helpers.assert_eq(#deferred, 1)
				deferred[1]()
				helpers.assert_eq(get_resets(), case.expected_resets or 0)
				helpers.assert_eq(get_hides(), case.expected_hides or 0)

				state.buffer = "agé"
				state.start_is_word_boundary = true
				helpers.assert_true(Bridge.check_escape_reset())
				helpers.assert_eq(state.buffer, "")
				helpers.assert_eq(state.start_is_word_boundary, false)
			end, debug.traceback)
			cleanup()
			if not ok then error(err, 0) end
		end
	end)

	helpers.it("Escape invalidates hotstring context only after deferral commits", function()
		for _, refusal in ipairs({ "false", "throw" }) do
			local Bridge, state, trap, deferred, _, _, cleanup = load_fixture({
				visible = true,
				defer_refuses = refusal == "false",
				defer_throws = refusal == "throw",
			})
			local ok, err = xpcall(function()
				local consumed = trap(escape_event())
				helpers.assert_eq(consumed, false,
					"Escape must pass through when deferred ownership is refused")
				helpers.assert_eq(state.buffer, "agé",
					"a pass-through Escape must retain the exact prior buffer")
				helpers.assert_eq(state.start_is_word_boundary, true)
				helpers.assert_eq(#deferred, 0)
			end, debug.traceback)
			cleanup()
			if not ok then error(err, 0) end
		end
	end)
end)

return true
