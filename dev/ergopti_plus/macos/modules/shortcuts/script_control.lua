--- modules/shortcuts/script_control.lua

--- ==============================================================================
--- MODULE: Script Control
--- DESCRIPTION:
--- Manages global shortcuts for the Ergopti+ script lifecycle:
---   AltGr (Right Option) + Return    → Toggle pause / resume all modules.
---   AltGr (Right Option) + Backspace → Reload the Hammerspoon configuration.
---
--- Each key slot is configurable: the user can bind any of the 14 listed actions
--- to either key via the menu.
---
--- FEATURES & RATIONALE:
--- 1. Right-Alt Detection: Distinguishes the physical right Option key from the
---    left one using rawFlags, so left-Alt shortcuts in apps are never stolen.
--- 2. Safe Pause: Uses pause_processing() rather than stop() on the keymap so
---    the script-control eventtap itself stays reachable while paused.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("infra.notifications")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
local TimerScheduler = require("adapters.timer_scheduler")
local Logger        = require("infra.logger")
local Keycodes      = require("infra.keycodes")
local i18n          = require("infra.i18n")

local Engine    = require("modules.gestures.engine")
local GestActions = require("modules.gestures.actions")
local KeyState  = require("adapters.key_state")

local LOG = "shortcuts.script_control"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Sentinel keycodes emitted by Karabiner's script-control rules
-- (platform/remap/init.lua → build_script_control_sentinel_rules).
-- These fire ONLY when the user physically presses right_command + one of the
-- three target keys. Tap actions that happen to emit backspace/return/escape
-- (e.g. left_command tap → backspace) can NEVER activate these sentinels,
-- because rule outputs bypass Karabiner's rule engine.
local KEYCODE_RETURN_SENTINEL    = Keycodes.F13_KARABINER_RETURN
local KEYCODE_BACKSPACE_SENTINEL = Keycodes.F14_KARABINER_BACKSPACE
local KEYCODE_ESCAPE_SENTINEL    = Keycodes.F15_KARABINER_ESCAPE
local SCRIPT_CONTROL_SHORTCUT_CLAIM = "script_control"

-- Physical keycodes used in the Karabiner-paused fallback path below. When KE is
-- running the sentinels above are the sole dispatch mechanism; this fallback
-- only exists so the user can still un-pause by pressing right_command + key
-- when KE's altgr remap is gone.
local KEYCODE_BACKSPACE = Keycodes.BACKSPACE
local KEYCODE_RETURN    = Keycodes.RETURN
local KEYCODE_ESCAPE    = Keycodes.ESCAPE

--- Prefix of the binding key every script-control dispatch passes to the gesture
--- action layer, so a script key and a gesture slot of the same name cannot
--- collide in the (binding, action) parameter store.
---
--- Exported because the menu must PROMPT for a parameter under the exact key
--- dispatch will later READ it under. Spelling it a second time in the menu is
--- how a configured link ended up written to an entry nothing consults, leaving
--- the key silently inert.
M.BINDING_PREFIX = "script__"

-- The script-control eventtap lives on the main run loop. macOS disables a
-- CGEventTap whose callback is stalled past the system timeout — and a blocking
-- osascript on that run loop (e.g. the pause/resume layout switch) can trip it.
-- A disabled tap silently stops delivering events, stranding the un-pause
-- shortcut, so a watchdog re-enables it on this interval as a hard safety net.
local TAP_WATCHDOG_INTERVAL_SEC = 2

-- Module-level state
local _is_paused       = false
local _pause_epoch     = 0
local _pause_transition = nil
local _queued_pause_target = nil
local _pause_transition_serial = 0
-- Exact SyntheticInput admission owner. A successful pause keeps it until the
-- symmetric resume commits; an uncommitted pause keeps it through every native
-- rollback callback, closing the idle-to-PAUSED race without inventing PAUSED.
local _pause_admission_fence = nil
local _tap             = nil
local _tap_committed   = false
local _tap_watchdog    = nil
local _tap_watchdog_committed = false
local _tap_generation  = 0
local _key_actions     = {return_key = "script_pause_toggle", backspace = "script_reload", escape = "script_quit"}
local _on_pause_change = nil
local _extras          = {}

-- Runtime owners created by the menu layer register under this fixed inventory.
-- The order is deliberate: backend-local dependency processes are fenced and
-- joined before menu activation/switch/startup continuations are unwound.
local DYNAMIC_PAUSE_OWNER_ORDER = {
	"mlx_dependency_bootstrap",
	"ollama_dependency_bootstrap",
	"mlx_model_maintenance",
	"ollama_model_maintenance",
	"llm_activation",
	"llm_model_switcher",
	"llm_startup",
}
local DYNAMIC_PAUSE_OWNER_SET = {}
for _, owner_name in ipairs(DYNAMIC_PAUSE_OWNER_ORDER) do
	DYNAMIC_PAUSE_OWNER_SET[owner_name] = true
end
local _dynamic_pause_owners = {}
-- Monotonic identity for the runtime owner inventory. A registration can occur
-- synchronously inside another owner's pause/resume callback; transactions must
-- then reject the stale prebuilt inventory instead of publishing a state that
-- omitted the newly registered owner.
local _dynamic_pause_owner_version = 0
local _paused_owner_steps = nil
-- Reversible owners whose inverse refused during an uncommitted pause remain
-- part of the next pause inventory even when their live snapshot now reports
-- inactive. Without this ledger, a failed bindings/WPM restore could be skipped
-- by the retry and then never receive the eventual committed resume.
local _pause_rollback_debt_steps = nil
-- A failed RESUME can activate an owner and then fail to re-pause it during
-- rollback. Keep that opposite-direction debt separate from the normal paused
-- owner ledger: before any later resume may acquire successors, the exact
-- re-pause operation must first settle.
local _resume_rollback_debt_steps = nil

local _keymap     = nil
local _shortcuts  = nil
local _gestures   = nil
local _karabiner  = nil

-- Pre-pause snapshots: only re-enable sub-systems that were active before the
-- pause, so a user-disabled gesture or shortcut set stays off after unpause.
-- The dedicated script-control tap deliberately survives a pause so the user
-- can recover or terminate the host. Only lifecycle actions keep that privilege;
-- an arbitrary UI/gesture action assigned to the same three physical slots must
-- remain subject to the pause that stopped every other Ergopti feature.
local PAUSED_ACTION_ALLOWLIST = {
	script_reload = true,
	script_quit   = true,
}




-- =====================================
-- =====================================
-- ======= 2/ Modifier Detection ========
-- =====================================
-- =====================================

--- Returns true when the event carries ONLY the right_command modifier — the
--- KE-paused fallback path. When KE is running, right_command is remapped to
--- right_option and physical script-control dispatch goes through the sentinel
--- keycodes emitted by KE (F18/F19/F20). When KE is paused/killed the remap is
--- gone, physical right_command fires as cmd, and this predicate lets the user
--- still un-pause via the old right_cmd + key combination.
--- Rejects any event that also has alt/ctrl/shift or left_command held.
--- @param e userdata The hs.eventtap.event object.
--- @return boolean True if the event is exactly right_command + key.
local function is_right_cmd_only(e)
	if type(e) ~= "userdata" or type(e.getFlags) ~= "function" then return false end

	local ok_flags, flags = pcall(function() return e:getFlags() end)
	if not ok_flags or type(flags) ~= "table" then return false end

	if flags.alt or flags.ctrl or flags.shift or not flags.cmd then return false end

	local ok_raw, raw = pcall(function() return e:rawFlags() end)
	local masks = (ok_raw and type(raw) == "number") and hs.eventtap.event.rawFlagMasks or nil
	if not masks then return false end

	local right_cmd = masks.deviceRightCommand or 0
	local left_cmd  = masks.deviceLeftCommand  or 0
	if right_cmd == 0 then return false end
	return (raw & right_cmd) ~= 0 and (raw & left_cmd) == 0
end

--- Returns true when a right-hand AltGr modifier is physically held right now.
---
--- The F13/F14/F15 sentinel keycodes ARE the real physical keys on extended
--- keyboards, so a bare F13/F14/F15 press is byte-identical (by keycode) to a
--- KE-emitted sentinel and cannot be told apart by the event flags alone (the KE
--- rule emits a bare key with no modifier — see karabiner/generator.lua
--- build_script_control_sentinel_rules / build_paused_script_control_rules). The
--- ONE invariant that always holds for a genuine sentinel and never for a stray
--- function-key press is that the user is physically holding a right-hand AltGr
--- at the moment the sentinel arrives (right_option when KE is active and has
--- remapped right_command, right_command when KE is paused). The live modifier
--- query is delegated to the KeyState adapter so this module performs no direct
--- OS call. We read the LIVE state rather than the sentinel event's own flags
--- because the two legitimate KE paths carry different (and sometimes no)
--- modifier flags on the emitted event, whereas the physical AltGr is held in both.
--- @return boolean True if a right command or right option is currently down.
local function is_right_modifier_held()
	return KeyState.is_right_altgr_held()
end

