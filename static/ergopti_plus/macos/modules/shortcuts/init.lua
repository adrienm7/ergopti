--- modules/shortcuts/init.lua

--- ==============================================================================
--- MODULE: Shortcuts Core
--- DESCRIPTION:
--- Orchestrates the entire shortcuts subsystem by grouping standard text/system 
--- utilities and the script lifecycle controls (pause, reload).
---
--- FEATURES & RATIONALE:
--- 1. Subsystem Delegation: Isolates standard utility shortcuts from panic buttons.
--- 2. Single API Surface: Exposes a unified set of controls to the UI Menu.
--- ==============================================================================

local hs = hs

local Bindings          = require("modules.shortcuts.bindings")
local ScriptControl     = require("modules.shortcuts.script_control")
local KeyboardShortcuts = require("modules.shortcuts.keyboard_shortcuts")
local GestureActions    = require("modules.gestures.actions")
local HotkeyRegistrar   = require("adapters.hotkey_registrar")
local StartupTransaction = require("infra.startup_transaction")
local Logger             = require("infra.logger")

local M = {}

local LOG = "shortcuts"
local SHORTCUT_ACTION_PARENT = "shortcut_bindings"
local DEFAULT_BINDING_PAUSE_CLAIM = "feature_toggle"
local REBIND_RECOVERY_CLAIM = "layout_rebind_recovery"
local binding_pause_claims = {}
local binding_lifecycle_epoch = 0
local binding_start_attempt = nil

--- Invalidates every in-flight aggregate start/resume transaction.
local function invalidate_binding_lifecycle()
	binding_lifecycle_epoch = binding_lifecycle_epoch + 1
end

--- Publishes one admission-authoritative pause claim.
--- @param claim string Stable claim identity.
local function add_binding_pause_claim(claim)
	binding_pause_claims[claim] = true
	invalidate_binding_lifecycle()
end

--- Normalizes one parent lifecycle claim.
--- @param parent string|nil Stable pause parent.
--- @return string claim
local function binding_pause_claim(parent)
	return type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_BINDING_PAUSE_CLAIM
end

--- @return boolean claimed
local function binding_pause_claimed()
	return next(binding_pause_claims) ~= nil
end

local function binding_external_pause_claimed()
	for claim in pairs(binding_pause_claims) do
		if claim ~= REBIND_RECOVERY_CLAIM then return true end
	end
	return false
end

local function release_rebind_recovery_claim()
	if binding_pause_claims[REBIND_RECOVERY_CLAIM] == true then
		binding_pause_claims[REBIND_RECOVERY_CLAIM] = nil
		invalidate_binding_lifecycle()
		return true
	end
	return false
end

--- Opens the action scope shared by static and configurable shortcuts.
--- @return boolean committed
local function resume_shortcut_actions()
	return GestureActions.resume_after_cleanup(SHORTCUT_ACTION_PARENT)
end

--- Fences and joins only shortcut-origin gesture-catalogue actions.
--- @return boolean settled
local function pause_shortcut_actions()
	return GestureActions.force_cleanup(SHORTCUT_ACTION_PARENT)
end

-- One live fence covers every adapter-owned native hotkey, including UI
-- shortcuts that are intentionally kept registered while the bindings layer is
-- stopped. The callback resolves ScriptControl at delivery time, so a pause or
-- resume takes effect without a fragile rebind sweep.
HotkeyRegistrar.set_delivery_guard(function()
	return ScriptControl.is_paused() ~= true
end)





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	shortcuts                = true,
	script_control_enabled   = true,
	script_control_shortcuts = { return_key = "script_pause_toggle", backspace = "script_reload", escape = "script_quit" },
	chatgpt_url              = Bindings.DEFAULT_CHATGPT_URL,
}





-- ========================================
-- ========================================
-- ======= 2/ Base API & Forwarding =======
-- ========================================
-- ========================================

-- Proxy Bindings Methods
M.DEFAULT_CHATGPT_URL    = Bindings.DEFAULT_CHATGPT_URL
M.list_shortcuts         = Bindings.list_shortcuts
M.enable                 = Bindings.enable
M.disable                = Bindings.disable
M.is_enabled             = Bindings.is_enabled
M.set_wrap_pairs_getter  = Bindings.set_wrap_pairs_getter
M.set_chatgpt_url        = Bindings.set_chatgpt_url

