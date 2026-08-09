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
local EventTapGuard = require("adapters.event_tap_guard")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
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
local _pause_transition = nil
local _queued_pause_target = nil
local _pause_transition_serial = 0
local _tap             = nil
local _tap_watchdog    = nil
local _key_actions     = {return_key = "script_pause_toggle", backspace = "script_reload", escape = "script_quit"}
local _on_pause_change = nil
local _extras          = {}

local _keymap     = nil
local _shortcuts  = nil
local _gestures   = nil
local _karabiner  = nil

-- Pre-pause snapshots: only re-enable sub-systems that were active before the
-- pause, so a user-disabled gesture or shortcut set stays off after unpause.
local _gestures_were_enabled  = false
local _shortcuts_were_running = false




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

--- Suspends all registered modules gracefully.
--- Uses pause_processing() on keymap so the script-control tap stays alive,
--- allowing the user to un-pause without reloading.
local function pause_all()
	-- Snapshot which sub-systems are active so resume_all() can restore exactly
	-- the pre-pause state rather than unconditionally re-enabling everything.
	_gestures_were_enabled  = _gestures  and type(_gestures.is_enabled) == "function"  and _gestures.is_enabled()  or false
	_shortcuts_were_running = _shortcuts and type(_shortcuts.is_bindings_started) == "function" and _shortcuts.is_bindings_started() or false

	if _keymap and type(_keymap.pause_processing) == "function" then
		pcall(function() _keymap.pause_processing() end)
	end
	-- Quiesce the LLM engine and tear down any visible tooltip. pause_processing
	-- only gates the keymap eventtap; the prediction engine's inactivity/chain
	-- timers and an in-flight streaming response are independent of it, so a
	-- prediction armed in the moment before pause would still paint and hit the
	-- backend. reset_predictions() hides the tooltip, stops those timers and
	-- bumps the fetch counter so stale streaming callbacks self-discard. This
	-- mirrors the AHK Ergopti_OnSuspendEnter reactor (« pause = tout éteint »).
	if _keymap and type(_keymap.reset_predictions) == "function" then
		pcall(function() _keymap.reset_predictions() end)
	end
	-- Stop BOTH warmup drivers: warmup_controller's scheduled retry chain AND
	-- api_mlx's own self-rescheduling retry (which is gated only on the LLM
	-- feature toggle, not on pause). Without api_mlx.stop_warmup() a cold-start
	-- warmup keeps POSTing through the pause and fires the "server ready"
	-- notification mid-pause (M-3).
	local ok_wc, wc = pcall(require, "modules.llm.warmup_controller")
	if ok_wc and wc and type(wc.stop) == "function" then
		pcall(function() wc.stop() end)
	end
	local ok_api, api = pcall(require, "modules.llm.api_mlx")
	if ok_api and api and type(api.stop_warmup) == "function" then
		pcall(function() api.stop_warmup() end)
	end
	-- Ollama's warmup needs parking for the same reason MLX's does, and its
	-- stop_warmup was added for the disable path without being wired here: an
	-- in-flight warmup POST kept its callbacks live across the pause and could
	-- flip readiness or fire the user-facing "server ready" notification while
	-- the script was supposed to be entirely off. No resume counterpart, per its
	-- own contract — it has no self-rescheduling retry chain to short-circuit
	-- and does not clear readiness, so a resume must not force a pointless
	-- re-warm of weights that are still loaded.
	local ok_oll, oll = pcall(require, "modules.llm.api_ollama")
	if ok_oll and oll and type(oll.stop_warmup) == "function" then
		pcall(function() oll.stop_warmup() end)
	end
	local ok_tt, tt = pcall(require, "ui.tooltip")
	if ok_tt and tt and type(tt.hide_forced) == "function" then
		pcall(function() tt.hide_forced() end)
	end
	-- Use pause_bindings() rather than stop() so the script-control eventtap
	-- itself stays alive — stop() would also call ScriptControl.stop() and
	-- kill this very tap, making AltGr+Enter unable to un-pause.
	if _shortcuts and type(_shortcuts.pause_bindings) == "function" then
		pcall(function() _shortcuts.pause_bindings() end)
	elseif _shortcuts and type(_shortcuts.stop) == "function" then
		pcall(function() _shortcuts.stop() end)
	end
	-- suspend() sets CoreState.suspended=true while leaving CoreState.enabled
	-- untouched. This means a menu toggle of gestures ON/OFF during pause
	-- changes the right axis and is honoured correctly at resume, instead of
	-- being overwritten by a stale snapshot-based enable_all() call.
	if _gestures and type(_gestures.suspend) == "function" then
		pcall(function() _gestures.suspend() end)
	elseif _gestures and type(_gestures.disable_all) == "function" then
		pcall(function() _gestures.disable_all() end)
	end