--- Returns true when the sentinel event carries the synthetic two-modifier tag that
--- Karabiner stamps onto every emitted F13/F14/F15 (generator
--- SCRIPT_CONTROL_SENTINEL_TAGS = {"left_control","left_shift"}). Both modifiers
--- must be present — requiring left_control alone is indistinguishable from a real
--- physical Ctrl+F15 keypress (M-6 / F-CRIT-1 residual), so we require BOTH.
--- A bare physical Ctrl+F15 carries flags.ctrl but NOT flags.shift, so it is
--- correctly rejected. A physical Ctrl+Shift+F15 is theoretically an edge case but
--- is unreachable in any normal keyboard interaction.
--- @param e userdata The hs.eventtap.event for the sentinel keystroke.
--- @return boolean
local function sentinel_is_tagged(e)
	-- Real hs events are userdata; a table is accepted too so the guard is unit-testable.
	if (type(e) ~= "userdata" and type(e) ~= "table") or type(e.getFlags) ~= "function" then return false end
	local ok, flags = pcall(function() return e:getFlags() end)
	return ok and type(flags) == "table" and flags.ctrl == true and flags.shift == true
end

--- A genuine sentinel is confirmed by EITHER the live AltGr modifier (active path,
--- modifier not consumed) OR the KE control tag on the event (paused path, mandatory
--- modifier consumed). Either is sufficient; a bare F-key press has neither.
--- @param e userdata The hs.eventtap.event.
--- @return boolean
local function sentinel_is_genuine(e)
	return is_right_modifier_held() or sentinel_is_tagged(e)
end





-- ==============================
-- ==============================
-- ======= 3/ Core Engine =======
-- ==============================
-- ==============================

--- Calls one pause-owner lifecycle operation through its exact settlement
--- contract. A nil return is not evidence that an asynchronous or native owner
--- is quiescent; every registered operation must explicitly return true.
--- @param label string Stable operation name for diagnostics.
--- @param action function Operation to call.
--- @return boolean ok
--- @return string|nil reason
local function call_lifecycle_operation(label, action)
	local ok_call, result, detail = pcall(action)
	if not ok_call then
		return false, string.format("%s raised: %s", label, tostring(result))
	end
	if result ~= true then
		return false, string.format("%s returned %s: %s", label, tostring(result), tostring(detail))
	end
	return true, nil
end

