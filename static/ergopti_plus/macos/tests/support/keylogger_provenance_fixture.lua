--- tests/support/keylogger_provenance_fixture.lua

--- Behavioural fixture for the keylogger's logical synthetic telemetry and the
--- independent, event-local SyntheticInput ownership channel. It deliberately
--- loads the real `modules.keylogger.init`, `adapters.synthetic_input`, and
--- `adapters.event_provenance` modules; only persistence and OS lifecycle
--- boundaries are replaced with in-memory doubles.

local helpers = require("tests.helpers")

local M = {}

local function find_upvalue(fn, wanted)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == wanted then return value end
	end
	error("cannot find upvalue " .. tostring(wanted), 2)
end

local function shallow_copy_array(values)
	local copy = {}
	for index, value in ipairs(values or {}) do copy[index] = value end
	return copy
end

--- Loads a fresh production keylogger without starting any OS watcher.
--- @return table fixture
function M.load_keylogger()
	local flushes = {}
	local state
	local foreground_captures = 0
	-- These adapters capture the active hs table and Quartz property constants at
	-- require-time. This fixture deliberately uses the production instances, so it
	-- owns their reload rather than making the generic helper erase intentional
	-- adapter stubs installed by unrelated tests.
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return true end,
	}
	package.loaded["infra.config_paths"] = {
		get_config_dir = function() return "/tmp/ergopti-test" end,
	}
	package.loaded["infra.dialog_util"] = { alert = function() end }

	package.loaded["modules.keylogger.log_manager"] = {
		init = function(core_state) state = core_state; return true end,
		ensure_ingest_running = function() return true end,
		defer_flush_buffer = function() return true end,
		flush_buffer = function()
			if not state then return true end
			flushes[#flushes + 1] = {
				events = shallow_copy_array(state.buffer_events),
				rich_chunks = shallow_copy_array(state.rich_chunks),
			}
			state.buffer_events = {}
			state.buffer_text = ""
			state.rich_chunks = {}
			return true
		end,
		stop = function() return true end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		init = function(core_state, _log_manager, is_paused)
			state = core_state
			return type(core_state) == "table" and type(is_paused) == "function"
		end,
		update_private_status = function() end,
		app_watcher_cb = function() end,
		update_ax_observer = function() end,
		capture_frontmost_app = function()
			foreground_captures = foreground_captures + 1
			state.is_secure_field = false
			return true
		end,
	}
	local kc_running = false
	package.loaded["modules.keylogger.kc_bridge"] = {
		init = function(core_state, _pathwatcher, _timer, _log_manager, may_persist)
			return type(core_state) == "table" and type(may_persist) == "function"
		end,
		set_log_manager = function(log_manager) return type(log_manager) == "table" end,
		start = function() kc_running = true; return true end,
		stop = function() kc_running = false; return true end,
		is_running = function() return kc_running end,
		is_ke_managed_output_kc = function() return false end,
	}
	local hardware_running = false
	package.loaded["modules.keylogger.watchers"] = {
		init = function(core_state, is_paused)
			return type(core_state) == "table" and type(is_paused) == "function"
		end,
		init_hardware_watchers = function()
			hardware_running = true
			return true
		end,
		stop_hardware_watchers = function()
			hardware_running = false
			return true
		end,
		is_running = function() return hardware_running end,
		check_idle = function() end,
		perform_maintenance = function() end,
		caffeinate_cb = function() end,
	}
	package.loaded["adapters.process_lifecycle"] = {
		onAppActivate = function(callback) return type(callback) == "function" end,
		start = function() return true end,
		stop = function() return true end,
	}
	package.loaded["adapters.keyboard_hook"] = {
		start = function() return true end,
		stop = function() return true end,
		isRunning = function() return true end,
	}
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function(id, callback)
			return type(id) == "string" and type(callback) == "function"
		end,
		unsubscribe = function() return true end,
	}

	local keylogger = helpers.load_with_stubs("modules.keylogger.init")
	state = find_upvalue(keylogger.notify_synthetic, "CoreState")

	local fixture = {
		keylogger = keylogger,
		state = state,
		flushes = flushes,
		hs = _G.hs,
		synthetic_input = require("adapters.synthetic_input"),
		provenance = require("adapters.event_provenance"),
	}
	function fixture.start(script_control)
		local timers = fixture.hs.timer.__timers
		local prior_count = #timers
		helpers.assert_eq(keylogger.start(script_control), true,
			"the provenance fixture must start before enabling persistence")
		for index = prior_count + 1, #timers do
			if timers[index].delay == 0 and timers[index].running then
				timers[index]:fire()
			end
		end
		helpers.assert_eq(foreground_captures, 1,
			"the deferred foreground-context capture must settle before input")
		helpers.assert_eq(state.is_secure_field, false,
			"the foreground-context settlement must commit a loggable fixture state")
		return true
	end
	return fixture
end

--- Emits one callback-owned key pair and returns its key-down event.
--- @param synthetic_input table Real adapters.synthetic_input module.
--- @param owner string Stable producer name.
--- @param effect string replacement|action.
--- @param key string|number Key name or code.
--- @param modifiers table|nil Modifier names.
--- @return table event
function M.tagged_key(synthetic_input, owner, effect, key, modifiers)
	local tx = synthetic_input.begin(owner, effect)
	local batch = synthetic_input.begin_callback(tx)
	local appended = synthetic_input.keyStroke(batch, modifiers or {}, key)
	assert(appended == true, "fixture could not append tagged key")
	local _, events = synthetic_input.finish_callback(batch, true)
	synthetic_input.seal(tx)
	assert(type(events) == "table" and events[1] ~= nil,
		"fixture did not receive a tagged key-down event")
	return events[1]
end

--- Builds an otherwise identical event without an ownership tag.
--- @param hs_table table Active Hammerspoon stub.
--- @param key string|number Key name or code.
--- @param modifiers table|nil Modifier names.
--- @return table event
function M.physical_key(hs_table, key, modifiers)
	return hs_table.eventtap.event.newKeyEvent(modifiers or {}, key, true)
end

return M
