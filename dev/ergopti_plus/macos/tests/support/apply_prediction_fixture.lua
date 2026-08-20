--- tests/support/apply_prediction_fixture.lua

--- ==============================================================================
--- MODULE: apply_prediction behavioral fixture
--- DESCRIPTION:
--- Loads the real LLM bridge, expander, keymap text emitter, and SyntheticInput
--- collector around a deterministic prediction-engine seam. Tests inspect the
--- Quartz events returned by the collector rather than the removed synthetic
--- echo counters.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}


local function noop() end


local function purge_driver_modules()
	for name in pairs(package.loaded) do
		if type(name) == "string"
			and (name:find("^modules%.") or name:find("^adapters%.")
				or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
end


--- Loads and drives one prediction acceptance inside a real callback collector.
--- @param options table { text, buffer?, expander_failure? }
--- @return table result Captured call, event, state, and side-effect data.
function M.run(options)
	options = options or {}
	local prediction_text = assert(options.text, "fixture requires prediction text")

	purge_driver_modules()
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local clipboard_writes = {}
	hs_stub.pasteboard.getContents = function() return "" end
	hs_stub.pasteboard.readAllData = function() return {} end
	hs_stub.pasteboard.setContents = function(value)
		clipboard_writes[#clipboard_writes + 1] = value
		return true
	end
	hs_stub.pasteboard.writeAllData = function() return true end

	local logger = helpers.make_logger_stub()
	logger.LEVELS = { DEBUG = 10 }
	package.loaded["infra.logger"] = logger
	package.loaded["infra.timings"] = {
		sec = function() return 0.05 end,
	}

	local accepted_count = 0
	local notified_count = 0
	local keylogger_buffers = {}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = noop,
		log_hotstring_dismissed = noop,
		notify_synthetic = function() notified_count = notified_count + 1 end,
		log_llm_accepted = function() accepted_count = accepted_count + 1 end,
		set_buffer = function(value)
			keylogger_buffers[#keylogger_buffers + 1] = value
		end,
	}

	local reset_count = 0
	local arm_chain_count = 0
	local engine = {
		init = function() return true end,
		set_runtime_guard = noop,
		consume = function(index)
			if index ~= 1 then return nil, nil end
			if options.no_prediction then return nil, nil end
			local prediction = { deletes = 0, to_type = prediction_text }
			return prediction, { prediction }
		end,
		reset = function()
			reset_count = reset_count + 1
			if type(options.reset_result) == "function" then return options.reset_result(reset_count) end
			if options.reset_result ~= nil then return options.reset_result end
			return true
		end,
		arm_chain = function()
			arm_chain_count = arm_chain_count + 1
			if type(options.arm_chain_result) == "function" then
				return options.arm_chain_result(arm_chain_count)
			end
			if options.arm_chain_result ~= nil then return options.arm_chain_result end
			return true
		end,
		get_llm_enabled = function() return false end,
		get_predictions = function() return {} end,
		get_current_index = function() return 1 end,
		get_navigation_mods = function() return {} end,
		get_validation_mods = function() return {} end,
		is_visible = function() return false end,
		start_timer = function() return true end,
		start_timer_word_end = function() return true end,
		stop_timer = function() return true end,
		perform_check = noop,
		handle_chain_signal = function() return false end,
		navigate = noop,
	}
	package.loaded["modules.llm.prediction_engine"] = engine
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = {
			llm_after_hotstring = false,
			llm_reset_on_nav = false,
		},
		check_modifiers = function() return false end,
	}

	package.loaded["ui.tooltip"] = {
		hide = noop,
		show_stacked = noop,
		set_timeout = noop,
		is_visible = function() return false end,
		tint = function() return nil end,
		set_colorization_enabled = noop,
		set_accent_color = noop,
		set_accept_callback = noop,
		set_cancel_callback = noop,
		set_on_show_callback = noop,
		set_runtime_guard = noop,
	}
	package.loaded["adapters.tooltip_renderer"] = { hide = noop }
	package.loaded["modules.keymap.registry"] = {
		init = function() return true end,
		mappings_for_tail = function() return nil end,
		mappings_for_star_tail = function() return nil end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {}
	package.loaded["modules.keymap.terminator_replay"] = {
		init = function() return true end,
		flush_now = noop,
	}
	package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local timer = hs_stub.timer.doAfter(delay, callback)
				return { timer = timer, cancel = function() timer:stop() end }, true
			end,
	}
	package.loaded["infra.manifest_reader"] = {
		default_for = function(key)
			if key == "hotstrings.trigger_char" then return "\u{2605}" end
			return false
		end,
	}
	package.loaded["infra.keycodes"] = {
		ESCAPE = 53,
		RETURN = 36,
		F16_LLM_CHAIN_SIGNAL = 106,
		to_name = function() return "f16" end,
	}

	local synthetic = require("adapters.synthetic_input")
	local km_utils = require("modules.keymap.utils")
	-- Keep the fixture about dispatch, not overlap policy.
	km_utils.resolve_prediction_overlap = function(_, deletes, text)
		if options.overlap_error then error("OVERLAP_THROW") end
		if options.overlap_nil then return nil, nil end
		return deletes, text
	end

	local expander
	if options.expander_failure then
		expander = {
			init = function() return true end,
			perform_text_replacement = function() return false end,
		}
		package.loaded["modules.keymap.expander"] = expander
	else
		expander = require("modules.keymap.expander")
	end

	local bridge = require("modules.keymap.llm_bridge")
	local suppress_count = 0
	local state = {
		buffer = options.buffer or "prefix ",
		magic_key = "\u{2605}",
		mappings = {},
		groups = {},
		preview_providers = {},
		start_is_word_boundary = true,
		suppress_rescan = function() suppress_count = suppress_count + 1 end,
	}
	bridge.init(state, {
		preview_star_enabled = true,
		preview_autocorrect_enabled = true,
	})
	if not options.expander_failure then
		expander.init(state, package.loaded["modules.keymap.registry"], bridge)
	end

	local buffer_before = state.buffer
	local timers_before = #hs_stub.timer.__timers
	synthetic.enter_callback()
	local call_ok, applied = pcall(bridge.apply_prediction, 1)
	local consume, events
	if call_ok then
		consume, events = synthetic.leave_callback(applied == true)
	else
		synthetic.abort_callback()
	end

	package.loaded["adapters.event_provenance"] = nil
	local provenance = require("adapters.event_provenance")
	return {
		applied = applied,
		call_ok = call_ok,
		consume = consume,
		events = events,
		state = state,
		buffer_before = buffer_before,
		accepted_count = accepted_count,
		notified_count = notified_count,
		keylogger_buffers = keylogger_buffers,
		reset_count = reset_count,
		arm_chain_count = arm_chain_count,
		suppress_count = suppress_count,
		clipboard_writes = clipboard_writes,
		timer_delta = #hs_stub.timer.__timers - timers_before,
		synthetic = synthetic,
		provenance = provenance,
	}
end


return M