-- Proxy Script Control Methods
M.ACTIONS               = ScriptControl.ACTIONS
M.ACTION_LABELS         = ScriptControl.ACTION_LABELS
M.start_script_control  = ScriptControl.start
M.stop_script_control   = ScriptControl.stop
M.is_paused             = ScriptControl.is_paused
M.is_pause_transition_pending = ScriptControl.is_pause_transition_pending
M.get_pause_epoch       = ScriptControl.get_pause_epoch
M.register_pause_owner  = ScriptControl.register_pause_owner
M.PAUSE_OWNER_IDS       = ScriptControl.PAUSE_OWNER_IDS
M.set_shortcut_action   = ScriptControl.set_shortcut_action
M.set_on_pause_change   = ScriptControl.set_on_pause_change
M.set_extras            = ScriptControl.set_extras
M.toggle_script_control = ScriptControl.toggle

-- Proxy Keyboard Shortcuts Methods
M.start_keyboard_shortcuts = KeyboardShortcuts.start
M.stop_keyboard_shortcuts  = KeyboardShortcuts.stop
M.set_keyboard_action      = KeyboardShortcuts.set_action
M.get_keyboard_action      = KeyboardShortcuts.get_action
M.get_keyboard_slot_label  = KeyboardShortcuts.get_slot_label
M.get_keyboard_assignments = KeyboardShortcuts.get_assignments
M.get_keyboard_slot_groups = function() return KeyboardShortcuts.SLOT_GROUPS end
M.available_keyboard_slots = KeyboardShortcuts.available_slots
M.assigned_keyboard_slots  = KeyboardShortcuts.assigned_slots

--- Stops independent shortcut children without letting one refusal hide its sibling.
--- @param steps table[] Ordered `{name, stop}` descriptors.
--- @return boolean settled True only when every child returned exact true.
local function stop_children(steps)
	local settled = true
	for _, step in ipairs(steps) do
		local ok, result_or_err = xpcall(step.stop, debug.traceback)
		if not ok or result_or_err ~= true then
			settled = false
			Logger.error(LOG, "Shortcut child '%s' stop did not settle: %s.",
				step.name, tostring(result_or_err))
		end
	end
	return settled
end

--- Starts all user-facing shortcut children while guarding every native
--- boundary with one exact transaction identity and claim epoch. A hotkey
--- factory may synchronously re-enter pause_bindings(); its claim must fence the
--- outer transaction before another child can be published.
--- @param steps table[] Ordered StartupTransaction descriptors.
--- @return boolean committed
local function run_binding_start_transaction(steps)
	if binding_pause_claimed() or binding_start_attempt ~= nil then return false end
	local attempt = { epoch = binding_lifecycle_epoch }
	binding_start_attempt = attempt

	local function attempt_is_current()
		return binding_start_attempt == attempt
			and binding_lifecycle_epoch == attempt.epoch
			and not binding_pause_claimed()
	end

	local guarded = {}
	for _, step in ipairs(steps) do
		local descriptor = step
		guarded[#guarded + 1] = {
			name = descriptor.name,
			stop = descriptor.stop,
			start = function()
				if not attempt_is_current() then return false end
				local result = descriptor.start(attempt_is_current)
				if result ~= true then return result end
				if not attempt_is_current() then return false end
				return true
			end,
		}
	end

	local committed = StartupTransaction.run(guarded)
	local still_current = attempt_is_current()
	if binding_start_attempt == attempt then binding_start_attempt = nil end
	if committed == true and still_current then return true end

	-- StartupTransaction already compensates every ordinary refusal, including
	-- the faulting child. This branch protects the final publication boundary if
	-- a future transaction implementation returns true after losing our epoch.
	if committed == true then
		for index = #steps, 1, -1 do
			local ok, result_or_err = xpcall(steps[index].stop, debug.traceback)
			if not ok or result_or_err ~= true then
				Logger.error(LOG, "Shortcut final-boundary rollback for '%s' did not settle: %s.",
					steps[index].name, tostring(result_or_err))
			end
		end
	end
	return false
end

--- Opens a child-local pause fence only inside the aggregate attempt identity.
--- @param child table
--- @param attempt_is_current function
--- @return boolean committed
local function start_after_aggregate_shutdown(child, attempt_is_current)
	if not attempt_is_current() then return false end
	if type(child.release_pause_admission) == "function"
		and child.release_pause_admission() ~= true then
		return false
	end
	if not attempt_is_current() then return false end
	return child.start()
