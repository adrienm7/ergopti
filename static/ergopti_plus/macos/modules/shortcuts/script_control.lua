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
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")
local Keycodes      = require("lib.keycodes")
local i18n          = require("lib.i18n")

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
-- (modules/karabiner/init.lua → build_script_control_sentinel_rules).
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
	-- Deferred for the same reason schedule_pause_layout_switch is: pause_all() runs
	-- SYNCHRONOUSLY inside the script-control eventtap callback, and karabiner.pause()
	-- encodes and writes a 100 kB+ karabiner.json (plus a /bin/mkdir subprocess on the
	-- fallback path). Blocking the tap that long lets macOS disable it with
	-- kCGEventTapDisabledByTimeout — which kills AltGr+Enter itself, leaving the user
	-- unable to un-pause. This is the last step of pause_all(), so deferring it
	-- reorders nothing.
	if _karabiner and type(_karabiner.pause) == "function" then
		hs.timer.doAfter(0, function() pcall(function() _karabiner.pause() end) end)
	end
end

--- Resumes all registered modules gracefully.
--- Only re-enables sub-systems that were active before pause_all() was called.
local function resume_all()
	if _keymap and type(_keymap.resume_processing) == "function" then
		pcall(function() _keymap.resume_processing() end)
	end
	if _shortcuts_were_running then
		if _shortcuts and type(_shortcuts.resume_bindings) == "function" then
			pcall(function() _shortcuts.resume_bindings() end)
		elseif _shortcuts and type(_shortcuts.start) == "function" then
			pcall(function() _shortcuts.start() end)
		end
	end
	-- resume() clears CoreState.suspended so the engine gate re-uses
	-- CoreState.enabled (the user feature flag). No snapshot needed: whatever
	-- the user toggled during pause is already in enabled, and resume never
	-- overrides it.
	if _gestures and type(_gestures.resume) == "function" then
		pcall(function() _gestures.resume() end)
	elseif _gestures_were_enabled then
		if _gestures and type(_gestures.enable_all) == "function" then
			pcall(function() _gestures.enable_all() end)
		end
	end
	-- Deferred for the same reason as the pause side, and more urgently: resume()
	-- calls regenerate(), which rebuilds the FULL Ergopti config rather than the
	-- reduced paused one, so it is the heavier of the two. Nothing below depends on
	-- the redeploy having landed.
	if _karabiner and type(_karabiner.resume) == "function" then
		hs.timer.doAfter(0, function() pcall(function() _karabiner.resume() end) end)
	end
	-- Symmetric to the pause-side stop_warmup()/wc.stop() pair: re-arm both warmup
	-- drivers. resume_warmup() clears the _warmup_stopped short-circuit so that
	-- api_mlx's own retry chain can run again (M-3). schedule_warmup_with_retry is
	-- fully self-guarding — it no-ops when LLM is disabled, model is unresolved, or
	-- backend is already ready — so it never fires from anything but a genuinely cold,
	-- enabled backend (never from profile restoration alone).
	local ok_api, api = pcall(require, "modules.llm.api_mlx")
	if ok_api and api and type(api.resume_warmup) == "function" then
		pcall(function() api.resume_warmup() end)
	end
	local ok_wc, wc = pcall(require, "modules.llm.warmup_controller")
	if ok_wc and wc and type(wc.schedule_warmup_with_retry) == "function" then
		pcall(function() wc.schedule_warmup_with_retry("script resume") end)
	end
	-- The context tracker is pause-gated at its entry points, so an app switch made
	-- DURING the pause never updated the cached context and nothing else re-syncs it:
	-- resuming in a different app left active_app_* and — critically — is_secure_field
	-- pinned to whatever was frontmost when the pause began. Re-sync here rather than
	-- weakening the pause guard, so « pause = tout éteint » still holds exactly.
	-- Lazy require, like the two warmup drivers above: script_control is not wired to
	-- the keylogger module and does not need to be for a one-shot resume call.
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if ok_kl and kl and type(kl.resync_context) == "function" then
		pcall(function() kl.resync_context() end)
	end
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
		_is_paused = not _is_paused

		if type(_on_pause_change) == "function" then
			pcall(_on_pause_change, _is_paused)
		end

		if _is_paused then
			Logger.info(LOG, "Pausing all script operations.")
			pause_all()
			notifications.notify(i18n.get("script_control.paused"), nil, "warning")
		else
			Logger.info(LOG, "Resuming all script operations.")
			resume_all()
			notifications.notify(i18n.get("script_control.resumed"), nil, "success")
		end
		return true
	end

	-- Use centralized action dispatcher for everything else
	Logger.debug(LOG, "Dispatching centralized action: %s…", action)
	pcall(GestActions.execute_single, action, binding)
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
	local ok, code = pcall(function() return e:getKeyCode() end)
	if not ok or type(code) ~= "number" then return false end

	-- Primary path: sentinel keycodes from KE's script-control rules. These ARE
	-- the physical F13/F14/F15 keycodes, so a bare function-key press on an
	-- extended keyboard would otherwise dispatch pause/reload/QUIT with no
	-- modifier. Require a right-hand AltGr to be physically held — the invariant
	-- of every genuine KE sentinel — and pass a stray function key through.
	if code == KEYCODE_BACKSPACE_SENTINEL then
		if not sentinel_is_genuine(e) then
			Logger.info(LOG, "Backspace sentinel (F14) seen but neither AltGr held (%s) nor tagged — passing through.",
				KeyState.describe_held_modifiers())
			return false
		end
		Logger.info(LOG, "Backspace sentinel (F14) — dispatching '%s'.", tostring(_key_actions.backspace))
		log_shortcut_if_available("Alt+Backspace")
		dispatch_action(_key_actions.backspace, M.BINDING_PREFIX .. "backspace")
		return true
	end
	if code == KEYCODE_RETURN_SENTINEL then
		if not sentinel_is_genuine(e) then
			Logger.info(LOG, "Return sentinel (F13) seen but neither AltGr held (%s) nor tagged — passing through.",
				KeyState.describe_held_modifiers())
			return false
		end
		Logger.info(LOG, "Return sentinel (F13) — dispatching '%s'.", tostring(_key_actions.return_key))
		log_shortcut_if_available("Alt+Enter")
		dispatch_action(_key_actions.return_key, M.BINDING_PREFIX .. "return_key")
		return true
	end
	if code == KEYCODE_ESCAPE_SENTINEL then
		if not sentinel_is_genuine(e) then
			Logger.info(LOG, "Escape sentinel (F15) seen but neither AltGr held (%s) nor tagged — passing through.",
				KeyState.describe_held_modifiers())
			return false
		end
		Logger.info(LOG, "Escape sentinel (F15) — dispatching '%s'.", tostring(_key_actions.escape))
		log_shortcut_if_available("Alt+Escape")
		dispatch_action(_key_actions.escape, M.BINDING_PREFIX .. "escape")
		return true
	end

	-- Fallback path: KE paused — physical right_command + target key.
	if not is_right_cmd_only(e) then return false end

	if code == KEYCODE_BACKSPACE then
		Logger.info(LOG, "Right-cmd + Backspace (KE-paused fallback) — dispatching '%s'.", tostring(_key_actions.backspace))
		log_shortcut_if_available("Alt+Backspace")
		return dispatch_action(_key_actions.backspace, M.BINDING_PREFIX .. "backspace")
	end
	if code == KEYCODE_RETURN then
		Logger.info(LOG, "Right-cmd + Return (KE-paused fallback) — dispatching '%s'.", tostring(_key_actions.return_key))
		log_shortcut_if_available("Alt+Enter")
		return dispatch_action(_key_actions.return_key, M.BINDING_PREFIX .. "return_key")
	end
	if code == KEYCODE_ESCAPE then
		Logger.info(LOG, "Right-cmd + Escape (KE-paused fallback) — dispatching '%s'.", tostring(_key_actions.escape))
		log_shortcut_if_available("Alt+Escape")
		return dispatch_action(_key_actions.escape, M.BINDING_PREFIX .. "escape")
	end

	return false
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

--- Programmatic pause — identical contract to pressing the pause key: sets the
--- flag, fires listeners, AND suspends all modules via the shared internal path.
function M.pause_all()
	if _is_paused then return end
	_is_paused = true
	if type(_on_pause_change) == "function" then pcall(_on_pause_change, true) end
	pause_all()
	Logger.info(LOG, "pause_all() called programmatically.")
end

--- Programmatic resume — symmetric to M.pause_all(); resumes all modules.
function M.resume_all()
	if not _is_paused then return end
	_is_paused = false
	if type(_on_pause_change) == "function" then pcall(_on_pause_change, false) end
	resume_all()
	Logger.info(LOG, "resume_all() called programmatically.")
end

return M
