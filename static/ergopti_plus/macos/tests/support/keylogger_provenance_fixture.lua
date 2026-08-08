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
		init = function(core_state) state = core_state end,
		ensure_ingest_running = function() end,
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
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		init = function(core_state) state = core_state end,
		update_private_status = function() end,
		app_watcher_cb = function() end,
		update_ax_observer = function() end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		init = function() end,
		set_log_manager = function() end,
		start = function() end,
		stop = function() end,
	}
	package.loaded["modules.keylogger.watchers"] = {
		init = function() end,
		init_hardware_watchers = function() end,
		stop_hardware_watchers = function() end,
		check_idle = function() end,
		perform_maintenance = function() end,
		caffeinate_cb = function() end,
	}
	package.loaded["adapters.process_lifecycle"] = {
		onAppActivate = function() end,
		start = function() end,
		stop = function() end,
	}
	package.loaded["adapters.keyboard_hook"] = {
		start = function() end,
		stop = function() end,
		isRunning = function() return true end,
	}

	local keylogger = helpers.load_with_stubs("modules.keylogger.init")
	state = find_upvalue(keylogger.notify_synthetic, "CoreState")

	return {
		keylogger = keylogger,
		state = state,
		flushes = flushes,
		hs = _G.hs,
		synthetic_input = require("adapters.synthetic_input"),
		provenance = require("adapters.event_provenance"),
	}
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
