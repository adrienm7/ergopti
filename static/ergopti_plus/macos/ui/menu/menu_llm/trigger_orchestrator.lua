--- ui/menu/menu_llm/trigger_orchestrator.lua

--- ==============================================================================
--- MODULE: Menu LLM — Trigger Orchestrator
--- DESCRIPTION:
--- Manages hotkey binding, activation, and profile-triggered prediction for the
--- LLM menu. Extracted from menu_llm/init.lua to keep the orchestrator thin.
---
--- FEATURES & RATIONALE:
--- 1. Single Responsibility: owns all hs.hotkey lifecycle — create, enable,
---    delete — so init.lua never touches hotkey objects directly.
--- 2. Profile Triggering: encapsulates the profile-swap-and-restore dance
---    (set active profile → fire prediction → restore previous profile).
--- 3. Shortcut Application: normalises raw mods/key pairs via shortcut_ui,
---    tears down the old hotkey, and wires up the new one atomically.
--- 4. Getter/Setter Closures: exposes get_trigger_hk / get_profile_hks so
---    startup_controller can reattach hotkeys without holding stale refs.
--- ==============================================================================

local M = {}

local Logger    = require("infra.logger")
local llm_mod   = require("modules.llm")
local Chord     = require("chord")
local Hotkeys   = require("adapters.hotkey_registrar")
local shortcut_ui = require("ui.menu.shortcut_utils")

local LOG = "menu_llm.trigger_orchestrator"





-- =====================================
-- =====================================
-- ======= 1/ Module Constructor =======
-- =====================================
-- =====================================

