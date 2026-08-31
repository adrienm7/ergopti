--- ui/menu/global_actions_transaction.lua

--- ==============================================================================
--- MODULE: Global Menu Actions Transaction
--- DESCRIPTION:
--- Owns Enable All, Disable All, and factory reset across live feature state, configurable
--- bindings, preferences, settings, recoverable files, Karabiner deployment,
--- and the controlled reload handoff.
---
--- FEATURES & RATIONALE:
--- 1. Single Journal: Every attempted synchronous mutation is journaled before
---    invocation, so a native throw after mutation still has an exact inverse.
--- 2. Async Ownership: Karabiner request acceptance and terminal settlement are
---    separate exact contracts protected against synchronous and duplicate calls.
--- 3. Retained Debt: Reverse compensation stops at the first refusal and keeps
---    the precise journal index and detached snapshots for a later retry.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "menu_global_actions"
local DISABLED_ACTION = "none"
local KEYBOARD_SETTING_PREFIX = "keyboard_shortcut_"
local RESET_SETTING_KEYS = { "llm_api_entries", "llm_api_entry_id" }
local SCRIPT_SLOTS = { "return_key", "backspace", "escape" }

--- Clones nested values without sharing keys or children.
--- @param value any Source value.
--- @return any clone
local function clone_value(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[clone_value(key)] = clone_value(child) end
	return copy
end

--- Compares nested values by exact type, key set, and leaf value.
--- @param left any First value.
--- @param right any Second value.
--- @return boolean equal
local function deep_equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not deep_equal(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Creates one session owner for both destructive global actions.
--- @param deps table Exact runtime, persistence, settings, file, and reload ports.
--- @return table|nil owner
function M.create(deps)
	if type(deps) ~= "table" or type(deps.state) ~= "table"
		or type(deps.capture_preferences) ~= "function"
		or type(deps.sync_runtime) ~= "function"
		or type(deps.save_preferences) ~= "function"
		or type(deps.restore_state) ~= "function"
		or type(deps.ensure_enable_ready) ~= "function"
		or type(deps.apply_enable_features) ~= "function"
		or type(deps.restore_enable_features) ~= "function"
		or type(deps.list_enable_terminators) ~= "function"
		or type(deps.settings) ~= "table"
		or type(deps.settings.get) ~= "function"
		or type(deps.settings.set) ~= "function"
		or type(deps.settings.get_keys) ~= "function"
		or type(deps.file_mover) ~= "table"
		or type(deps.file_mover.capture) ~= "function"
		or type(deps.file_mover.move) ~= "function"
		or type(deps.file_mover.restore) ~= "function"
		or type(deps.reset_journal) ~= "table"
		or type(deps.reset_journal.prepare) ~= "function"
		or type(deps.reset_journal.mark_commit) ~= "function"
		or type(deps.reset_journal.mark_prepared) ~= "function"
		or type(deps.reset_journal.clear) ~= "function"
		or type(deps.gestures) ~= "table"
		or type(deps.gestures.get_action) ~= "function"
		or type(deps.gestures.set_action) ~= "function"
		or type(deps.gestures.enable_all) ~= "function"
		or type(deps.gestures.disable_all) ~= "function"
		or type(deps.shortcuts) ~= "table"
		or type(deps.shortcuts.list_shortcuts) ~= "function"
		or type(deps.shortcuts.enable) ~= "function"
		or type(deps.shortcuts.disable) ~= "function"
		or type(deps.shortcuts.set_shortcut_action) ~= "function"
		or type(deps.shortcuts.get_keyboard_action) ~= "function"
		or type(deps.shortcuts.set_keyboard_action) ~= "function"
		or type(deps.shortcuts.get_keyboard_assignments) ~= "function"
		or type(deps.karabiner) ~= "table"
		or type(deps.karabiner.snapshot_settings) ~= "function"
		or type(deps.karabiner.clear_all_bindings) ~= "function"
		or type(deps.karabiner.reset_to_defaults) ~= "function"
		or type(deps.karabiner.restore_settings) ~= "function"
		or type(deps.request_reload) ~= "function"
		or type(deps.terminal_pending) ~= "function" then
		Logger.error(LOG, "Global action transaction dependencies are incomplete.")
		return nil
	end

	local state = deps.state
	local gestures = type(deps.gestures) == "table" and deps.gestures or {}
	local shortcuts = type(deps.shortcuts) == "table" and deps.shortcuts or {}
	local gesture_slots = type(deps.gesture_slots) == "table" and deps.gesture_slots or {}
	local gesture_defaults = type(deps.gesture_defaults) == "table" and deps.gesture_defaults or {}
	local script_defaults = type(deps.script_defaults) == "table" and deps.script_defaults or {}
	local active_transaction = nil
	local external_writer = nil
	local external_writer_generation = 0

	--- Calls a synchronous boundary that must return literal true.
	--- @param label string Stable diagnostic label.
	--- @param fn function Boundary function.
	--- @param ... any Arguments forwarded to the boundary.
	--- @return boolean committed
	local function call_exact(label, fn, ...)
		if type(fn) ~= "function" then
			Logger.error(LOG, "%s is unavailable.", label)
			return false
		end
		local call_ok, result = xpcall(function(...) return fn(...) end, debug.traceback, ...)
		if not call_ok or result ~= true then
			Logger.error(LOG, "%s did not commit: %s.", label, tostring(result))
			return false
		end
		return true
	end

	--- Reads one settings value without collapsing a native error into nil.
	--- @param key string Settings key.
	--- @return boolean captured
	--- @return any value_or_error
	local function read_setting(key)
		local call_ok, value = xpcall(function() return deps.settings.get(key) end, debug.traceback)
		if not call_ok then
			Logger.error(LOG, "Settings snapshot failed for '%s': %s.", key, tostring(value))
			return false, value
		end
		return true, clone_value(value)
	end

	--- Writes one native void setting and proves commitment through exact read-back.
	--- @param key string Settings key.
	--- @param value any Desired value.
	--- @return boolean committed
	local function write_setting(key, value)
		local call_ok, result = xpcall(function()
			return deps.settings.set(key, clone_value(value))
		end, debug.traceback)
		if not call_ok or result == false then
			Logger.error(LOG, "Settings write failed for '%s': %s.", key, tostring(result))
			return false
		end
		local read_ok, observed = read_setting(key)
		if not read_ok or not deep_equal(observed, value) then
			Logger.error(LOG, "Settings write for '%s' did not match exact read-back.", key)
			return false
		end
		return true
	end

	--- Captures sorted configurable keyboard slots from the native settings store.
	--- @return table|nil snapshot
	local function capture_keyboard_slots()
		local call_ok, keys = xpcall(deps.settings.get_keys, debug.traceback)
		if not call_ok or type(keys) ~= "table" then
			Logger.error(LOG, "Keyboard shortcut settings enumeration failed: %s.", tostring(keys))
			return nil
		end
		local assignments_ok, assignments = xpcall(
			shortcuts.get_keyboard_assignments,
			debug.traceback
		)
		if not assignments_ok or type(assignments) ~= "table" then
			Logger.error(LOG, "Keyboard shortcut runtime enumeration failed: %s.",
				tostring(assignments))
			return nil
		end
		local slots = {}
		local slot_set = {}
		for slot in pairs(assignments) do
			if type(slot) == "string" and slot ~= "" then slot_set[slot] = true end
		end
		for _, key in ipairs(keys) do
			if type(key) == "string" and key:sub(1, #KEYBOARD_SETTING_PREFIX) == KEYBOARD_SETTING_PREFIX then
				slot_set[key:sub(#KEYBOARD_SETTING_PREFIX + 1)] = true
			end
		end
		for slot in pairs(slot_set) do
			local value_ok, value = xpcall(function()
				return shortcuts.get_keyboard_action(slot)
			end, debug.traceback)
			if not value_ok or type(value) ~= "string" then
				Logger.error(LOG, "Keyboard shortcut snapshot failed for '%s': %s.",
					slot, tostring(value))
				return nil
			end
			slots[#slots + 1] = { slot = slot, action = value }
		end
		table.sort(slots, function(left, right) return left.slot < right.slot end)
		return slots
	end

	--- Captures all runtime values needed to reverse a global state mutation.
	--- @param kind string Transaction kind.
	--- @return table|nil plan
	local function build_plan(kind)
		local preferences_ok, preference_snapshot = xpcall(
			deps.capture_preferences,
			debug.traceback
		)
		if not preferences_ok or type(preference_snapshot) ~= "table" then
			Logger.error(LOG, "Global %s preference snapshot failed: %s.",
				kind, tostring(preference_snapshot))
			return nil
		end
		local karabiner_snapshot = {}
		if kind ~= "enable" then
			local karabiner_ok
			karabiner_ok, karabiner_snapshot = xpcall(
				deps.karabiner.snapshot_settings,
				debug.traceback
			)
			if not karabiner_ok or type(karabiner_snapshot) ~= "table" then
				Logger.error(LOG, "Global %s Karabiner snapshot failed: %s.",
					kind, tostring(karabiner_snapshot))
				return nil
			end
		end

		local gesture_snapshot = {}
		for _, slot in ipairs(gesture_slots) do
			local get_ok, action = xpcall(function() return gestures.get_action(slot) end, debug.traceback)
			if not get_ok or type(action) ~= "string" then
				Logger.error(LOG, "Gesture snapshot failed for '%s': %s.", slot, tostring(action))
				return nil
			end
			gesture_snapshot[slot] = action
		end

		local shortcut_snapshot = {}
		if kind == "disable" or kind == "enable" then
			local list_ok, listed = xpcall(shortcuts.list_shortcuts, debug.traceback)
			if not list_ok or type(listed) ~= "table" then
				Logger.error(LOG, "Named shortcut snapshot failed: %s.", tostring(listed))
				return nil
			end
			for _, shortcut in ipairs(listed) do
				if type(shortcut) == "table" and type(shortcut.id) == "string" then
					shortcut_snapshot[#shortcut_snapshot + 1] = {
						id = shortcut.id,
						enabled = shortcut.enabled == true,
					}
				end
			end
			table.sort(shortcut_snapshot, function(left, right) return left.id < right.id end)
		end

		local keyboard_snapshot = {}
		if kind ~= "enable" then
			keyboard_snapshot = capture_keyboard_slots()
			if not keyboard_snapshot then return nil end
		end
		local reset_settings = {}
		if kind == "reset" then
			for _, key in ipairs(RESET_SETTING_KEYS) do
				local setting_ok, value = read_setting(key)
				if not setting_ok then return nil end
				reset_settings[#reset_settings + 1] = { key = key, value = value }
			end
		end
		local enable_terminators = {}
		if kind == "enable" then
			local terminators_ok, listed_terminators = xpcall(
				deps.list_enable_terminators,
				debug.traceback
			)
			if not terminators_ok or type(listed_terminators) ~= "table" then
				Logger.error(LOG, "Enable All terminator snapshot failed: %s.",
					tostring(listed_terminators))
				return nil
			end
			local seen_terminators = {}
			for _, key in ipairs(listed_terminators) do
				if type(key) ~= "string" or key == "" then
					Logger.error(LOG, "Enable All terminator snapshot contained an invalid key.")
					return nil
				end
				if not seen_terminators[key] then
					seen_terminators[key] = true
					enable_terminators[#enable_terminators + 1] = key
				end
			end
			table.sort(enable_terminators)
		end

		return {
			kind = kind,
			state_snapshot = clone_value(state),
			preference_snapshot = clone_value(preference_snapshot),
			gesture_snapshot = gesture_snapshot,
			script_snapshot = clone_value(state.script_control_shortcuts or {}),
			shortcut_snapshot = shortcut_snapshot,
			keyboard_snapshot = keyboard_snapshot,
			reset_settings = reset_settings,
			enable_terminators = enable_terminators,
			reset_paths = clone_value(deps.reset_paths or {}),
			karabiner_snapshot = clone_value(karabiner_snapshot),
			journal = {},
			rollback_index = 0,
			karabiner_attempted = false,
			karabiner_restored = false,
			settled = false,
		}
	end

	--- Mutates the shared state and detached preference candidate to Enable All.
	--- @param transaction table Active transaction.
	local function mutate_enable_state(transaction)
		state.keymap = true
		state.gestures = true
		state.shortcuts = true
		state.llm_enabled = true
		state.keylogger_enabled = true
		state.script_control_enabled = true
		if state.personal_info ~= nil then state.personal_info = true end
		for name in pairs(state.hotstrings or {}) do state.hotstrings[name] = true end
		for key in pairs(state.terminator_states or {}) do state.terminator_states[key] = true end
		for _, key in ipairs(transaction.enable_terminators) do
			state.terminator_states[key] = true
		end
		state.preview_star_enabled = true
		state.preview_autocorrect_enabled = true
		state.preview_ai_enabled = true

		local candidate = clone_value(transaction.preference_snapshot)
		for _, key in ipairs({
			"keymap", "gestures", "shortcuts", "llm_enabled", "keylogger_enabled",
			"script_control_enabled", "personal_info", "preview_star_enabled",
			"preview_autocorrect_enabled", "preview_ai_enabled",
		}) do
			if state[key] ~= nil then candidate[key] = state[key] end
		end
		candidate.hotstrings = clone_value(state.hotstrings or {})
		candidate.terminator_states = clone_value(state.terminator_states or {})
		for _, sections in pairs(candidate.section_states or {}) do
			if type(sections) == "table" then
				for section in pairs(sections) do sections[section] = true end
			end
		end
		candidate.shortcut_keys = {}
		for _, shortcut in ipairs(transaction.shortcut_snapshot) do
			candidate.shortcut_keys[shortcut.id] = true
		end
		transaction.candidate_preferences = candidate
	end

	--- Mutates the shared state table to the Disable All candidate.
	--- @param transaction table Active transaction.
	local function mutate_disable_state(transaction)
		state.keymap = false
		state.gestures = false
		state.shortcuts = false
		state.llm_enabled = false
		state.keylogger_enabled = false
		state.script_control_enabled = false
		if state.personal_info ~= nil then state.personal_info = false end
		for name in pairs(state.hotstrings or {}) do state.hotstrings[name] = false end
		for key in pairs(state.terminator_states or {}) do state.terminator_states[key] = false end
		state.preview_star_enabled = false
		state.preview_autocorrect_enabled = false
		state.preview_ai_enabled = false
		if type(state.script_control_shortcuts) ~= "table" then state.script_control_shortcuts = {} end
		for _, slot in ipairs(SCRIPT_SLOTS) do state.script_control_shortcuts[slot] = DISABLED_ACTION end
		transaction.candidate_preferences = clone_value(transaction.preference_snapshot)
		transaction.candidate_preferences.gesture_actions = {}
		for _, slot in ipairs(gesture_slots) do
			transaction.candidate_preferences.gesture_actions[slot] = DISABLED_ACTION
		end
		transaction.candidate_preferences.shortcut_keys = {}
		for _, shortcut in ipairs(transaction.shortcut_snapshot) do
			transaction.candidate_preferences.shortcut_keys[shortcut.id] = false
		end
	end

	--- Mutates only reset-time binding state while config files remain recoverable.
	--- @param transaction table Active transaction.
	local function mutate_reset_state(transaction)
		if type(state.script_control_shortcuts) ~= "table" then state.script_control_shortcuts = {} end
		for _, slot in ipairs(SCRIPT_SLOTS) do
			state.script_control_shortcuts[slot] = script_defaults[slot]
		end
		transaction.candidate_preferences = clone_value(transaction.preference_snapshot)
		transaction.candidate_preferences.gesture_actions = clone_value(gesture_defaults)
	end

	--- Applies every state-backed runtime binding and optional config publication.
	--- @param transaction table Active transaction.
	--- @return boolean committed
	local function apply_state_runtime(transaction)
		if transaction.kind == "disable" then
			mutate_disable_state(transaction)
		elseif transaction.kind == "enable" then
			if call_exact("Enable All keymap preflight", deps.ensure_enable_ready) ~= true then
				return false
			end
			mutate_enable_state(transaction)
		else
			mutate_reset_state(transaction)
		end
		if transaction.kind == "enable" then
			if call_exact("Gesture master enable", gestures.enable_all) ~= true then return false end
			for _, shortcut in ipairs(transaction.shortcut_snapshot) do
				if call_exact(
					"Named shortcut enable '" .. shortcut.id .. "'",
					shortcuts.enable,
					shortcut.id
				) ~= true then return false end
			end
		end
		if call_exact("Global runtime synchronization", deps.sync_runtime,
			transaction.candidate_preferences, false) ~= true then return false end
		if transaction.kind == "disable"
			and call_exact("Gesture master disable", gestures.disable_all) ~= true then
			return false
		end

		for _, slot in ipairs(transaction.kind ~= "enable" and gesture_slots or {}) do
			local target = transaction.kind == "disable"
				and DISABLED_ACTION or gesture_defaults[slot]
			if type(target) ~= "string" or call_exact(
				"Gesture setter '" .. tostring(slot) .. "'",
				gestures.set_action,
				slot,
				target
			) ~= true then return false end
		end
		for _, slot in ipairs(transaction.kind ~= "enable" and SCRIPT_SLOTS or {}) do
			local target = transaction.kind == "disable"
				and DISABLED_ACTION or script_defaults[slot]
			if type(target) ~= "string" or call_exact(
				"Script-control setter '" .. slot .. "'",
				shortcuts.set_shortcut_action,
				slot,
				target
			) ~= true then return false end
		end
		if transaction.kind == "disable" then
			for _, shortcut in ipairs(transaction.shortcut_snapshot) do
				if call_exact(
					"Named shortcut disable '" .. shortcut.id .. "'",
					shortcuts.disable,
					shortcut.id
				) ~= true then return false end
			end
		end
		return true
	end

	--- Restores the exact state/runtime snapshot and its durable publication.
	--- @param transaction table Active transaction.
	--- @return boolean committed
	local function restore_state_runtime(transaction)
		if call_exact("Global state table inverse", deps.restore_state,
			state, transaction.state_snapshot) ~= true then return false end
		if call_exact("Global runtime inverse", deps.sync_runtime,
			transaction.preference_snapshot, true) ~= true then return false end
		local gesture_master = transaction.state_snapshot.gestures == true
			and gestures.enable_all or gestures.disable_all
		if call_exact("Gesture master inverse", gesture_master) ~= true then return false end
		for _, shortcut in ipairs(transaction.shortcut_snapshot) do
			local method = shortcut.enabled and shortcuts.enable or shortcuts.disable
			if call_exact(
				"Named shortcut inverse '" .. shortcut.id .. "'",
				method,
				shortcut.id
			) ~= true then return false end
		end
		for _, slot in ipairs(transaction.kind ~= "enable" and gesture_slots or {}) do
			if call_exact(
				"Gesture inverse '" .. tostring(slot) .. "'",
				gestures.set_action,
				slot,
				transaction.gesture_snapshot[slot]
			) ~= true then return false end
		end
		for _, slot in ipairs(transaction.kind ~= "enable" and SCRIPT_SLOTS or {}) do
			if call_exact(
				"Script-control inverse '" .. slot .. "'",
				shortcuts.set_shortcut_action,
				slot,
				transaction.script_snapshot[slot]
			) ~= true then return false end
		end
		if (transaction.kind == "disable"
			or (transaction.kind == "enable" and transaction.preferences_attempted))
			and call_exact("Global preference inverse", deps.save_preferences) ~= true then
			return false
		end
		return true
	end

	--- Appends and executes one synchronous journal step.
	--- @param transaction table Active transaction.
	--- @param label string Step label.
	--- @param apply function Candidate function.
	--- @param rollback function Inverse function.
	--- @return boolean committed
	local function run_step(transaction, label, apply, rollback)
		local step = { label = label, rollback = rollback }
		transaction.journal[#transaction.journal + 1] = step
		transaction.rollback_index = #transaction.journal
		return call_exact(label, apply)
	end

	--- Executes every synchronous candidate boundary before Karabiner deployment.
	--- @param transaction table Active transaction.
	--- @return boolean committed
	local function apply_synchronous_steps(transaction)
		if run_step(
			transaction,
			"Global state and runtime candidate",
			function() return apply_state_runtime(transaction) end,
			function() return restore_state_runtime(transaction) end
		) ~= true then return false end

		if transaction.kind == "enable" then
			if run_step(
				transaction,
				"Enable All keymap feature candidate",
				function()
					return deps.apply_enable_features(transaction.candidate_preferences)
				end,
				function()
					return deps.restore_enable_features(transaction.preference_snapshot)
				end
			) ~= true then return false end
			if run_step(
				transaction,
				"Global preference publication",
				function()
					transaction.preferences_attempted = true
					return deps.save_preferences()
				end,
				function() return true end
			) ~= true then return false end
			return true
		end

		if transaction.kind == "disable" then
			if run_step(
				transaction,
				"Global preference publication",
				function() return deps.save_preferences() end,
				function() return true end
			) ~= true then return false end
		end

		for _, slot in ipairs(transaction.keyboard_snapshot) do
			local captured = slot
			if run_step(
				transaction,
				"Keyboard shortcut candidate '" .. captured.slot .. "'",
				function()
					return call_exact(
						"Keyboard shortcut setter '" .. captured.slot .. "'",
						shortcuts.set_keyboard_action,
						captured.slot,
						DISABLED_ACTION
					)
				end,
				function()
					return call_exact(
						"Keyboard shortcut inverse '" .. captured.slot .. "'",
						shortcuts.set_keyboard_action,
						captured.slot,
						captured.action
					)
				end
			) ~= true then return false end
		end

		for _, setting in ipairs(transaction.reset_settings) do
			local captured = setting
			local target = captured.key == "llm_api_entries" and {} or ""
			if run_step(
				transaction,
				"Reset setting candidate '" .. captured.key .. "'",
				function() return write_setting(captured.key, target) end,
				function() return write_setting(captured.key, captured.value) end
			) ~= true then return false end
		end

		return true
	end

	--- Captures and moves reset files only after exact Karabiner deployment.
	--- The reset deployment rewrites its own config, so capturing earlier would
	--- retain bytes that no longer match the pathname at the forward move.
	--- @param transaction table Active reset transaction.
	--- @return boolean committed
	local function apply_post_karabiner_steps(transaction)
		local entries = {}
		for _, path in ipairs(transaction.reset_paths) do
			local capture_ok, entry, detail = xpcall(function()
				return deps.file_mover.capture(path)
			end, debug.traceback)
			if not capture_ok or type(entry) ~= "table" then
				Logger.error(LOG, "Reset file snapshot failed for '%s': %s.",
					path, tostring(detail or entry))
				for index = #entries, 1, -1 do
					call_exact("Reset capture cleanup", deps.file_mover.restore, entries[index])
				end
				return false
			end
			entries[#entries + 1] = entry
		end

		if run_step(
			transaction,
			"Durable reset recovery journal",
			function() return deps.reset_journal:prepare(entries) end,
			function() return deps.reset_journal:clear() end
		) ~= true then
			for index = #entries, 1, -1 do
				call_exact("Reset capture cleanup", deps.file_mover.restore, entries[index])
			end
			return false
		end

		for _, entry in ipairs(entries) do
			if run_step(
				transaction,
				"Retained reset capability '" .. entry.path .. "'",
				function() return true end,
				function() return deps.file_mover.restore(entry) end
			) ~= true then return false end
			if run_step(
				transaction,
				"Recoverable reset move '" .. entry.path .. "'",
				function() return deps.file_mover.move(entry) end,
				function() return true end
			) ~= true then return false end
		end
		if run_step(
			transaction,
			"Durable reset commit marker",
			function() return deps.reset_journal:mark_commit() end,
			function() return deps.reset_journal:mark_prepared() end
		) ~= true then return false end
		return true
	end

	local recover_transaction

	--- Completes a failed transaction only after every inverse settles in reverse.
	--- @param transaction table Active transaction.
	--- @param reason string Candidate failure reason.
	--- @return boolean Always false for the rejected candidate.
	local function reject_transaction(transaction, reason)
		if transaction.settled or active_transaction ~= transaction then return false end
		transaction.failure_reason = tostring(reason or "candidate-refused")
		transaction.phase = "rollback"
		Logger.error(LOG, "Global %s transaction failed; exact compensation retained: %s.",
			transaction.kind, transaction.failure_reason)
		recover_transaction(transaction)
		return false
	end

	--- Runs one async method without trusting a synchronous callback before return.
	--- @param transaction table Active transaction.
	--- @param label string Stable diagnostic label.
	--- @param method function Async method accepting one callback.
	--- @param on_terminal function Callback receiving exact ok/detail.
	--- @return boolean accepted
	local function dispatch_async(transaction, label, method, on_terminal)
		local callback_seen = false
		local dispatching = true
		local queued_ok = false
		local queued_detail = nil
		local function deliver_terminal(ok, detail)
			local callback_ok, callback_result = xpcall(function()
				return on_terminal(ok == true, detail)
			end, debug.traceback)
			if not callback_ok then
				reject_transaction(
					transaction,
					label .. " callback raised: " .. tostring(callback_result)
				)
				return false
			end
			return callback_result
		end
		local function terminal(ok, detail)
			if callback_seen then
				-- A reset reload handoff can synchronously finalize logging/UI and then
				-- return while this Lua frame is still alive. Duplicate native delivery
				-- remains inert, but must not resurrect a logger capability afterwards.
				if transaction.phase ~= "reload-handoff" then
					Logger.warn(LOG, "Duplicate %s terminal ignored.", label)
				end
				return
			end
			callback_seen = true
			if dispatching then
				queued_ok = ok == true
				queued_detail = detail
				return
			end
			deliver_terminal(ok, detail)
		end

		local call_ok, accepted = xpcall(function() return method(terminal) end, debug.traceback)
		dispatching = false
		if not call_ok or accepted ~= true then
			callback_seen = true
			Logger.error(LOG, "%s request did not commit: %s.", label, tostring(accepted))
			return false
		end
		if callback_seen then deliver_terminal(queued_ok, queued_detail) end
		return true
	end

	--- Publishes the success-only UI effects after the final exact boundary.
	--- @param transaction table Committed transaction.
	local function publish_success(transaction)
		transaction.settled = true
		transaction.phase = "committed"
		if active_transaction == transaction then active_transaction = nil end
		if type(deps.notify_success) == "function" then
			local notify_ok, notify_err = xpcall(function()
				return deps.notify_success(transaction.kind)
			end, debug.traceback)
			if not notify_ok then Logger.error(LOG, "Global action success notification failed: %s.", tostring(notify_err)) end
		end
		if type(deps.update_menu) == "function" then
			local update_ok, update_err = xpcall(deps.update_menu, debug.traceback)
			if not update_ok then Logger.error(LOG, "Global action menu refresh failed: %s.", tostring(update_err)) end
		end
		Logger.success(LOG, "Global %s transaction committed.", transaction.kind)
	end

	--- Handles the exact candidate Karabiner terminal and final reload boundary.
	--- @param transaction table Active transaction.
	--- @param committed boolean Exact terminal state.
	--- @param detail any Terminal detail.
	--- @return boolean committed_action
	local function handle_candidate_terminal(transaction, committed, detail)
		if transaction.settled or active_transaction ~= transaction then return false end
		if committed ~= true then
			transaction.completion_result = false
			return reject_transaction(transaction, "Karabiner terminal refused: " .. tostring(detail))
		end
		if transaction.kind == "reset" then
			if apply_post_karabiner_steps(transaction) ~= true then
				transaction.completion_result = false
				return reject_transaction(transaction, "recoverable file move refused")
			end
			transaction.phase = "reload-handoff"
			local reload_ok, reload_result = xpcall(function()
				return deps.request_reload(function(abort_detail)
					if transaction.settled or active_transaction ~= transaction then
						return false
					end
					transaction.completion_result = false
					return reject_transaction(
						transaction,
						"reload handoff aborted: " .. tostring(abort_detail)
					)
				end)
			end, debug.traceback)
			if not reload_ok or reload_result ~= true then
				transaction.completion_result = false
				return reject_transaction(transaction, "reload handoff refused: " .. tostring(reload_result))
			end
			-- Ownership now belongs jointly to this retained global mutation fence and
			-- the controlled reload coordinator. Do not clear the owner, notify,
			-- refresh the menu, or log after request_reload(): a synchronous coordinator
			-- may already have finalized every local capability before hs.reload returns.
			return true
		end
		publish_success(transaction)
		transaction.completion_result = true
		return true
	end

	--- Dispatches the candidate Karabiner bulk mutation.
	--- @param transaction table Active transaction.
	--- @return boolean accepted_or_completed
	local function dispatch_candidate(transaction)
		transaction.karabiner_attempted = true
		transaction.karabiner_journal_index = transaction.rollback_index
		transaction.phase = "karabiner-candidate"
		local method = transaction.kind == "disable"
			and deps.karabiner.clear_all_bindings
			or deps.karabiner.reset_to_defaults
		local accepted = dispatch_async(
			transaction,
			"Global " .. transaction.kind .. " Karabiner deployment",
			method,
			function(ok, detail) return handle_candidate_terminal(transaction, ok, detail) end
		)
		if accepted ~= true then return reject_transaction(transaction, "Karabiner request refused") end
		if transaction.completion_result ~= nil then return transaction.completion_result end
		return true
	end

	--- Retries the retained Karabiner inverse and synchronous journal debt.
	--- @param transaction table Active failed transaction.
	--- @return boolean settled
	recover_transaction = function(transaction)
		if active_transaction ~= transaction or transaction.settled then return false end
		if transaction.recovery_pending or transaction.recovery_running then return false end
		transaction.recovery_running = true
		local function finish(result)
			transaction.recovery_running = false
			return result
		end
		local karabiner_index = transaction.karabiner_journal_index
			or transaction.rollback_index
		transaction.phase = "post-karabiner-journal-inverse"
		while transaction.rollback_index > karabiner_index do
			local step = transaction.journal[transaction.rollback_index]
			if call_exact(step.label .. " inverse", step.rollback) ~= true then
				Logger.error(LOG, "Global compensation debt retained at '%s'.", step.label)
				return finish(false)
			end
			transaction.rollback_index = transaction.rollback_index - 1
		end
		if transaction.karabiner_attempted and not transaction.karabiner_restored then
			transaction.phase = "karabiner-inverse"
			transaction.recovery_pending = true
			local accepted = dispatch_async(
				transaction,
				"Global Karabiner inverse",
				function(on_done)
					return deps.karabiner.restore_settings(
						clone_value(transaction.karabiner_snapshot),
						on_done
					)
				end,
				function(ok, detail)
					transaction.recovery_pending = false
					if ok ~= true then
						Logger.error(LOG, "Global Karabiner inverse remains pending: %s.", tostring(detail))
						return false
					end
					transaction.karabiner_restored = true
					if transaction.recovery_running then return true end
					return recover_transaction(transaction)
				end
			)
			if accepted ~= true then
				transaction.recovery_pending = false
				return finish(false)
			end
			if transaction.settled then return finish(true) end
			if transaction.recovery_pending then return finish(false) end
			if not transaction.karabiner_restored then return finish(false) end
		end

		transaction.phase = "journal-inverse"
		while transaction.rollback_index > 0 do
			local step = transaction.journal[transaction.rollback_index]
			if call_exact(step.label .. " inverse", step.rollback) ~= true then
				Logger.error(LOG, "Global compensation debt retained at '%s'.", step.label)
				return finish(false)
			end
			transaction.rollback_index = transaction.rollback_index - 1
		end
		transaction.settled = true
		transaction.phase = "rolled-back"
		if active_transaction == transaction then active_transaction = nil end
		Logger.info(LOG, "Global %s transaction rolled back exactly.", transaction.kind)
		return finish(true)
	end

	--- Starts one global transaction after settling any retained inverse debt.
	--- @param kind string `disable` or `reset`.
	--- @return boolean accepted_or_committed
	local function request(kind)
		if external_writer ~= nil then
			Logger.warn(LOG, "Global %s action refused while external writer '%s' is active.",
				kind, tostring(external_writer.label))
			return false
		end
		if active_transaction then
			if active_transaction.phase == "rollback"
				or active_transaction.phase == "post-karabiner-journal-inverse"
				or active_transaction.phase == "karabiner-inverse"
				or active_transaction.phase == "journal-inverse" then
				if recover_transaction(active_transaction) ~= true then return false end
			else
				Logger.warn(LOG, "Global %s action refused while '%s' is pending.",
					kind, tostring(active_transaction.phase))
				return false
			end
		end

		local snapshot_owner = {
			kind = kind,
			phase = "terminal-preflight",
			settled = false,
		}
		active_transaction = snapshot_owner
		local pending_ok, terminal_pending = xpcall(
			deps.terminal_pending, debug.traceback)
		if active_transaction ~= snapshot_owner then return false end
		if not pending_ok or type(terminal_pending) ~= "boolean" or terminal_pending then
			snapshot_owner.settled = true
			active_transaction = nil
			Logger.warn(LOG,
				"Global %s action refused because terminal quiescence was not proved: %s.",
				kind, tostring(terminal_pending))
			return false
		end
		snapshot_owner.phase = "snapshot"
		Logger.start(LOG, "Starting global %s transaction…", kind)
		local transaction = build_plan(kind)
		if active_transaction ~= snapshot_owner then return false end
		if not transaction then
			snapshot_owner.settled = true
			active_transaction = nil
			return false
		end
		active_transaction = transaction
		transaction.phase = "synchronous-candidate"
		if apply_synchronous_steps(transaction) ~= true then
			return reject_transaction(transaction, "synchronous candidate refused")
		end
		if kind == "enable" then
			publish_success(transaction)
			return true
		end
		return dispatch_candidate(transaction)
	end

	local owner = {}

	--- Requests the exact Enable All transaction.
	--- @return boolean committed
	function owner.enable_all()
		return request("enable")
	end

	--- Runs one non-transactional global writer under the same admission fence as
	--- Disable All and Reset. The token is published before any opaque preflight
	--- and released by identity after the callback returns or throws.
	--- @param label string Diagnostic action label.
	--- @param callback function Entire external writer body.
	--- @return any result Exact callback result, or false on refusal/throw.
	function owner.run_exclusive(label, callback)
		if type(callback) ~= "function" then
			Logger.error(LOG, "Global external writer '%s' has no callback.", tostring(label))
			return false
		end
		if active_transaction ~= nil or external_writer ~= nil then
			Logger.warn(LOG, "Global external writer '%s' refused while another owner is active.",
				tostring(label))
			return false
		end
		external_writer_generation = external_writer_generation + 1
		local token = {
			generation = external_writer_generation,
			label = label,
		}
		external_writer = token
		local pending_ok, terminal_pending = xpcall(
			deps.terminal_pending, debug.traceback)
		if not pending_ok or type(terminal_pending) ~= "boolean" or terminal_pending then
			if external_writer == token then external_writer = nil end
			Logger.warn(LOG,
				"Global external writer '%s' refused because terminal quiescence was not proved: %s.",
				tostring(label), tostring(terminal_pending))
			return false
		end
		local ok, result = xpcall(callback, debug.traceback)
		if external_writer == token then external_writer = nil end
		if not ok then
			Logger.error(LOG, "Global external writer '%s' raised: %s.",
				tostring(label), tostring(result))
			return false
		end
		return result
	end

	--- Requests the exact Disable All transaction.
	--- @return boolean accepted_or_committed
	function owner.disable_all()
		return request("disable")
	end

	--- Requests the exact factory-reset transaction.
	--- @return boolean accepted_or_committed
	function owner.reset_defaults()
		return request("reset")
	end

	--- Reports whether a candidate or retained compensation currently owns state.
	--- @return boolean pending
	function owner.is_pending()
		return external_writer ~= nil
			or (active_transaction ~= nil and not active_transaction.settled)
	end

	return owner
end

return M
