--- modules/gestures/actions.lua

--- ==============================================================================
--- MODULE: Gestures Actions Registry
--- DESCRIPTION:
--- Maps internal logic representations to human-readable labels and concrete
--- Hammerspoon actions (keystrokes, system events, etc.).
--- ==============================================================================

local M = {}

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
local LOG           = "gestures.actions"

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

--- The dedicated script-control tap survives global PAUSE, but only its two
--- root lifecycle actions may bypass feature admission. Arbitrary catalogue
--- actions assigned to the same physical slots remain fenced normally.
--- @param name string Action identifier.
--- @param binding string|nil Binding provenance.
--- @return boolean control_plane
local function is_script_control_plane_action(name, binding)
	return type(binding) == "string" and binding:match("^script__") ~= nil
		and (name == "script_reload" or name == "script_quit")
end

--- Maps a configurable keyboard binding to the shortcut parent while every
--- engine and direct gesture dispatch remains in the gesture parent.
--- @param binding any Binding identity supplied by execute_single().
--- @return string parent
local function parent_for_binding(binding)
	if type(binding) == "string" and binding:match("^keyboard__") then
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
	pcall(function() hs.eventtap.event.newSystemKeyEvent(key, true):post() end)
	pcall(function() hs.eventtap.event.newSystemKeyEvent(key, false):post() end)
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

--- Resolves the driver's log directory, honouring a relocated config dir.
--- Mirrors the resolver in ui/menu/init.lua so the gesture actions and the menu
--- entries can never open two different folders. Falls back to hs.configdir,
--- which is where the driver lives when the config dir has not been moved.
--- @return string Absolute log directory, with a trailing slash.
local function logs_dir()
	local ok_mp, mp = pcall(require, "ui.menu.menu_paths")
	local base = ok_mp and type(mp.get_config_dir) == "function" and mp.get_config_dir() or nil
	if type(base) == "string" and base ~= "" then
		if not base:match("[/\\]$") then base = base .. "/" end
		return base .. "hammerspoon/logs/"
	end
	return hs.configdir .. "/logs/"
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

--- Switch to the previous application in the MRU list.
--- ke_lifecycle never exposed switch_to_previous_app, so the lazy-require branch
--- that used to sit here was dead and the keystroke below was the only path ever
--- taken. Removed rather than left as a shim, per the no-unused-fallback rule.
local function switch_to_previous_application()
	postKeyStroke({"cmd"}, "tab")
end

--- Switch to the previous window of the frontmost application.
--- This used to share cmd+tab with switch_to_previous_application, so the
--- "Prev. window" gesture silently performed an app switch. cmd+grave is the
--- macOS binding that actually cycles windows within the front app.
local function switch_to_previous_window_precise()
	postKeyStroke({"cmd"}, "`")
end

--- Triggers a macOS system-wide dictionary lookup/definition.
function M.trigger_lookup(explicit_parent)
	local requested_parent = explicit_parent or current_action_parent()
	local parent = requested_parent == SHORTCUT_ACTION_PARENT
		and SHORTCUT_ACTION_PARENT or GESTURE_ACTION_PARENT
	if not aux_admission_open(parent) or _lookup_operations[parent] ~= nil then
		return false
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

local function show_application_switcher_overlay()
    postKeyStroke({"cmd"}, "tab")
end

--- Navigates between windows of the current application.
local function winNav(goNext)
	local key = goNext and "`" or "~"
	postKeyStroke({"cmd"}, key)
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
--- @return boolean, table|nil
local function _cached_all_spaces(spaces)
	local now = hs.timer.secondsSinceEpoch()
	if _all_spaces_cache ~= nil and (now - _all_spaces_at) < SPACES_LAYOUT_TTL_SEC then
		return true, _all_spaces_cache
	end
	local ok, all = pcall(spaces.allSpaces)
	if ok and type(all) == "table" then
		_all_spaces_cache = all
		_all_spaces_at    = now
	end
	return ok, all
end