end

--- Retries a failed layout replacement without touching action scopes or
--- subsystem-level state such as keep-awake.
local function recover_layout_rebind()
	if binding_external_pause_claimed() then return false end
	local owned_recovery = release_rebind_recovery_claim()
	local committed = run_binding_start_transaction({
		{
			name = "bindings_rebind_recovery",
			start = Bindings.resume_hotkeys_after_pause or Bindings.resume_after_pause,
			stop = Bindings.pause_hotkeys_only or Bindings.pause or Bindings.stop,
		},
		{
			name = "keyboard_shortcuts_rebind_recovery",
			start = KeyboardShortcuts.resume_after_pause or KeyboardShortcuts.start,
			stop = KeyboardShortcuts.pause or KeyboardShortcuts.stop,
		},
	})
	if committed ~= true and owned_recovery then
		add_binding_pause_claim(REBIND_RECOVERY_CLAIM)
	end
	return committed
end

--- Starts the user-facing shortcut layer: the static Bindings AND the
--- configurable keyboard shortcuts. Symmetric with stop() and resume_bindings()
--- — both manage KeyboardShortcuts, so the initial start must too (otherwise the
--- configurable Cmd/Ctrl/Option shortcuts stay dead until the first pause/resume).
--- ScriptControl has its own dedicated start/stop (start_script_control) so its
--- pause/quit/reload tap survives a bindings toggle.
--- @return boolean committed True only when both child starts committed.
function M.start()
	if binding_external_pause_claimed() then return false end
	local recovering_rebind = release_rebind_recovery_claim()
	local committed = run_binding_start_transaction({
		{name = "shortcut_action_scope", start = resume_shortcut_actions,
			stop = pause_shortcut_actions},
		{name = "bindings", start = function(attempt_is_current)
			return start_after_aggregate_shutdown(Bindings, attempt_is_current)
		end, stop = Bindings.stop},
		{name = "keyboard_shortcuts", start = function(attempt_is_current)
			return start_after_aggregate_shutdown(KeyboardShortcuts, attempt_is_current)
		end, stop = KeyboardShortcuts.stop},
	})
	if committed ~= true and recovering_rebind then
		add_binding_pause_claim(REBIND_RECOVERY_CLAIM)
	end
	return committed
end

--- Stops every shortcut child, including the independent script-control tap.
--- @return boolean settled True only when every child cleanup committed.
function M.stop()
	invalidate_binding_lifecycle()
	local settled = stop_children({
		{name = "shortcut_action_scope", stop = pause_shortcut_actions},
		{name = "bindings", stop = Bindings.stop},
		{name = "script_control", stop = ScriptControl.stop},
		{name = "keyboard_shortcuts", stop = KeyboardShortcuts.stop},
	})
	return settled
end

--- Stops only the user-facing bindings and keyboard shortcuts, leaving the
--- script-control eventtap alive so AltGr+Enter/Escape/Backspace can still
--- un-pause the script. Called by pause_all() in script_control.lua instead
--- of stop() which would also kill the script-control tap itself.
--- @return boolean settled True only when both user-facing children stopped.
function M.pause_bindings(parent)
	add_binding_pause_claim(binding_pause_claim(parent))
	return stop_children({
		{name = "shortcut_action_scope", stop = pause_shortcut_actions},
		{name = "bindings", stop = Bindings.pause or Bindings.stop},
		{name = "keyboard_shortcuts",
			stop = KeyboardShortcuts.pause or KeyboardShortcuts.stop},
	})
end

--- Releases one lifecycle claim without starting any shortcut child.
--- ScriptControl uses this inverse when its PAUSE snapshot found the feature
--- already OFF: the global fence must still exist while paused, but releasing it
--- may not manufacture an ON intent that the user never had.
--- @param parent string|nil Stable pause parent.
--- @return boolean committed
function M.release_bindings_pause_claim(parent)
	local claim = binding_pause_claim(parent)
	if binding_pause_claims[claim] == true then
		binding_pause_claims[claim] = nil
		invalidate_binding_lifecycle()
	end
	return true
end