--- Rolls back every reversible lifecycle operation that may already have
--- mutated state. The failing operation is registered before it is called, so
--- mutate-then-throw and mutate-then-false implementations are covered too.
--- @param operation string Human-readable transaction name.
--- @param applied table[] Applied descriptors in forward order.
--- @return string|nil Joined rollback failures, if any.
--- @return table[] Exact reversible descriptors still owing restoration.
local function rollback_lifecycle_operations(operation, applied)
	local failures = {}
	local unsettled_reverse = {}
	for index = #applied, 1, -1 do
		local step = applied[index]
		local ok_rollback, rollback_reason = call_lifecycle_operation(
			step.label .. " rollback",
			step.rollback
		)
		if not ok_rollback then
			failures[#failures + 1] = rollback_reason
			unsettled_reverse[#unsettled_reverse + 1] = step
			Logger.error(LOG, "%s rollback failed: %s.", operation, tostring(rollback_reason))
		end
	end
	local unsettled = {}
	for index = #unsettled_reverse, 1, -1 do
		unsettled[#unsettled + 1] = unsettled_reverse[index]
	end
	if #failures == 0 then return nil, unsettled end
	return table.concat(failures, "; "), unsettled
end

--- Reads one boolean lifecycle snapshot without letting a dependency throw out
--- of the pause callback. A false value is valid state, not operation failure.
--- @param label string Stable snapshot name.
--- @param action function Snapshot getter.
--- @return boolean ok
--- @return boolean|nil value
--- @return string|nil reason
local function read_lifecycle_snapshot(label, action)
	local ok_call, value = pcall(action)
	if not ok_call then
		return false, nil, string.format("%s raised: %s", label, tostring(value))
	end
	if type(value) ~= "boolean" then
		return false, nil, string.format("%s returned non-boolean: %s", label, tostring(value))
	end
	return true, value, nil
end

--- Suspends all registered modules as one local transaction.
---
--- Every required API and inverse is preflighted before the first mutation.
--- Required one-way cleanups are explicitly marked: restoring a stale tooltip
--- or prediction would be incorrect, while Ollama's stop only invalidates one
--- in-flight generation and deliberately has no resume counterpart. A failure
--- in any step still rolls every reversible module back and prevents PAUSED
--- from being published.
--- @return boolean True only when every required quiescence step committed.
--- @return string|nil Failure detail.
local function pause_all()
	-- The legacy public API remains callable before M.start() (covered by
	-- test_script_control.lua). Once the eventtap exists, every injected driver
	-- dependency is required; a partial pause would be a false PAUSED state.
	local enforce_dependencies = _tap ~= nil
	local prior_debt = _pause_rollback_debt_steps or {}
	local owner_version = _dynamic_pause_owner_version
	local prior_debt_by_label = {}
	for _, debt_step in ipairs(prior_debt) do
		prior_debt_by_label[debt_step.label] = debt_step
	end
	local steps = {}
	local step_labels = {}
	local shortcuts_were_running = false
	local shortcuts_have_cleanup_debt = false
	local shortcuts_have_reversible_debt = prior_debt_by_label["shortcuts.pause_bindings"] ~= nil
		or prior_debt_by_label["shortcuts.stop"] ~= nil
	local gestures_were_enabled = false
	local ok_step, step_reason

	local function dependency_failure(reason)
		if enforce_dependencies then return false, reason end
		Logger.warn(LOG, "Pre-start pause dependency skipped: %s.", tostring(reason))
		return true, nil
	end

	local function add_required_step(label, action, rollback, one_way_contract, resume_label)
		local retained = prior_debt_by_label[label]
		if retained then
			steps[#steps + 1] = retained
			step_labels[label] = true
			return true, nil
		end
		if type(action) ~= "function" then
			return dependency_failure(label .. " API unavailable")
		end
		if rollback ~= nil and type(rollback) ~= "function" then
			return dependency_failure(label .. " has no inverse rollback")
		end
		if rollback == nil and type(one_way_contract) ~= "string" then
			return dependency_failure(label .. " has no inverse rollback or one-way contract")
		end
		steps[#steps + 1] = {
			label = label,
			action = action,
			rollback = rollback,
			one_way_contract = one_way_contract,
			resume_label = resume_label,
		}
		step_labels[label] = true
		return true, nil
	end

	local function require_pause_module(module_name)
		local ok_require, module_or_err = pcall(require, module_name)
		if not ok_require or type(module_or_err) ~= "table" then
			local reason = ok_require
				and string.format("require(%s) returned %s", module_name, type(module_or_err))
				or string.format("require(%s) raised: %s", module_name, tostring(module_or_err))
			local ok_dependency, dependency_reason = dependency_failure(reason)
			if not ok_dependency then return nil, dependency_reason end
			return nil, nil
		end
		return module_or_err, nil
	end

	if enforce_dependencies and not _keymap then return false, "keymap dependency unavailable" end
	if enforce_dependencies and not _shortcuts then return false, "shortcuts dependency unavailable" end
	if enforce_dependencies and not _gestures then return false, "gestures dependency unavailable" end

	for _, owner_name in ipairs(DYNAMIC_PAUSE_OWNER_ORDER) do
		local owner = _dynamic_pause_owners[owner_name]
		if owner then
			ok_step, step_reason = add_required_step(
				owner_name .. ".pause",
				owner.pause,
				owner.resume,
				nil,
				owner_name .. ".resume"
			)
			if not ok_step then return false, step_reason end
		end
	end

	if _shortcuts then
		if type(_shortcuts.is_bindings_started) ~= "function" then
			local ok_dependency, dependency_reason = dependency_failure(
				"shortcuts.is_bindings_started API unavailable")
			if not ok_dependency then return false, dependency_reason end
		else
			local ok_snapshot, snapshot_value, snapshot_reason = read_lifecycle_snapshot(
				"shortcuts.is_bindings_started", _shortcuts.is_bindings_started)
			if not ok_snapshot then return false, snapshot_reason end
			shortcuts_were_running = snapshot_value
		end
		if type(_shortcuts.has_bindings_pause_debt) == "function" then
			local ok_debt, debt_value, debt_reason = read_lifecycle_snapshot(
				"shortcuts.has_bindings_pause_debt", _shortcuts.has_bindings_pause_debt)
			if not ok_debt then return false, debt_reason end
			shortcuts_have_cleanup_debt = debt_value
		end
	end
	if _gestures and type(_gestures.is_enabled) == "function" then
		local ok_snapshot, snapshot_value, snapshot_reason = read_lifecycle_snapshot(
			"gestures.is_enabled", _gestures.is_enabled)
		if not ok_snapshot then return false, snapshot_reason end
		gestures_were_enabled = snapshot_value
	elseif _gestures and type(_gestures.suspend) ~= "function" then
		local ok_dependency, dependency_reason = dependency_failure(
			"gestures.is_enabled API unavailable for disable_all fallback")
		if not ok_dependency then return false, dependency_reason end
	end

	ok_step, step_reason = add_required_step(
		"keymap.pause_processing",
		_keymap and _keymap.pause_processing,
		_keymap and _keymap.resume_processing,
		nil,
		"keymap.resume_processing"
	)
	if not ok_step then return false, step_reason end

	if _shortcuts and type(_shortcuts.pause_bindings) == "function" then
		-- Always install the global claim, including when the feature snapshot is
		-- already OFF. Otherwise a menu ON transition behind PAUSE can reopen the
		-- shortcut action scope because no `script_control` sibling claim exists.
		local shortcut_action = function()
			return _shortcuts.pause_bindings(SCRIPT_CONTROL_SHORTCUT_CLAIM)
		end
		local shortcut_rollback
		local shortcut_resume_label
		if shortcuts_were_running then
			shortcut_rollback = type(_shortcuts.resume_bindings) == "function" and function()
				return _shortcuts.resume_bindings(SCRIPT_CONTROL_SHORTCUT_CLAIM)
			end or nil
			shortcut_resume_label = "shortcuts.resume_bindings"
		else
			shortcut_rollback = type(_shortcuts.release_bindings_pause_claim) == "function"
				and function()
					return _shortcuts.release_bindings_pause_claim(
						SCRIPT_CONTROL_SHORTCUT_CLAIM)
				end or nil
			shortcut_resume_label = "shortcuts.release_bindings_pause_claim"
		end
		ok_step, step_reason = add_required_step(
			"shortcuts.pause_bindings",
			shortcut_action,
			shortcut_rollback,
			nil,
			shortcut_resume_label
		)
		if not ok_step then return false, step_reason end
	elseif shortcuts_were_running then
		ok_step, step_reason = add_required_step(
			"shortcuts.stop",
			_shortcuts and _shortcuts.stop,
			_shortcuts and _shortcuts.start,
			nil,
			"shortcuts.start"
		)
		if not ok_step then return false, step_reason end
	elseif shortcuts_have_cleanup_debt and not shortcuts_have_reversible_debt then
		local cleanup_action = _shortcuts and (
			type(_shortcuts.pause_bindings) == "function" and _shortcuts.pause_bindings
			or _shortcuts.stop
		) or nil
		ok_step, step_reason = add_required_step(
			"shortcuts.cleanup_bindings_debt",
			cleanup_action,
			nil,
			"settle native shortcut child debt without restoring an OFF layer"
		)
		if not ok_step then return false, step_reason end
	end

	-- suspend() preserves CoreState.enabled while gating every gesture. The
	-- fallback is only reversible when gestures were enabled before pause.
	if _gestures and type(_gestures.suspend) == "function" then
		ok_step, step_reason = add_required_step(
			"gestures.suspend",
			_gestures.suspend,
			_gestures.resume,
			nil,
			"gestures.resume"
		)
		if not ok_step then return false, step_reason end
	elseif gestures_were_enabled then
		ok_step, step_reason = add_required_step(
			"gestures.disable_all",
			_gestures and _gestures.disable_all,
			_gestures and _gestures.enable_all,
			nil,
			"gestures.enable_all"
		)
		if not ok_step then return false, step_reason end
	end

	local api, api_reason = require_pause_module("modules.llm.api_mlx")
	if api_reason then return false, api_reason end
	if api then
		local pause_mlx = type(api.pause_warmup) == "function"
			and api.pause_warmup or api.stop_warmup
		ok_step, step_reason = add_required_step(
			type(api.pause_warmup) == "function"
				and "api_mlx.pause_warmup" or "api_mlx.stop_warmup",
			pause_mlx,
			api.resume_warmup,
			nil,
			"api_mlx.resume_warmup"
		)
		if not ok_step then return false, step_reason end
	end

	local wc, wc_reason = require_pause_module("modules.llm.warmup_controller")
	if wc_reason then return false, wc_reason end
	if wc then
		local warmup_rollback = nil
		if type(wc.resume_warmup) == "function" then
			warmup_rollback = wc.resume_warmup
		elseif type(wc.schedule_warmup_with_retry) == "function" then
			warmup_rollback = function()
				return wc.schedule_warmup_with_retry("script pause rollback")
			end
		end
		local pause_warmup = type(wc.pause_warmup) == "function"
			and wc.pause_warmup or wc.stop
		ok_step, step_reason = add_required_step(
			type(wc.pause_warmup) == "function"
				and "warmup_controller.pause_warmup" or "warmup_controller.stop",
			pause_warmup,
			warmup_rollback,
			nil,
			"warmup_controller.resume_warmup"
		)
		if not ok_step then return false, step_reason end
	end

	local oll, oll_reason = require_pause_module("modules.llm.api_ollama")
	if oll_reason then return false, oll_reason end
	if oll then
		local pause_ollama = type(oll.pause_warmup) == "function"
			and oll.pause_warmup or oll.stop_warmup
		local resume_ollama = type(oll.pause_warmup) == "function"
			and oll.resume_warmup or nil
		ok_step, step_reason = add_required_step(
			type(oll.pause_warmup) == "function"
				and "api_ollama.pause_warmup" or "api_ollama.stop_warmup",
			pause_ollama,
			resume_ollama,
			resume_ollama == nil
				and "legacy generation invalidation has no restart contract" or nil,
			"api_ollama.resume_warmup"
		)
		if not ok_step then return false, step_reason end
	end

	local remote, remote_reason = require_pause_module("modules.llm.api_remote")
	if remote_reason then return false, remote_reason end
	if remote then
		local pause_remote = type(remote.pause_warmup) == "function"
			and remote.pause_warmup or remote.stop_warmup
		local resume_remote = type(remote.pause_warmup) == "function"
			and remote.resume_warmup or nil
		ok_step, step_reason = add_required_step(
			type(remote.pause_warmup) == "function"
				and "api_remote.pause_warmup" or "api_remote.stop_warmup",
			pause_remote,
			resume_remote,
			resume_remote == nil
				and "legacy generation invalidation has no restart contract" or nil,
			"api_remote.resume_warmup"
		)
		if not ok_step then return false, step_reason end
	end

	for _, owner in ipairs({
		{ module = "ui.wpm.wpm_menubar", label = "wpm_menubar" },
		{ module = "ui.wpm.wpm_widget", label = "wpm_widget" },
	}) do
		local surface, surface_reason = require_pause_module(owner.module)
		if surface_reason then return false, surface_reason end
		if surface then
			local ok_running, was_running, running_reason = read_lifecycle_snapshot(
				owner.label .. ".is_running", surface.is_running)
			if not ok_running then return false, running_reason end
			if was_running then
				local resume_action = type(surface.resume_after_pause) == "function"
					and surface.resume_after_pause or surface.start
				ok_step, step_reason = add_required_step(
					owner.label .. ".stop", surface.stop, resume_action, nil,
					owner.label .. ".resume_after_pause")
				if not ok_step then return false, step_reason end
			end
		end
	end

	local onboarding, onboarding_reason = require_pause_module("platform.remap.onboarding")
	if onboarding_reason then return false, onboarding_reason end
	if onboarding then
		ok_step, step_reason = add_required_step(
			"remap_onboarding.stop",
			onboarding.stop,
			nil,
			"a cancelled privileged installation must be restarted explicitly"
		)
		if not ok_step then return false, step_reason end
	end

	-- reset_predictions is required and intentionally one-way: re-arming a stale
	-- streaming generation after rollback would let an obsolete response paint.
	-- The pause-specific boundary performs the same authoritative teardown without
	-- scheduling dismissal telemetry that could fire after PAUSED is published.
	local reset_predictions = _keymap and (
		type(_keymap.reset_predictions_for_pause) == "function"
			and _keymap.reset_predictions_for_pause
		or _keymap.reset_predictions
	) or nil
	ok_step, step_reason = add_required_step(
		"keymap.reset_predictions",
		reset_predictions,
		nil,
		"stale prediction generations must never be restored"
	)
	if not ok_step then return false, step_reason end

	local tt, tt_reason = require_pause_module("ui.tooltip")
	if tt_reason then return false, tt_reason end
	if tt then
		ok_step, step_reason = add_required_step(
			"tooltip.hide_forced",
			tt.hide_forced,
			nil,
			"reopening stale visual output after rollback would lie"
		)
		if not ok_step then return false, step_reason end
	end

	-- A previous uncommitted pause may have failed to restore an owner. Its live
	-- state can now look inactive, so snapshot-gated inventory alone is unsound.
	-- Reuse the original closure and inverse exactly once when the normal fixed
	-- inventory did not already include it.
	for _, debt_step in ipairs(prior_debt) do
		if step_labels[debt_step.label] ~= true then
			steps[#steps + 1] = debt_step
			step_labels[debt_step.label] = true
		end
	end

	local applied = {}
	local visited_labels = {}
	local function rollback_applied(action_reason)
		local rollback_reason, rollback_debt = rollback_lifecycle_operations("Pause", applied)
		local unsettled_by_label = {}
		for _, debt_step in ipairs(rollback_debt) do
			unsettled_by_label[debt_step.label] = debt_step
		end
		local merged_debt = {}
		local merged_labels = {}
		for _, debt_step in ipairs(prior_debt) do
			if visited_labels[debt_step.label] ~= true
				or unsettled_by_label[debt_step.label] then
				merged_debt[#merged_debt + 1] = debt_step
				merged_labels[debt_step.label] = true
			end
		end
		for _, debt_step in ipairs(rollback_debt) do
			if merged_labels[debt_step.label] ~= true then
				merged_debt[#merged_debt + 1] = debt_step
				merged_labels[debt_step.label] = true
			end
		end
		_pause_rollback_debt_steps = #merged_debt > 0 and merged_debt or nil
		if rollback_reason then
			action_reason = action_reason .. "; rollback failures: " .. rollback_reason
		end
		return false, action_reason
	end
	for _, step in ipairs(steps) do
		visited_labels[step.label] = true
		-- Register before invoking: the operation may mutate and then throw/false.
		if step.rollback then applied[#applied + 1] = step end
		local ok_action, action_reason = call_lifecycle_operation(step.label, step.action)
		if not ok_action then
			return rollback_applied(action_reason)
		end
		if _dynamic_pause_owner_version ~= owner_version then
			return rollback_applied(
				"pause-owner registry changed during pause quiescence")
		end
	end

	-- Preserve the exact set that committed. Resume replays only these inverses;
	-- a surface that was disabled before pause can therefore never be resurrected.
	_paused_owner_steps = {}
	for _, step in ipairs(applied) do
		_paused_owner_steps[#_paused_owner_steps + 1] = step
	end
	_pause_rollback_debt_steps = nil
	return true, nil
end

--- Retains one exact RESUME rollback descriptor without duplicating its owner.
--- @param step table Descriptor whose `rollback` re-pauses the owner.
local function retain_resume_rollback_debt(step)
	if type(step) ~= "table" or type(step.rollback) ~= "function" then return end
	_resume_rollback_debt_steps = _resume_rollback_debt_steps or {}
	for _, retained in ipairs(_resume_rollback_debt_steps) do
		if retained == step or retained.label == step.label then return end
	end
	_resume_rollback_debt_steps[#_resume_rollback_debt_steps + 1] = step
end

--- Converts one committed PAUSE ledger into exact re-pause descriptors.
--- The conversion is required before the final admission release: every owner
--- in this ledger has just resumed, but the externally published state is still
--- PAUSED until that release commits.
--- @param paused_ledger table[] Exact reversible descriptors from pause_all().
local function retain_paused_ledger_as_resume_debt(paused_ledger)
	for _, paused_step in ipairs(paused_ledger or {}) do
		retain_resume_rollback_debt({
			label = paused_step.resume_label or (paused_step.label .. " inverse"),
			action = paused_step.rollback,
			rollback = paused_step.action,
		})
	end
end

--- Reasserts exact PAUSED ownership left ambiguous by a failed RESUME rollback.
--- No forward/resume operation may run until every retained inverse settles.
--- @return boolean settled
--- @return string|nil reason
local function settle_resume_rollback_debt()
	local debt = _resume_rollback_debt_steps
	if type(debt) ~= "table" or #debt == 0 then
		_resume_rollback_debt_steps = nil
		return true, nil
	end

	local unsettled = {}
	local failures = {}
	for _, step in ipairs(debt) do
		local ok_step, step_reason = call_lifecycle_operation(
			step.label .. " retained rollback", step.rollback)
		if not ok_step then
			unsettled[#unsettled + 1] = step
			failures[#failures + 1] = step_reason
		end
	end
	_resume_rollback_debt_steps = #unsettled > 0 and unsettled or nil
	if #failures > 0 then return false, table.concat(failures, "; ") end
	return true, nil
end

--- Resumes all registered modules as one local transaction.
--- Only re-enables sub-systems that were active before pause_all() was called.
--- @return boolean True only when every required activation committed.
--- @return string|nil Failure detail.
local function resume_all()
	local debt_settled, debt_reason = settle_resume_rollback_debt()
	if not debt_settled then
		return false, "retained resume rollback debt: " .. tostring(debt_reason)
	end

	local paused_ledger = _paused_owner_steps or {}
	local paused_ledger_count = #paused_ledger
	local owner_version = _dynamic_pause_owner_version
	local steps = {}
	for _, paused_step in ipairs(paused_ledger) do
		steps[#steps + 1] = {
			label = paused_step.resume_label or (paused_step.label .. " inverse"),
			action = paused_step.rollback,
			rollback = paused_step.action,
		}
	end

	local applied = {}
	local function rollback_applied(reason)
		local rollback_reason, rollback_debt = rollback_lifecycle_operations("Resume", applied)
		for _, debt_step in ipairs(rollback_debt) do
			retain_resume_rollback_debt(debt_step)
		end
		if rollback_reason then reason = reason .. "; rollback failures: " .. rollback_reason end
		return false, reason
	end
	for _, step in ipairs(steps) do
		-- Register before invoking: an activation may mutate and then throw/refuse.
		applied[#applied + 1] = step
		local ok_action, action_reason = call_lifecycle_operation(step.label, step.action)
		if not ok_action then
			return rollback_applied(action_reason)
		end
		-- register_pause_owner() may run synchronously inside an activation callback.
		-- It sees the still-published PAUSED state and appends its newly quiesced
		-- owner to this ledger. Refuse this snapshot rather than losing that owner at
		-- the final clear; the next explicit RESUME will include its exact inverse.
		if _paused_owner_steps ~= paused_ledger
			or #paused_ledger ~= paused_ledger_count
			or _dynamic_pause_owner_version ~= owner_version then
			return rollback_applied(
				"pause-owner ledger changed during resume activation")
		end
	end
	-- A lifecycle callback can register another pause owner synchronously. If that
	-- late registration retained ambiguous re-pause debt, the forward loop above
	-- is not a complete RESUME even though every originally listed action settled.
	if _resume_rollback_debt_steps ~= nil
		and #_resume_rollback_debt_steps > 0 then
		return rollback_applied(
			"resume acquired while a late re-pause debt remained")
	end

	-- The context tracker is pause-gated at its entry points, so an app switch made
	-- DURING the pause never updated the cached context and nothing else re-syncs it:
	-- resuming in a different app left active_app_* and — critically — is_secure_field
	-- pinned to whatever was frontmost when the pause began. Re-sync here rather than
	-- weakening the pause guard, so « pause = tout éteint » still holds exactly.
	-- Lazy require, like the two warmup drivers above: script_control is not wired to
	-- the keylogger module and does not need to be for a one-shot resume call.
	-- This one-shot refresh is deliberately best-effort: metrics OFF leaves the
	-- keylogger uninitialized, and resync_context() then returns false even though
	-- resume is otherwise valid. It activates nothing and therefore needs no inverse.
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if not ok_kl then
		Logger.warn(LOG, "Optional resume operation failed without blocking activation: %s.",
			"require(modules.keylogger) raised: " .. tostring(kl))
		kl = nil
	end
	if kl and type(kl.resync_context) == "function" then
		local ok_resync, resync_result = xpcall(kl.resync_context, debug.traceback)
		if not ok_resync or resync_result == false then
			Logger.warn(LOG,
				"Optional resume operation keylogger.resync_context failed without blocking activation: %s.",
				tostring(resync_result))
		end
	end
	if _paused_owner_steps ~= paused_ledger
		or #paused_ledger ~= paused_ledger_count
		or _dynamic_pause_owner_version ~= owner_version then
		return rollback_applied(
			"pause-owner ledger changed during optional resume finalization")
	end
	-- Keep the committed PAUSE ledger owned until the outer transaction releases
	-- its exact admission fence. If that final boundary refuses, these same
	-- descriptors are the only sound source for re-pausing every activated owner.
	return true, nil, paused_ledger
end

--- Returns the most recent requested pause state, including a queued reversal.
--- @return boolean Desired pause state.
local function desired_pause_state()
	if _queued_pause_target ~= nil then return _queued_pause_target end
	if _pause_transition then return _pause_transition.target end
	return _is_paused
end

--- Publishes one already-committed pause state to listeners and the user.
--- @param target_paused boolean Settled pause state.
local function publish_pause_state(target_paused)
	if type(_on_pause_change) == "function" then
		Logger.callback(LOG, "Pause-change listener", _on_pause_change, target_paused)
	end
	if target_paused then
		notifications.notify(i18n.get("script_control.paused"), nil, "warning")
	else
		notifications.notify(i18n.get("script_control.resumed"), nil, "success")
	end
end

--- Commits one Hammerspoon-side pause state. Resume remains privately paused
--- until every local activation step succeeds; a failed step rolls all earlier
--- steps back and returns without notifying listeners or the user.
--- @param target_paused boolean Settled pause state.
--- @return boolean committed
--- @return string|nil reason
local release_pause_admission

local function commit_pause_state(target_paused)
	if _is_paused == target_paused then return true, nil end
	-- The runtime epoch changes only once native publication reaches the local
	-- commit boundary. A refused native request leaves the running owners valid;
	-- a local refusal is instead compensated through the same owner registry.
	_pause_epoch = _pause_epoch + 1
	if target_paused then
		Logger.info(LOG, "Pausing all script operations after PAUSED acknowledgement.")
		local ok_pause, pause_reason = pause_all()
		if not ok_pause then return false, pause_reason end
		_is_paused = true
	else
		Logger.info(LOG, "Resuming all script operations after Karabiner regeneration committed.")
		local ok_resume, resume_reason, resumed_ledger = resume_all()
		if not ok_resume then return false, resume_reason end
		-- Admission is the final local commit point. Publishing RESUMED before this
		-- exact token releases lets callbacks open new output while the adapter is
		-- still fenced. On refusal, restore the local paused state and retain the
		-- same token for the native rollback/next explicit retry.
		if not release_pause_admission(_pause_admission_fence) then
			-- Convert before compensation: exact re-pause is fallible, and a
			-- mutate-then-refuse owner must remain represented while the last
			-- published state is still PAUSED.
			retain_paused_ledger_as_resume_debt(resumed_ledger)
			-- Replay only owners that this RESUME actually activated. One-way PAUSE
			-- cleanups (prediction reset, tooltip dismissal, onboarding cancellation)
			-- were never inverted and remain quiescent; re-running the full inventory
			-- here would create a new unowned one-way failure class.
			local rollback_ok, rollback_reason = settle_resume_rollback_debt()
			local reason = "synthetic-input admission fence release was refused"
			if not rollback_ok then
				reason = reason .. "; local pause rollback failed: " .. tostring(rollback_reason)
			end
			return false, reason
		end
		-- The PAUSE ledger is consumed only at the true outer commit point. Until
		-- admission reopens literally, it remains the rollback source of truth.
		if _paused_owner_steps == resumed_ledger then _paused_owner_steps = nil end
		_is_paused = false
	end
	publish_pause_state(target_paused)
	return true, nil
end

--- Surfaces a failed native transition without changing the last settled state.
--- @param target_paused boolean Requested pause state.
--- @param reason any Failure detail for logs.
local function report_pause_transition_failure(target_paused, reason)
	local operation = target_paused and "pause" or "resume"
	Logger.error(LOG, "Script %s transaction failed; settled state preserved: %s.",
		operation, tostring(reason))
	local key = target_paused and "script_control.pause_failed" or "script_control.resume_failed"
	notifications.notify(i18n.get(key), nil, "error")
end

local request_pause_transition


--- Releases one exact pause admission owner without silently clearing debt.
--- @param token table|nil SyntheticInput admission token.
--- @return boolean settled
release_pause_admission = function(token)
	if token == nil then return true end
	local ok, released_or_error = pcall(SyntheticInput.release_admission_fence, token)
	if not ok or released_or_error ~= true then
		Logger.error(LOG, "Synthetic-input admission fence release failed: %s.",
			tostring(released_or_error))
		return false
	end
	if _pause_admission_fence == token then _pause_admission_fence = nil end
	return true
end

--- Completes one request once and then applies the latest queued user intent.
--- @param transaction table Captured transition descriptor.
--- @param ok boolean Whether the complete transaction committed.
--- @param reason any Failure detail.
local function complete_pause_transition(transaction, ok, reason)
	if _pause_transition ~= transaction then return end
	_pause_transition = nil
	if transaction.target == true then
		if ok == true then
			_pause_admission_fence = transaction.admission_fence
		else
			release_pause_admission(transaction.admission_fence)
		end
	end
	if ok ~= true then
		report_pause_transition_failure(transaction.target, reason)
	end

	local queued = _queued_pause_target
	_queued_pause_target = nil
	local queued_repause_debt = queued == true and _is_paused == true
		and _resume_rollback_debt_steps ~= nil
		and #_resume_rollback_debt_steps > 0
	if queued ~= nil and (queued ~= _is_paused or queued_repause_debt) then
		request_pause_transition(queued)
	end
end

--- Restores native PAUSED after a local Hammerspoon resume step failed. The
--- failure remains unpublished until the platform layer reports PAUSED or a
--- fail-closed fence/no-live-lease result through the callback.
--- @param transaction table Captured resume transaction.
--- @param resume_reason string Local root-cause detail.
local function rollback_native_resume(transaction, resume_reason)
	if _pause_transition ~= transaction then return end
	transaction.stage = "native-resume-rollback"
	Logger.error(LOG, "Local resume activation failed; restoring native PAUSED before publication: %s.",
		tostring(resume_reason))
	local method = _karabiner and _karabiner.pause or nil
	if type(method) ~= "function" then
		Logger.error(LOG,
			"Local resume failed (%s), but native re-pause API is unavailable; failure remains unpublished.",
			tostring(resume_reason))
		return
	end

	local callback_fired = false
	local function finish_rollback(ok, rollback_reason)
		if callback_fired then return end
		callback_fired = true
		if _pause_transition ~= transaction then return end
		local final_reason = resume_reason
		if ok ~= true then
			-- The platform contract settles a failed pause callback only after the
			-- exact lease has been fenced or when no live lease exists.
			final_reason = string.format("%s; native re-pause settled fail-closed: %s",
				tostring(resume_reason), tostring(rollback_reason))
		end
		complete_pause_transition(transaction, false, final_reason)
	end

	local ok_call, accepted_or_err = pcall(method, finish_rollback)
	if not ok_call then
		Logger.error(LOG,
			"Local resume failed (%s), and native re-pause raised (%s); failure remains unpublished.",
			tostring(resume_reason), tostring(accepted_or_err))
	elseif accepted_or_err ~= true and not callback_fired then
		Logger.error(LOG,
			"Local resume failed (%s), and native re-pause was rejected without a safety callback; failure remains unpublished.",
			tostring(resume_reason))
	end
end

--- Restores native RESUMED after a local Hammerspoon pause step failed. Local
--- reversible modules have already been rolled back before this function runs;
--- the failure remains unpublished until the native layer confirms RESUMED or
--- reports that its fail-closed PAUSED state has settled.
--- @param transaction table Captured pause transaction.
--- @param pause_reason string Local root-cause detail.
local function rollback_native_pause(transaction, pause_reason)
	if _pause_transition ~= transaction then return end
	transaction.stage = "native-pause-rollback"
	Logger.error(LOG, "Local pause quiescence failed; restoring native RESUMED before publication: %s.",
		tostring(pause_reason))
	local method = _karabiner and _karabiner.resume or nil
	if type(method) ~= "function" then
		Logger.error(LOG,
			"Local pause failed (%s), but native resume API is unavailable; failure remains unpublished.",
			tostring(pause_reason))
		return
	end

	local callback_fired = false
	local function finish_rollback(ok, rollback_reason)
		if callback_fired then return end
		callback_fired = true
		if _pause_transition ~= transaction then return end
		local final_reason = pause_reason
		if ok ~= true then
			-- Native resume is fail-closed: a failed completion remains PAUSED.
			-- Local modules are running again, so never publish a false PAUSED state;
			-- surface the split-state failure and leave a fresh pause retry reachable.
			final_reason = string.format("%s; native resume rollback settled fail-closed: %s",
				tostring(pause_reason), tostring(rollback_reason))
		end
		complete_pause_transition(transaction, false, final_reason)
	end

	local ok_call, accepted_or_err = pcall(method, finish_rollback)
	if not ok_call then
		Logger.error(LOG,
			"Local pause failed (%s), and native resume raised (%s); failure remains unpublished.",
			tostring(pause_reason), tostring(accepted_or_err))
	elseif accepted_or_err ~= true and not callback_fired then
		Logger.error(LOG,
			"Local pause failed (%s), and native resume was rejected without a safety callback; failure remains unpublished.",
			tostring(pause_reason))
	end
end

--- Handles the native result, then commits the Hammerspoon half atomically.
--- @param transaction table Captured transition descriptor.
--- @param ok boolean Whether the native transaction committed.
--- @param reason any Controller result detail.
local function settle_pause_transition(transaction, ok, reason)
	if _pause_transition ~= transaction then return end
	if transaction.stage == "native-resume-rollback"
		or transaction.stage == "native-pause-rollback" then return end
	if ok ~= true then
		complete_pause_transition(transaction, false, reason)
		return
	end

	local committed, commit_reason = commit_pause_state(transaction.target)
	if committed then
		complete_pause_transition(transaction, true, reason)
	elseif transaction.target == false then
		rollback_native_resume(transaction, commit_reason)
	else
		rollback_native_pause(transaction, commit_reason)
	end
end

--- Calls the asynchronous Karabiner transition outside the eventtap callback.
--- @param transaction table Captured transition descriptor.
local function dispatch_native_pause_transition(transaction)
	if _pause_transition ~= transaction then return end
	transaction.timer = nil
	local method_name = transaction.target and "pause" or "resume"
	local method = _karabiner and _karabiner[method_name] or nil
	if type(method) ~= "function" then
		settle_pause_transition(transaction, false, "Karabiner transition API unavailable")
		return
	end

	local callback_fired = false
	local ok_call, accepted_or_err = pcall(method, function(ok, reason)
		if callback_fired then return end
		callback_fired = true
		settle_pause_transition(transaction, ok == true, reason)
	end)
	if not ok_call then
		settle_pause_transition(transaction, false, accepted_or_err)
	elseif accepted_or_err ~= true and not callback_fired then
		settle_pause_transition(transaction, false, "Karabiner transition request rejected")
	end
end

--- Requests a transactional pause-state change.
---
--- PAUSED is the pause commit point. Resume commits later: only after RESUMED,
--- config regeneration/publication and lease-bound input startup all succeed.
--- Until the relevant completion callback, is_paused(), listeners, notifications
--- and every Hammerspoon submodule retain their last settled state. Requests are
--- deferred so the physical shortcut's eventtap can always return immediately,
--- and a second toggle is coalesced as latest intent.
--- @param target_paused boolean Desired state.
--- @return boolean True when accepted or already satisfied.
request_pause_transition = function(target_paused, input_drained, admission_fence)
	target_paused = target_paused == true
	if _pause_transition then
		local desired = desired_pause_state()
		local rollback_pending = _pause_transition.stage == "native-resume-rollback"
			or _pause_transition.stage == "native-pause-rollback"
		if (rollback_pending and _pause_transition.target == target_paused)
			or desired ~= target_paused then
			_queued_pause_target = target_paused
			Logger.debug(LOG, "Queued script pause target: %s.", tostring(target_paused))
		end
		return true
	end
	if _is_paused == target_paused then
		-- A failed RESUME rollback may leave one owner activation ambiguous while
		-- the last published state correctly remains PAUSED. A same-state pause is
		-- the recovery port: retry only those exact local re-pause operations, with
		-- no new admission fence or native Karabiner transaction.
		if target_paused and _resume_rollback_debt_steps ~= nil then
			local settled, settle_reason = settle_resume_rollback_debt()
			if not settled then
				report_pause_transition_failure(true, settle_reason)
				return false
			end
		end
		return true
	end
	if target_paused and input_drained ~= true and _pause_admission_fence ~= nil then
		-- A failed preflight rollback keeps this exact token active and admission
		-- closed. A later explicit pause therefore already owns the original
		-- idle-to-PAUSED boundary: asking when_idle() to acquire a second fence can
		-- only refuse forever while our first token remains live.
		admission_fence = _pause_admission_fence
		input_drained = true
	end
	if target_paused and input_drained ~= true then
		_pause_transition_serial = _pause_transition_serial + 1
		local transaction = {
			id = _pause_transition_serial,
			target = true,
			stage = "synthetic-input-drain",
		}
		_pause_transition = transaction
		local drain_ok, accepted_or_error = pcall(SyntheticInput.when_idle, function()
			if _pause_transition ~= transaction then return end
			local queued = _queued_pause_target
			_queued_pause_target = nil
			if queued == false then
				_pause_transition = nil
				return
			end
			local acquired_ok, fence_or_error = pcall(
				SyntheticInput.acquire_admission_fence, "script_pause")
			if not acquired_ok or fence_or_error == nil then
				_pause_transition = nil
				report_pause_transition_failure(true,
					"synthetic input admission fence was not committed: "
						.. tostring(fence_or_error))
				return
			end
			_pause_transition = nil
			request_pause_transition(true, true, fence_or_error)
		end)
		if not drain_ok or accepted_or_error ~= true then
			_pause_transition = nil
			report_pause_transition_failure(true,
				"synthetic input drain was not committed: " .. tostring(accepted_or_error))
			return false
		end
		return true
	end
	if target_paused and admission_fence == nil then
		admission_fence = _pause_admission_fence
		if admission_fence == nil then
			local acquired_ok, fence_or_error = pcall(
				SyntheticInput.acquire_admission_fence, "script_pause")
			if not acquired_ok or fence_or_error == nil then
				report_pause_transition_failure(true,
					"synthetic input admission fence was not committed: "
						.. tostring(fence_or_error))
				return false
			end
			admission_fence = fence_or_error
			-- Publish ownership immediately, before every fallible Karabiner probe.
			-- A later rollback refusal must never orphan this exact token in a local.
			_pause_admission_fence = admission_fence
		end
	end
	if target_paused and admission_fence ~= nil then
		if _pause_admission_fence ~= nil and _pause_admission_fence ~= admission_fence then
			report_pause_transition_failure(true,
				"synthetic input admission fence ownership changed before pause")
			return false
		end
		_pause_admission_fence = admission_fence
	end
	local integration_enabled = false
	if _karabiner and type(_karabiner.get_enabled) ~= "function" then
		local release_ok = not target_paused or release_pause_admission(admission_fence)
		local reason = "Karabiner enabled-state API unavailable"
		if not release_ok then reason = reason .. "; admission rollback remains pending" end
		report_pause_transition_failure(target_paused, reason)
		return false
	end
	if _karabiner then
		local ok_enabled, enabled_or_err = pcall(_karabiner.get_enabled)
		if not ok_enabled or type(enabled_or_err) ~= "boolean" then
			local release_ok = not target_paused or release_pause_admission(admission_fence)
			local reason = not ok_enabled and tostring(enabled_or_err)
				or ("Karabiner enabled-state API returned "
					.. type(enabled_or_err) .. ", expected boolean")
			if not release_ok then reason = reason .. "; admission rollback remains pending" end
			report_pause_transition_failure(target_paused, reason)
			return false
		end
		integration_enabled = enabled_or_err == true
	end
	if not integration_enabled then
		local committed, commit_reason = commit_pause_state(target_paused)
		if not committed then
			if target_paused then release_pause_admission(admission_fence) end
			report_pause_transition_failure(target_paused, commit_reason)
			return false
		end
		if target_paused then
			_pause_admission_fence = admission_fence
		end
		return true
	end

	_pause_transition_serial = _pause_transition_serial + 1
	local transaction = {
		id = _pause_transition_serial,
		target = target_paused,
		timer = nil,
		admission_fence = target_paused and admission_fence or _pause_admission_fence,
	}
	_pause_transition = transaction
	local ok_timer, timer_or_err = pcall(hs.timer.doAfter, 0, function()
		dispatch_native_pause_transition(transaction)
	end)
	if not ok_timer or not timer_or_err then
		settle_pause_transition(transaction, false,
			ok_timer and "could not schedule native transition" or timer_or_err)
		return false
	end
	transaction.timer = timer_or_err
	return true
end

--- Dispatches a configured action by its identifier.
--- @param action string The action id (e.g. "pause", "reload", "open_init").
--- @return boolean True if the originating keystroke should be consumed.
--- Calls _extras[name] when present. Used as the fallback path for actions
--- that need a context handler the script_control module doesn't own
--- (file paths, hotstring editor, metrics windows, …).
--- @param name string The extras key.
--- @return boolean true if the handler ran (or returned without error).
local function call_extra(name)
	if type(_extras[name]) == "function" then
		local ok, handled = Logger.callback(LOG,
			"Script-control extra '" .. tostring(name) .. "'", _extras[name])
		return ok == true and handled ~= false
	else
		Logger.debug(LOG, "Action '%s' has no registered handler in extras.", name)
	end
	return false
end

local function dispatch_action(action, binding)
	if type(action) ~= "string" or action == "none" or action == "--" then return false end

	if action == "script_pause_toggle" then
		local target_paused = not desired_pause_state()
		Logger.info(LOG, "Requesting script %s transaction.", target_paused and "pause" or "resume")
		request_pause_transition(target_paused)
		return true
	end

	if _is_paused and PAUSED_ACTION_ALLOWLIST[action] ~= true then
		Logger.debug(LOG, "Ignoring non-lifecycle script-control action while paused: %s.", action)
		return true
	end

	-- Use centralized action dispatcher for everything else
	Logger.debug(LOG, "Dispatching centralized action: %s…", action)
	local ok_exec, handled = Logger.callback(LOG,
		"Central script-control action '" .. tostring(action) .. "'",
		GestActions.execute_single, action, binding)
	-- …and fall back to the extras table when the central registry does not know
	-- the action. call_extra had NO caller, so M.set_extras stored handlers that
	-- nothing could ever reach: a public API documenting a dispatch path that did
	-- not exist. Registering a handler and watching it never fire is worse than
	-- having no extension point at all.
	if not ok_exec or handled ~= true then
		return call_extra(action)
	end
	return true
end

--- Logs a shortcut activation via the keylogger if available.
--- @param label string Human-readable shortcut label for the log.
local function log_shortcut_if_available(label)
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if ok_kl and kl and type(kl.log_shortcut) == "function" then
		local app = hs.application.frontmostApplication()
		Logger.callback(LOG, "Shortcut telemetry", kl.log_shortcut,
			label, app and app:title() or "Unknown")
	end
end

--- Handles incoming keyDown events; consumes the event when it matches a configured slot.
---
--- Two independent dispatch paths:
---   1. Sentinel keycodes (F13/F14/F15) — emitted by Karabiner's script-control
---      rules on physical right_command + return/backspace/escape. This is the
---      primary path when KE is running and cannot be spoofed by tap actions,
---      because KE rule outputs bypass further rule matching.
---   2. Right-command fallback — when KE is paused/killed, physical right_command
---      fires as cmd (not alt), so we accept rcmd + backspace/return/escape
---      directly so the user can still un-pause without reloading.
---
--- @param e userdata The hs.eventtap.event object.
--- @return boolean True to consume the keystroke, false to pass it through.
local function handle_key(e)
	local provenance, status, fence = EventProvenance.classify_with_fence(
		e, "shortcuts.script_control")
	local fence_events = fence and fence.events or nil
	local function finish(consume) return consume == true, fence_events end
	if fence and fence.consume_original == true then return finish(true) end
	if provenance ~= nil or status == EventProvenance.STATUS_UNREADABLE then
		return finish(false)
	end
	local ok, code = pcall(function() return e:getKeyCode() end)
	if not ok or type(code) ~= "number" then return finish(false) end

	local function defer_dispatch(log_format, label, action, binding)
		return SyntheticInput.defer_after_callback("script control " .. binding,
			function()
				Logger.info(LOG, log_format, tostring(action))
				log_shortcut_if_available(label)
				return dispatch_action(action, M.BINDING_PREFIX .. binding)
			end)
	end

	local function defer_rejected_sentinel(name, keycode)
		SyntheticInput.defer_after_callback("rejected script-control sentinel",
			function()
				Logger.info(LOG,
					"%s sentinel (%s) seen without an authoritative Ergopti modifier — passing through (%s).",
					name, keycode, KeyState.describe_held_modifiers())
			end)
	end

	-- Primary path: sentinel keycodes from KE's script-control rules. These ARE
	-- the physical F13/F14/F15 keycodes, so a bare function-key press on an
	-- extended keyboard would otherwise dispatch pause/reload/QUIT with no
	-- modifier. Require a right-hand AltGr to be physically held — the invariant
	-- of every genuine KE sentinel — and pass a stray function key through.
	if code == KEYCODE_BACKSPACE_SENTINEL then
		if not sentinel_is_genuine(e) then
			defer_rejected_sentinel("Backspace", "F14")
			return finish(false)
		end
		return finish(defer_dispatch("Backspace sentinel (F14) — dispatching '%s'.",
			"Alt+Backspace", _key_actions.backspace, "backspace"))
	end
	if code == KEYCODE_RETURN_SENTINEL then
		if not sentinel_is_genuine(e) then
			defer_rejected_sentinel("Return", "F13")
			return finish(false)
		end
		return finish(defer_dispatch("Return sentinel (F13) — dispatching '%s'.",
			"Alt+Enter", _key_actions.return_key, "return_key"))
	end
	if code == KEYCODE_ESCAPE_SENTINEL then
		if not sentinel_is_genuine(e) then
			defer_rejected_sentinel("Escape", "F15")
			return finish(false)
		end
		return finish(defer_dispatch("Escape sentinel (F15) — dispatching '%s'.",
			"Alt+Escape", _key_actions.escape, "escape"))
	end

	-- Fallback path: KE paused — physical right_command + target key.
	if not is_right_cmd_only(e) then return finish(false) end

	if code == KEYCODE_BACKSPACE then
		return finish(defer_dispatch(
			"Right-cmd + Backspace (KE-paused fallback) — dispatching '%s'.",
			"Alt+Backspace", _key_actions.backspace, "backspace"))
	end
	if code == KEYCODE_RETURN then
		return finish(defer_dispatch(
			"Right-cmd + Return (KE-paused fallback) — dispatching '%s'.",
			"Alt+Enter", _key_actions.return_key, "return_key"))
	end
	if code == KEYCODE_ESCAPE then
		return finish(defer_dispatch(
			"Right-cmd + Escape (KE-paused fallback) — dispatching '%s'.",
			"Alt+Escape", _key_actions.escape, "escape"))
	end

	return finish(false)
end

--- Starts one exact eventtap and verifies that it is enabled before commit.
--- @param tap userdata Eventtap candidate retained by the caller.
--- @param operation string Context for diagnostics.
--- @return boolean committed True only when the exact tap is enabled.
local function start_eventtap_exact(tap, operation)
	if not tap or type(tap.start) ~= "function" then
		Logger.error(LOG, "%s failed: eventtap has no start method.", operation)
		return false
	end
	local ok_start, start_result = Logger.pcall(LOG, function() return tap:start() end)
	if not ok_start or start_result == false then
		Logger.error(LOG, "%s failed while starting the exact eventtap.", operation)
		return false
	end
	if type(tap.isEnabled) ~= "function" then
		Logger.error(LOG, "%s failed: eventtap has no enabled-state query.", operation)
		return false
	end
	local ok_state, enabled = Logger.pcall(LOG, function() return tap:isEnabled() end)
	if not ok_state or enabled ~= true then
		Logger.error(LOG, "%s failed: the exact eventtap is not enabled.", operation)
		return false
	end
	return true
end

--- Reports whether one exact eventtap is enabled without hiding query errors.
--- @param tap userdata Eventtap retained by this module.
--- @return boolean enabled
local function eventtap_is_enabled(tap)
	if not tap or type(tap.isEnabled) ~= "function" then return false end
	local ok_state, enabled = Logger.pcall(LOG, function() return tap:isEnabled() end)
	return ok_state and enabled == true
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

M.ACTIONS = GestActions.SG_NAMES
M.PAUSE_OWNER_IDS = {
	"mlx_dependency_bootstrap",
	"ollama_dependency_bootstrap",
	"mlx_model_maintenance",
	"ollama_model_maintenance",
	"llm_activation",
	"llm_model_switcher",
	"llm_startup",
	"keymap_processing",
	"shortcut_bindings",
	"gestures",
	"mlx_warmup",
	"warmup_controller",
	"ollama_warmup",
	"remote_warmup",
	"wpm_menubar",
	"wpm_widget",
	"remap_onboarding",
	"predictions",
	"tooltip",
}

-- Build a flat id→label lookup from SG_NAMES, skipping separators and headers.
do
	local labels = {}
	if type(M.ACTIONS) == "table" then
		for _, id in ipairs(M.ACTIONS) do
			if type(id) == "string" and id ~= "-" and id ~= "--" and id:sub(1, 1) ~= "#" then
				labels[id] = GestActions.get_label(id)
			end
		end
	end
	M.ACTION_LABELS = labels
end

--- Retrieves the localized label for a given action ID.
--- @param name string The action ID.
--- @return string The human-readable label.
function M.get_action_label(name)
	if GestActions and type(GestActions.get_label) == "function" then
		return GestActions.get_label(name)
	end
	return name
end

--- Starts the script-control eventtap with references to sibling modules.
--- @param keymap table Keymap module (must expose pause_processing / resume_processing).
--- @param shortcuts table Shortcuts module (must expose start / stop).
--- @param gestures table Gestures module (must expose enable_all / disable_all).
--- @param karabiner table|nil Optional Karabiner module (must expose pause / resume).
--- @return boolean committed True only when both native resources are owned.
function M.start(keymap, shortcuts, gestures, karabiner)
	if _tap and _tap_committed and _tap_watchdog and _tap_watchdog_committed then
		Logger.warn(LOG, "M.start() called more than once — ignoring duplicate call.")
		return true
	end
	if _tap or _tap_watchdog then
		if M.stop() ~= true then
			Logger.error(LOG, "Script control cannot start while prior native cleanup is pending.")
			return false
		end
	end
	Logger.start(LOG, "Starting script control…")

	_keymap    = type(keymap)    == "table" and keymap    or nil
	_shortcuts = type(shortcuts) == "table" and shortcuts or nil
	_gestures  = type(gestures)  == "table" and gestures  or nil
	_karabiner = type(karabiner) == "table" and karabiner or nil

	if not _keymap    then Logger.warn(LOG, "M.start(): keymap module not provided — pause/resume will be partial.") end
	if not _shortcuts then Logger.warn(LOG, "M.start(): shortcuts module not provided — pause/resume will be partial.") end
	if not _gestures  then Logger.warn(LOG, "M.start(): gestures module not provided — pause/resume will be partial.") end

	_tap_generation = _tap_generation + 1
	local generation = _tap_generation
	local tap_candidate
	local ok, new_tap = pcall(hs.eventtap.new, {hs.eventtap.event.types.keyDown}, function(event)
		if generation ~= _tap_generation or _tap ~= tap_candidate or not _tap_committed then
			return false
		end
		local ok_handler, consume, replacement_events = Logger.callback(
			LOG, "Script-control eventtap", handle_key, event)
		if not ok_handler then return false end
		return consume, replacement_events
	end)
	tap_candidate = new_tap
	if not ok or not new_tap then
		_tap_generation = _tap_generation + 1
		Logger.error(LOG, "Failed to create script-control eventtap — %s.", tostring(new_tap))
		return false
	end

	_tap = new_tap
	_tap_committed = false
	if not start_eventtap_exact(_tap, "Script-control startup") then
		_tap_generation = _tap_generation + 1
		M.stop()
		return false
	end
	_tap_committed = true

	-- Hard safety net: Hammerspoon normally recovers CoreGraphics timeout signals
	-- in native code, but any tap still observed disabled must be re-enabled so
	-- the script-management shortcuts cannot remain stuck off.
	local watchdog_candidate
	local ok_schedule, watchdog_handle, watchdog_committed = pcall(
		TimerScheduler.every, TAP_WATCHDOG_INTERVAL_SEC, function()
			if generation ~= _tap_generation
				or _tap_watchdog ~= watchdog_candidate
				or not _tap_watchdog_committed
				or _tap ~= tap_candidate
				or not _tap_committed then
				return
			end
			if not eventtap_is_enabled(_tap) then
				Logger.warn(LOG, "Script-control eventtap was disabled by macOS — re-enabling.")
				start_eventtap_exact(_tap, "Script-control watchdog recovery")
			end
		end)
	watchdog_candidate = watchdog_handle
	if ok_schedule and type(watchdog_handle) == "table" then
		_tap_watchdog = watchdog_handle
		_tap_watchdog_committed = watchdog_committed == true
	end
	if not ok_schedule or type(watchdog_handle) ~= "table" or watchdog_committed ~= true then
		_tap_generation = _tap_generation + 1
		M.stop()
		Logger.error(LOG, "Script-control watchdog could not be armed; eventtap startup rolled back — %s.",
			tostring(ok_schedule and watchdog_committed or watchdog_handle))
		return false
	end
	Logger.success(LOG, "Script control started.")
	return true
end

--- Stops the script-control eventtap.
--- @return boolean settled True only when both native resources are released.
function M.stop()
	if _pause_transition ~= nil then
		-- Once a native pause/resume request (or its rollback) is owned, there is no
		-- cancellation API that proves the exact controller lease settled. Clearing
		-- the descriptor here would make its late terminal a no-op while the native
		-- and local states diverge. Join it instead: the callback closes ownership,
		-- and a later stop can then release the settled resources.
		Logger.error(LOG,
			"Script control stop deferred while pause transaction %s remains owned.",
			tostring(_pause_transition.stage or _pause_transition.target))
		return false
	end
	_queued_pause_target = nil
	_pause_transition_serial = _pause_transition_serial + 1
	_tap_generation = _tap_generation + 1
	Logger.start(LOG, "Stopping script control…")
	local settled = true
	if _pause_admission_fence
		and not release_pause_admission(_pause_admission_fence) then
		settled = false
	end
	_tap_committed = false
	_tap_watchdog_committed = false

	if _tap_watchdog then
		local ok_cancel, cancelled = pcall(TimerScheduler.cancel, _tap_watchdog)
		if ok_cancel and cancelled == true then
			_tap_watchdog = nil
		else
			settled = false
			Logger.error(LOG, "Script-control watchdog stop failed; retained for retry — %s.",
				tostring(ok_cancel and cancelled or cancelled))
		end
	end

	if _tap then
		local ok_stop, stop_result = pcall(function()
			if type(_tap.stop) ~= "function" then return false end
			return _tap:stop()
		end)
		if ok_stop and stop_result ~= false then
			_tap = nil
		else
			settled = false
			Logger.error(LOG, "Script-control eventtap stop failed; retained for retry — %s.",
				tostring(ok_stop and stop_result or stop_result))
		end
	end

	if not settled then
		Logger.error(LOG, "Script control could not stop completely.")
		return false
	end
	Logger.success(LOG, "Script control stopped.")
	return true
end

--- Returns whether the script is currently paused.
--- @return boolean True if paused.
function M.is_paused()
	return _is_paused
end

--- Returns whether an exact pause-state transaction or retained inverse debt
--- still owns the boundary between ACTIVE and PAUSED. Unlike `is_paused()`,
--- this query covers the synthetic-input drain, queued reversal, native
--- transition/rollback, admission-fence debt, and any reversible owner whose
--- inverse has not settled yet.
--- @return boolean True while pause/resume publication is not transactionally safe.
function M.is_pause_transition_pending()
	return _pause_transition ~= nil
		or _queued_pause_target ~= nil
		or (_pause_rollback_debt_steps ~= nil and #_pause_rollback_debt_steps > 0)
		or (_resume_rollback_debt_steps ~= nil and #_resume_rollback_debt_steps > 0)
		or (_pause_admission_fence ~= nil and _is_paused ~= true)
end

--- Registers one runtime-created owner in the fixed pause inventory.
--- Owners are never replaced in place: doing so could orphan the exact resource
--- retained by the previous closure. Registration while paused immediately
--- quiesces the candidate and adds only that committed owner to the resume ledger.
--- @param owner_name string Fixed owner identifier.
--- @param owner table Table exposing exact `pause()` and `resume()` methods.
--- @return boolean committed
function M.register_pause_owner(owner_name, owner)
	if DYNAMIC_PAUSE_OWNER_SET[owner_name] ~= true or type(owner) ~= "table"
		or type(owner.pause) ~= "function" or type(owner.resume) ~= "function" then
		Logger.error(LOG, "Pause-owner registration rejected for '%s'.", tostring(owner_name))
		return false
	end
	local existing = _dynamic_pause_owners[owner_name]
	if existing then
		if existing == owner then return true end
		Logger.error(LOG, "Pause-owner '%s' is already registered; replacement refused.", owner_name)
		return false
	end

	local pause_step = {
		label = owner_name .. ".pause",
		action = owner.pause,
		rollback = owner.resume,
		resume_label = owner_name .. ".resume",
	}
	_dynamic_pause_owners[owner_name] = owner
	_dynamic_pause_owner_version = _dynamic_pause_owner_version + 1
	if _is_paused then
		local paused, reason = call_lifecycle_operation(pause_step.label, pause_step.action)
		if not paused then
			local owner_retained = false
			local restored, restore_reason = call_lifecycle_operation(
				pause_step.resume_label, pause_step.rollback)
			if restored ~= true then
				_paused_owner_steps = _paused_owner_steps or {}
				_paused_owner_steps[#_paused_owner_steps + 1] = pause_step
				retain_resume_rollback_debt({
					label = pause_step.resume_label,
					action = pause_step.rollback,
					rollback = pause_step.action,
				})
				owner_retained = true
				Logger.error(LOG,
					"Pause-owner '%s' registration rollback remains owned: %s.",
					owner_name, tostring(restore_reason))
			else
				if _dynamic_pause_owners[owner_name] == owner then
					_dynamic_pause_owners[owner_name] = nil
				end
			end
			Logger.error(LOG, "Pause-owner '%s' could not join the settled pause: %s.",
				owner_name, tostring(reason))
			-- Registration itself is committed when the exact inverse debt is
			-- retained in the global resume ledger. Callers must stay pause-gated,
			-- but they are no longer permanently orphaned after the later retry.
			return owner_retained
		end
		_paused_owner_steps = _paused_owner_steps or {}
		_paused_owner_steps[#_paused_owner_steps + 1] = pause_step
	end
	Logger.debug(LOG, "Pause owner registered: %s.", owner_name)
	return true
end

--- Returns the current pause transaction epoch.
--- @return integer Monotonic runtime generation.
function M.get_pause_epoch()
	return _pause_epoch
end

--- Configures the action triggered by a specific key slot.
--- @param keyname string "return_key", "backspace", or "escape".
--- @param action string One of the recognised action ids.
--- @return boolean committed
function M.set_shortcut_action(keyname, action)
	if type(keyname) ~= "string" or type(action) ~= "string" then
		Logger.error(LOG, "set_shortcut_action(): both keyname and action must be strings.")
		return false
	end
	_key_actions[keyname] = action
	Logger.debug(LOG, "Key slot '%s' → '%s'.", keyname, action)
	return true
end

--- Registers a callback invoked whenever the pause state changes.
--- @param cb function Called with (is_paused: boolean).
function M.set_on_pause_change(cb)
	if type(cb) ~= "function" then
		Logger.error(LOG, "set_on_pause_change(): argument must be a function.")
		return
	end
	_on_pause_change = cb
	Logger.debug(LOG, "Pause-change callback registered.")
end

--- Provides handlers for actions that require external context (file paths, UI windows, …).
--- Recognised keys mirror the ids in ACTION_DEFINITIONS for the categories
--- that script_control delegates rather than handles in-line:
---   open_paths_editor, open_hotstrings_editor,
---   open_metrics_typing, open_metrics_apps,
---   open_script_source, open_personal_shortcuts,
---   open_personal_hotstrings, open_personal_info,
---   open_config, open_logs_folder, open_today_log,
---   add_hotstring, trigger_prediction.
--- Keys with no handler are quietly skipped (debug log) so the right-Alt key
--- slots and gestures stay assignable on a fresh install.
function M.set_extras(tbl)
	if type(tbl) ~= "table" then
		Logger.error(LOG, "set_extras(): argument must be a table.")
		return
	end
	_extras = tbl
	local count = 0
	for _ in pairs(tbl) do count = count + 1 end
	Logger.debug(LOG, "Extras table registered (%d handler(s)).", count)
end

--- Programmatically toggles the paused state (same as pressing the configured key).
function M.toggle()
	Logger.debug(LOG, "Programmatic pause toggle requested.")
	local ok, handled = Logger.callback(LOG, "Programmatic pause toggle",
		dispatch_action, "script_pause_toggle")
	return ok == true and handled == true
end

--- Requests the same transactional pause as the pause key. State, listeners,
--- notifications, and Hammerspoon submodules change only after exact PAUSED.
function M.pause_all()
	Logger.info(LOG, "Programmatic pause transaction requested.")
	return request_pause_transition(true)
end

--- Requests the symmetric resume transaction; commits only after RESUMED and the
--- subsequent config publication plus lease-bound input startup have succeeded.
function M.resume_all()
	Logger.info(LOG, "Programmatic resume transaction requested.")
	return request_pause_transition(false)
end

return M