--- Navigates between macOS Spaces (Desktops).
local function spaceNav(goNext)
	-- space_wrap is persisted, restored and exposed as a menu checkbox, but nothing
	-- ever read it: the toggle looked functional and did nothing. macOS itself stops
	-- at the first and last Space, so honouring the setting means suppressing the
	-- navigation at the edge rather than asking the OS to wrap.
	if _state and _state.space_wrap == false then
		local spaces = _spaces_module()
		if spaces and type(spaces.spaceType) == "function" then
			-- allSpaces is a private-API round-trip and this runs on the gesture
			-- frame callback, where a stall shows up directly as input lag. The
			-- Space LAYOUT changes only when the user adds or removes a desktop,
			-- so it is cached briefly; the focused Space, which changes with every
			-- navigation, is always read live.
			local ok_all, all = _cached_all_spaces(spaces)
			local ok_cur, cur = pcall(spaces.focusedSpace)
			if ok_all and ok_cur and type(all) == "table" and cur then
				local screen_spaces
				for _, list in pairs(all) do
					for _, id in ipairs(list) do
						if id == cur then screen_spaces = list break end
					end
					if screen_spaces then break end
				end
				if screen_spaces and #screen_spaces > 0 then
					local at_edge = (goNext and screen_spaces[#screen_spaces] == cur)
						or ((not goNext) and screen_spaces[1] == cur)
					if at_edge then
						Logger.debug(LOG, "Space navigation suppressed at the edge (space_wrap disabled).")
						return
					end
				end
			end
		end
	end

	local key_code = goNext and 124 or 123 -- 124=Right, 123=Left
	-- AppleScript-generated key events carry no Ergopti provenance. Both taps then
	-- treated this Space navigation as physical typing, so action-epoch consumers
	-- could retain text/LLM state from the previous desktop. Numeric Quartz keycodes
	-- are supported by the same exact-tag adapter used by named gesture keys.
	postKeyStroke({ "ctrl" }, key_code)
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
	function() spaceNav(false) end, 
	function() spaceNav(true) end)

ax("volume",     
	function() sysKey("SOUND_DOWN") end, 
	function() sysKey("SOUND_UP") end, true)

ax("brightness", 
	function() sysKey("BRIGHTNESS_DOWN") end, 
	function() sysKey("BRIGHTNESS_UP") end, true)

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
sg("app_switcher",      show_application_switcher_overlay)
sg("app_previous",      switch_to_previous_application)
sg("app_window_previous",  switch_to_previous_window_precise)

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

sg("sticky_shift",             function() arm_sticky({ "shift" }) end)
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
sg("win_prev",            function() winNav(false) end)
sg("win_next",              function() winNav(true) end)
sg("snap_left",              function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:moveToUnit(hs.layout.left50) end) end
end)
sg("snap_right",             function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:moveToUnit(hs.layout.right50) end) end
end)
sg("maximize",                     function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:maximize() end) end
end)
sg("space_prev",             function() spaceNav(false) end)
sg("space_next",               function() spaceNav(true) end)
sg("mission_control",        function()
	postKeyStroke({}, 160)
end)
sg("app_expose",                  function()
	postKeyStroke({ "ctrl" }, 125)
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
sg("brightness_up",             function() sysKey("BRIGHTNESS_UP") end)
sg("brightness_down",           function() sysKey("BRIGHTNESS_DOWN") end)
sg("track_play",               function() sysKey("PLAY") end)
sg("track_next",              function() sysKey("NEXT") end)
sg("track_prev",            function() sysKey("PREVIOUS") end)

-- Single arrows

-- Shift + Arrows

-- Shift + Alt + Arrows (Word selection)

-- System
sg("screenshot_window_clipboard",     function()
	return ScreenshotSave.capture({ "-cw" }, current_action_parent())
end)
sg("screenshot_window_save",          function()
	return ScreenshotSave.save({ "-w" }, "win", current_action_parent())
end)
sg("screenshot_region_clipboard",      function()
	return ScreenshotSave.capture({ "-ci" }, current_action_parent())
end)
sg("screenshot_region_save",           function()
	return ScreenshotSave.save({ "-i" }, "reg", current_action_parent())
end)
sg("screenshot_fullscreen_clipboard",   function()
	return ScreenshotSave.capture({ "-c" }, current_action_parent())
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
sg("select_line", function()
	local ok, Text = pcall(require, "modules.shortcuts.actions.text")
	if ok and type(Text.select_line) == "function" then
		return Text.select_line(current_action_parent())
	end
	return false
end)
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
sg("open_personal_shortcuts",     function()
	return AuxOwner.open(hs.configdir .. "/personal_shortcuts.toml",
		"open personal shortcuts", nil, current_action_parent())
end)
sg("open_personal_hotstrings",    function()
	local ok_mp, mp = pcall(require, "ui.menu.menu_paths")
	local p = ok_mp and type(mp.get) == "function" and mp.get("PersonalTomlPath")
	if type(p) == "string" and p ~= "" then
		return AuxOwner.open(p, "open personal hotstrings", nil, current_action_parent())
	else
		return AuxOwner.open(hs.configdir .. "/hotstrings/personal_hotstrings.toml",
			"open personal hotstrings", nil, current_action_parent())
	end
end)
sg("open_personal_info",               function()
	return AuxOwner.open(hs.configdir .. "/personal_info.toml",
		"open personal info", nil, current_action_parent())
end)
sg("open_config",                    function()
	return AuxOwner.open(hs.configdir .. "/config.toml",
		"open config", nil, current_action_parent())
end)
sg("open_logs_folder",                function()
	return AuxOwner.open(logs_dir(), "open logs folder", nil, current_action_parent())
end)
sg("open_today_log",                   function()
	local ok_p, path = pcall(function()
		return logs_dir() .. "ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"
	end)
	-- The open is skipped rather than attempted with a nil path: the launcher
	-- logs an ERROR for a nil target, which is the fail-fast we want, but only
	-- when there was really a path to open.
	if ok_p then return AuxOwner.open(path, "open today's log", nil, current_action_parent()) end
	return false
end)
sg("open_error_log",                   function()
	local ok_p, path = pcall(function()
		local ok_l, Logger = pcall(require, "infra.logger")
		if ok_l and type(Logger) == "table" and type(Logger.ERRORS_LOG_FILE) == "string" and Logger.ERRORS_LOG_FILE ~= "" then
			return Logger.ERRORS_LOG_FILE
		end
		return logs_dir() .. "ErgoptiPlus_errors_" .. os.date("%Y-%m-%d") .. ".log"
	end)
	if ok_p then return AuxOwner.open(path, "open error log", nil, current_action_parent()) end
	return false
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
			restore_search_clipboard(my_generation)
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
			restore_search_clipboard(my_generation)
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
	if not text_ok or type(Text) ~= "table"
		or not mouse_ok or type(Mouse) ~= "table" then
		Logger.error(LOG, "Shared action lifecycle modules could not be loaded: %s / %s.",
			tostring(Text), tostring(Mouse))
		return nil
	end
	return {
		{id = "auxiliary", subject = AuxOwner,
			pause = "pause", resume = "resume", query = "is_paused",
			pending = "has_pending"},
		{id = "text", subject = Text,
			pause = "pause_text_actions", resume = "resume_text_actions",
			query = "is_text_actions_paused", pending = "has_pending_text_action"},
		{id = "mouse", subject = Mouse,
			pause = "pause_mouse_actions", resume = "resume_mouse_actions",
			query = "is_mouse_actions_paused", pending = "has_pending_mouse_action"},
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
		local request_ok, accepted_or_err = xpcall(function()
			return TerminationCoordinator.request_exit("script_quit", 0)
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
sg("open_console",                        function() pcall(hs.openConsole) end)





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

-- Path to the shared actions.toml, resolved through the single shared-tree
-- resolver (Paths.shared) so the shared root lives in exactly one place.
local _shared_toml = Paths.shared("modules/actions/actions.toml")
local _modifier_chords_json = Paths.shared("modules/actions/modifier_chords.json")

--- Parses the shared actions.toml using a lightweight line-by-line reader.
--- Returns { sg_order = [...], ax_order = [...], sg_actions = {name={platform=...}},
--- ax_actions = {name={platform=...}}, karabiner_aliases = {karabiner_id = shared_id} }
local function load_shared_actions(path)
	local result = { sg_order = {}, ax_order = {}, sg_actions = {}, ax_actions = {}, karabiner_aliases = {} }
	local ok, f = pcall(io.open, path, "r")
	if not ok or not f then
		Logger.warn("gestures.actions", "Shared actions TOML not found: %s — using fallback.", tostring(path))
		return nil
	end

	local current_section = nil
	local current_key     = nil
	local in_array        = false
	local array_buf       = {}
	local current_action  = nil  -- e.g. "sg_actions.left_click_toggle"

	for line in f:lines() do
		local trimmed = line:match("^%s*(.-)%s*$")

		-- Skip blank lines and comments
		if trimmed == "" or trimmed:sub(1, 1) == "#" then goto continue end

		-- Multi-line array continuation
		if in_array then
			if trimmed:sub(1, 1) == "]" then
				-- End of array
				if current_section == "sg_order" then
					result.sg_order = array_buf
				elseif current_section == "ax_order" then
					result.ax_order = array_buf
				end
				in_array  = false
				array_buf = {}
			else
				-- Collect array items: strip trailing comma and quotes
				local item = trimmed:match('^"(.-)"')
				if item then array_buf[#array_buf + 1] = item end
			end
			goto continue
		end

		-- Section header [name] or [name.subkey]
		local section = trimmed:match("^%[([^%[%]]+)%]$")
		if section then
			current_section = section
			current_action  = nil
			-- Pre-create entry for known action sections
			local kind, name = section:match("^(sg_actions)%.(.+)$")
			if not kind then kind, name = section:match("^(ax_actions)%.(.+)$") end
			if kind and name then
				current_action = section
				result[kind][name] = result[kind][name] or {}
			end
			goto continue
		end

		-- Key = value
		local key, val = trimmed:match("^([%w_]+)%s*=%s*(.+)$")
		if key and val then
			-- Unquote string values
			local str_val = val:match('^"(.-)"$') or val
			-- Array opening without closing on same line
			if val:sub(1, 1) == "[" and not val:find("]", 2, true) then
				current_key = key
				in_array    = true
				array_buf   = {}
			elseif current_action then
				-- Store attribute of current [sg_actions.X] or [ax_actions.X]
				local kind, name = current_action:match("^(sg_actions)%.(.+)$")
				if not kind then kind, name = current_action:match("^(ax_actions)%.(.+)$") end
				if kind and name then
					result[kind][name][key] = str_val
				end
			elseif current_section == "karabiner_aliases" then
				-- A flat id = "target" table, not an action block: without this
				-- branch the reader silently drops it and the remap picker shows
				-- the raw Karabiner identifier for every aliased action.
				result.karabiner_aliases[key] = str_val
			end
		end

		::continue::
	end
	f:close()
	return result
end

local _shared = load_shared_actions(_shared_toml)

--- Karabiner ids that name an action the catalogue already carries under another
--- name, as { karabiner_id = shared_id }. The remap picker is indexed on
--- Karabiner ids, so it resolves a label through this rather than carrying a
--- second copy of the same translated string in twenty-one locale files.
--- @return table
function M.karabiner_aliases()
	return (_shared and _shared.karabiner_aliases) or {}
end

local function parameter_key(binding, action)
	return tostring(binding or "") .. "__" .. tostring(action or "")
end

--- Split only on a recognised parameterized-action suffix. A binding itself
--- may contain ``__`` (for example keyboard__cmd_k), so splitting at the
--- first delimiter would restore the parameter under the wrong binding.
function M.split_action_parameter_key(key)
	if type(key) ~= "string" then return nil, nil end
	for action, meta in pairs((_shared and _shared.sg_actions) or {}) do
		if type(meta) == "table" and type(meta.parameter) == "string" then
			local suffix = "__" .. action
			if key:sub(-#suffix) == suffix then return key:sub(1, #key - #suffix), action end
		end
	end
	return nil, nil
end

function M.get_action_parameter_spec(action)
	local meta = _shared and _shared.sg_actions and _shared.sg_actions[action]
	return meta and meta.parameter or nil
end

function M.validate_action_parameter(action, value)
	local spec = M.get_action_parameter_spec(action)
	if not spec then return true end
	if type(value) ~= "string" or not value:match("^https?://%S+$") then return false end
	if spec == "search_url" then
		local _, placeholders = value:gsub("%%s", "")
		return placeholders == 1
	end
	return true
end

function M.get_action_parameter(binding, action)
	if not _state or type(_state.action_params) ~= "table" then return "" end
	return _state.action_params[parameter_key(binding, action)] or ""
end

function M.set_action_parameter(binding, action, value)
	if not _state or not M.validate_action_parameter(action, value) then return false end
	_state.action_params = _state.action_params or {}
	_state.action_params[parameter_key(binding, action)] = value
	return true
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
	local ok_json, data = pcall(hs.json.decode, raw)
	if not ok_json or type(data) ~= "table" then
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

register_modifier_chords(load_modifier_chords(_modifier_chords_json))

-- The driver key this build of the catalogue answers to.
local THIS_PLATFORM = "hs"

--- True when a catalogue `platform` field claims this driver.
---
--- The field is "all", one driver key, or a comma-separated list of them. The
--- list form exists because the field could not previously say "two drivers out
--- of three": the two window cyclers ship on macOS and Windows and not on
--- Linux, and both single-value answers were false — "all" put dead rows in the
--- Linux picker, "hs" or "ahk" hid half the feature.
--- @param platform string|nil The declared field, or nil for the "all" default.
--- @return boolean
local function claims_this_platform(platform)
	if type(platform) ~= "string" or platform == "" or platform == "all" then return true end
	for key in platform:gmatch("[^,%s]+") do
		if key == THIS_PLATFORM then return true end
	end
	return false
end

--- Builds a picker-order list from the shared TOML, keeping only entries
--- matching the given platform ("hs") plus sentinels ("--", "#…").
--- The modifier-chord placeholder is expanded from modifier_chords.json.
local function build_sg_names(shared)
	if not shared then
		-- The shared action-order catalogue is unavailable: omit picker entries
		-- rather than exposing an unsynchronised fallback list.
		return nil
	end
	local out = {}
	for _, item in ipairs(shared.sg_order) do
		-- Sentinels and headers always pass through (TOML uses "--" and "#…")
		if item == "--" then
			out[#out + 1] = "-"
		elseif item:sub(1, 1) == "#" then
			-- Header from TOML: the number of leading "#" encodes the heading
			-- level ("#grp_input" = h1, "##mouse_nav" = h2). Re-emit with the
			-- SAME marker so the picker can render the hierarchy. The locale value
			-- carries a legacy "#" prefix — strip it so the level comes only from
			-- the TOML marker, not the translated text.
			local hashes     = item:match("^#+")
			local key_suffix = item:sub(#hashes + 1)
			local i18n_key   = "sg_actions.sg_order.header." .. key_suffix
			local translated = i18n.get(i18n_key)
			local title      = (translated ~= i18n_key) and translated or key_suffix
			title            = (title:gsub("^#+", ""))
			out[#out + 1] = hashes .. title
		elseif item == "_modifier_chords_placeholder" then
			for _, group in ipairs(MODIFIER_ACTION_GROUPS) do
				out[#out + 1] = "##Raccourcis " .. group.label
				for _, action_id in ipairs(group.actions) do out[#out + 1] = action_id end
			end
		elseif item:sub(1, 1) == "_" then
			-- Driver-specific placeholders are ignored deliberately.
		else
			local meta = shared.sg_actions[item]
			if claims_this_platform(meta and meta.platform) then
				out[#out + 1] = item
			end
		end
	end
	return out
end

local function build_ax_names(shared)
	if not shared then return nil end
	-- "none" is the disabled-axis sentinel; always first, never in the TOML order list
	local out = {"none"}
	for _, item in ipairs(shared.ax_order) do
		local meta = shared.ax_actions[item]
		if claims_this_platform(meta and meta.platform) then
			out[#out + 1] = item
		end
	end
	return out
end

M.AX_NAMES = build_ax_names(_shared) or {
	"none", "char", "char_sel", "words", "words_sel",
	"line_arrow", "line_sel", "lines", "paragraphs", "line_bounds", "document",
	"tabs", "windows", "spaces", "volume", "brightness", "tracks",
}

-- Static export so callers (script_control, tests) can read SG_NAMES directly
-- without calling get_sg_names(); mirrors the AX_NAMES pattern above.
-- Built once at module load time using the fallback list when _shared is absent.
M.SG_NAMES = nil  -- populated below after get_sg_names() is defined

--- Returns the ordered list of SG action names with translated section headers.
--- Called at menu-build time so headers always reflect the active locale.
function M.get_sg_names()
	local names = build_sg_names(_shared)
	if names then return names end
	-- Fallback when the shared TOML could not be loaded
	local h = function(key) return "#" .. i18n.get(key) end
	return {
		"none", "-",
		h("sg_actions.sg_order.header.mouse_nav"),
		"left_click_toggle", "right_click_toggle", "lookup",
		"app_switcher", "app_previous", "app_window_previous",
		"-", h("sg_actions.sg_order.header.keys"),
		"enter", "tab", "escape", "backspace", "delete",
		"-", h("sg_actions.sg_order.header.tabs"),
		"tab_new", "tab_close", "tab_prev", "tab_next",
		"-", h("sg_actions.sg_order.header.windows"),
		"win_prev", "win_next", "close_window", "fullscreen",
		"snap_left", "snap_right", "maximize",
		"-", h("sg_actions.sg_order.header.spaces"),
		"space_prev", "space_next", "mission_control", "app_expose",
		"-", h("sg_actions.sg_order.header.cursor"),
		"arrow_up", "arrow_down", "arrow_left", "arrow_right",
		"word_prev", "word_next",
		"line_up", "line_down", "line_start", "line_end",
		"para_prev", "para_next", "doc_start", "doc_end",
		"-", h("sg_actions.sg_order.header.selection"),
		"sel_up", "sel_down", "sel_left", "sel_right",
		"sel_word_prev", "sel_word_next",
		"-", h("sg_actions.sg_order.header.media"),
		"vol_up", "vol_down", "mute", "brightness_up", "brightness_down",
		"track_play", "track_next", "track_prev",
		"-", h("sg_actions.sg_order.header.screenshot"),
		"screenshot_window_clipboard", "screenshot_window_save",
		"screenshot_region_clipboard", "screenshot_region_save",
		"screenshot_fullscreen_clipboard", "screenshot_fullscreen_save",
		"-", h("sg_actions.sg_order.header.system"),
		"lock_screen", "notification_center",
		"-", h("sg_actions.sg_order.header.ui"),
		"open_metrics_typing", "open_metrics_apps",
		"open_hotstrings_editor", "open_paths_editor",
		"-", h("sg_actions.sg_order.header.files"),
		"open_script_source", "open_personal_shortcuts",
		"open_personal_hotstrings", "open_personal_info",
		"open_config", "open_logs_folder", "open_today_log", "open_error_log",
		"-", h("sg_actions.sg_order.header.script"),
		"script_pause_toggle", "script_reload", "script_save_reload", "script_quit",
		"-", h("sg_actions.sg_order.header.debug"),
		"open_console",
		"-", h("sg_actions.sg_order.header.cmd"),
		"-", h("sg_actions.sg_order.header.cmd_shift"),
	}
end

function M.get_label(name)
	if not name or name == "none" then
		return i18n.get("sg_actions.none")
	end
	if MODIFIER_ACTION_LABELS[name] then return MODIFIER_ACTION_LABELS[name] end
	-- Prefer locale JSON so the label is translated for the active language
	local key_sg = "sg_actions." .. name
	local s = i18n.get(key_sg)
	if s ~= key_sg then return s end
	local key_ax = "ax_actions." .. name
	local s_ax = i18n.get(key_ax)
	if s_ax ~= key_ax then return s_ax end
	-- No hardcoded fallback: an action without a label key is a gate failure
	-- (test-action-labels-have-locale-keys.cjs), not something to paper over with
	-- a second copy of the English strings. Returning the id makes the omission
	-- visible if one ever slips past.
	return name
end

--- Dispatches a registered single-shot action.
--- @param name string Action identifier.
--- @param binding table|nil The binding that invoked it.
--- @return boolean True when a handler was found and invoked; false when the
--- action is unknown here, so the caller can try its own fallback instead of
--- assuming the action ran.
function M.execute_single(name, binding)
	local parent = parent_for_binding(binding)
	local control_plane = is_script_control_plane_action(name, binding)
	if not control_plane and not aux_admission_open(parent) then return false end
	local s = SG[name]
	if not s or type(s.fn) ~= "function" then return false end
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
			"Gesture action '" .. tostring(name) .. "'", s.fn, binding)
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