--- Restores user-facing bindings after a pause. Symmetric to pause_bindings().
--- @return boolean committed True only when both child starts committed.
function M.resume_bindings(parent)
	local claim = binding_pause_claim(parent)
	local owned_claim = binding_pause_claims[claim] == true
	M.release_bindings_pause_claim(claim)
	if binding_external_pause_claimed() then
		local settled = stop_children({
			{name = "shortcut_action_scope", stop = pause_shortcut_actions},
			{name = "bindings", stop = Bindings.pause or Bindings.stop},
			{name = "keyboard_shortcuts",
				stop = KeyboardShortcuts.pause or KeyboardShortcuts.stop},
		})
		if claim == DEFAULT_BINDING_PAUSE_CLAIM then
			-- A user-facing ON transition behind ScriptControl PAUSE must not
			-- publish success while every native child remains fenced. Preserve the
			-- feature claim so the menu transaction rolls its desired state back.
			add_binding_pause_claim(claim)
			return false
		end
		return settled
	end
	local recovering_rebind = release_rebind_recovery_claim()
	local committed
	committed = run_binding_start_transaction({
		{name = "shortcut_action_scope", start = resume_shortcut_actions,
			stop = pause_shortcut_actions},
		{
			name = "bindings",
			start = function(attempt_is_current)
				if recovering_rebind then
					if not attempt_is_current() then return false end
					local resume = Bindings.resume_rebind_after_pause
						or Bindings.resume_after_pause or Bindings.start
					local committed = resume()
					if committed ~= true or not attempt_is_current() then return false end
					return true
				end
				return (Bindings.resume_after_pause or Bindings.start)()
			end,
			stop = Bindings.pause or Bindings.stop,
		},
		{
			name = "keyboard_shortcuts",
			start = KeyboardShortcuts.resume_after_pause or KeyboardShortcuts.start,
			stop = KeyboardShortcuts.pause or KeyboardShortcuts.stop,
		},
	})
	if committed ~= true and owned_claim then add_binding_pause_claim(claim) end
	if committed ~= true and recovering_rebind then
		add_binding_pause_claim(REBIND_RECOVERY_CLAIM)
	end
	return committed
end

--- Re-arms the layout-dependent hotkeys after a keyboard-layout change, so they
--- track the new physical key positions (hs.hotkey.bind resolves key names to
--- scancodes at bind time).
--- Unlike the pause_bindings()/resume_bindings() pair, this NEVER changes whether
--- the layer is running: it is a no-op when the bindings are stopped. That pair is
--- a symmetric round-trip only when the layer was ON to begin with — used here it
--- silently re-enabled every shortcut the user had switched off from the menu on
--- each layout change, while the tray checkbox still displayed OFF. A caller that
--- merely wants to rebind must not be able to resurrect a layer the user turned
--- off, so the running/stopped decision stays exclusively with the menu and with
--- script_control (which snapshots the state before pausing).
--- @return boolean True when the layer was running and was actually re-armed.
function M.rebind_for_layout()
	if binding_external_pause_claimed() then return false end
	if binding_pause_claims[REBIND_RECOVERY_CLAIM] == true then
		return recover_layout_rebind()
	end
	if not Bindings.is_started() then return false end
	local committed = run_binding_start_transaction({
		{
			name = "bindings_rebind",
			start = Bindings.rebind,
			stop = Bindings.pause_hotkeys_only or Bindings.pause or Bindings.stop,
		},
		{
			name = "keyboard_shortcuts_rebind",
			start = function(attempt_is_current)
				if KeyboardShortcuts.stop() ~= true then return false end
				if not attempt_is_current() then return false end
				return KeyboardShortcuts.start()
			end,
			stop = KeyboardShortcuts.pause or KeyboardShortcuts.stop,
		},
	})
	if committed ~= true
		and binding_pause_claims[REBIND_RECOVERY_CLAIM] ~= true then
		add_binding_pause_claim(REBIND_RECOVERY_CLAIM)
	end
	return committed
end

--- Returns true when the binding layer is active (started and not stopped).
--- @return boolean
function M.is_bindings_started()
	return Bindings.is_started()
		or (binding_pause_claims[REBIND_RECOVERY_CLAIM] == true
			and not binding_external_pause_claimed())
end

--- Reports child cleanup debt independently from the user-facing ON/OFF state.
--- @return boolean pending
function M.has_bindings_pause_debt()
	if binding_pause_claims[REBIND_RECOVERY_CLAIM] == true then return true end
	if type(Bindings.has_pause_debt) ~= "function" then return false end
	-- Preserve the exact child contract. ScriptControl must reject nil and catch
	-- throws as ambiguous ownership instead of normalizing them to "no debt".
	return Bindings.has_pause_debt()
end

return M
