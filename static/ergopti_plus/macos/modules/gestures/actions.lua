--- modules/gestures/actions.lua

--- ==============================================================================
--- MODULE: Gestures Actions Registry
--- DESCRIPTION:
--- Maps internal logic representations to human-readable labels and concrete
--- Hammerspoon actions (keystrokes, system events, etc.).
--- ==============================================================================

local M = {}
local BindingIdentity = require("config_binding_identity")
local KeyboardPublication = require("config_keyboard_publication")
local BindingPublication = require("config_binding_publication")

local hs            = hs
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local Paths         = require("infra.paths")
local Timings       = require("infra.timings")
local i18n          = require("infra.i18n")
local text_utils    = require("infra.text_utils")
local FileSystem    = require("adapters.file_system")
local KeyState      = require("adapters.key_state")
local SyntheticInput = require("adapters.synthetic_input")
local TerminationCoordinator = require("infra.termination_coordinator")
local Click         = require("modules.gestures.actions_click")
local Sticky        = require("modules.gestures.sticky_modifiers")
local AuxOwner      = require("modules.gestures.actions_aux_owner")
local ScreenshotSave = require("modules.shortcuts.actions.screenshot_save")
local WrapPair      = require("wrap_pair")
local DesktopNavigation = require("desktop_navigation")
local SendInput     = require("send_input")
local AppParameter  = require("app_parameter")
local ProgramParameter = require("program_parameter")
local _program_revision = 0
local _program_parameters_owned = false
local PromptAction  = require("llm.prompt_action")
local ProfileSelector = require("llm.profile_selector")
local Tone          = require("llm.tone")
local Vision        = require("llm.vision")
local JsonCodec     = require("adapters.json_codec")
local ChordCatalogue = require("infra.script_chord_catalogue")
local LOG           = "gestures.actions"
local Brightness = require("brightness_actions").load()

-- Explicit inter-key delay for every simulated keystroke. hs.eventtap.keyStroke()
-- defaults this argument to 200 000 us and implements it as a BLOCKING usleep on the
-- main run loop, so an omitted delay stalls the loop that services the typing event
-- tap — long enough for macOS to disable it (kCGEventTapDisabledByTimeout). Declared
-- here, above every closure that captures it, so it is never bound as a nil global.
local KEYSTROKE_NO_DELAY_US = 0
local CLIPBOARD_COPY_SETTLE_SEC = Timings.sec("debounce", "clipboard_copy_settle_ms")
local GESTURE_ACTION_PARENT = "gestures"
local SHORTCUT_ACTION_PARENT = "shortcut_bindings"

local _state = nil
local _dispatch_parent = GESTURE_ACTION_PARENT
local _action_scope_lifecycles = {}
local _lookup_operations = {}