end

--- Calls one resume or rollback operation without swallowing a thrown error or
--- an explicit false result. Legacy lifecycle functions return nil on success,
--- so only the explicit false sentinel is a rejected operation.
--- @param label string Stable operation name for diagnostics.
--- @param action function Operation to call.
--- @return boolean ok
--- @return string|nil reason
local function call_resume_operation(label, action)
	local ok_call, result, detail = pcall(action)
	if not ok_call then
		return false, string.format("%s raised: %s", label, tostring(result))
	end
	if result == false then
		return false, string.format("%s returned false: %s", label, tostring(detail))
	end
	return true, nil
end

--- Rolls back every resume operation that could already have mutated state.
--- The failing operation itself is included because it may mutate before it
--- throws or returns false. Inverses run in strict reverse order.
--- @param applied table[] Applied resume descriptors.
--- @return string|nil Joined rollback failures, if any.
local function rollback_resume_operations(applied)
	local failures = {}
	for index = #applied, 1, -1 do
		local step = applied[index]
		local ok_rollback, rollback_reason = call_resume_operation(
			step.label .. " rollback",
			step.rollback
		)
		if not ok_rollback then
			failures[#failures + 1] = rollback_reason
			Logger.error(LOG, "Resume rollback failed: %s.", tostring(rollback_reason))
		end
	end
	if #failures == 0 then return nil end
	return table.concat(failures, "; ")
end

--- Resumes all registered modules as one local transaction.
--- Only re-enables sub-systems that were active before pause_all() was called.
--- @return boolean True only when every required activation committed.
--- @return string|nil Failure detail.
local function resume_all()
	-- The public API is deliberately safe before M.start() (covered by
	-- test_script_control.lua). Optional lazy modules are still re-armed there,
	-- but only an initialized driver has local activation state to roll back.
	local enforce_transaction = _tap ~= nil
	local steps = {}

	local function add_reversible_step(label, action, rollback)
		if type(action) ~= "function" then return true, nil end
		if type(rollback) ~= "function" then
			return false, label .. " has no inverse rollback"
		end
		steps[#steps + 1] = { label = label, action = action, rollback = rollback }
		return true, nil
	end

	local ok_step, step_reason = add_reversible_step(
		"keymap.resume_processing",
		_keymap and _keymap.resume_processing,
		_keymap and _keymap.pause_processing
	)
	if not ok_step then return false, step_reason end

	if _shortcuts_were_running then
		local shortcut_action = _shortcuts and (
			type(_shortcuts.resume_bindings) == "function" and _shortcuts.resume_bindings
			or _shortcuts.start
		) or nil
		local shortcut_label = _shortcuts and type(_shortcuts.resume_bindings) == "function"
			and "shortcuts.resume_bindings" or "shortcuts.start"
		local shortcut_rollback = _shortcuts and (
			type(_shortcuts.pause_bindings) == "function" and _shortcuts.pause_bindings
			or _shortcuts.stop
		) or nil
		if type(shortcut_action) ~= "function" then
			return false, "shortcuts resume API unavailable"
		end
		ok_step, step_reason = add_reversible_step(
			shortcut_label,
			shortcut_action,
			shortcut_rollback
		)
		if not ok_step then return false, step_reason end
	end
	-- resume() clears CoreState.suspended so the engine gate re-uses
	-- CoreState.enabled (the user feature flag). No snapshot needed: whatever
	-- the user toggled during pause is already in enabled, and resume never
	-- overrides it.
	if _gestures and type(_gestures.resume) == "function" then
		local gesture_rollback = type(_gestures.suspend) == "function"
			and _gestures.suspend or _gestures.disable_all
		ok_step, step_reason = add_reversible_step(
			"gestures.resume",
			_gestures.resume,
			gesture_rollback
		)
		if not ok_step then return false, step_reason end
	elseif _gestures_were_enabled then
		if not _gestures or type(_gestures.enable_all) ~= "function" then
			return false, "gestures enable API unavailable"
		end
		ok_step, step_reason = add_reversible_step(
			"gestures.enable_all",
			_gestures.enable_all,
			_gestures.disable_all
		)
		if not ok_step then return false, step_reason end
	end
	-- Symmetric to the pause-side stop_warmup()/wc.stop() pair: re-arm both warmup
	-- drivers. resume_warmup() clears the _warmup_stopped short-circuit so that
	-- api_mlx's own retry chain can run again (M-3). schedule_warmup_with_retry is
	-- fully self-guarding — it no-ops when LLM is disabled, model is unresolved, or
	-- backend is already ready — so it never fires from anything but a genuinely cold,
	-- enabled backend (never from profile restoration alone).
	local ok_api, api = pcall(require, "modules.llm.api_mlx")
	if not ok_api then
		if enforce_transaction then
			return false, "require(modules.llm.api_mlx) raised: " .. tostring(api)
		end
		api = nil
	end
	if api and type(api.resume_warmup) == "function" then
		ok_step, step_reason = add_reversible_step(
			"api_mlx.resume_warmup",
			api.resume_warmup,
			api.stop_warmup
		)
		if not ok_step then return false, step_reason end
	end
	local ok_wc, wc = pcall(require, "modules.llm.warmup_controller")
	if not ok_wc then
		if enforce_transaction then
			return false, "require(modules.llm.warmup_controller) raised: " .. tostring(wc)
		end
		wc = nil
	end
	if wc and type(wc.schedule_warmup_with_retry) == "function" then
		ok_step, step_reason = add_reversible_step(
			"warmup_controller.schedule_warmup_with_retry",
			function() return wc.schedule_warmup_with_retry("script resume") end,
			wc.stop
		)
		if not ok_step then return false, step_reason end
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
		steps[#steps + 1] = {
			label = "keylogger.resync_context",
			action = kl.resync_context,
			rollback = nil,
			best_effort = true,
		}
	end

	local applied = {}
	for _, step in ipairs(steps) do
		-- Register the inverse before calling the operation: a throwing function
		-- can already have mutated its first field before raising.
		if step.rollback then applied[#applied + 1] = step end
		local ok_action, action_reason = call_resume_operation(step.label, step.action)
		if not ok_action then
			if step.best_effort then
				Logger.warn(LOG, "Optional resume operation failed without blocking activation: %s.",
					tostring(action_reason))
			elseif not enforce_transaction then
				Logger.warn(LOG, "Pre-start resume operation ignored: %s.", tostring(action_reason))
			else
				local rollback_reason = rollback_resume_operations(applied)
				if rollback_reason then
					action_reason = action_reason .. "; rollback failures: " .. rollback_reason
				end
				return false, action_reason
			end
		end
	end
	return true, nil
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
		local ok_listener, listener_err = pcall(_on_pause_change, target_paused)
		if not ok_listener then
			Logger.error(LOG, "Pause-change listener failed after commit: %s.", tostring(listener_err))
		end
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
local function commit_pause_state(target_paused)
	if _is_paused == target_paused then return true, nil end
	if target_paused then
		_is_paused = true
		Logger.info(LOG, "Pausing all script operations after PAUSED acknowledgement.")
		pause_all()
	else
		Logger.info(LOG, "Resuming all script operations after Karabiner regeneration committed.")
		local ok_resume, resume_reason = resume_all()
		if not ok_resume then return false, resume_reason end
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

--- Completes one request once and then applies the latest queued user intent.
--- @param transaction table Captured transition descriptor.
--- @param ok boolean Whether the complete transaction committed.
--- @param reason any Failure detail.
local function complete_pause_transition(transaction, ok, reason)
	if _pause_transition ~= transaction then return end
	_pause_transition = nil
	if ok ~= true then
		report_pause_transition_failure(transaction.target, reason)
	end

	local queued = _queued_pause_target
	_queued_pause_target = nil
	if queued ~= nil and queued ~= _is_paused then
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

--- Handles the native result, then commits the Hammerspoon half atomically.
--- @param transaction table Captured transition descriptor.
--- @param ok boolean Whether the native transaction committed.
--- @param reason any Controller result detail.
local function settle_pause_transition(transaction, ok, reason)
	if _pause_transition ~= transaction then return end
	if transaction.stage == "native-resume-rollback" then return end
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
		complete_pause_transition(transaction, false, commit_reason)
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
request_pause_transition = function(target_paused)
	target_paused = target_paused == true
	if _pause_transition then
		local desired = desired_pause_state()
		if desired ~= target_paused then
			_queued_pause_target = target_paused
			Logger.debug(LOG, "Queued script pause target: %s.", tostring(target_paused))
		end
		return true
	end
	if _is_paused == target_paused then return true end

	local integration_enabled = false
	if _karabiner and type(_karabiner.get_enabled) ~= "function" then
		report_pause_transition_failure(target_paused, "Karabiner enabled-state API unavailable")
		return false
	end
	if _karabiner then
		local ok_enabled, enabled_or_err = pcall(_karabiner.get_enabled)
		if not ok_enabled then
			report_pause_transition_failure(target_paused, enabled_or_err)
			return false
		end
		integration_enabled = enabled_or_err == true
	end
	if not integration_enabled then
		local committed, commit_reason = commit_pause_state(target_paused)
		if not committed then
			report_pause_transition_failure(target_paused, commit_reason)
			return false
		end
		return true
	end

	_pause_transition_serial = _pause_transition_serial + 1
	local transaction = {
		id = _pause_transition_serial,
		target = target_paused,
		timer = nil,
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
		pcall(_extras[name])
	else
		Logger.debug(LOG, "Action '%s' has no registered handler in extras.", name)
	end
	return true
end

local function dispatch_action(action, binding)
	if type(action) ~= "string" or action == "none" or action == "--" then return false end

	if action == "script_pause_toggle" then
		local target_paused = not desired_pause_state()
		Logger.info(LOG, "Requesting script %s transaction.", target_paused and "pause" or "resume")
		request_pause_transition(target_paused)
		return true
	end

	-- Use centralized action dispatcher for everything else
	Logger.debug(LOG, "Dispatching centralized action: %s…", action)
	local ok_exec, handled = pcall(GestActions.execute_single, action, binding)
	-- …and fall back to the extras table when the central registry does not know
	-- the action. call_extra had NO caller, so M.set_extras stored handlers that
	-- nothing could ever reach: a public API documenting a dispatch path that did
	-- not exist. Registering a handler and watching it never fire is worse than
	-- having no extension point at all.
	if not ok_exec or handled ~= true then
		call_extra(action)
	end
	return true
end

--- Logs a shortcut activation via the keylogger if available.
--- @param label string Human-readable shortcut label for the log.
local function log_shortcut_if_available(label)
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if ok_kl and kl and type(kl.log_shortcut) == "function" then
		local app = hs.application.frontmostApplication()
		pcall(kl.log_shortcut, label, app and app:title() or "Unknown")
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
	if EventTapGuard.handle_disabled(e, _tap, "shortcuts.script_control") then return false end
	local provenance, status, fence = EventProvenance.classify_with_fence(
		e, "shortcuts.script_control")
	local fence_events = fence and fence.events or nil
	local function finish(consume) return consume == true, fence_events end
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
				dispatch_action(action, M.BINDING_PREFIX .. binding)
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





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

M.ACTIONS = GestActions.SG_NAMES

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
function M.start(keymap, shortcuts, gestures, karabiner)
	if _tap then
		Logger.warn(LOG, "M.start() called more than once — ignoring duplicate call.")
		return
	end
	Logger.start(LOG, "Starting script control…")

	_keymap    = type(keymap)    == "table" and keymap    or nil
	_shortcuts = type(shortcuts) == "table" and shortcuts or nil
	_gestures  = type(gestures)  == "table" and gestures  or nil
	_karabiner = type(karabiner) == "table" and karabiner or nil

	if not _keymap    then Logger.warn(LOG, "M.start(): keymap module not provided — pause/resume will be partial.") end
	if not _shortcuts then Logger.warn(LOG, "M.start(): shortcuts module not provided — pause/resume will be partial.") end
	if not _gestures  then Logger.warn(LOG, "M.start(): gestures module not provided — pause/resume will be partial.") end

	local ok, new_tap = pcall(hs.eventtap.new, {hs.eventtap.event.types.keyDown}, handle_key)
	if not ok or not new_tap then
		Logger.error(LOG, "Failed to create script-control eventtap.")
		return
	end

	_tap = new_tap
	pcall(function() _tap:start() end)

	-- Hard safety net: if macOS ever disables the tap (a stalled callback or a
	-- blocking osascript on the run loop), re-enable it so the script-management
	-- shortcuts can never get permanently stuck off.
	if _tap_watchdog then pcall(function() _tap_watchdog:stop() end) end
	_tap_watchdog = hs.timer.doEvery(TAP_WATCHDOG_INTERVAL_SEC, function()
		if _tap and type(_tap.isEnabled) == "function" and not _tap:isEnabled() then
			Logger.warn(LOG, "Script-control eventtap was disabled by macOS — re-enabling.")
			pcall(function() _tap:start() end)
		end
	end)
	Logger.success(LOG, "Script control started.")
end

--- Stops the script-control eventtap.
function M.stop()
	if _pause_transition and _pause_transition.timer then
		pcall(function() _pause_transition.timer:stop() end)
	end
	_pause_transition = nil
	_queued_pause_target = nil
	_pause_transition_serial = _pause_transition_serial + 1
	Logger.start(LOG, "Stopping script control…")

	if not _tap then
		Logger.debug(LOG, "M.stop(): eventtap was not running — nothing to do.")
		Logger.success(LOG, "Script control stopped.")
		return
	end

	if _tap_watchdog then
		pcall(function() _tap_watchdog:stop() end)
		_tap_watchdog = nil
	end

	if type(_tap.stop) == "function" then
		pcall(function() _tap:stop() end)
	end
	_tap = nil

	Logger.success(LOG, "Script control stopped.")
end

--- Returns whether the script is currently paused.
--- @return boolean True if paused.
function M.is_paused()
	return _is_paused
end

--- Configures the action triggered by a specific key slot.
--- @param keyname string "return_key", "backspace", or "escape".
--- @param action string One of the recognised action ids.
function M.set_shortcut_action(keyname, action)
	if type(keyname) ~= "string" or type(action) ~= "string" then
		Logger.error(LOG, "set_shortcut_action(): both keyname and action must be strings.")
		return
	end
	_key_actions[keyname] = action
	Logger.debug(LOG, "Key slot '%s' → '%s'.", keyname, action)
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
	pcall(dispatch_action, "script_pause_toggle")
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