--- Creates a new trigger orchestrator bound to the given context.
--- @param ctx table Required fields: state, keymap, save_prefs, update_menu,
---   get_startup_silence, set_startup_silence, get_trigger_hk, get_profile_hks.
---   The last four are closures into init.lua's locals so the orchestrator
---   never holds stale references to the hotkey objects.
--- @return table Instance with: bind_hotkey, activate_hotkey,
---   trigger_prediction_with_profile, apply_llm_shortcut,
---   apply_llm_profile_shortcut.
function M.new(ctx)
	if type(ctx) ~= "table" then
		Logger.error(LOG, "M.new(): ctx must be a table — module non-functional.")
		return {}
	end

	local state              = ctx.state
	local keymap             = ctx.keymap
	local save_prefs         = ctx.save_prefs
	local update_menu        = ctx.update_menu
	local get_startup_silence = ctx.get_startup_silence
	local get_trigger_hk     = ctx.get_trigger_hk
	local get_profile_hks    = ctx.get_profile_hks
	local set_trigger_hk     = ctx.set_trigger_hk
	local set_profile_hk     = ctx.set_profile_hk

	local inst = {}
	local handle_records = {}
	local cleanup_debts = {}
	local recovery_debt = nil
	local restore_fence = 0

	--- Creates a detached shortcut snapshot for comparison and rollback.
	--- @param value any Shortcut value.
	--- @return any clone
	local function clone_value(value)
		if type(value) ~= "table" then return value end
		local clone = {}
		for key_name, child in pairs(value) do clone[clone_value(key_name)] = clone_value(child) end
		return clone
	end

	--- Compares two normalized shortcut values without relying on table identity.
	--- @param left table|boolean|nil First shortcut.
	--- @param right table|boolean|nil Second shortcut.
	--- @return boolean equal
	local function shortcuts_equal(left, right)
		if type(left) ~= "table" or type(right) ~= "table" then return left == right end
		if left.key ~= right.key then return false end
		if type(left.mods) ~= "table" or type(right.mods) ~= "table" then
			return left.mods == right.mods
		end
		if #left.mods ~= #right.mods then return false end
		for index, modifier in ipairs(left.mods) do
			if right.mods[index] ~= modifier then return false end
		end
		return true
	end

	--- Invokes a registrar lifecycle boundary and accepts only literal success.
	--- @param label string Boundary label.
	--- @param callback function|nil Registrar callback.
	--- @param ... any Arguments forwarded to callback.
	--- @return boolean settled
	local function invoke_hotkey_boundary(label, callback, ...)
		if type(callback) ~= "function" then
			Logger.error(LOG, "%s refused because its lifecycle callback is unavailable.", label)
			return false
		end
		local ok, result = xpcall(callback, debug.traceback, ...)
		if not ok or result ~= true then
			Logger.error(LOG, "%s refused: %s.", label, tostring(result))
			return false
		end
		return true
	end

	--- Invokes the required preference publisher with exact settlement.
	--- @param label string Boundary label.
	--- @return boolean committed
	local function persist_shortcuts(label)
		if type(save_prefs) ~= "function" then
			Logger.error(LOG, "%s refused because save_prefs is unavailable.", label)
			return false
		end
		local ok, result = xpcall(save_prefs, debug.traceback)
		if not ok or result ~= true then
			Logger.error(LOG, "%s refused: %s.", label, tostring(result))
			return false
		end
		return true
	end

	--- Refreshes the menu without interpreting nil as an operational refusal.
	--- @param label string Boundary label.
	--- @return boolean settled
	local function refresh_menu(label)
		if type(update_menu) ~= "function" then
			Logger.error(LOG, "%s refused because update_menu is unavailable.", label)
			return false
		end
		local ok, result = xpcall(update_menu, debug.traceback)
		if not ok or result == false then
			Logger.error(LOG, "%s refused: %s.", label, tostring(result))
			return false
		end
		return true
	end

	--- Adds one nested preference-restore fence.
	local function open_restore_fence()
		restore_fence = restore_fence + 1
	end

	--- Releases one nested preference-restore fence.
	local function close_restore_fence()
		if restore_fence > 0 then restore_fence = restore_fence - 1 end
	end

	--- Changes native delivery without publishing the record's callback gate.
	--- @param record table Owned record.
	--- @param enabled boolean Desired native state.
	--- @param label string Boundary label.
	--- @return boolean settled
	local function set_record_enabled(record, enabled, label)
		if type(record) ~= "table" or record.handle == nil then return false end
		return invoke_hotkey_boundary(label, Hotkeys.setEnabled, record.handle, enabled)
	end

	--- Releases one exact record and forgets it only after registrar settlement.
	--- @param record table Owned record.
	--- @param label string Boundary label.
	--- @return boolean settled
	local function release_record(record, label)
		if type(record) ~= "table" or record.handle == nil then return true end
		record.committed = false
		-- A failed disable is not terminal if unbind can still release the owner
		set_record_enabled(record, false, label .. " disable")
		if not invoke_hotkey_boundary(label .. " delete", Hotkeys.unbind, record.handle) then
			return false
		end
		handle_records[record.handle] = nil
		record.handle = nil
		return true
	end

	--- Retains an inert record whose native release must be retried.
	--- @param record table Owned record.
	local function retain_cleanup_debt(record)
		if type(record) ~= "table" or record.handle == nil or record.cleanup_queued then return end
		record.committed = false
		record.cleanup_queued = true
		cleanup_debts[#cleanup_debts + 1] = record
	end

	--- Retries every inert candidate/retired handle before admitting new work.
	--- @return boolean settled
	local function settle_cleanup_debts()
		if #cleanup_debts == 0 then return true end
		local pending = {}
		for _, record in ipairs(cleanup_debts) do
			record.cleanup_queued = false
			if not release_record(record, "Retained LLM shortcut cleanup") then
				record.cleanup_queued = true
				pending[#pending + 1] = record
			end
		end
		cleanup_debts = pending
		if #cleanup_debts > 0 then
			Logger.error(LOG, "LLM shortcut cleanup remains pending for %d exact handle(s).",
				#cleanup_debts)
			return false
		end
		return true
	end

	--- Acquires a registrar handle behind an inert callback gate, then disables it.
	--- @param mods table Modifier list.
	--- @param key string Key name.
	--- @param callback function User callback.
	--- @return table|nil record
	local function acquire_record(mods, key, callback)
		local chord_ok, chord, chord_error = xpcall(Chord.format, debug.traceback, mods, key)
		if not chord_ok or type(chord) ~= "string" or chord == "" then
			Logger.error(LOG, "LLM shortcut chord construction refused: %s.",
				tostring(chord_ok and chord_error or chord))
			return nil
		end

		local record = {
			callback = callback,
			chord = chord,
			committed = false,
			handle = nil,
		}
		local ok, handle = xpcall(Hotkeys.bind, debug.traceback, chord, function(...)
			if record.committed ~= true then return false end
			return record.callback(...)
		end)
		if not ok or not handle then
			Logger.error(LOG, "LLM shortcut acquisition refused for %s: %s.",
				chord, tostring(handle))
			return nil
		end
		record.handle = handle
		handle_records[handle] = record

		-- Registrar.bind() returns an active native binding. The callback gate above
		-- is already closed, and native disable makes the successor fully staged
		if not set_record_enabled(record, false, "LLM shortcut candidate staging") then
			if not release_record(record, "Rejected LLM shortcut candidate") then
				retain_cleanup_debt(record)
			end
			return nil
		end
		return record
	end

	--- Restores the exact prior record's delivery state.
	--- @param record table|nil Prior record.
	--- @param should_deliver boolean Prior callback publication state.
	--- @return boolean settled
	local function restore_record(record, should_deliver)
		if not record then return true end
		if should_deliver ~= true then
			record.committed = false
			return set_record_enabled(record, false, "LLM shortcut rollback disable")
		end
		if not set_record_enabled(record, true, "LLM shortcut rollback enable") then
			record.committed = false
			return false
		end
		record.committed = true
		return true
	end

	--- Restores a rejected shortcut transition and retains unsettled compensation.
	--- @param debt table Mutable transition ledger.
	--- @return boolean settled
	local function restore_transition(debt)
		debt.restore_preference()
		local failures = {}

		if debt.persistence then
			if persist_shortcuts("LLM shortcut preference rollback") then
				debt.persistence = false
			else
				failures[#failures + 1] = "preference rollback"
			end
			-- A transactional writer may restore its last committed candidate when
			-- compensation refuses; reclaim this shortcut field immediately
			debt.restore_preference()
		end

		if debt.candidate then
			if not release_record(debt.candidate, "LLM shortcut candidate rollback") then
				retain_cleanup_debt(debt.candidate)
			end
			debt.candidate = nil
		end

		if debt.old_restore then
			if restore_record(debt.old_record, debt.old_should_deliver) then
				debt.old_restore = false
			else
				failures[#failures + 1] = "native rollback"
			end
		end

		if debt.menu then
			if refresh_menu("LLM shortcut menu rollback") then
				debt.menu = false
			else
				failures[#failures + 1] = "menu rollback"
			end
		end

		if #failures > 0 then
			recovery_debt = debt
			Logger.error(LOG, "LLM shortcut rollback remains pending at: %s.",
				table.concat(failures, ", "))
			return false
		end

		recovery_debt = nil
		close_restore_fence()
		return true
	end

	--- Retries retained compensation before another shortcut transition.
	--- @return boolean settled
	local function settle_recovery_debt()
		if not recovery_debt then return true end
		Logger.warn(LOG, "Retrying retained LLM shortcut rollback before a new action.")
		return restore_transition(recovery_debt)
	end

	--- Settles all exact owners before admitting a new transition.
	--- @return boolean settled
	local function settle_debts()
		if not settle_recovery_debt() then return false end
		return settle_cleanup_debts()
	end


	--- Safely acquires a disabled registrar handle.
	--- @param mods table Modifier list (e.g. {"ctrl"}).
	--- @param key string Key name.
	--- @param callback function Called on key press.
	--- @return any|nil Opaque registrar handle or nil.
	function inst.bind_hotkey(mods, key, callback)
		Logger.debug(LOG, "Attempting hotkey bind: mods=%s, key=%s",
			type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
			key or "nil")
		if not settle_debts() then return nil end
		local record = acquire_record(mods, key, callback)
		if record then
			Logger.debug(LOG, "Hotkey created successfully: %s+%s",
				type(mods) == "table" and table.concat(mods, "+") or "", key or "")
			return record.handle
		else
			Logger.error(LOG, "Hotkey binding failed for %s+%s.",
				type(mods) == "table" and table.concat(mods, "+") or "", key or "")
			return nil
		end
	end


	--- Enables an exact registrar-owned hotkey.
	--- Returns true on success, false otherwise.
	--- @param hk any Opaque registrar handle.
	--- @return boolean
	function inst.activate_hotkey(hk)
		local record = handle_records[hk]
		if not record then
			Logger.error(LOG, "Cannot activate an unowned LLM hotkey handle.")
			return false
		end
		if not set_record_enabled(record, true, "LLM shortcut activation") then return false end
		record.committed = true
		return true
	end


	--- Fires a one-shot prediction under a specific LLM profile, then restores
	--- the previously active profile. Designed for profile-shortcut triggers.
	--- @param profile_id string The profile to activate transiently.
	function inst.trigger_prediction_with_profile(profile_id)
		if type(profile_id) ~= "string" or profile_id == "" then
			Logger.warn(LOG, "trigger_prediction_with_profile: invalid profile_id: %s", tostring(profile_id))
			return
		end
		if not keymap or type(keymap.trigger_prediction) ~= "function" then
			Logger.error(LOG, "trigger_prediction_with_profile: keymap or trigger_prediction is unavailable.")
			return
		end

		Logger.debug(LOG, "Triggering prediction with profile '%s'", profile_id)

		if type(keymap.reset_predictions) == "function" then
			pcall(keymap.reset_predictions)
			Logger.debug(LOG, "Active predictions cancelled before profile trigger.")
		end

		local previous_profile = state.llm_active_profile or "basic"
		Logger.debug(LOG, "Changing profile: %s -> %s", previous_profile, profile_id)

		-- Resolve a human-readable label for the notification toast.
		local profile_label = profile_id
		for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
			if type(profile) == "table" and profile.id == profile_id and type(profile.label) == "string" then
				profile_label = profile.label
				break
			end
		end
		if profile_label == profile_id then
			for _, profile in ipairs(type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}) do
				if type(profile) == "table" and profile.id == profile_id and type(profile.label) == "string" then
					profile_label = profile.label
					break
				end
			end
		end

		llm_mod.set_active_profile(profile_id)
		pcall(keymap.trigger_prediction, true, profile_label)
		llm_mod.set_active_profile(previous_profile)

		Logger.debug(LOG, "Profile restored: %s", previous_profile)
	end


	--- Applies one exact shortcut transition over native, state, and persistence.
	--- @param spec table Slot-specific getters/setters and log label.
	--- @param normalized table|nil Desired normalized shortcut.
	--- @param callback function Candidate press callback.
	--- @param opts table|nil Transition options.
	--- @return boolean committed
	local function apply_shortcut_transition(spec, normalized, callback, opts)
		opts = type(opts) == "table" and opts or {}
		if not settle_debts() then return false end
		if restore_fence > 0 then
			Logger.error(LOG, "%s refused while another exact shortcut transaction is unsettled.",
				spec.label)
			return false
		end

		local old_handle = spec.get_handle()
		local old_record = old_handle and handle_records[old_handle] or nil
		if old_handle and not old_record then
			Logger.error(LOG, "%s refused because its exact handle is not owned.", spec.label)
			return false
		end
		local old_preference = spec.get_preference()
		local restore_preference = type(spec.make_preference_restore) == "function"
			and spec.make_preference_restore(old_preference)
			or function() spec.set_preference(old_preference) end
		local desired_preference = normalized and {
			mods = clone_value(normalized.mods),
			key = normalized.key,
		} or spec.disabled_value
		local should_deliver = opts.activate ~= false

		-- A disable request must still release any live native owner even when a
		-- stale/malformed preference already says "disabled". Equality is a no-op
		-- only when both the desired action and its exact owner exist.
		if old_record and normalized
			and shortcuts_equal(old_preference, desired_preference) then
			if should_deliver then
				if old_record.committed ~= true then
					return inst.activate_hotkey(old_handle)
				end
				return true
			end
			-- A repeated startup/restoration pass can request the same chord behind
			-- a silent gate. Close logical delivery before asking the registrar to
			-- settle native suspension, and keep the exact owner retryable on refusal.
			old_record.committed = false
			return set_record_enabled(old_record, false,
				spec.label .. " existing-owner suspension")
		end
		if not old_record and not normalized
			and shortcuts_equal(old_preference, desired_preference) then
			return true
		end

		local candidate = nil
		if normalized then
			candidate = acquire_record(normalized.mods, normalized.key, callback)
			if not candidate then return false end
			if should_deliver
				and not set_record_enabled(candidate, true, spec.label .. " candidate activation") then
				if not release_record(candidate, spec.label .. " rejected candidate") then
					retain_cleanup_debt(candidate)
				end
				return false
			end
		end

		open_restore_fence()
		local debt = {
			candidate = candidate,
			old_preference = old_preference,
			old_record = old_record,
			old_restore = false,
			old_should_deliver = old_record and old_record.committed == true or false,
			menu = false,
			persistence = false,
			restore_preference = restore_preference,
		}

		if old_record then
			old_record.committed = false
			debt.old_restore = true
			if not set_record_enabled(old_record, false, spec.label .. " prior-owner suspension") then
				recovery_debt = debt
				restore_transition(debt)
				return false
			end
		end

		spec.set_preference(clone_value(desired_preference))
		if opts.persist == true then
			debt.persistence = true
			if not persist_shortcuts(spec.label .. " preference commit") then
				recovery_debt = debt
				restore_transition(debt)
				return false
			end
		end

		if opts.persist == true then
			debt.menu = true
			if not refresh_menu(spec.label .. " menu refresh") then
				recovery_debt = debt
				restore_transition(debt)
				return false
			end
		end

		if old_record and not release_record(old_record, spec.label .. " prior-owner release") then
			recovery_debt = debt
			restore_transition(debt)
			return false
		end
		debt.old_restore = false

		if candidate then
			spec.set_handle(candidate.handle)
			candidate.committed = should_deliver
			debt.candidate = nil
		else
			spec.set_handle(nil)
		end
		close_restore_fence()

		Logger.debug(LOG, "%s committed.", spec.label)
		return true
	end

	--- Tears down or replaces the global LLM trigger as one exact transaction.
	--- @param mods table|nil Modifier list.
	--- @param key string|nil Key name.
	--- @param opts table|nil Optional persistence controls.
	--- @return boolean committed
	function inst.apply_llm_shortcut(mods, key, opts)
		opts = type(opts) == "table" and opts or {}
		local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
		local persist = opts.persist ~= false and not get_startup_silence()
		return apply_shortcut_transition({
			label = "Primary LLM shortcut",
			disabled_value = false,
			get_handle = get_trigger_hk,
			set_handle = set_trigger_hk,
			get_preference = function() return state.llm_trigger_shortcut end,
			set_preference = function(value) state.llm_trigger_shortcut = value end,
		}, normalized, function()
			if keymap and type(keymap.trigger_prediction) == "function" then
				local ok, result = xpcall(keymap.trigger_prediction, debug.traceback, true)
				if not ok then
					Logger.error(LOG, "Primary LLM shortcut callback raised: %s.", tostring(result))
					return false
				end
				return result
			end
			return false
		end, {
			activate = not get_startup_silence(),
			persist = persist,
		})
	end

	--- Rebuilds both native hotkey sets from an acknowledged preference snapshot.
	--- @param snapshot table Last committed preference snapshot.
	--- @return boolean restored
	function inst.restore_shortcuts(snapshot)
		if type(snapshot) ~= "table" then return false end
		if restore_fence > 0 then
			Logger.debug(LOG,
				"Shortcut snapshot restoration deferred to the active exact transaction owner.")
			return true
		end
		if not settle_debts() then return false end
		local restored = true
		local trigger = snapshot.llm_trigger_shortcut
		if type(trigger) == "table" then
			if inst.apply_llm_shortcut(trigger.mods, trigger.key, {persist = false}) ~= true then
				restored = false
			end
		else
			if inst.apply_llm_shortcut(nil, nil, {persist = false}) ~= true then
				restored = false
			end
		end

		local desired = type(snapshot.llm_profile_shortcuts) == "table"
			and snapshot.llm_profile_shortcuts or {}
		local existing_ids = {}
		for profile_id in pairs(get_profile_hks()) do existing_ids[#existing_ids + 1] = profile_id end
		for _, profile_id in ipairs(existing_ids) do
			if desired[profile_id] == nil then
				if inst.apply_llm_profile_shortcut(profile_id, nil, nil, {persist = false}) ~= true then
					restored = false
				end
			end
		end
		for profile_id, shortcut in pairs(desired) do
			if type(shortcut) == "table" then
				if inst.apply_llm_profile_shortcut(profile_id, shortcut.mods, shortcut.key,
					{persist = false}) ~= true then
					restored = false
				end
			end
		end
		return restored
	end


	--- Begins a parent-owned profile deletion without releasing the exact handle.
	--- @param profile_id string Profile id.
	--- @return table|nil lease Deferred removal lease.
	local function begin_profile_removal(profile_id)
		if not settle_debts() then return nil end
		if restore_fence > 0 then return nil end
		local old_handle = get_profile_hks()[profile_id]
		local old_record = old_handle and handle_records[old_handle] or nil
		if old_handle and not old_record then
			Logger.error(LOG,
				"Profile shortcut removal refused because '%s' has an unowned handle.", profile_id)
			return nil
		end
		local old_preference = type(state.llm_profile_shortcuts) == "table"
			and state.llm_profile_shortcuts[profile_id] or nil
		local old_shortcuts = state.llm_profile_shortcuts
		local old_should_deliver = old_record and old_record.committed == true or false

		open_restore_fence()
		if old_record then
			old_record.committed = false
			if not set_record_enabled(old_record, false,
				"Profile shortcut deferred-removal suspension") then
				local debt = {
					candidate = nil,
					old_preference = old_preference,
					old_record = old_record,
					old_restore = true,
					old_should_deliver = old_should_deliver,
					persistence = false,
					restore_preference = function()
						state.llm_profile_shortcuts = old_shortcuts
						if type(old_shortcuts) == "table" then
							old_shortcuts[profile_id] = old_preference
						end
					end,
				}
				recovery_debt = debt
				restore_transition(debt)
				return nil
			end
		end

		local active = true
		local published = false
		local restored = false
		local lease = {}

		--- Publishes only the in-memory shortcut preference into the parent snapshot.
		--- @return boolean published_now
		function lease.publish()
			if not active then return false end
			if type(state.llm_profile_shortcuts) ~= "table" then
				state.llm_profile_shortcuts = {}
			end
			state.llm_profile_shortcuts[profile_id] = nil
			published = true
			return true
		end

		--- Releases the old native handle after the parent persistence commit.
		--- @return boolean settled
		function lease.commit()
			if not active or not published then return false end
			if old_record and not release_record(old_record,
				"Profile shortcut deferred-removal release") then
				return false
			end
			set_profile_hk(profile_id, nil)
			active = false
			close_restore_fence()
			return true
		end

		--- Restores the old preference and native delivery without closing the fence.
		--- @return boolean settled
		function lease.restore()
			if not active then return false end
			state.llm_profile_shortcuts = old_shortcuts
			if type(old_shortcuts) == "table" then
				old_shortcuts[profile_id] = old_preference
			end
			restored = restore_record(old_record, old_should_deliver)
			return restored
		end

		--- Closes a successfully restored parent rollback.
		--- @return boolean settled
		function lease.finish_rollback()
			if not active or not restored then return false end
			active = false
			close_restore_fence()
			return true
		end

		return lease
	end

	--- Replaces or disables one profile shortcut transactionally.
	--- @param profile_id string The profile this shortcut belongs to.
	--- @param mods table|nil Modifier list.
	--- @param key string|nil Key name.
	--- @param opts table|nil Optional persistence or deferred-removal controls.
	--- @return boolean|table committed Or a deferred removal lease.
	function inst.apply_llm_profile_shortcut(profile_id, mods, key, opts)
		if type(profile_id) ~= "string" or profile_id == "" then return false end
		opts = type(opts) == "table" and opts or {}
		local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
		Logger.debug(LOG, "apply_llm_profile_shortcut('%s', mods=%s, key=%s) -> normalized=%s",
			profile_id,
			type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
			key or "nil",
			normalized and (table.concat(normalized.mods, "+") .. "+" .. normalized.key) or "nil")
		if opts.defer == true then
			if normalized then return false end
			return begin_profile_removal(profile_id)
		end

		local persist = opts.persist ~= false and opts.silent ~= true
		return apply_shortcut_transition({
			label = "Profile LLM shortcut '" .. profile_id .. "'",
			disabled_value = nil,
			get_handle = function() return get_profile_hks()[profile_id] end,
			set_handle = function(value) set_profile_hk(profile_id, value) end,
			get_preference = function()
				return type(state.llm_profile_shortcuts) == "table"
					and state.llm_profile_shortcuts[profile_id] or nil
			end,
			set_preference = function(value)
				if type(state.llm_profile_shortcuts) ~= "table" then
					state.llm_profile_shortcuts = {}
				end
				state.llm_profile_shortcuts[profile_id] = value
			end,
			make_preference_restore = function(old_value)
				local old_shortcuts = state.llm_profile_shortcuts
				return function()
					state.llm_profile_shortcuts = old_shortcuts
					if type(old_shortcuts) == "table" then
						old_shortcuts[profile_id] = old_value
					end
				end
			end,
		}, normalized, function()
			Logger.debug(LOG, "Profile shortcut triggered: '%s'", profile_id)
			return inst.trigger_prediction_with_profile(profile_id)
		end, {
			activate = opts.silent ~= true,
			persist = persist,
		})
	end

	return inst
end

return M