--- Resolves the composite admission state for one feature parent. The fence is
--- separate from every child owner: opening Aux while Text/Mouse/Screenshot are
--- still resuming must never make the aggregate action catalogue dispatchable.
--- @param parent string|nil Stable action parent.
--- @return table lifecycle
local function action_scope_lifecycle(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or GESTURE_ACTION_PARENT
	local lifecycle = _action_scope_lifecycles[scope_id]
	if lifecycle then return lifecycle end
	lifecycle = {
		id = scope_id,
		epoch = 0,
		admission_open = true,
		transition = nil,
	}
	_action_scope_lifecycles[scope_id] = lifecycle
	return lifecycle
end

--- Closes aggregate admission synchronously and supersedes any in-flight resume.
--- @param parent string Stable action parent.
--- @return table lifecycle
local function fence_action_scope(parent)
	local lifecycle = action_scope_lifecycle(parent)
	lifecycle.epoch = lifecycle.epoch + 1
	lifecycle.admission_open = false
	lifecycle.transition = nil
	return lifecycle
end

--- Tests the identity of one aggregate resume transaction.
--- @param lifecycle table Parent lifecycle state.
--- @param attempt table Exact resume attempt.
--- @return boolean current
local function action_resume_is_current(lifecycle, attempt)
	return lifecycle.transition == attempt
		and lifecycle.epoch == attempt.epoch
		and lifecycle.admission_open == false
end

--- The dedicated script-control tap survives global PAUSE, but only the
--- script-management actions of the shared chord catalogue (paused_actions of
--- _shared/modules/actions/script_chords.json) may bypass feature admission.
--- Arbitrary catalogue actions assigned to the same chords remain fenced
--- normally.
--- @param name string Action identifier.
--- @param binding string|nil Binding provenance.
--- @return boolean control_plane
local function is_script_control_plane_action(name, binding)
	return type(binding) == "string" and binding:match("^script__") ~= nil
		and ChordCatalogue.get().paused_actions[name] == true
end

--- Maps a configurable keyboard binding (a keyboard slot or a number-row tap
--- key) to the shortcut parent while every engine and direct gesture dispatch
--- remains in the gesture parent.
--- @param binding any Binding identity supplied by execute_single().
--- @return string parent
local function parent_for_binding(binding)
	if type(binding) == "string"
		and (binding:match("^keyboard__") or binding:match("^tap_key__")) then
		return SHORTCUT_ACTION_PARENT
	end
	return GESTURE_ACTION_PARENT
end

--- @return string parent
local function current_action_parent()
	return _dispatch_parent
end

--- Binds the global shared state reference.
--- @param core_state table The shared state object from the core module.
function M.init(core_state)
	Logger.start(LOG, "Initializing…")
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — module non-functional.")
		return
	end
	_state = core_state
	Logger.success(LOG, "Initialized.")
end





-- =========================================
-- =========================================
-- ======= 1/ Low-Level Key Helpers ========
-- =========================================
-- =========================================

--- Sends a system-level media or hardware key event.
--- NX system-defined events are deliberately outside SyntheticInput: they are
--- not keyDown/keyUp events and never enter keymap/keylogger keyboard callbacks.
--- @param key string The hardware key name (e.g. "SOUND_UP").
local function sysKey(key)
	local function post_phase(is_down)
		local phase = is_down and "down" or "up"
		local created, event_or_error = xpcall(function()
			return hs.eventtap.event.newSystemKeyEvent(key, is_down)
		end, debug.traceback)
		if not created or event_or_error == nil or event_or_error == false then
			Logger.error(LOG, "System key %s %s construction failed: %s.",
				tostring(key), phase, tostring(event_or_error))
			return false
		end
		local posted, post_result = xpcall(function()
			return event_or_error:post()
		end, debug.traceback)
		if not posted or post_result == nil or post_result == false then
			Logger.error(LOG, "System key %s %s post was refused: %s.",
				tostring(key), phase, tostring(post_result))
			return false
		end
		return true
	end
	local down_posted = post_phase(true)
	local up_posted = post_phase(false)
	return down_posted and up_posted
end

local function apply_focused_window_action(label, callback)
	local focused, window_or_error = xpcall(hs.window.focusedWindow, debug.traceback)
	if not focused then
		Logger.error(LOG, "%s focused-window lookup failed: %s.",
			label, tostring(window_or_error))
		return false
	end
	if window_or_error == nil or window_or_error == false then return false end
	local applied, result = xpcall(callback, debug.traceback, window_or_error)
	if not applied or result == nil or result == false then
		Logger.error(LOG, "%s was refused: %s.", label, tostring(result))
		return false
	end
	return true
end

--- Simulates a keystroke with optional modifiers.
--- Always passes an explicit delay: hs.eventtap.keyStroke() otherwise falls back to
--- its 200 000 us default, which it implements as a BLOCKING usleep on the main run
--- loop — long enough for macOS to disable the typing event tap it stalls.
--- @param mods table List of modifiers (e.g. {"cmd", "shift"}).
--- @param key string The key code or character.
local function postKeyStroke(mods, key)
	local ok, result = xpcall(function()
		return SyntheticInput.emit_key_stroke(mods, key, KEYSTROKE_NO_DELAY_US)
	end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "synthetic key stroke was refused for %s: %s",
			tostring(key), tostring(result))
		return false
	end
	return true
end

local function defer_key(label, mods, key, delay)
	return AuxOwner.after(delay or 0, label, function()
		return postKeyStroke(mods, key)
	end, current_action_parent())
end

local function url_encode_query(value)
	value = tostring(value or "")
	return (value:gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

local function open_url(url)
	if type(url) ~= "string" or url == "" then return end
	pcall(function() hs.urlevent.openURL(url) end)
end

--- Reads the auxiliary owner's logical admission fence without letting a
--- malformed owner reopen action dispatch.
--- @return boolean open True only when the owner explicitly reports ACTIVE.
local function aux_admission_open(parent)
	local scope_id = parent or current_action_parent()
	local lifecycle = action_scope_lifecycle(scope_id)
	if lifecycle.admission_open ~= true or lifecycle.transition ~= nil then
		return false
	end
	local ok, paused_or_error = xpcall(
		AuxOwner.is_paused, debug.traceback, scope_id)
	if not ok then
		Logger.error(LOG, "Auxiliary admission query failed: %s.", tostring(paused_or_error))
		return false
	end
	return paused_or_error == false
end

--- Cancels one staged auxiliary timer and reports retained exact cleanup debt.
--- @param token table Exact token returned by AuxOwner.prepare_after().
--- @param context string Transaction context.
--- @return boolean settled
local function rollback_aux_timer(token, context)
	local ok, result = xpcall(AuxOwner.rollback_after, debug.traceback, token)
	if not ok or result ~= true then
		Logger.error(LOG, "%s timer rollback remains pending: %s.",
			tostring(context), tostring(result))
		return false
	end
	return true
end

--- Prepares one exactly tagged lookup mouse event without crossing the native boundary.
--- @param event_type integer Native mouse event type.
--- @param position table Current pointer position.
--- @param parent string Stable action parent.
--- @param phase string Provenance phase.
--- @return table|nil event Opaque SyntheticInput event owner.
--- @return string|nil detail Construction refusal detail.
local function construct_lookup_mouse_event(event_type, position, parent, phase)
	local ok, event_or_error, detail = xpcall(function()
		return SyntheticInput.prepare_mouse_event(parent, event_type, position, {
			phase = phase,
		})
	end, debug.traceback)
	if not ok or event_or_error == nil then
		return nil, ok and tostring(detail) or tostring(event_or_error)
	end
	return event_or_error
end

--- Posts one preconstructed lookup mouse event with exact native result handling.
--- @param event table Opaque SyntheticInput event owner.
--- @return boolean committed
--- @return string|nil detail Native refusal detail.
local function post_lookup_mouse_event(event)
	local ok, result_or_error, detail = xpcall(
		SyntheticInput.post_mouse_event, debug.traceback, event)
	if not ok or result_or_error ~= true then
		return false, ok and tostring(detail) or tostring(result_or_error)
	end
	return true, nil
end

--- Posts one lookup event while keeping the parent acquisition visible to a
--- re-entrant cleanup.  The down ownership is published conservatively before
--- crossing the native boundary because a mutate-then-refuse post still needs
--- the exact compensating mouse-up.
--- @param operation table Lookup acquisition.
--- @param event table|userdata Exact preconstructed event.
--- @param is_down boolean
--- @return boolean committed
--- @return string|nil detail
local function post_lookup_mouse_boundary(operation, event, is_down)
	operation.boundary_active = true
	if is_down then operation.mouse_down_owned = true end
	local posted, detail = post_lookup_mouse_event(event)
	operation.boundary_active = false
	if is_down then
		operation.down_event = nil
	elseif posted == true then
		operation.up_event = nil
		operation.mouse_down_owned = false
	end
	return posted, detail
end

--- Settles one lookup acquisition without allowing a sibling parent to consume
--- its mouse-button or timer debt.
--- @param parent string Stable action parent.
--- @return boolean settled
local function cleanup_lookup_operation(parent)
	local operation = _lookup_operations[parent]
	if not operation then return true end
	operation.authorized = false
	local timer_settled = true
	if operation.timer_token ~= nil then
		timer_settled = rollback_aux_timer(operation.timer_token, "Dictionary lookup")
		if timer_settled then operation.timer_token = nil end
	end
	if operation.boundary_active == true then return false end
	local mouse_settled = true
	if operation.mouse_down_owned == true then
		local posted = post_lookup_mouse_boundary(operation, operation.up_event, false)
		mouse_settled = posted == true
	else
		for _, field in ipairs({ "down_event", "up_event" }) do
			local event = operation[field]
			if event ~= nil then
				local discarded = SyntheticInput.discard_mouse_event(event)
				if discarded then operation[field] = nil else mouse_settled = false end
			end
		end
	end
	if timer_settled and mouse_settled and operation.boundary_active ~= true
		and operation.mouse_down_owned ~= true and operation.down_event == nil
		and operation.up_event == nil then
		if _lookup_operations[parent] == operation then
			_lookup_operations[parent] = nil
		end
		return true
	end
	return false
end





-- ===================================
-- ===================================
-- ======= 2/ Action Registry ========
-- ===================================
-- ===================================

local AX = {} -- Axis actions (continuous/scalable)
local SG = {} -- Single actions (discrete)

--- Registers an axis-based action (scalable).
local function ax(name, prev_fn, next_fn, scalable)
	AX[name] = { prev = prev_fn, next = next_fn, scalable = scalable }
end

--- Registers a discrete single-fire action.
--- Accepts an optional label string as second argument so callers can pass
--- (name, label, fn) without breaking the two-argument form (name, fn).
--- Without this guard the 3-arg form silently bound the label string as fn,
--- making every modifier+letter/digit action a no-op.
local function sg(name, label_or_fn, fn_arg)
	local fn = type(fn_arg) == "function" and fn_arg or label_or_fn
	SG[name] = { fn = fn }
end

--- Calls `method` on a lazily required UI module, logging loudly on a miss.
--- The plain `pcall(function() require(mod).method() end)` shape this replaces
--- collapsed three distinct failures — module absent, method absent, method
--- raised — into the same silent no-op, so four actions stayed dead through a
--- module rename with nothing in the logs to say so.
--- @param mod string Module name to require.
--- @param method string Method to invoke on it.
--- @param ... any Arguments forwarded to the method.
local function invoke_ui(mod, method, ...)
	local ok_mod, m = pcall(require, mod)
	if not ok_mod or type(m) ~= "table" then
		Logger.error(LOG, "Action target '%s' could not be required — gesture is a no-op.", mod)
		return
	end
	if type(m[method]) ~= "function" then
		Logger.error(LOG, "Action target '%s' has no '%s' function — gesture is a no-op.", mod, method)
		return
	end
	local ok_call, err = pcall(m[method], ...)
	if not ok_call then
		Logger.error(LOG, "Action '%s.%s' raised: %s", mod, method, tostring(err))
	end
end

--- Activates the most recently used other application directly.
---
--- This posted Cmd+Tab. The Dock commits its switcher only when Command itself
--- is released, and a posted Tab keystroke carrying the Command flag releases
--- nothing: one tap did nothing, a second one left the switcher open on screen.
--- modules/gestures/app_switch.lua focuses the application's window instead.
--- It runs off the dispatch callback, because listing the windows asks every
--- application over the accessibility API, which an input callback must not
--- wait on. Required at the call so a test can put its own desk behind it.
--- @param scope string app_switch.SCOPE_ALL_SCREENS or SCOPE_THIS_SCREEN.
--- @return boolean scheduled
local function switch_to_previous_application(scope)
	local scheduled = AuxOwner.after(0, "previous application", function()
		return require("modules.gestures.app_switch").previous_app(scope)
	end, current_action_parent())
	return scheduled == true
end

--- Activates the least recently used application, what a Cmd+Shift+Tab tap
--- selects. Posted, that keystroke switched nothing either.
--- @return boolean scheduled
local function switch_to_least_recent_application()
	local scheduled = AuxOwner.after(0, "least recent application", function()
		return require("modules.gestures.app_switch").least_recent_app()
	end, current_action_parent())
	return scheduled == true
end

--- Cycles the windows of the frontmost application directly. A posted Cmd+`
--- depends on the keyboard layout carrying a backquote, which several non-US
--- layouts do not; the remapped cycle_windows_in_app key (F17, watchers.lua)
--- focuses windows itself for the same reason, but only with the remap layer.
--- @param step number 1 for the next window, -1 for the previous one.
--- @return boolean scheduled
local function switch_application_window(step)
	local scheduled = AuxOwner.after(0, "application window", function()
		return require("modules.gestures.app_switch").app_window(step)
	end, current_action_parent())
	return scheduled == true
end

--- Triggers a macOS system-wide dictionary lookup/definition.
function M.trigger_lookup(explicit_parent)
	local requested_parent = explicit_parent or current_action_parent()
	local parent = requested_parent == SHORTCUT_ACTION_PARENT
		and SHORTCUT_ACTION_PARENT or GESTURE_ACTION_PARENT
	if not aux_admission_open(parent) then return false end
	if _lookup_operations[parent] ~= nil then
		local cleanup_ok, cleanup_result = xpcall(
			cleanup_lookup_operation, debug.traceback, parent)
		if not cleanup_ok or cleanup_result ~= true then
			Logger.error(LOG,
				"Dictionary lookup mouse-up cleanup remains pending for '%s': %s.",
				parent, tostring(cleanup_result))
			return false
		end
		-- Cleanup may synchronously cross a lifecycle boundary. Revalidate the
		-- composite fence before acquiring the replacement lookup transaction.
		if not aux_admission_open(parent) then return false end
	end
	local acquired, prepared, timer_token = xpcall(function()
		return AuxOwner.prepare_after(0.05, "dictionary lookup", function()
			postKeyStroke({"cmd", "ctrl"}, "d")
		end, parent)
	end, debug.traceback)
	if not acquired or prepared ~= true or type(timer_token) ~= "table" then
		Logger.error(LOG, "Dictionary lookup timer acquisition failed: %s.",
			tostring(prepared))
		return false
	end
	local operation = {
		parent = parent,
		timer_token = timer_token,
		down_event = nil,
		up_event = nil,
		mouse_down_owned = false,
		boundary_active = false,
		authorized = true,
	}
	_lookup_operations[parent] = operation

	local position_ok, position_or_error = xpcall(hs.mouse.absolutePosition, debug.traceback)
	if not position_ok or type(position_or_error) ~= "table" then
		cleanup_lookup_operation(parent)
		Logger.error(LOG, "Dictionary lookup mouse position read failed: %s.",
			tostring(position_or_error))
		return false
	end
	if not aux_admission_open(parent) then
		cleanup_lookup_operation(parent)
		return false
	end

	local types_ok, event_types_or_error = xpcall(function()
		return hs.eventtap.event.types
	end, debug.traceback)
	if not types_ok or type(event_types_or_error) ~= "table" then
		cleanup_lookup_operation(parent)
		Logger.error(LOG, "Dictionary lookup mouse event types read failed: %s.",
			tostring(event_types_or_error))
		return false
	end
	local down_event, down_error = construct_lookup_mouse_event(
		event_types_or_error.rightMouseDown, position_or_error, parent, "down")
	operation.down_event = down_event
	local up_event, up_error = construct_lookup_mouse_event(
		event_types_or_error.rightMouseUp, position_or_error, parent, "up")
	operation.up_event = up_event
	if down_event == nil or up_event == nil then
		cleanup_lookup_operation(parent)
		Logger.error(LOG, "Dictionary lookup mouse event construction failed: %s / %s.",
			tostring(down_error), tostring(up_error))
		return false
	end
	if not aux_admission_open(parent) then
		cleanup_lookup_operation(parent)
		return false
	end

	local down_posted, down_post_error =
		post_lookup_mouse_boundary(operation, down_event, true)
	if down_posted ~= true then
		cleanup_lookup_operation(parent)
		Logger.error(LOG, "Dictionary lookup mouse-down post failed: %s.",
			tostring(down_post_error))
		return false
	end
	if not aux_admission_open(parent) or operation.authorized ~= true then
		cleanup_lookup_operation(parent)
		return false
	end

	local up_posted, up_post_error =
		post_lookup_mouse_boundary(operation, up_event, false)
	if up_posted ~= true then
		cleanup_lookup_operation(parent)
		Logger.error(LOG, "Dictionary lookup mouse-up post failed: %s.",
			tostring(up_post_error))
		return false
	end
	if not aux_admission_open(parent) or operation.authorized ~= true then
		cleanup_lookup_operation(parent)
		return false
	end

	local commit_ok, committed = xpcall(AuxOwner.commit_after, debug.traceback, timer_token)
	if not commit_ok or committed ~= true then
		cleanup_lookup_operation(parent)
		Logger.error(LOG, "Dictionary lookup timer commit failed: %s.", tostring(committed))
		return false
	end
	operation.timer_token = nil
	if _lookup_operations[parent] == operation then _lookup_operations[parent] = nil end
	return true
end

-- The synthetic click-hold subsystem lives in its own module so the action
-- registry below stays a pure name -> behaviour mapping. Re-export its public
-- surface on M so existing callers (and the registry) keep their call sites.
M.force_cleanup           = Click.force_cleanup
M.toggle_right_click      = function()
	return Click.toggle_right_click(current_action_parent())
end
M.toggle_left_click       = function()
	return Click.toggle_left_click(current_action_parent())
end
M.is_right_click_held     = Click.is_right_click_held

--- Navigates between windows of the current application.
local function winNav(goNext)
	local mods = goNext and { "cmd" } or { "cmd", "shift" }
	postKeyStroke(mods, "`")
end

-- The Spaces binding wraps a private API: loading it and querying it are both
-- slow enough to matter on the gesture frame callback, and the module was being
-- require()d afresh on every single navigation.
local _spaces_mod = nil
local function _spaces_module()
	if _spaces_mod == nil then
		local ok_sp, mod = pcall(require, "hs.spaces")
		_spaces_mod = (ok_sp and mod) or false
	end
	return _spaces_mod or nil
end

-- Seconds the Space LAYOUT is trusted without re-querying. It only changes when
-- the user adds or removes a desktop, which cannot happen mid-gesture.
local SPACES_LAYOUT_TTL_SEC = 5.0
local _all_spaces_cache = nil
local _all_spaces_at    = 0

--- Returns (ok, allSpaces) using a short-lived cache.
--- @param spaces table The Spaces binding module.
--- @param refresh boolean|nil True to re-read the layout whatever its age.
--- @return boolean, table|nil
local function _cached_all_spaces(spaces, refresh)
	local now = hs.timer.secondsSinceEpoch()
	if refresh ~= true and _all_spaces_cache ~= nil
		and (now - _all_spaces_at) < SPACES_LAYOUT_TTL_SEC then
		return true, _all_spaces_cache
	end
	local ok, all = pcall(spaces.allSpaces)
	if ok and type(all) == "table" then
		_all_spaces_cache = all
		_all_spaces_at    = now
	end
	return ok, all
end

--- The Spaces of the screen that holds the focused Space, in Ctrl+Arrow order,
--- and the position of the focused one among them.
---
--- allSpaces is a private-API round-trip and this runs on the gesture frame
--- callback, where a stall shows up directly as input lag. The Space LAYOUT
--- changes only when the user adds or removes a desktop, so it is cached
--- briefly; the focused Space, which changes with every navigation, is always
--- read live. A focused Space missing from the cached layout means a desktop
--- was added within the cache lifetime, so the layout is read once more.
--- @param spaces table The Spaces binding module.
--- @return table|nil list Ordered Space ids of the focused screen.
--- @return integer|nil index 0-based position of the focused Space in list.
--- @return string|nil reason Why the layout could not be read.
local function focused_screen_spaces(spaces)
	local ok_cur, cur = pcall(spaces.focusedSpace)
	if not ok_cur or cur == nil then
		return nil, nil, "the focused Space is unreadable (" .. tostring(cur) .. ")"
	end
	for _, refresh in ipairs({ false, true }) do
		local ok_all, all = _cached_all_spaces(spaces, refresh)
		if not ok_all or type(all) ~= "table" then
			return nil, nil, "the Space layout is unreadable (" .. tostring(all) .. ")"
		end
		for _, list in pairs(all) do
			for position, id in ipairs(list) do
				if id == cur then return list, position - 1, nil end
			end
		end
	end
	return nil, nil, "the focused Space " .. tostring(cur) .. " is on no screen"
end

-- Ctrl+Left and Ctrl+Right, as Quartz key codes. AppleScript-generated key
-- events carry no Ergopti provenance: both taps then treated a Space
-- navigation as physical typing, so action-epoch consumers could retain
-- text/LLM state from the previous desktop. Numeric Quartz keycodes are
-- supported by the same exact-tag adapter used by named gesture keys.
local SPACE_STEP_KEY = { [DesktopNavigation.PREVIOUS] = 123, [DesktopNavigation.NEXT] = 124 }

--- Moves one Space in a direction, as Ctrl+Arrow does: macOS stops at the
--- first and the last Space of the screen.
--- @param direction string DesktopNavigation.PREVIOUS or .NEXT.
--- @return boolean posted
local function space_step(direction)
	return postKeyStroke({ "ctrl" }, SPACE_STEP_KEY[direction])
end

--- Jumps to one Space of the focused screen, or walks there one Ctrl+Arrow at
--- a time when the jump is refused.
---
--- gotoSpace clicks the Space's button in Mission Control through the Dock's
--- accessibility tree and waits for Mission Control to open, so it holds the
--- Hammerspoon run loop for a moment. It therefore never runs inside the
--- gesture or hotkey callback that asked for it (the caller defers it through
--- the auxiliary owner), and only for a jump across the whole screen: a
--- neighbour is always a single keystroke.
--- @param spaces table The Spaces binding module.
--- @param space_id integer The Space to land on.
--- @param steps integer Signed number of single steps to the same Space.
--- @return boolean arrived
local function goto_space_or_walk(spaces, space_id, steps)
	local ok, went, err = pcall(spaces.gotoSpace, space_id)
	if ok and went == true then
		Logger.debug(LOG, "Wrapped to Space %s.", tostring(space_id))
		return true
	end
	Logger.warn(LOG, "Jump to Space %s refused (%s) — walking %d Space(s) with Ctrl+Arrow instead.",
		tostring(space_id), tostring(ok and err or went), math.abs(steps))
	local direction = steps > 0 and DesktopNavigation.NEXT or DesktopNavigation.PREVIOUS
	for _ = 1, math.abs(steps) do
		if not space_step(direction) then return false end
	end
	return true
end

--- Moves one Space in a direction, wrapping at the edges of the focused
--- screen: from its last Space to its first and from its first to its last.
--- macOS stops at both ends, so the wrap is Ergopti's.
---
--- Without a readable layout the edge cannot be told apart from the middle:
--- the step is then the plain one, and the log says the wrap was not possible.
--- @param direction string DesktopNavigation.PREVIOUS or .NEXT.
--- @return boolean handled
local function wrapping_space_step(direction)
	local spaces = _spaces_module()
	if not spaces then
		Logger.warn(LOG, "The Spaces binding is unavailable — moving one Space without wrapping.")
		return space_step(direction)
	end
	local list, index, reason = focused_screen_spaces(spaces)
	if not list then
		Logger.warn(LOG, "Cannot wrap: %s — moving one Space without wrapping.", reason)
		return space_step(direction)
	end
	local target = DesktopNavigation.target(index, #list, direction, true)
	local steps = target - index
	if steps == 0 then
		Logger.debug(LOG, "The focused screen has a single Space — nothing to wrap to.")
		return true
	end
	-- The key follows the sign of the step, not the requested direction: with
	-- two Spaces the wrap from the last one is a single step LEFT.
	if math.abs(steps) == 1 then
		return space_step(steps > 0 and DesktopNavigation.NEXT or DesktopNavigation.PREVIOUS)
	end
	local target_id = list[target + 1]
	Logger.debug(LOG, "Wrapping from Space %s to Space %s.", tostring(list[index + 1]), tostring(target_id))
	return AuxOwner.after(0, "space wrap", function()
		return goto_space_or_walk(spaces, target_id, steps)
	end, current_action_parent())
end

--- Opens Mission Control or App Exposé through the Dock itself. The F3 key and
--- Ctrl+Down posted before do nothing once the user changes or disables those
--- shortcuts in System Settings; the Dock notification does not depend on them.
--- @param method string toggleMissionControl or toggleAppExpose.
--- @return boolean toggled
local function dock_toggle(method)
	local spaces = _spaces_module()
	if not spaces or type(spaces[method]) ~= "function" then
		Logger.error(LOG, "The Spaces binding has no %s — the action is a no-op.", method)
		return false
	end
	local ok, err = pcall(spaces[method])
	if not ok then
		Logger.error(LOG, "The Spaces binding's %s raised: %s.", method, tostring(err))
		return false
	end
	return true
end

-- Axis actions (prev / next)
ax("tabs",       
	function() postKeyStroke({"ctrl", "shift"}, "tab") end,
	function() postKeyStroke({"ctrl"}, "tab") end, true)

ax("char",       
	function() postKeyStroke({}, "left") end,
	function() postKeyStroke({}, "right") end, true)

ax("char_sel",   
	function() postKeyStroke({"shift"}, "left") end,
	function() postKeyStroke({"shift"}, "right") end, true)

ax("line_arrow", 
	function() postKeyStroke({}, "up") end,
	function() postKeyStroke({}, "down") end, true)

ax("line_sel",   
	function() postKeyStroke({"shift"}, "up") end,
	function() postKeyStroke({"shift"}, "down") end, true)

ax("words",      
	function() postKeyStroke({"alt"}, "left") end,
	function() postKeyStroke({"alt"}, "right") end, true)

ax("words_sel",  
	function() postKeyStroke({"shift", "alt"}, "left") end,
	function() postKeyStroke({"shift", "alt"}, "right") end, true)

ax("windows",    
	function() winNav(false) end, 
	function() winNav(true) end)

ax("spaces",     
	function() space_step(DesktopNavigation.PREVIOUS) end, 
	function() space_step(DesktopNavigation.NEXT) end)

ax("volume",     
	function() sysKey("SOUND_DOWN") end, 
	function() sysKey("SOUND_UP") end, true)

ax("brightness", 
	function() return sysKey(Brightness.actions.brightness_down.macos_system) end, 
	function() return sysKey(Brightness.actions.brightness_up.macos_system) end, true)

ax("tracks",     
	function() sysKey("PREVIOUS") end, 
	function() sysKey("NEXT") end)

ax("lines",      
	function() return defer_key("line up", {"alt"}, "up") end,
	function() return defer_key("line down", {"alt"}, "down") end, true)

ax("line_bounds",
	function() return defer_key("line start", {"cmd"}, "left") end,
	function() return defer_key("line end", {"cmd"}, "right") end)

ax("paragraphs", 
	function() postKeyStroke({"alt"}, "up") end,
	function() postKeyStroke({"alt"}, "down") end, true)

ax("document",   
	function() postKeyStroke({"cmd"}, "up") end,
	function() postKeyStroke({"cmd"}, "down") end)

-- Single actions
sg("none",                         function() end)

-- Selection & navigation cursor
sg("left_click_toggle",   M.toggle_left_click)
sg("right_click_toggle",   M.toggle_right_click)
sg("lookup", function()
	return M.trigger_lookup(current_action_parent())
end)
-- One action per target and scope. app_switcher, alt_tab_apps (Alt+F17),
-- app_window_previous, win_prev and win_next did the same thing as one of
-- these on macOS; config migration step v5_to_v6 maps a stored one to its twin.
--- Captures native assignment and canonical configuration before asynchronous input.
--- @param binding string Actual gesture or keyboard binding that dispatched it.
--- @return table|nil publication Full IO check and callback-free terminal seal.
local function native_switcher_publication(binding)
	if type(binding) ~= "string" or binding == "" then return nil end
	local parent, lifecycle = current_action_parent(), action_scope_lifecycle(current_action_parent())
	local epoch, state = lifecycle.epoch, _state
	local Preferences = require("infra.preferences")
	local path = require("infra.config_paths").get("ConfigTomlPath")
	local source = Preferences.source_snapshot(path)
	if type(source) ~= "table" or source.status ~= "ok" or type(source.content) ~= "string" then return nil end
	local source_guard = Preferences.capture_source_delivery_guard(path)
	local assignment, assignment_owner, assignment_method, assignment_name
	if binding:sub(1, 10) == "keyboard__" or binding:sub(1, 9) == "tap_key__" or binding:sub(1, 8) == "script__" then
		local name = binding:sub(1, 10) == "keyboard__"
			and "modules.shortcuts.keyboard_shortcuts"
			or (binding:sub(1, 9) == "tap_key__" and "modules.shortcuts.tap_keys" or "modules.shortcuts.script_control")
		assignment_name = name
		assignment_owner = rawget(package.loaded, name)
		assignment_method = assignment_owner and assignment_owner.capture_action_delivery_guard
		if type(assignment_method) ~= "function" then return nil end
		assignment = assignment_method(binding, "system_app_switcher")
	elseif state and state.ga and state.ga[binding] == "system_app_switcher" then
		local actions = state.ga
		assignment = function() return _state == state and state.ga == actions and actions[binding] == "system_app_switcher" end
	end
	if type(assignment) ~= "function" then return nil end
	local function cached()
		return lifecycle.epoch == epoch and lifecycle.admission_open == true and lifecycle.transition == nil
			and source_guard() == true and assignment() == true
			and rawequal(rawget(package.loaded, "modules.gestures.actions"), M)
			and (not assignment_owner or (rawequal(rawget(package.loaded, assignment_name), assignment_owner)
				and assignment_owner.capture_action_delivery_guard == assignment_method))
	end
	local function current()
		if not cached() or not aux_admission_open(parent) then return false end
		local content, status = FileSystem.read_with_status(path)
		return status == "ok" and content == source.content and cached()
	end
	if not current() then return nil end
	return { current = current, cached = cached }
end

sg("system_app_switcher", function(binding)
	local publication = native_switcher_publication(binding)
	if not publication then
		Logger.error(LOG, "Native switcher refused an unavailable or retired binding source.")
		return false
	end
	return require("modules.gestures.native_app_switcher_action").request(current_action_parent(), publication)
end)
sg("app_previous",      function() return switch_to_previous_application("all_screens") end)
sg("app_previous_screen", function() return switch_to_previous_application("this_screen") end)
sg("cmd_shift_tab",     switch_to_least_recent_application)

-- Keys
-- ── Actions the shared catalogue describes for macOS ────────────────────────
--
-- 27 registrations used to be written out here, each spelling a key and its
-- modifiers into its own closure. They now come from
-- _shared/modules/actions/actions.toml via _generated/gesture_emit_actions.lua.
--
-- These are macOS values, not shared ones: of the 24 actions both drivers
-- implement as a bare keystroke, 15 differ. macOS moves by word with Option
-- where Windows uses Control, closes a window with cmd+w against alt+F4, and
-- spells several keys differently outright (return/Enter, delete/BackSpace).
--
-- The closure below captures `row` safely: a Lua generic `for` binds fresh
-- locals each iteration, so every handler keeps its own values. The AHK twin
-- cannot do this — an AHK loop closure captures the loop VARIABLE, so its
-- emitters have to be built by helper functions taking the values as arguments.
local ok_emit, emit_rows = pcall(require, "_generated.gesture_emit_actions")
if not ok_emit or type(emit_rows) ~= "table" then
	error("gestures/actions: _generated/gesture_emit_actions.lua is missing or invalid — "
		.. "27 gesture actions would silently do nothing. Run `npm run gen`.")
end
for _, row in ipairs(emit_rows) do
	sg(row.id, function() postKeyStroke(row.mods, row.key) end)
end




-- ── The Karabiner catalogue's non-keystroke actions ─────────────────────────
--
-- macos/platform/remap/data/actions.json describes 73 actions the REMAP layer can
-- put on a key. 36 of them are tappable and had no row in the shared catalogue,
-- so the gesture picker could not offer a single one — the same feature was
-- reachable from a remapped key and unreachable from a swipe, with nothing
-- saying why. The 18 that are plain keystrokes come through the generated table
-- above; these 18 cannot, and each family fails differently:
--
--   layer_on / layer_off / capsword  — state that lives INSIDE Karabiner. The
--       only IPC is `karabiner_cli --set-variable`, so they are writes, not
--       keystrokes (platform/remap/ke_variables.lua).
--   the 15 sticky_*                  — `sticky_modifier` is a manipulator
--       construct with no IPC at all, so macOS implements the behaviour itself
--       (modules/gestures/sticky_modifiers.lua).
--
-- The 19 hold-only actions of the catalogue are deliberately absent: a gesture
-- has no duration, so "hold Shift" cannot be expressed as one.

-- `layer_active` is the one navigation-layer authority read by manipulators.
-- Mirror variables add asynchronous writers without adding observable state.
local KE_LAYER_VARIABLE = "layer_active"
local KE_LAYER_ON       = 1
local KE_LAYER_OFF      = 0
local KE_CAPSWORD_VARIABLE   = "capsword"
local KE_CAPSWORD_ACTIVE     = 1

-- The remap menu stores the sticky auto-cancel delay in milliseconds.
local MILLISECONDS_PER_SECOND = 1000

--- The Karabiner variable bridge, required lazily so a driver booted without the
--- remap layer still loads this registry.
--- @return table|nil
local function ke_variables()
	local ok, mod = pcall(require, "platform.remap.ke_variables")
	if not ok or type(mod) ~= "table" then
		Logger.error(LOG, "platform.remap.ke_variables could not be required — the gesture is a no-op.")
		return nil
	end
	return mod
end

--- Reads the user's sticky auto-cancel delay, in seconds.
--- Returns nil rather than a default: the value is the one set in the remap
--- menu, and substituting one here would silently override that choice on the
--- exact boot where the configuration failed to load.
--- @return number|nil
local function sticky_timeout_sec()
	local ok, Remap = pcall(require, "platform.remap")
	if not ok or type(Remap) ~= "table" or type(Remap.get_sticky_timeout) ~= "function" then
		Logger.error(LOG, "platform.remap exposes no get_sticky_timeout — sticky gesture is a no-op.")
		return nil
	end
	local ms = Remap.get_sticky_timeout()
	if type(ms) ~= "number" or ms <= 0 then
		Logger.error(LOG, "Sticky timeout is '%s' — refusing to arm on a guessed delay.", tostring(ms))
		return nil
	end
	return ms / MILLISECONDS_PER_SECOND
end

--- Arms a set of one-shot modifiers for the next keystroke.
--- @param modifiers table Array of hs modifier names.
local function arm_sticky(modifiers)
	local secs = sticky_timeout_sec()
	if not secs then return end
	return Sticky.toggle(modifiers, secs, current_action_parent())
end

sg("layer_on", function()
	local ke = ke_variables()
	if ke then ke.set(KE_LAYER_VARIABLE, KE_LAYER_ON) end
end)
sg("layer_off", function()
	local ke = ke_variables()
	if ke then ke.set(KE_LAYER_VARIABLE, KE_LAYER_OFF) end
end)
sg("capsword", function()
	local ke = ke_variables()
	if not ke then return end
	local function finish_activation(ok, reason, revision)
		if ok ~= true or reason ~= "written" then
			Logger.debug(LOG, "CapsWord gesture activation did not settle: %s.", tostring(reason))
			return
		end
		local controller_ok, controller = pcall(require, "platform.remap.lease_controller")
		if not controller_ok or type(controller) ~= "table"
			or type(controller.status) ~= "function" then
			Logger.error(LOG, "CapsWord gesture cannot verify the live remap lease: %s.",
				tostring(controller))
			return
		end
		local status_ok, phase = pcall(controller.status)
		if not status_ok or phase ~= "active" then
			Logger.debug(LOG, "CapsWord gesture LED activation discarded in lease phase %s.",
				tostring(phase))
			return
		end
		local revision_ok, current_revision = pcall(ke.capsword_revision)
		if not revision_ok or current_revision ~= revision then
			Logger.debug(LOG, "CapsWord gesture LED activation was superseded.")
			return
		end
		Logger.pcall(LOG, KeyState.set_capslock, true)
	end
	if not ke.set(KE_CAPSWORD_VARIABLE, KE_CAPSWORD_ACTIVE, finish_activation) then return end
	-- A keystroke cannot toggle CapsLock: macOS delivers it as a flagsChanged
	-- event rather than a keyDown/keyUp pair, so keyStroke fails silently. The
	-- adapter owns the only path that works after the lease-gated write settles,
	-- and it is the same one
	-- platform/remap/watchers.lua uses to switch CapsWord back off.
end)

sg("sticky_shift", function()
	local keymap = require("modules.keymap")
	return keymap.arm_one_shot_shift()
end)
sg("sticky_ctrl",              function() arm_sticky({ "ctrl" }) end)
sg("sticky_cmd",               function() arm_sticky({ "cmd" }) end)
sg("sticky_option",            function() arm_sticky({ "alt" }) end)
sg("sticky_cmd_shift",         function() arm_sticky({ "cmd", "shift" }) end)
sg("sticky_cmd_option",        function() arm_sticky({ "cmd", "alt" }) end)
sg("sticky_cmd_ctrl",          function() arm_sticky({ "cmd", "ctrl" }) end)
sg("sticky_option_shift",      function() arm_sticky({ "alt", "shift" }) end)
sg("sticky_option_ctrl",       function() arm_sticky({ "alt", "ctrl" }) end)
sg("sticky_ctrl_shift",        function() arm_sticky({ "ctrl", "shift" }) end)
sg("sticky_cmd_option_shift",  function() arm_sticky({ "cmd", "alt", "shift" }) end)
sg("sticky_cmd_option_ctrl",   function() arm_sticky({ "cmd", "alt", "ctrl" }) end)
sg("sticky_cmd_shift_ctrl",    function() arm_sticky({ "cmd", "shift", "ctrl" }) end)
sg("sticky_option_shift_ctrl", function() arm_sticky({ "alt", "shift", "ctrl" }) end)
sg("sticky_hyper",             function() arm_sticky({ "cmd", "alt", "shift", "ctrl" }) end)


-- Tabs

-- Windows & Spaces
sg("win_app_prev",        function() return switch_application_window(-1) end)
sg("win_app_next",        function() return switch_application_window(1) end)
sg("snap_left",              function()
	return apply_focused_window_action("Snap left", function(win)
		return win:moveToUnit(hs.layout.left50)
	end)
end)
sg("snap_right",             function()
	return apply_focused_window_action("Snap right", function(win)
		return win:moveToUnit(hs.layout.right50)
	end)
end)
sg("maximize",                     function()
	return apply_focused_window_action("Maximize", function(win)
		return win:maximize()
	end)
end)
sg("space_prev",             function() space_step(DesktopNavigation.PREVIOUS) end)
sg("space_next",               function() space_step(DesktopNavigation.NEXT) end)
sg("space_prev_wrap",        function() return wrapping_space_step(DesktopNavigation.PREVIOUS) end)
sg("space_next_wrap",        function() return wrapping_space_step(DesktopNavigation.NEXT) end)
sg("mission_control",        function() return dock_toggle("toggleMissionControl") end)
sg("app_expose",             function() return dock_toggle("toggleAppExpose") end)
-- Command + the Mission Control key: macOS's own Show Desktop shortcut.
sg("show_desktop",                function()
	return postKeyStroke({ "cmd" }, 160)
end)

-- Cursor movement
sg("line_up",               function() return defer_key("line up", {"alt"}, "up") end)
sg("line_down",             function() return defer_key("line down", {"alt"}, "down") end)
sg("line_start",            function() return defer_key("line start", {"cmd"}, "left") end)
sg("line_end",              function() return defer_key("line end", {"cmd"}, "right") end)

-- Media
sg("vol_up",                        function() sysKey("SOUND_UP") end)
sg("vol_down",                      function() sysKey("SOUND_DOWN") end)
sg("mute",                       function() sysKey("MUTE") end)
sg("brightness_up",             function() return sysKey(Brightness.actions.brightness_up.macos_system) end)
sg("brightness_down",           function() return sysKey(Brightness.actions.brightness_down.macos_system) end)
sg("track_play",               function() sysKey("PLAY") end)
sg("track_next",              function() sysKey("NEXT") end)
sg("track_prev",            function() sysKey("PREVIOUS") end)

-- Single arrows

-- Shift + Arrows

-- Shift + Alt + Arrows (Word selection)

-- System
sg("screenshot_window_clipboard",     function()
	return ScreenshotSave.capture({ "-w" }, current_action_parent())
end)
sg("screenshot_window_save",          function()
	return ScreenshotSave.save({ "-w" }, "win", current_action_parent())
end)
sg("screenshot_region_clipboard",      function()
	return ScreenshotSave.capture({ "-i" }, current_action_parent())
end)
sg("screenshot_region_save",           function()
	return ScreenshotSave.save({ "-i" }, "reg", current_action_parent())
end)
sg("screenshot_fullscreen_clipboard",   function()
	return ScreenshotSave.capture({}, current_action_parent())
end)
sg("screenshot_fullscreen_save",        function()
	return ScreenshotSave.save({}, "full", current_action_parent())
end)

-- Four actions macOS has always implemented — in the keyboard-SHORTCUT layer —
-- and never exposed as gestures. The shared catalogue declared them
-- platform = "ahk", so the picker (which filters on that) hid them, and the
-- cross-driver feature matrix read as "macOS does not have this" for four
-- features it ships. Registering them here is what makes the declaration true;
-- the TOML flip to "all" without this would have put four dead rows in the
-- picker, since execute_single() refuses an action it has no handler for.
--
-- Required lazily, inside the closure: these modules pull in the whole shortcuts
-- tree, and requiring it at gesture-registry load time would drag it into boot
-- for users who never bind one of these.
--- Builds a gesture action that runs one function of a parent-scoped owner of
--- the shortcut layer under the dispatching parent, so PAUSE of that parent
--- fences it and a sibling parent's PAUSE does not. A confirmed action also
--- gets the application the user acted from, which its question read before
--- bringing the driver to the front (execute_single).
--- @param module_name string The owner module.
--- @param method string Public function taking the parent, then that
--- application (nil for an action that asks nothing).
--- @return function
local function owner_action(module_name, method)
	return function(_, acted_from)
		local ok, Owner = pcall(require, module_name)
		if not ok or type(Owner) ~= "table" or type(Owner[method]) ~= "function" then
			Logger.error(LOG, "Action '%s.%s' is unavailable: %s.", module_name, method, tostring(Owner))
			return false
		end
		return Owner[method](current_action_parent(), acted_from)
	end
end

--- @param method string Public function of modules.shortcuts.actions.text.
--- @return function
local function text_action(method)
	return owner_action("modules.shortcuts.actions.text", method)
end

sg("select_line", text_action("select_line"))
sg("select_word", text_action("select_word"))
sg("paste_plain", text_action("paste_as_plain_text"))
-- The case actions: the two toggles and the three explicit conversions, all
-- through the shared Unicode table (unicode_case), pinned by the shared corpus.
sg("uppercase_selection", text_action("toggle_uppercase"))
sg("titlecase_selection", text_action("toggle_titlecase"))
sg("selection_uppercase", text_action("selection_uppercase"))
sg("selection_lowercase", text_action("selection_lowercase"))
sg("selection_titlecase", text_action("selection_titlecase"))
-- Wraps the current LINE (Cmd+Left, "(", Cmd+Right, ")"), like Windows.
sg("surround_parens", text_action("surround_with_parens"))
-- The pair is the binding's own parameter: two bindings may wrap with two pairs.
sg("wrap_selection", function(binding)
	local value = M.get_action_parameter(binding, "wrap_selection")
	local left, right = M.wrap_pair_for(value)
	if not left then
		Logger.warn(LOG, "wrap_selection ignored for binding '%s': no valid pair is stored ('%s').",
			tostring(binding), tostring(value))
		return false
	end
	local ok, Text = pcall(require, "modules.shortcuts.actions.text")
	if not ok or type(Text.wrap_copied_selection) ~= "function" then
		Logger.error(LOG, "Text action 'wrap_copied_selection' is unavailable: %s.", tostring(Text))
		return false
	end
	return Text.wrap_copied_selection(left, right, current_action_parent())
end)

--- Types a text through the synthetic-input adapter, which tags every event
--- with its provenance so the keymap never reads it back as typing.
--- @param text string
--- @return boolean True when the text was queued.
local function postKeyStrokes(text)
	local ok, result = xpcall(function()
		return SyntheticInput.emit_key_strokes(text)
	end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "synthetic text was refused (%d byte(s)): %s", #text, tostring(result))
		return false
	end
	return true
end

--- Types the binding's text, or presses its key or shortcut (send_text,
--- send_key, send_shortcut). primary and super are both Command here and press
--- once; a named key is its Hammerspoon name; a character on its own is typed
--- as that character, and a character in a shortcut is the key the current
--- input source carries it on.
--- @param action string send_text, send_key or send_shortcut.
--- @param binding string The binding whose parameter holds the value.
--- @return boolean True when the input was sent.
local function send_input_action(action, binding)
	local kind = M.get_action_parameter_spec(action)
	local vocabulary = M.send_vocabulary()
	local parsed = SendInput.parse(kind, M.get_action_parameter(binding, action), vocabulary)
	if not parsed then
		Logger.warn(LOG, "%s ignored for binding '%s': no valid value is stored.", action, tostring(binding))
		return false
	end
	if kind == "text" then return postKeyStrokes(parsed.text) end
	local mods, held = {}, {}
	for _, id in ipairs(parsed.mods or {}) do
		local name = SendInput.entry(vocabulary, "modifiers", id).hs
		if not held[name] then
			held[name] = true
			mods[#mods + 1] = name
		end
	end
	if parsed.named then
		return postKeyStroke(mods, SendInput.entry(vocabulary, "keys", parsed.named).hs)
	end
	if kind == "key" then return postKeyStrokes(parsed.char) end
	return postKeyStroke(mods, parsed.char)
end
-- The value is the binding's own parameter, as for wrap_selection.
sg("send_text", function(binding) return send_input_action("send_text", binding) end)
sg("send_key", function(binding) return send_input_action("send_key", binding) end)
sg("send_shortcut", function(binding) return send_input_action("send_shortcut", binding) end)
-- A prediction now, from the text typed so far. The keymap bridge owns the
-- prediction engine, which logs and shows every refusal (paused, AI off,
-- backend not ready, nothing typed). Required at dispatch: the keymap loads
-- after this registry.
sg("llm_generate_prediction", function()
	local ok_keymap, keymap = pcall(require, "modules.keymap")
	if not ok_keymap or type(keymap) ~= "table"
		or type(keymap.request_manual_prediction) ~= "function" then
		Logger.error(LOG, "llm_generate_prediction: the keymap bridge is unavailable: %s.",
			tostring(keymap))
		return false
	end
	return keymap.request_manual_prediction()
end)

--- Runs a prediction now with a chosen prompt profile, through the keymap
--- bridge that owns the prediction engine (loaded after this registry). The
--- engine checks the profile still exists and shows every refusal.
--- @param action string The action id, for the log.
--- @param value string "<profile_id>" or "<profile_id>|<count>".
--- @return boolean True when the request was sent.
local function request_prompt_prediction(action, value)
	local ok_keymap, keymap = pcall(require, "modules.keymap")
	if not ok_keymap or type(keymap) ~= "table"
		or type(keymap.request_prompt_prediction) ~= "function" then
		Logger.error(LOG, "%s: the keymap bridge is unavailable: %s.", action, tostring(keymap))
		return false
	end
	return keymap.request_prompt_prediction(value)
end
-- The prompt and the count are the binding's own parameter, as for wrap_selection.
sg("llm_prompt_prediction", function(binding)
	local value = M.get_action_parameter(binding, "llm_prompt_prediction")
	if not PromptAction.is_valid(value) then
		Logger.warn(LOG, "llm_prompt_prediction ignored for binding '%s': no valid prompt is stored ('%s').",
			tostring(binding), tostring(value))
		return false
	end
	return request_prompt_prediction("llm_prompt_prediction", value)
end)
-- Live mode with the binding's prompt, or off when it is on. The value is
-- handed over even when invalid: a second press of ANY live binding turns live
-- mode off, and the engine refuses an invalid prompt only when turning it on.
sg("llm_live_prompt_toggle", function(binding)
	local value = M.get_action_parameter(binding, "llm_live_prompt_toggle")
	local ok_keymap, keymap = pcall(require, "modules.keymap")
	if not ok_keymap or type(keymap) ~= "table" or type(keymap.toggle_live_prompt) ~= "function" then
		Logger.error(LOG, "llm_live_prompt_toggle: the keymap bridge is unavailable: %s.", tostring(keymap))
		return false
	end
	return keymap.toggle_live_prompt(value)
end)
-- One ready-made action per built-in profile (llm_predict_<id>), with the AI
-- menu's count. Derived from profiles.json, like the catalogue, so a new
-- built-in profile gets its action without a hand-written registration here.
local BUILTIN_PROMPT_PROFILES = ProfileSelector.load_built_in_profiles()
if #BUILTIN_PROMPT_PROFILES == 0 then
	error("gestures/actions: _shared/modules/llm/profiles.json holds no built-in profile — "
		.. "the llm_predict_* actions cannot be registered.")
end
for _, profile in ipairs(BUILTIN_PROMPT_PROFILES) do
	local profile_id = profile.id
	local action = "llm_predict_" .. profile_id
	sg(action, function() return request_prompt_prediction(action, PromptAction.format(profile_id)) end)
end
-- The tone ladder on the selection (llm_tone_*): one registration per
-- direction and end behaviour, through the keymap bridge like the predictions.
local TONE_ACTIONS = {
	{ id = "llm_tone_more_formal", direction = Tone.MORE_FORMAL, cycle = false },
	{ id = "llm_tone_more_familiar", direction = Tone.MORE_FAMILIAR, cycle = false },
	{ id = "llm_tone_more_formal_cycle", direction = Tone.MORE_FORMAL, cycle = true },
	{ id = "llm_tone_more_familiar_cycle", direction = Tone.MORE_FAMILIAR, cycle = true },
}
for _, tone_action in ipairs(TONE_ACTIONS) do
	local spec = tone_action
	sg(spec.id, function()
		local ok_keymap, keymap = pcall(require, "modules.keymap")
		if not ok_keymap or type(keymap) ~= "table" or type(keymap.request_tone_step) ~= "function" then
			Logger.error(LOG, "%s: the keymap bridge is unavailable: %s.", spec.id, tostring(keymap))
			return false
		end
		return keymap.request_tone_step(spec.direction, spec.cycle, current_action_parent())
	end)
end
-- Screen reading (llm_screen_region / llm_screen_full / llm_screen_error): the
-- vision backend is the binding's own parameter, through the keymap bridge like
-- the predictions; the error explanation reads a region with its own answers.
local SCREEN_ANSWER_ACTIONS = {
	{ id = "llm_screen_region", mode = "MODE_REGION", answers = "ANSWERS_SCREEN" },
	{ id = "llm_screen_full", mode = "MODE_FULL", answers = "ANSWERS_SCREEN" },
	{ id = "llm_screen_error", mode = "MODE_REGION", answers = "ANSWERS_ERROR" },
}
for _, screen_action in ipairs(SCREEN_ANSWER_ACTIONS) do
	local spec = screen_action
	sg(spec.id, function(binding)
		local value = M.get_action_parameter(binding, spec.id)
		if not Vision.is_valid(value) then
			Logger.warn(LOG, "%s ignored for binding '%s': no valid vision backend is stored ('%s').",
				spec.id, tostring(binding), tostring(value))
			return false
		end
		local ok_keymap, keymap = pcall(require, "modules.keymap")
		if not ok_keymap or type(keymap) ~= "table" or type(keymap.request_screen_answers) ~= "function" then
			Logger.error(LOG, "%s: the keymap bridge is unavailable: %s.", spec.id, tostring(keymap))
			return false
		end
		local ScreenAnswer = require("modules.llm.screen_answer")
		return keymap.request_screen_answers(value, ScreenAnswer[spec.mode], current_action_parent(),
			ScreenAnswer[spec.answers])
	end)
end
-- Translation of the selection (llm_translate_selection): the target language
-- is the binding's own parameter, through the keymap bridge like the tone steps.
sg("llm_translate_selection", function(binding)
	local value = M.get_action_parameter(binding, "llm_translate_selection")
	if not M.validate_action_parameter("llm_translate_selection", value) then
		Logger.warn(LOG, "llm_translate_selection ignored for binding '%s': no valid language is stored ('%s').",
			tostring(binding), tostring(value))
		return false
	end
	local ok_keymap, keymap = pcall(require, "modules.keymap")
	if not ok_keymap or type(keymap) ~= "table" or type(keymap.request_selection_translation) ~= "function" then
		Logger.error(LOG, "llm_translate_selection: the keymap bridge is unavailable: %s.", tostring(keymap))
		return false
	end
	return keymap.request_selection_translation(value, current_action_parent())
end)
-- The AI agent (llm_agent_selection / llm_agent_command / llm_agent_auto_toggle):
-- its settings are the AI agent menu's, so the bindings carry no parameter; the
-- keymap bridge hands them to modules/llm/agent_runner.lua, which logs and shows
-- every refusal.
local AGENT_ACTIONS = {
	{ id = "llm_agent_selection", bridge = "request_agent_selection", parent = true },
	{ id = "llm_agent_command", bridge = "request_agent_command" },
	{ id = "llm_agent_auto_toggle", bridge = "toggle_agent_auto" },
}
for _, agent_action in ipairs(AGENT_ACTIONS) do
	local spec = agent_action
	sg(spec.id, function()
		local ok_keymap, keymap = pcall(require, "modules.keymap")
		if not ok_keymap or type(keymap) ~= "table" or type(keymap[spec.bridge]) ~= "function" then
			Logger.error(LOG, "%s: the keymap bridge is unavailable: %s.", spec.id, tostring(keymap))
			return false
		end
		if spec.parent then return keymap[spec.bridge](current_action_parent()) end
		return keymap[spec.bridge]()
	end)
end
sg("teleport_mouse", function()
	local ok, Mouse = pcall(require, "modules.shortcuts.actions.system_mouse")
	if ok and type(Mouse.teleport_mouse) == "function" then
		return Mouse.teleport_mouse(current_action_parent())
	end
	return false
end)
sg("spotlight_mouse", function()
	local ok, Mouse = pcall(require, "modules.shortcuts.actions.system_mouse")
	if ok and type(Mouse.spotlight_mouse) == "function" then
		return Mouse.spotlight_mouse(nil, current_action_parent())
	end
	return false
end)
sg("toggle_capslock", function()
	local ok, Sys = pcall(require, "modules.shortcuts.actions.system")
	if ok and type(Sys.toggle_capslock) == "function" then Sys.toggle_capslock() end
end)

--- @param method string Public function of modules.shortcuts.actions.system_mouse.
--- @return function
local function mouse_action(method)
	return owner_action("modules.shortcuts.actions.system_mouse", method)
end

-- Formerly fixed hotkeys only (Ctrl+., Ctrl+P): no gesture or slot could bind them.
sg("open_emoji_picker", mouse_action("open_emoji_picker"))
sg("display_mirror_toggle", mouse_action("toggle_display_mirror"))
-- Formerly fixed hotkeys only (Ctrl+D, Ctrl+E, Ctrl+I, Ctrl+S, Ctrl+X). The
-- app-navigation and pixel owners are parent-scoped like the text and mouse
-- ones, and joined to this module's lifecycle in scoped_action_children().
-- The frontmost window saved to the screenshots folder, under the dispatching
-- parent's screenshot owner: what the key left of 1 ran before it became a tap key.
sg("screen_capture_instant", owner_action("modules.shortcuts.actions.system", "capture_frontmost_window"))
sg("open_downloads", owner_action("modules.shortcuts.actions.apps", "open_downloads"))
sg("open_file_manager", owner_action("modules.shortcuts.actions.apps", "open_finder"))
sg("open_system_settings", owner_action("modules.shortcuts.actions.apps", "open_settings"))
sg("copy_selected_path", owner_action("modules.shortcuts.actions.apps", "copy_or_open_path"))
sg("pick_color", owner_action("modules.shortcuts.actions.system_pixel", "copy_pixel_color"))
-- Keep-awake is one session for the machine, whoever starts it: the shortcut
-- layer owns it (its Bindings lifecycle pauses and resumes it) and it stops by
-- itself at the first physical input, so a gesture leaves nothing that outlives
-- the user's next action.
sg("activity_simulation", function()
	local ok, Sys = pcall(require, "modules.shortcuts.actions.system")
	if not ok or type(Sys.toggle_awake) ~= "function" then
		Logger.error(LOG, "Keep-awake is unavailable: %s.", tostring(Sys))
		return false
	end
	return Sys.toggle_awake()
end)

sg("lock_screen", function()
	local ok, Mouse = pcall(require, "modules.shortcuts.actions.system_mouse")
	if ok and type(Mouse.lock_screen) == "function" then
		return Mouse.lock_screen(current_action_parent())
	end
	return false
end)
sg("notification_center",          function()
	return AuxOwner.applescript(
		"tell application \"System Events\" to click menu bar item \"Notification Center\" of menu bar 1 of application process \"ControlCenter\"",
		"open notification center", nil, current_action_parent())
end)

-- The system actions that run a native command (modules/gestures/system_actions),
-- each under the dispatching parent. The ones the catalogue declares
-- `confirm = true` are asked for by execute_single before they run.
local SYSTEM_ACTIONS = {
	"minimize_all", "quit_frontmost_app", "force_quit_frontmost", "clear_clipboard",
	"center_mouse", "mic_mute_toggle", "sleep_displays", "toggle_dark_mode",
	"empty_trash", "eject_all_disks", "remove_quarantine_selection",
	"make_executable_selection", "open_terminal_here", "new_text_file_here",
}
for _, system_action in ipairs(SYSTEM_ACTIONS) do
	sg(system_action, owner_action("modules.gestures.system_actions", system_action))
end
-- The application is the binding's own parameter, as for open_url.
sg("run_program", function(binding) return M.run_program(binding) end)
sg("open_app", function(binding)
	local value = M.get_action_parameter(binding, "open_app")
	if not M.validate_action_parameter("open_app", value) then
		Logger.warn(LOG, "open_app ignored for binding '%s': no valid application is stored ('%s').",
			tostring(binding), tostring(value))
		return false
	end
	local ok, System = pcall(require, "modules.gestures.system_actions")
	if not ok or type(System) ~= "table" or type(System.open_app) ~= "function" then
		Logger.error(LOG, "open_app is unavailable: %s.", tostring(System))
		return false
	end
	return System.open_app(value, current_action_parent())
end)

-- Applications and Stats
-- These four target the same modules the menu dispatches to (ui/menu/init.lua),
-- which is the reference for the real module names: the metrics overlays were
-- never one "ui.metrics_overlay" module, the hotstring editor is singular, and
-- the paths editor lives behind the menu_paths module rather than a UI module.
sg("open_metrics_typing",            function() invoke_ui("ui.metrics_typing", "show") end)
sg("open_metrics_apps",        function() invoke_ui("ui.metrics_apps", "show") end)
sg("open_hotstrings_editor",    function() invoke_ui("ui.hotstring_editor", "open") end)
sg("open_paths_editor",            function() invoke_ui("ui.menu.menu_paths", "open_editor") end)
sg("open_script_source",               function()
	return AuxOwner.open(hs.configdir, "open script source", nil, current_action_parent())
end)
-- The user's files live in the configuration folder, resolved by
-- infra/config_paths like every other reader. They were opened from
-- hs.configdir, the script folder, which is the application bundle once
-- installed: the actions opened files that do not exist there
-- (hardening-b-installed-layout).
--- Opens one of the user's files through its config_paths key.
--- @param key string config_paths.get key.
--- @param label string Opener label.
--- @return boolean started
local function open_user_file(key, label)
	local path = require("infra.config_paths").get(key)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "%s: the configuration path %s is not resolvable.", label, key)
		return false
	end
	return AuxOwner.open(path, label, nil, current_action_parent())
end
sg("open_personal_shortcuts",     function()
	return open_user_file("PersonalShortcutsLuaPath", "open personal shortcuts")
end)
sg("open_personal_hotstrings",    function()
	return open_user_file("PersonalTomlPath", "open personal hotstrings")
end)
sg("open_personal_info",               function()
	return open_user_file("PersonalInfoTomlPath", "open personal info")
end)
sg("open_config",                    function()
	return open_user_file("ConfigTomlPath", "open config")
end)
-- The three log actions share the Debug menu's owner (ui/log_openers), which
-- asks the logger for each path at the moment of the gesture; only the
-- asynchronous opener, owned here by the gesture scope, differs.
--- @param label string Opener label shown in the owner's diagnostics.
--- @return function open_fn
local function gesture_opener(label)
	local parent = current_action_parent()
	return function(target) return AuxOwner.open(target, label, nil, parent) end
end
sg("open_logs_folder",                function()
	return require("ui.log_openers").open_logs_folder(gesture_opener("open logs folder"))
end)
sg("open_today_log",                   function()
	return require("ui.log_openers").open_today_log(gesture_opener("open today's log"))
end)
sg("open_error_log",                   function()
	return require("ui.log_openers").open_today_errors(gesture_opener("open error log"))
end)

-- Parameterized actions read their value from the binding that invoked them.
-- They intentionally do not use a global fallback: every gesture/shortcut keeps
-- the exact URL selected by the user in its own configuration entry.
sg("open_url", function(binding)
	local url = M.get_action_parameter(binding, "open_url")
	if M.validate_action_parameter("open_url", url) then open_url(url) end
end)
-- Clipboard capture state for search_web. Declared above the closure that reads
-- it: a local declared below one binds a nil global instead, and the failure
-- surfaces only inside a timer callback where the file logger never sees it.
local _search_capture_in_flight = false
local _search_parent = nil
local _search_saved_clipboard = nil
local _search_capture_generation = 0
local _search_recovery_only = false
local _search_capture_authorized = false
local _search_capture_timer = nil
local _search_restore_retry_timer = nil
local _search_capture_timer_parent = nil
local _search_restore_retry_timer_parent = nil
local _search_deferred_retry_armed = false
local _search_mutation_depth = 0
local _search_cleanup_requested = false

local function search_capture_is_current(parent, generation)
	return _search_capture_in_flight == true
		and _search_parent == parent
		and _search_capture_authorized == true
		and _search_capture_generation == generation
		and aux_admission_open(parent)
end

--- Returns the exact timer currently owned by one search slot.
--- @param slot string `capture` or `restore`.
--- @return table|userdata|nil handle
local function get_search_timer(slot)
	return slot == "capture" and _search_capture_timer or _search_restore_retry_timer
end

local function get_search_timer_parent(slot)
	return slot == "capture"
		and _search_capture_timer_parent or _search_restore_retry_timer_parent
end

--- Publishes one exact timer into its search slot.
--- @param slot string `capture` or `restore`.
--- @param handle table|userdata|nil Native timer handle.
local function set_search_timer(slot, handle, parent)
	if slot == "capture" then
		_search_capture_timer = handle
		_search_capture_timer_parent = handle and parent or nil
	else
		_search_restore_retry_timer = handle
		_search_restore_retry_timer_parent = handle and parent or nil
	end
end

--- Stops one exact timer without clearing a refused cleanup capability.
--- @param slot string `capture` or `restore`.
--- @return boolean settled
local function stop_search_timer(slot, parent)
	local handle = get_search_timer(slot)
	if handle == nil then return true end
	if parent ~= nil and get_search_timer_parent(slot) ~= parent then return true end
	local ok_method, stop_method = pcall(function() return handle.stop end)
	if not ok_method or type(stop_method) ~= "function" then
		Logger.error(LOG, "search_web %s timer has no readable stop method.", slot)
		return false
	end
	local ok_stop, stop_result = xpcall(function()
		return stop_method(handle)
	end, debug.traceback)
	if not ok_stop or stop_result == nil or stop_result == false then
		Logger.error(LOG, "search_web %s timer stop refused; exact handle retained: %s.",
			slot, tostring(stop_result))
		return false
	end
	if get_search_timer(slot) == handle then set_search_timer(slot, nil, nil) end
	return true
end

local function release_search_clipboard(generation)
	if generation ~= _search_capture_generation then return end
	local parent = _search_parent
	local capture_stopped = stop_search_timer("capture", parent)
	local restore_stopped = stop_search_timer("restore", parent)
	if not capture_stopped or not restore_stopped then
		return false, "search timer cleanup pending"
	end
	_search_capture_in_flight = false
	_search_parent = nil
	_search_saved_clipboard = nil
	_search_recovery_only = false
	_search_capture_authorized = false
	_search_deferred_retry_armed = false
	_search_cleanup_requested = false
	_search_capture_generation = _search_capture_generation + 1
	return true
end

local function restore_search_clipboard(generation)
	if generation ~= _search_capture_generation or not _search_capture_in_flight then
		return false, "stale search generation"
	end
	local saved = _search_saved_clipboard
	local ok_restore, restore_result
	_search_mutation_depth = _search_mutation_depth + 1
	if type(saved) == "table" and next(saved) ~= nil then
		ok_restore, restore_result = pcall(hs.pasteboard.writeAllData, saved)
	else
		ok_restore, restore_result = pcall(hs.pasteboard.clearContents)
	end
	_search_mutation_depth = _search_mutation_depth - 1
	if not ok_restore or restore_result ~= true then
		return false, ok_restore and "clipboard restore returned " .. tostring(restore_result)
			or restore_result
	end
	local released, release_error = release_search_clipboard(generation)
	if released ~= true then return false, release_error end
	return true, nil
end

local function arm_search_timer(slot, delay, label, generation, parent, callback)
	if stop_search_timer(slot, parent) ~= true then
		return false, "predecessor timer cleanup pending"
	end
	local handle = nil
	local installing = true
	local callback_ran = false
	local ok_timer, timer_or_error = pcall(hs.timer.doAfter, delay, function()
		callback_ran = true
		if installing then return end
		if get_search_timer(slot) ~= handle then return end
		if get_search_timer_parent(slot) ~= parent then return end
		-- Delivery is exact terminal proof for this one-shot even after the
		-- logical search generation has been revoked. Retire the native slot
		-- before applying the business fence so a later PAUSE retry does not
		-- signal an already-terminal handle again.
		set_search_timer(slot, nil, nil)
		if generation ~= _search_capture_generation then return end
		if slot == "capture" and not search_capture_is_current(parent, generation) then return end
		local ok_callback, callback_error = xpcall(callback, debug.traceback)
		if not ok_callback then
			Logger.error(LOG, "search_web %s callback failed: %s.", label, tostring(callback_error))
			_search_recovery_only = true
		end
	end)
	installing = false
	handle = ok_timer and timer_or_error or nil
	if handle ~= nil and handle ~= false then set_search_timer(slot, handle, parent) end
	if not ok_timer or timer_or_error == nil or timer_or_error == false or callback_ran then
		stop_search_timer(slot, parent)
		return false, ok_timer and (callback_ran and "timer fired during installation"
			or "hs.timer.doAfter returned no handle") or timer_or_error
	end
	if slot == "capture" and not search_capture_is_current(parent, generation) then
		stop_search_timer(slot, parent)
		return false, "search capture superseded during timer acquisition"
	end
	return true
end

local queue_search_restore_retry
queue_search_restore_retry = function(generation)
	if _search_restore_retry_timer or _search_deferred_retry_armed then return true end
	local function attempt_restore()
			local restored, restore_error = restore_search_clipboard(generation)
			if restored or generation ~= _search_capture_generation then return end
			_search_recovery_only = true
			Logger.error(LOG, "search_web clipboard restore retry refused: %s.",
				tostring(restore_error))
			queue_search_restore_retry(generation)
	end
	local timer_armed, timer_error = arm_search_timer(
		"restore", CLIPBOARD_COPY_SETTLE_SEC, "restore retry", generation,
		_search_parent, attempt_restore)
	if timer_armed then
		return true
	end
	if type(SyntheticInput.defer_after_callback) == "function" then
		local installing = true
		local callback_ran = false
		local ok_defer, deferred = pcall(SyntheticInput.defer_after_callback,
			"search_web clipboard restore recovery", function()
				callback_ran = true
				if installing then return end
				_search_deferred_retry_armed = false
				local ok_callback, callback_error = xpcall(attempt_restore, debug.traceback)
				if not ok_callback then
					Logger.error(LOG, "search_web deferred restore callback failed: %s.",
						tostring(callback_error))
				end
			end)
		installing = false
		if ok_defer and deferred == true and not callback_ran then
			_search_deferred_retry_armed = true
			return true
		end
	end
	Logger.error(LOG, "search_web clipboard restore retry could not be armed: %s.",
		tostring(timer_error))
	return false
end

local function retain_search_restore_failure(generation, context, restore_error)
	_search_recovery_only = true
	queue_search_restore_retry(generation)
	Logger.error(LOG, "search_web %s; clipboard owner retained: %s.",
		context, tostring(restore_error))
end

local function cleanup_search_capture(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or GESTURE_ACTION_PARENT
	if not _search_capture_in_flight or _search_parent ~= scope_id then
		local capture_stopped = stop_search_timer("capture", scope_id)
		local restore_stopped = stop_search_timer("restore", scope_id)
		return capture_stopped == true and restore_stopped == true
	end
	-- Fence browser publication before crossing fallible timer/clipboard cleanup.
	-- A refused native stop may still deliver its callback, but it can no longer
	-- restore/open anything after the gesture lifecycle has been revoked.
	_search_capture_authorized = false
	if _search_mutation_depth > 0 then
		_search_cleanup_requested = true
		Logger.error(LOG,
			"search_web cleanup deferred until the active clipboard boundary returns.")
		return false
	end
	local generation = _search_capture_generation
	local restored, restore_error = restore_search_clipboard(generation)
	if restored then return true end
	_search_recovery_only = true
	queue_search_restore_retry(generation)
	Logger.error(LOG, "search_web cleanup refused; clipboard owner retained: %s.",
		tostring(restore_error))
	return false
end

sg("search_web", function(binding)
	local template = M.get_action_parameter(binding, "search_web")
	if not M.validate_action_parameter("search_web", template) then return end
	local parent = current_action_parent()
	if _search_capture_in_flight then
		if _search_parent ~= parent then
			Logger.debug(LOG,
				"search_web refused while sibling parent '%s' owns clipboard recovery.",
				tostring(_search_parent))
			return false
		end
		if _search_recovery_only then
			local recovered, recovery_error = restore_search_clipboard(_search_capture_generation)
			if not recovered then
				queue_search_restore_retry(_search_capture_generation)
				Logger.error(LOG, "search_web refused while clipboard recovery is pending: %s.",
					tostring(recovery_error))
				return
			end
		else
			Logger.debug(LOG, "search_web ignored while another capture owns the clipboard.")
			return
		end
	end
	-- Capture the user's clipboard ONLY when no capture is already in flight.
	-- Two search_web gestures in quick succession made the second snapshot what
	-- the FIRST had just copied — the selection, not the user's clipboard — and
	-- then dutifully "restored" it, so the real clipboard was gone for good. The
	-- same stale-snapshot class the text-transform path was hardened against.
	local ok_snapshot, snapshot_or_error = pcall(hs.pasteboard.readAllData)
	if not ok_snapshot or type(snapshot_or_error) ~= "table" then
		Logger.error(LOG, "search_web clipboard snapshot failed: %s.", tostring(snapshot_or_error))
		return
	end
	if not aux_admission_open(parent) then return false end
	_search_saved_clipboard = snapshot_or_error
	_search_capture_in_flight = true
	_search_parent = parent
	_search_capture_authorized = true
	_search_cleanup_requested = false
	_search_capture_generation = _search_capture_generation + 1
	local my_generation = _search_capture_generation
	_search_mutation_depth = _search_mutation_depth + 1
	local ok_clear, clear_error = pcall(hs.pasteboard.clearContents)
	_search_mutation_depth = _search_mutation_depth - 1
	if not ok_clear or clear_error ~= true then
		local restored, restore_error = restore_search_clipboard(my_generation)
		if not restored then
			_search_recovery_only = true
			queue_search_restore_retry(my_generation)
		end
		Logger.error(LOG, "search_web clipboard clear failed: %s.", tostring(clear_error))
		return
	end
	if _search_cleanup_requested or not search_capture_is_current(parent, my_generation) then
		if _search_capture_in_flight and _search_parent == parent
			and _search_capture_generation == my_generation then
			_search_capture_authorized = false
			local restored, restore_error = restore_search_clipboard(my_generation)
			if not restored then
				retain_search_restore_failure(my_generation,
					"superseded after clipboard clear", restore_error)
			end
		end
		return false
	end
	local timer_armed, timer_error = arm_search_timer(
		"capture", CLIPBOARD_COPY_SETTLE_SEC, "capture", my_generation, parent, function()
		if not search_capture_is_current(parent, my_generation) then return end
		local ok_selected, selected = pcall(hs.pasteboard.getContents)
		local restored, restore_error = restore_search_clipboard(my_generation)
		if not restored then
			_search_recovery_only = true
			Logger.error(LOG, "search_web clipboard restore refused; ownership retained: %s.",
				tostring(restore_error))
			queue_search_restore_retry(my_generation)
		end
		if not ok_selected or type(selected) ~= "string" or selected == "" then
			Logger.error(LOG, "search_web selection copy produced no text: %s.", tostring(selected))
			return
		end
		if not aux_admission_open(parent) then return end
		-- url_encode_query returns percent-escapes, and this value lands on the
		-- REPLACEMENT side of gsub where "%2" reads as capture reference #2. Any
		-- selection containing a space encodes to "%20" and raised "invalid capture
		-- index %2" — inside an hs.timer callback, so the error went to the HS
		-- Console and never to the file logger, and the search silently never opened.
		open_url((template:gsub("%%s", text_utils.escape_gsub_replacement(url_encode_query(selected)))))
	end)
	if not timer_armed then
		local restore_error = "capture superseded before timer commit"
		-- A lifecycle cleanup may have fully restored/released this generation
		-- while hs.timer.doAfter() was still on-stack. Do not publish a stale
		-- recovery timer after that cleanup has already certified settlement.
		if _search_capture_in_flight and _search_parent == parent
			and _search_capture_generation == my_generation then
			local restored
			restored, restore_error = restore_search_clipboard(my_generation)
			if not restored then
				_search_recovery_only = true
				queue_search_restore_retry(my_generation)
			end
		end
		Logger.error(LOG, "search_web capture timer was refused: %s (restore=%s).",
			tostring(timer_error), tostring(restore_error))
		return
	end
	if not search_capture_is_current(parent, my_generation) then
		stop_search_timer("capture", parent)
		if _search_capture_in_flight and _search_parent == parent
			and _search_capture_generation == my_generation then
			_search_capture_authorized = false
			local restored, restore_error = restore_search_clipboard(my_generation)
			if not restored then
				retain_search_restore_failure(my_generation,
					"superseded after capture timer acquisition", restore_error)
			end
		end
		return false
	end
	_search_mutation_depth = _search_mutation_depth + 1
	local ok_copy, copied = pcall(
		SyntheticInput.emit_key_stroke, { "cmd" }, "c", KEYSTROKE_NO_DELAY_US)
	_search_mutation_depth = _search_mutation_depth - 1
	if not ok_copy or copied ~= true
		or _search_cleanup_requested
		or not search_capture_is_current(parent, my_generation) then
		_search_capture_authorized = false
		stop_search_timer("capture", parent)
		local restored, restore_error = restore_search_clipboard(my_generation)
		if not restored then
			_search_recovery_only = true
			queue_search_restore_retry(my_generation)
		end
		Logger.error(LOG, "search_web copy shortcut was refused: %s (restore=%s).",
			tostring(copied), tostring(restore_error))
		return false
	end
	return true
end)

--- Builds the exact lifecycle inventory shared by both action parents.
--- @return table|nil children
local function scoped_action_children()
	local text_ok, Text = pcall(require, "modules.shortcuts.actions.text")
	local mouse_ok, Mouse = pcall(require, "modules.shortcuts.actions.system_mouse")
	local apps_ok, Apps = pcall(require, "modules.shortcuts.actions.apps")
	local pixel_ok, Pixel = pcall(require, "modules.shortcuts.actions.system_pixel")
	if not text_ok or type(Text) ~= "table"
		or not mouse_ok or type(Mouse) ~= "table"
		or not apps_ok or type(Apps) ~= "table"
		or not pixel_ok or type(Pixel) ~= "table" then
		Logger.error(LOG, "Shared action lifecycle modules could not be loaded: %s / %s / %s / %s.",
			tostring(Text), tostring(Mouse), tostring(Apps), tostring(Pixel))
		return nil
	end
	return {
		{id = "native_switcher", subject = require("modules.gestures.native_app_switcher_action"),
			pause = "pause", resume = "resume", query = "is_paused", pending = "has_pending"},
		{id = "auxiliary", subject = AuxOwner,
			pause = "pause", resume = "resume", query = "is_paused",
			pending = "has_pending"},
		{id = "text", subject = Text,
			pause = "pause_text_actions", resume = "resume_text_actions",
			query = "is_text_actions_paused", pending = "has_pending_text_action"},
		{id = "mouse", subject = Mouse,
			pause = "pause_mouse_actions", resume = "resume_mouse_actions",
			query = "is_mouse_actions_paused", pending = "has_pending_mouse_action"},
		{id = "apps", subject = Apps,
			pause = "pause_apps_actions", resume = "resume_apps_actions",
			query = "is_apps_actions_paused", pending = "has_pending_apps_action"},
		{id = "pixel", subject = Pixel,
			pause = "pause_pixel_actions", resume = "resume_pixel_actions",
			query = "is_pixel_actions_paused", pending = "has_pending_pixel_action"},
		{id = "screenshot", subject = ScreenshotSave,
			pause = "pause_screenshot_actions", resume = "resume_screenshot_actions",
			query = "has_screenshot_pause_claim",
			pending = "has_pending_screenshot_action"},
	}
end

--- Invokes one scoped child lifecycle edge with an exact literal-true contract.
--- @param child table Lifecycle descriptor.
--- @param edge string `pause` or `resume`.
--- @param parent string Stable action parent.
--- @return boolean settled
local function call_scoped_child(child, edge, parent)
	local fn = child.subject and child.subject[child[edge]]
	if type(fn) ~= "function" then return false end
	local ok, result = xpcall(fn, debug.traceback, parent)
	if not ok or result ~= true then
		Logger.error(LOG, "%s %s did not settle for '%s': %s.",
			child.id, edge, parent, tostring(result))
		return false
	end
	return true
end

--- Reads one scoped child pause state without normalizing nil or throws.
--- @param child table Lifecycle descriptor.
--- @param parent string Stable action parent.
--- @return boolean readable
--- @return boolean|nil paused
local function scoped_child_is_paused(child, parent)
	local fn = child.subject and child.subject[child.query]
	if type(fn) ~= "function" then return false, nil end
	local ok, paused = xpcall(fn, debug.traceback, parent)
	if not ok or type(paused) ~= "boolean" then return false, nil end
	return true, paused
end

--- Reads one scoped child pending state without normalizing ambiguity.
--- @param child table Lifecycle descriptor.
--- @param parent string Stable action parent.
--- @return boolean readable
--- @return boolean|nil pending
local function scoped_child_has_pending(child, parent)
	local fn = child.subject and child.subject[child.pending]
	if type(fn) ~= "function" then return false, nil end
	local ok, pending = xpcall(fn, debug.traceback, parent)
	if not ok or type(pending) ~= "boolean" then return false, nil end
	return true, pending
end

M.force_cleanup = function(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or GESTURE_ACTION_PARENT
	-- Close the aggregate before the first fallible child cleanup. This also
	-- invalidates an outer resume if cleanup is entered synchronously by a child.
	fence_action_scope(scope_id)
	local children = scoped_action_children()
	local click_ok, click_result = xpcall(
		Click.force_cleanup, debug.traceback, scope_id)
	local search_ok, search_result = xpcall(
		cleanup_search_capture, debug.traceback, scope_id)
	local sticky_ok, sticky_result = xpcall(Sticky.clear, debug.traceback, scope_id)
	local lookup_ok, lookup_result = xpcall(
		cleanup_lookup_operation, debug.traceback, scope_id)
	local children_settled = children ~= nil
	for _, child in ipairs(children or {}) do
		local paused_result = call_scoped_child(child, "pause", scope_id)
		local readable, paused = scoped_child_is_paused(child, scope_id)
		local pending_readable, pending = scoped_child_has_pending(child, scope_id)
		if paused_result ~= true
			or readable ~= true or paused ~= true
			or pending_readable ~= true or pending ~= false then
			children_settled = false
		end
	end
	if not click_ok then Logger.error(LOG, "Click cleanup raised: %s.", tostring(click_result)) end
	if not search_ok then Logger.error(LOG, "Search cleanup raised: %s.", tostring(search_result)) end
	if not sticky_ok then Logger.error(LOG, "Sticky cleanup raised: %s.", tostring(sticky_result)) end
	if not lookup_ok then Logger.error(LOG, "Lookup cleanup raised: %s.", tostring(lookup_result)) end
	return click_ok and click_result == true
		and search_ok and search_result == true
		and sticky_ok and sticky_result == true
		and lookup_ok and lookup_result == true
		and children_settled == true
end

function M.resume_after_cleanup(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or GESTURE_ACTION_PARENT
	if M.force_cleanup(scope_id) ~= true then return false end
	local children = scoped_action_children()
	if not children then return false end
	local lifecycle = action_scope_lifecycle(scope_id)
	lifecycle.epoch = lifecycle.epoch + 1
	local attempt = { epoch = lifecycle.epoch }
	lifecycle.transition = attempt
	lifecycle.admission_open = false
	local attempted = {}
	local function rollback_resume()
		-- Retire our identity before rollback callbacks run so a synchronous
		-- dispatch from cleanup observes the closed composite fence as well.
		if lifecycle.transition == attempt then
			lifecycle.transition = nil
			lifecycle.admission_open = false
			lifecycle.epoch = lifecycle.epoch + 1
		end
		for index = #attempted, 1, -1 do
			call_scoped_child(attempted[index], "pause", scope_id)
		end
		return false
	end
	for _, child in ipairs(children) do
		attempted[#attempted + 1] = child
		if not action_resume_is_current(lifecycle, attempt) then
			return rollback_resume()
		end
		local resumed = call_scoped_child(child, "resume", scope_id)
		if not action_resume_is_current(lifecycle, attempt) then
			return rollback_resume()
		end
		local readable, paused = scoped_child_is_paused(child, scope_id)
		if not action_resume_is_current(lifecycle, attempt) then
			return rollback_resume()
		end
		local pending_readable, pending = scoped_child_has_pending(child, scope_id)
		if resumed ~= true or readable ~= true or paused ~= false
			or pending_readable ~= true or pending ~= false
			or not action_resume_is_current(lifecycle, attempt) then
			return rollback_resume()
		end
	end
	for _, child in ipairs(children) do
		local readable, paused = scoped_child_is_paused(child, scope_id)
		if not action_resume_is_current(lifecycle, attempt) then
			return rollback_resume()
		end
		local pending_readable, pending = scoped_child_has_pending(child, scope_id)
		if readable ~= true or paused ~= false
			or pending_readable ~= true or pending ~= false
			or not action_resume_is_current(lifecycle, attempt) then
			return rollback_resume()
		end
	end
	if not action_resume_is_current(lifecycle, attempt) then
		return rollback_resume()
	end
	lifecycle.transition = nil
	lifecycle.admission_open = true
	return true
end

-- Script management
sg("script_pause_toggle",     function()
	local ok, sc = pcall(require, "modules.shortcuts.script_control")
	if ok and type(sc.toggle) == "function" then pcall(sc.toggle) end
end)
sg("script_reload",                       function() pcall(hs.reload) end)
sg("script_save_reload",      function()
	if not aux_admission_open() then return false end
	local acquired, prepared, timer_token = xpcall(function()
		return AuxOwner.prepare_after(0.3, "script save reload", function()
			pcall(hs.reload)
		end, current_action_parent())
	end, debug.traceback)
	if not acquired or prepared ~= true or type(timer_token) ~= "table" then
		Logger.error(LOG, "Script save/reload timer acquisition failed: %s.",
			tostring(prepared))
		return false
	end

	local post_ok, post_result = xpcall(function()
		return postKeyStroke({"cmd"}, "s")
	end, debug.traceback)
	if not post_ok or post_result ~= true or not aux_admission_open() then
		rollback_aux_timer(timer_token, "Script save/reload")
		Logger.error(LOG, "Script save/reload save dispatch failed: %s.",
			tostring(post_result))
		return false
	end

	local commit_ok, committed = xpcall(AuxOwner.commit_after, debug.traceback, timer_token)
	if not commit_ok or committed ~= true then
		rollback_aux_timer(timer_token, "Script save/reload")
		Logger.error(LOG, "Script save/reload timer commit failed: %s.", tostring(committed))
		return false
	end
	return true
end)
sg("script_quit",                         function()
	pcall(function() hs.closeConsole() end)
	-- Leave the gesture/eventtap stack before starting the lifecycle transaction.
	-- The coordinator keeps every F17 consumer and classifier live until the exact
	-- token reports STOPPED, then the root teardown owns keylogger/MLX/helpers and
	-- finally calls os.exit. Shared stock/personal Karabiner remains untouched.
	local exit_requested = false
	local function request_controlled_exit()
		if exit_requested then return end
		exit_requested = true
		-- request_user_exit arms the bounded quit watchdog shared with menubar Quit
		local request_ok, accepted_or_err = xpcall(function()
			return TerminationCoordinator.request_user_exit("script_quit")
		end, debug.traceback)
		if not request_ok or accepted_or_err ~= true then
			Logger.error(LOG, "script_quit controlled exit was rejected: %s",
				tostring(accepted_or_err))
		end
	end
	local scheduled, schedule_result = pcall(function()
		return hs.timer.doAfter(0, request_controlled_exit)
	end)
	if not scheduled or schedule_result == nil or schedule_result == false then
		Logger.error(LOG, "script_quit could not schedule controlled exit: %s", tostring(schedule_result))
		-- request_exit starts the asynchronous root transaction; invoking it here
		-- never bypasses the exact lease fence or performs a direct process exit.
		request_controlled_exit()
	end
end)

-- Debug
sg("open_console",                        function() return require("ui.console_window").open() end)





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

-- Hard-coded action labels — same in every locale (symbols + universal terms).
-- app_expose and mission_control are intentionally absent: they vary by language
-- and are served from the locale JSON.
-- The 132-entry hardcoded English LABELS table stood here, as a last-resort
-- fallback "so new locales never show raw keys". Every one of its entries had
-- a locale key, so it was unreachable — a second copy of the translations, free
-- to drift from the real ones with no symptom, because unreachable code shows
-- none. Deleted; the premise it rested on is now a gate:
-- tools/test/test-action-labels-have-locale-keys.cjs fails if any registered
-- action lacks a label key in any of the 21 locales.

local _modifier_chords_json = Paths.shared("modules/actions/modifier_chords.json")

-- The macOS action catalogue, generated from _shared/modules/actions/actions.toml
-- by tools/codegen/codegen-action-catalogue.cjs and already filtered to this
-- platform: picker order, heading levels and locale keys, per-action metadata
-- and the Karabiner aliases. It replaces a hand-written line reader that only
-- understood `key = "string"` and stored anything else as a raw string without
-- an error. Missing is a broken install, not an empty picker.
local ok_catalogue, Catalogue = pcall(require, "_generated.action_catalogue")
if not ok_catalogue or type(Catalogue) ~= "table" or type(Catalogue.actions) ~= "table"
	or type(Catalogue.sg_items) ~= "table" or type(Catalogue.ax_items) ~= "table" then
	error("gestures/actions: _generated/action_catalogue.lua is missing or invalid — "
		.. "the action picker would be empty. Run `npm run gen`: " .. tostring(Catalogue))
end

--- Karabiner ids that name an action the catalogue already carries under another
--- name, as { karabiner_id = shared_id }. The remap picker is indexed on
--- Karabiner ids, so it resolves a label through this rather than carrying a
--- second copy of the same translated string in twenty-one locale files.
--- @return table A copy, so a caller cannot edit the catalogue.
function M.karabiner_aliases()
	local out = {}
	for alias, target in pairs(Catalogue.karabiner_aliases or {}) do out[alias] = target end
	return out
end

local function parameter_key(binding, action)
	return tostring(binding or "") .. "__" .. tostring(action or "")
end

--- Split only on a recognised parameterized-action suffix. A binding itself
--- may contain ``__`` (for example keyboard__cmd_k), so splitting at the
--- first delimiter would restore the parameter under the wrong binding.
function M.split_action_parameter_key(key)
	if type(key) ~= "string" then return nil, nil end
	for action, meta in pairs(Catalogue.actions) do
		if type(meta.parameter) == "string" then
			local suffix = "__" .. action
			if key:sub(-#suffix) == suffix then return key:sub(1, #key - #suffix), action end
		end
	end
	return nil, nil
end

--- Judges the bare gesture domain only after its actual owner has published
--- both slot catalogues. Other owners and unavailable catalogues remain unjudged.
--- @param binding any Native binding id.
--- @return boolean|nil fits
function M.action_parameter_binding_fits(binding)
	if type(binding) == "string" and binding:sub(1, 10) == "keyboard__" then
		local catalogue = KeyboardPublication.current(rawget(package.loaded, "modules.shortcuts.keyboard_shortcuts"))
		return BindingIdentity.keyboard_binding_fits(binding, catalogue), BindingIdentity.RETIRED_KEYBOARD
	end
	if type(binding) == "string" and binding:sub(1, 9) == "tap_key__" then
		local taps = rawget(package.loaded, "modules.shortcuts.tap_keys")
		local catalogue = BindingPublication.current("tap", "modules.shortcuts.tap_keys", taps)
		return BindingIdentity.tap_binding_fits(binding, catalogue), BindingIdentity.RETIRED_TAP
	end
	if type(binding) == "string" and binding:sub(1, 8) == "script__" then
		local catalogue = BindingPublication.current("script", "infra.script_chord_catalogue", ChordCatalogue)
		return BindingIdentity.script_binding_fits(binding, catalogue), BindingIdentity.RETIRED_SCRIPT
	end
	local gestures = package.loaded["modules.gestures"]
	if type(gestures) ~= "table" or type(gestures.gesture_slot_catalogue) ~= "function" then return nil end
	return BindingIdentity.gesture_binding_fits(binding, gestures.gesture_slot_catalogue())
end

function M.get_action_parameter_spec(action)
	local meta = Catalogue.actions[action]
	return meta and meta.parameter or nil
end

--- The built-in wrap pairs in catalogue order, from the text module that loads
--- _shared/modules/wrap_symbols/wrap_symbols.json.
--- @return table Array of { left, right }.
local function wrap_pair_list()
	local ok, Text = pcall(require, "modules.shortcuts.actions.text")
	if not ok or type(Text) ~= "table" or type(Text.wrap_pair_list) ~= "function" then
		Logger.error(LOG, "The wrap-pair catalogue is unavailable: %s.", tostring(Text))
		return {}
	end
	return Text.wrap_pair_list()
end

--- The left and right symbols a wrap_selection parameter names.
--- @param value any The stored parameter.
--- @return string|nil left
--- @return string|nil right Both nil when the value names no pair.
function M.wrap_pair_for(value)
	return WrapPair.parse(value, wrap_pair_list())
end

-- The vocabulary of the send_* parameters, read on first use.
local SEND_KEYS_PATH = Paths.shared("modules/actions/send_keys.json")
local _send_vocabulary = nil

--- The decoded _shared/modules/actions/send_keys.json. A missing or malformed
--- file raises: every send_* binding would otherwise refuse its value with no
--- explanation.
--- @return table
function M.send_vocabulary()
	if _send_vocabulary then return _send_vocabulary end
	local raw = FileSystem.read(SEND_KEYS_PATH)
	local decoded = raw and JsonCodec.decode(raw) or nil
	if type(decoded) ~= "table" or type(decoded.keys) ~= "table"
		or type(decoded.modifiers) ~= "table" or type(decoded.text_max_code_points) ~= "number" then
		error("gestures/actions: the send-input vocabulary is unreadable at " .. tostring(SEND_KEYS_PATH))
	end
	_send_vocabulary = decoded
	return decoded
end

--- Replaces the {1} of a localized template on plain indices: the detail may
--- hold a % that gsub would read as a capture reference.
--- @param template string
--- @param detail string
--- @return string
local function fill_placeholder(template, detail)
	local at = template:find("{1}", 1, true)
	if not at then return template .. "\n" .. detail end
	return template:sub(1, at - 1) .. detail .. template:sub(at + 3)
end

function M.validate_action_parameter(action, value)
	local spec = M.get_action_parameter_spec(action)
	if not spec then return true end
	if spec == "wrap_pair" then return (M.wrap_pair_for(value)) ~= nil end
	-- Syntax only: whether the profile still exists is checked when the action runs,
	-- so deleting a custom prompt does not wipe the bindings that name it
	if spec == "llm_prompt" then return PromptAction.is_valid(value) end
	-- Syntax only too: whether the provider exists is checked when the action runs
	if spec == "llm_vision" then return Vision.is_valid(value) end
	if spec == "llm_language" then return require("modules.llm.selection_translation").is_valid(value) end
	-- Syntax only: whether the application is installed is checked when it opens
	if spec == "app" then return AppParameter.is_valid(value) end
	if spec == "program" then return ProgramParameter.parse(value, "hs") ~= nil end
	if SendInput.KINDS[spec] then return SendInput.parse(spec, value, M.send_vocabulary()) ~= nil end
	if type(value) ~= "string" or not value:match("^https?://%S+$") then return false end
	if spec == "search_url" then
		local _, placeholders = value:gsub("%%s", "")
		return placeholders == 1
	end
	if spec == "url" then return true end
	error("gestures/actions: no validator for parameter kind '" .. tostring(spec) .. "'.")
end

--- The text a binding editor shows to ask for an action's parameter. The
--- search-URL prompt holds a LITERAL %s the user has to type, so no text here
--- goes through string.format; {1} is replaced by plain indices for the same
--- reason.
--- @param action string Action id with a parameter.
--- @return string
function M.parameter_prompt(action)
	local spec = M.get_action_parameter_spec(action)
	if spec == "search_url" then return i18n.get("dialog.gestures.param_search_url") end
	if spec == "url" then return i18n.get("dialog.gestures.param_link") end
	if spec == "app" then return i18n.get("dialog.gestures.param_app") end
	if spec == "program" then return i18n.get("dialog.gestures.param_program") end
	if spec == "text" then
		return fill_placeholder(i18n.get("dialog.gestures.param_text"),
			tostring(M.send_vocabulary().text_max_code_points))
	end
	if spec == "key" or spec == "shortcut" then
		return fill_placeholder(i18n.get("dialog.gestures.param_" .. spec),
			SendInput.describe_keys(M.send_vocabulary()))
	end
	if spec == "llm_prompt" then
		local lines = {}
		for _, choice in ipairs(M.llm_prompt_choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_prompt"), table.concat(lines, "\n"))
	end
	if spec == "llm_vision" then
		local lines = {}
		for _, choice in ipairs(M.llm_vision_choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_vision"), table.concat(lines, "\n"))
	end
	if spec == "llm_language" then
		local lines = {}
		for _, choice in ipairs(M.llm_language_choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_language"), table.concat(lines, "\n"))
	end
	if spec == "wrap_pair" then
		local template = i18n.get("dialog.gestures.param_wrap_pair")
		local samples = WrapPair.describe(wrap_pair_list())
		local at = template:find("{1}", 1, true)
		if not at then return template .. "\n" .. samples end
		return template:sub(1, at - 1) .. samples .. template:sub(at + 3)
	end
	error("gestures/actions: no prompt for parameter kind '" .. tostring(spec) .. "'.")
end

--- The text shown when a typed parameter is refused.
--- @param action string Action id with a parameter.
--- @return string
function M.parameter_error(action)
	local spec = M.get_action_parameter_spec(action)
	if spec == "wrap_pair" then return i18n.get("dialog.gestures.param_err_wrap_pair") end
	if spec == "llm_prompt" then return i18n.get("dialog.gestures.param_err_llm_prompt") end
	if spec == "llm_vision" then return i18n.get("dialog.gestures.param_err_llm_vision") end
	if spec == "llm_language" then return i18n.get("dialog.gestures.param_err_llm_language") end
	if spec == "app" then return i18n.get("dialog.gestures.param_err_app") end
	if spec == "program" then return i18n.get("dialog.gestures.param_err_program") end
	if SendInput.KINDS[spec] then
		return fill_placeholder(i18n.get("dialog.gestures.param_err_" .. spec),
			tostring(M.send_vocabulary().text_max_code_points))
	end
	if spec == "search_url" then
		return i18n.get("dialog.gestures.param_err_url") .. " "
			.. i18n.get("dialog.gestures.param_err_many_placeholders")
	end
	return i18n.get("dialog.gestures.param_err_url")
end

--- The AI menu's current prediction count: what a prompt binding without a
--- count of its own requests.
--- @return number count
function M.llm_prompt_default_count()
	local Engine = require("modules.llm.prediction_engine")
	local found, count = Engine.get_llm_runtime_setting("llm_num_predictions")
	if found ~= true or type(count) ~= "number" then
		error("gestures/actions: the prediction engine has no prediction count.")
	end
	return count
end

--- The prompts a llm_prompt binding may name, as the AI menu lists them:
--- built-in profiles in menu order, then the user's custom profiles.
--- @return table Array of { value = profile id, label = menu label }.
function M.llm_prompt_choices()
	local Llm = require("modules.llm")
	local ProfileLabel = require("ui.menu.menu_llm.profile_label")
	local count = M.llm_prompt_default_count()
	local choices = {}
	for _, profile in ipairs(Llm.BUILTIN_PROFILES) do
		choices[#choices + 1] = { value = profile.id, label = ProfileLabel.format(profile.label, count) }
	end
	for index, profile in ipairs(Llm.get_user_profiles()) do
		if type(profile) == "table" and type(profile.id) == "string" then
			-- The custom-profile fallback name mirrors the AI menu's own row
			local label = profile.label or (i18n.get("menu.profiles.custom_profile_label") .. " " .. index)
			choices[#choices + 1] = { value = profile.id, label = ProfileLabel.format(label, count) }
		end
	end
	return choices
end

--- The vision backends a llm_vision binding may name: the local server first,
--- then the local OpenAI-compatible servers that answered the last sweep
--- (modules/llm/local_servers.lua; their model goes in the binding), then the
--- API providers that take an image (modules/llm/provider_uses.lua),
--- in the catalogue's order, each with the vision model used when the binding
--- names none ("" when the backend needs one).
--- @return table Array of { value = backend id, label, defaultModel }.
function M.llm_vision_choices()
	local Remote = require("modules.llm.api_remote")
	local ProviderUses = require("modules.llm.provider_uses")
	local LocalServers = require("modules.llm.local_servers")
	local defaults = require("modules.llm.screen_answer").config().default_models
	local choices = { {
		value = Vision.LOCAL_BACKEND,
		label = i18n.get("llm.vision.local_backend"),
		defaultModel = defaults[Vision.LOCAL_BACKEND] or "",
	} }
	for _, server_id in ipairs(ProviderUses.provider_ids(LocalServers.detected(), Remote.PROVIDERS,
		ProviderUses.VISION)) do
		choices[#choices + 1] = { value = server_id, label = Remote.PROVIDERS[server_id].label, defaultModel = "" }
	end
	for _, provider_id in ipairs(ProviderUses.provider_ids(Remote.PROVIDER_ORDER, Remote.PROVIDERS,
		ProviderUses.VISION)) do
		choices[#choices + 1] = {
			value = provider_id,
			label = Remote.PROVIDERS[provider_id].label,
			defaultModel = defaults[provider_id] or "",
		}
	end
	return choices
end

--- The target languages a llm_language binding may name: the interface
--- language first, then every shipped locale in the language menu's order.
--- @return table Array of { value, label }.
function M.llm_language_choices()
	return require("modules.llm.selection_translation").choices()
end

function M.get_action_parameter(binding, action)
	if type(binding) == "string" and (binding:sub(1, 9) == "tap_key__" or binding:sub(1, 10) == "keyboard__" or binding:sub(1, 8) == "script__") then
		local fits, reason = M.action_parameter_binding_fits(binding)
		if fits == false then
			if _state and type(_state.action_params) == "table" and _state.action_params[parameter_key(binding, action)] ~= nil then
				require("config_outdated").report({ "gestures", "action_parameters", parameter_key(binding, action) }, reason, Logger)
			end
			return ""
		end
	end
	if not _state or type(_state.action_params) ~= "table" then return "" end
	return _state.action_params[parameter_key(binding, action)] or ""
end

--- Identifies existing executable binding families without inventing another invoker.
function M.program_binding_supported(binding)
	return type(binding) == "string" and ((type(_state) == "table" and type(_state.ga) == "table"
		and _state.ga[binding] ~= nil) or binding:match("^keyboard__.+$") ~= nil
		or binding:match("^script__.+$") ~= nil or binding:match("^tap_key__.+$") ~= nil)
end

--- Captures acknowledged binding leaves, exact source and the current action parent.
local _program_admission = nil
local _program_admission_checking = false

--- Registers the boot-owned parameter transaction admission port exactly once.
function M.configure_program_admission(callback)
	if type(callback) ~= "function" or _program_admission ~= nil then return false end
	_program_admission = callback
	return true
end

--- Reports boot readiness without hiding the picker needed to retry owned debt.
function M.program_admission_available()
	return type(_program_admission) == "function"
end

local function program_admission_open()
	if type(_program_admission) ~= "function" or _program_admission_checking then return false end
	_program_admission_checking = true
	local ok, receipt = pcall(_program_admission)
	_program_admission_checking = false
	return ok and receipt == true
end

function M.run_program(binding)
	local ok, started = pcall(function()
		local parent = current_action_parent()
		if not program_admission_open() or not M.program_binding_supported(binding)
			or not _state or not AuxOwner.program_available()
			or not aux_admission_open(parent) then return false end
		local Preferences = require("infra.preferences")
		local ConfigPaths = require("infra.config_paths")
		local Toml = require("infra.toml.codec")
		local path = ConfigPaths.get("ConfigTomlPath")
		local scalar = M.get_action_parameter(binding, "run_program")
		local parsed = ProgramParameter.parse(scalar, "hs")
		if not parsed then return false end
		local function binding_action()
			if type(_state.ga) == "table" and _state.ga[binding] ~= nil then
				return _state.ga[binding], "gestures", binding
			end
			if binding:match("^script__") then
				local id = binding:sub(9)
				return require("modules.shortcuts.script_control").get_shortcut_actions()[id], "script_control", id
			end
			local descriptors = {
				{ "keyboard__", "modules.shortcuts.keyboard_shortcuts", "keyboard" },
				{ "tap_key__", "modules.shortcuts.tap_keys", "tap_keys" },
			}
			for _, descriptor in ipairs(descriptors) do
				if binding:sub(1, #descriptor[1]) == descriptor[1] then
					local id = binding:sub(#descriptor[1] + 1)
					return require(descriptor[2]).get_action(id), descriptor[3], id
				end
			end
			return nil
		end
		local action, section, id = binding_action()
		-- Admission checks only owned binding leaves so unrelated outdated values
		-- stay retained. The exact acknowledged source still fences execution.
		local source = Preferences.source_snapshot(path)
		local content, status = FileSystem.read_with_status(path)
		if not program_admission_open() or action ~= "run_program"
			or type(source) ~= "table" or source.status ~= "ok"
			or type(source.content) ~= "string" or status ~= "ok" or content ~= source.content then return false end
		local config = Toml.decode(source.content)
		local parameters = type(config.gestures) == "table" and config.gestures.action_parameters
		local actions = section == "gestures" and config.gestures
			or type(config.shortcuts) == "table" and config.shortcuts[section]
		if type(actions) ~= "table" or actions[id] ~= "run_program" or type(parameters) ~= "table"
			or parameters[parameter_key(binding, "run_program")] ~= scalar then return false end
		local revision = _program_revision
		local function admitted()
			if not program_admission_open() or not aux_admission_open(parent) or revision ~= _program_revision
				or ConfigPaths.get("ConfigTomlPath") ~= path
				or M.get_action_parameter(binding, "run_program") ~= scalar
				or binding_action() ~= "run_program"
				or Preferences.source_matches(source, Preferences.source_snapshot(path)) ~= true then return false end
			local current, current_status = FileSystem.read_with_status(path)
			return program_admission_open() and current_status == "ok" and current == source.content
				and ConfigPaths.get("ConfigTomlPath") == path and revision == _program_revision
				and Preferences.source_matches(source, Preferences.source_snapshot(path)) == true
		end
		local digest = require("adapters.crypto").sha256_bytes(source.content, function()
			Logger.error(LOG, "Private user program source hashing refused.")
		end)
		if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return false end
		_program_parameters_owned = true
		local NativeAutomation = require("adapters.apple_shortcuts_native")
		if NativeAutomation.is_chosen_program(parsed.executable, parsed.arguments) then
			AuxOwner.revalidate_automation(parsed.executable, parsed.arguments, admitted, parent)
			-- Query acceptance is not automation invocation. A persisted chosen ID
			-- cannot bypass the same unavailable service-retirement gate as the picker.
			return false
		end
		return AuxOwner.run_program(parsed.executable, parsed.arguments, admitted, parent,
			{ source_path = path, source_sha256 = digest })
	end)
	return ok and started == true
end

local function retire_program_parameters()
	if not _program_parameters_owned then return true end
	local gestures = AuxOwner.stop_programs(GESTURE_ACTION_PARENT)
	local shortcuts = AuxOwner.stop_programs(SHORTCUT_ACTION_PARENT)
	return gestures == true and shortcuts == true
end

function M.set_action_parameter(binding, action, value)
	if not _state or M.action_parameter_binding_fits(binding) == false
		or not M.validate_action_parameter(action, value) then return false end
	if not retire_program_parameters() then return false end
	_state.action_params = _state.action_params or {}
	_state.action_params[parameter_key(binding, action)] = value
	_program_revision = _program_revision + 1
	return true
end

--- Replaces one detached parameter snapshot after complete validation.
--- Used by scoped preference transactions and their exact compensation owner.
--- @param parameters table Complete parameter snapshot.
--- @return boolean committed
function M.replace_action_parameters(parameters)
	if not _state or type(parameters) ~= "table" then return false end
	if not retire_program_parameters() then return false end
	local staged = {}
	for key, value in pairs(parameters) do
		if type(key) ~= "string" or type(value) ~= "string" then return false end
		local _, action = M.split_action_parameter_key(key)
		if action and not M.validate_action_parameter(action, value) then return false end
		staged[key] = value
	end
	_state.action_params = staged
	_program_revision = _program_revision + 1
	return true
end

--- Captures a private parameter revision without exposing mutable state.
--- Physical delivery carries this proof across all source and admission reads.
function M.capture_parameter_delivery_guard()
	local state, revision = _state, _program_revision
	local parameters = state and state.action_params
	return function()
		return state ~= nil and _state == state and _program_revision == revision
			and (_state and _state.action_params) == parameters
	end
end

--- Captures canonical parameter agreement using the actual action owner.
function M.capture_parameter_source_guard(document, recognizes)
	local state, revision, runtime = _state, _program_revision, _state and _state.action_params
	if not state or type(runtime) ~= "table" or type(document) ~= "table" or type(recognizes) ~= "function" then return nil end
	local source = type(document.gestures) == "table" and document.gestures.action_parameters or nil
	if source ~= nil and type(source) ~= "table" then return nil end
	local expected = {}
	for key, value in pairs(source or {}) do
		local binding, action = M.split_action_parameter_key(key)
		if binding and action and M.validate_action_parameter(action, value) == true and recognizes(binding) then expected[key] = value end
	end
	for key, value in pairs(runtime) do
		local binding = M.split_action_parameter_key(key)
		if binding and recognizes(binding) and expected[key] ~= value then return nil end
	end
	for key, value in pairs(expected) do if runtime[key] ~= value then return nil end end
	local function current() return _state == state and _program_revision == revision and _state.action_params == runtime end
	if not current() then return nil end
	return current
end

function M.get_all_action_parameters()
	local out = {}
	for key, value in pairs((_state and _state.action_params) or {}) do out[key] = value end
	return out
end

-- Labels for modifier-key actions are intentionally kept outside i18n: the
-- shared catalogue defines their exact, language-neutral display form (for
-- example "Ctrl + A") for every driver.
local MODIFIER_ACTION_LABELS = {}
local MODIFIER_ACTION_GROUPS = {}

local function load_modifier_chords(path)
	local raw = FileSystem.read(path)
	if not raw then
		Logger.warn(LOG, "Shared modifier chords JSON not found: %s", tostring(path))
		return nil
	end
	local data, decode_err = JsonCodec.decode(raw)
	if decode_err ~= nil or type(data) ~= "table" then
		Logger.warn(LOG, "Shared modifier chords JSON is invalid: %s", tostring(path))
		return nil
	end
	return data
end

local function join(parts, separator)
	return table.concat(parts, separator)
end

local function register_modifier_chords(catalogue)
	local platform = catalogue and catalogue.platforms and catalogue.platforms.macos
	local modifiers = platform and platform.modifiers
	local keys = catalogue and catalogue.keys
	if type(modifiers) ~= "table" or type(keys) ~= "table" then return end

	local max_mask = (2 ^ #modifiers) - 1
	for mask = 1, max_mask do
		local ids, labels, native_mods = {}, {}, {}
		for index, modifier in ipairs(modifiers) do
			if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then
				ids[#ids + 1] = modifier.id
				labels[#labels + 1] = modifier.label
				native_mods[#native_mods + 1] = modifier.hammerspoon
			end
		end
		local id_prefix = join(ids, "_")
		local label_prefix = join(labels, " + ")
		local action_ids = {}
		for _, key_def in ipairs(keys) do
			local action_id = id_prefix .. "_" .. key_def.id
			local action_label = label_prefix .. " + " .. key_def.label
			local key = key_def.macos_key or key_def.id
			local mods = {}
			for index, modifier in ipairs(native_mods) do mods[index] = modifier end
			MODIFIER_ACTION_LABELS[action_id] = action_label
			action_ids[#action_ids + 1] = action_id
			sg(action_id, function() postKeyStroke(mods, key) end)
		end
		MODIFIER_ACTION_GROUPS[#MODIFIER_ACTION_GROUPS + 1] = {
			label = label_prefix,
			actions = action_ids,
		}
	end
end

local ModifierChordCatalogue = load_modifier_chords(_modifier_chords_json)
register_modifier_chords(ModifierChordCatalogue)

--- The translated text of one picker heading. Older header values carry a
--- leading "#" from when the level was spelled inside the text; the level now
--- comes only from the catalogue, so the marker is stripped.
--- @param key string Locale key of the heading.
--- @return string
local function heading_text(key)
	return (i18n.get(key):gsub("^#+", ""))
end

--- Ordered axis names for the picker, "none" first (the disabled-axis sentinel
--- the picker shows as its own row). Only macOS dispatches an axis, so this is
--- the one catalogue that lists any.
M.AX_NAMES = { "none" }
for _, name in ipairs(Catalogue.ax_items) do M.AX_NAMES[#M.AX_NAMES + 1] = name end

-- Static export so callers (script_control, tests) can read SG_NAMES directly
-- without calling get_sg_names(); mirrors the AX_NAMES pattern above.
M.SG_NAMES = nil  -- populated below after get_sg_names() is defined

--- Returns the ordered SG names with translated section headers: action ids,
--- and headings as "#" (level 1) or "##" (level 2) followed by their text. The
--- modifier-chord block expands into one sub-heading per modifier combination,
--- built from the localized group key and the language-neutral combination
--- label; it used to be a hardcoded French heading in every locale.
--- Called at menu-build time so headers always reflect the active locale.
function M.get_sg_names()
	local out = {}
	for _, item in ipairs(Catalogue.sg_items) do
		if item.kind == "action" then
			out[#out + 1] = item.id
		elseif item.kind == "heading" then
			out[#out + 1] = string.rep("#", item.level) .. heading_text(item.key)
		elseif item.kind == "modifier_chords" then
			for _, group in ipairs(MODIFIER_ACTION_GROUPS) do
				out[#out + 1] = string.rep("#", item.level) .. i18n.format(item.group_key, group.label)
				for _, action_id in ipairs(group.actions) do out[#out + 1] = action_id end
			end
		else
			error("gestures/actions: unknown catalogue item kind '" .. tostring(item.kind) .. "'.")
		end
	end
	return out
end

--- Every id a binding may name: the listed single actions (modifier chords
--- included), the axis actions and "none". Built once — the catalogue and the
--- chord matrix are fixed for the life of the process.
local ASSIGNABLE = require("actions.assignable").build(Catalogue, ModifierChordCatalogue, "macos")

--- True when `name` is an action the catalogue offers on macOS. Bindings are
--- validated against this, as Windows validates against its registry, so an id
--- that no longer exists is refused at assignment instead of being stored and
--- dispatched as a silent no-op.
--- @param name any
--- @return boolean
function M.is_assignable(name)
	return type(name) == "string" and ASSIGNABLE[name] == true
end

--- The ids this driver can actually run, for the catalogue parity test.
--- @return table { sg = {id...}, ax = {id...} }, each sorted.
function M.registered_action_ids()
	local out = { sg = {}, ax = {} }
	for name in pairs(SG) do out.sg[#out.sg + 1] = name end
	for name in pairs(AX) do out.ax[#out.ax + 1] = name end
	table.sort(out.sg)
	table.sort(out.ax)
	return out
end

function M.get_label(name)
	if not name or name == "none" then
		return i18n.get("sg_actions.none")
	end
	if MODIFIER_ACTION_LABELS[name] then return MODIFIER_ACTION_LABELS[name] end
	-- The label key the generated catalogue declares. An id this platform does
	-- not offer (a binding written on another OS) still resolves through the
	-- conventional keys. No hardcoded fallback: an action without a label key is
	-- a gate failure (test-action-catalogue-codegen.cjs), not something to paper
	-- over with a second copy of the English strings; the id is shown as-is.
	local meta = Catalogue.actions[name]
	local keys = meta and { meta.label_key } or { "sg_actions." .. name, "ax_actions." .. name }
	for _, key in ipairs(keys) do
		local s = i18n.get(key)
		if s ~= key then return s end
	end
	return name
end

--- Runs one registered single action under the parent that dispatched it.
--- @param name string Action identifier.
--- @param binding table|nil The binding that invoked it.
--- @param s table The registry entry.
--- @param parent string The dispatch parent.
--- @param control_plane boolean Whether the action is script control.
--- @param acted_from table|nil The application a confirmation read before its
--- question, handed to the handler after the binding.
--- @return boolean True when the handler ran under a still-admitted parent.
local function dispatch_single(name, binding, s, parent, control_plane, acted_from)
	local prior_parent = _dispatch_parent
	_dispatch_parent = parent
	-- Any tap action (other than the click-toggle itself) must deactivate a held click
	-- so that a selection started with left_click_toggle is properly released first.
	if name ~= "left_click_toggle" and name ~= "right_click_toggle" then
		local released, release_result = xpcall(
			Click.release_held_for_tap, debug.traceback, name, parent)
		if not released or release_result ~= true then
			_dispatch_parent = prior_parent
			Logger.error(LOG, "Gesture action '%s' refused because held-click cleanup failed: %s.",
				tostring(name), tostring(release_result))
			return false
		end
	end
	if not control_plane and not aux_admission_open(parent) then
		_dispatch_parent = prior_parent
		return false
	end
	-- Logger.callback (not a bare pcall) so a throwing action leaves a trace: with
	-- ~150+ registered closures dispatched here, a caught-then-dropped exception
	-- would otherwise be completely invisible in the logs (gestures-actions-silent-pcall).
	local dispatch_ok, callback_ok = xpcall(function()
		return Logger.callback(LOG,
			"Gesture action '" .. tostring(name) .. "'", s.fn, binding, acted_from)
	end, debug.traceback)
	local admission_committed = control_plane or aux_admission_open(parent)
	_dispatch_parent = prior_parent
	if not dispatch_ok then
		Logger.error(LOG, "Gesture action dispatch boundary failed: %s.",
			tostring(callback_ok))
		return false
	end
	-- A registered action owns the dispatch even when its business operation
	-- refuses. Only transport failure or a superseded lifecycle admission lets
	-- the caller fall through to another action provider.
	return callback_ok == true and admission_committed == true
end

--- Dispatches a registered single-shot action. An action the catalogue
--- declares `confirm = true` only asks here; it runs from the answer, and only
--- while its parent is still admitted.
--- @param name string Action identifier.
--- @param binding table|nil The binding that invoked it.
--- @return boolean True when a handler was found and invoked (or its
--- confirmation asked for); false when the action is unknown here, so the
--- caller can try its own fallback instead of assuming the action ran.
function M.execute_single(name, binding)
	local parent = parent_for_binding(binding)
	local control_plane = is_script_control_plane_action(name, binding)
	if not control_plane and not aux_admission_open(parent) then return false end
	local s = SG[name]
	if not s or type(s.fn) ~= "function" then return false end
	local meta = Catalogue.actions[name]
	if meta and meta.confirm == true then
		-- Required on the first confirmation only: the alert pulls in the dialog
		-- and screen adapters, which no other action needs at load.
		local ok_confirm, ActionConfirm = pcall(require, "modules.gestures.action_confirm")
		if not ok_confirm or type(ActionConfirm) ~= "table" or type(ActionConfirm.ask) ~= "function" then
			Logger.error(LOG, "'%s' needs a confirmation that cannot be asked (%s) — not run.",
				tostring(name), tostring(ActionConfirm))
			return false
		end
		-- The action owns the dispatch whether or not its question could be shown
		-- (ask logs why not): a fallback provider must never run it unasked.
		ActionConfirm.ask(M.get_label(name), function(acted_from)
			if not aux_admission_open(parent) then
				Logger.info(LOG, "'%s' was confirmed after its scope was paused — not run.", name)
				return
			end
			dispatch_single(name, binding, s, parent, control_plane, acted_from)
		end)
		return true
	end
	return dispatch_single(name, binding, s, parent, control_plane)
end

function M.execute_axis(name, goNext)
	if not aux_admission_open(GESTURE_ACTION_PARENT) then return false end
	local a = AX[name]
	if not a then return false end
	local fn = goNext and a.next or a.prev
	if type(fn) == "function" then
		local prior_parent = _dispatch_parent
		_dispatch_parent = GESTURE_ACTION_PARENT
		local dispatch_ok, ok, result = xpcall(function()
			return Logger.callback(LOG,
				"Gesture axis action '" .. tostring(name) .. "'", fn)
		end, debug.traceback)
		local admission_committed = aux_admission_open(GESTURE_ACTION_PARENT)
		_dispatch_parent = prior_parent
		if not dispatch_ok then
			Logger.error(LOG, "Gesture axis dispatch boundary failed: %s.", tostring(ok))
			return false
		end
		return ok == true and result ~= false and admission_committed == true
	end
	return false
end

function M.is_scalable(name)
	local a = AX[name]
	return a and a.scalable == true
end

-- Populate the static SG_NAMES now that get_sg_names() is defined
M.SG_NAMES = M.get_sg_names()

return M
