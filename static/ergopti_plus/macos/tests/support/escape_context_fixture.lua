--- tests/support/escape_context_fixture.lua

--- ==============================================================================
--- MODULE: Escape Context Fixture
--- DESCRIPTION:
--- Constructs the real LLM bridge and its Escape trap with observable context.
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
	"modules.diagnostics.hid_diagnostic_mailbox",
}

local function load_fixture(options, lifetime)
	options = options or {}
	helpers.load_with_stubs("hs")

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
	lifetime.bridge = Bridge
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

	local native_eventtap = hs.eventtap
	local original_new = native_eventtap.new
	lifetime.eventtap, lifetime.original_new = native_eventtap, original_new
	native_eventtap.new = function(_types, callback)
		trap_callback = callback
		local enabled = false
		return {
			start = function(self) enabled = true; return self end,
			stop = function(self) enabled = false; return self end,
			isEnabled = function() return enabled end,
		}
	end
	if options.on_trap_install then options.on_trap_install(native_eventtap, original_new) end
	helpers.assert_eq(type(show_callback), "function")
	helpers.assert_true(show_callback())
	helpers.assert_eq(type(trap_callback), "function")
	if options.quarantined then Bridge.set_runtime_quarantined(true) end

	return Bridge, state, trap_callback, deferred,
		function() return engine_resets end,
		function() return hides end
end


--- Runs assertions against the initialized bridge and trap.
--- @param options table Fixture configuration and optional trap-install observer.
--- @param callback function Receives bridge, state, trap, deferred work and counters.
local function with_fixture(options, callback)
	return helpers.with_stub_scope(STUBBED_MODULES, function()
		local lifetime = {}
		local results = table.pack(xpcall(function()
			return callback(load_fixture(options, lifetime))
		end, debug.traceback))
		local stopped, stop_result = pcall(function()
			if lifetime.bridge then return lifetime.bridge.stop() end
			return true
		end)
		if lifetime.eventtap then lifetime.eventtap.new = lifetime.original_new end
		if not results[1] then error(results[2], 0) end
		if not stopped then error(stop_result, 0) end
		if stop_result ~= true then error("Escape fixture cleanup refused", 0) end
		return table.unpack(results, 2, results.n)
	end)
end

return { with_fixture = with_fixture }
