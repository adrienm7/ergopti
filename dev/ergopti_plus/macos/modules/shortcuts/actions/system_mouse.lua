--- modules/shortcuts/actions/system_mouse.lua

--- ==============================================================================
--- MODULE: Shortcuts — System Actions — Mouse & Display Utilities
--- DESCRIPTION:
--- Mouse teleport, display mirroring, emoji picker, and mouse spotlight helpers
--- extracted from system.lua. Merged back into the system module table at load time.
---
--- FEATURES & RATIONALE:
--- 1. Screen Teleport: Cycles the cursor across all connected screens and shows a
---    brief spotlight so the new cursor position is immediately visible.
--- 2. Display Mirror: Uses CoreGraphics via inline Python so mirroring toggles
---    reliably without depending on the fragile Cmd+F1 media-key route.
--- 3. Mouse Spotlight: Draws a yellow ring on the cursor’s screen and a red ×
---    on every other screen; auto-dismisses on mouse move or timeout.
--- 4. Exact Pause Ownership: Fences and joins mirror processes, timers, eventtaps,
---    and canvases before the shortcut lifecycle can publish PAUSED.
--- ==============================================================================

local M = {}

local hs             = hs
local Logger         = require("infra.logger")
local notifications  = require("infra.notifications")
local i18n           = require("infra.i18n")
local MouseControl   = require("adapters.mouse_control")
local ShellRunner    = require("adapters.shell_runner")
local SyntheticInput = require("adapters.synthetic_input")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "shortcuts.actions.system"

-- Absolute path: the interactive layer must not inherit its binaries from PATH,
-- which differs between a login shell and the Hammerspoon process.
local PYTHON_BIN = "/usr/bin/python3"

-- Spotlight ring color (circle on the screen that holds the cursor)
local SPOTLIGHT_COLOR = {red = 1, green = 0.85, blue = 0}    -- Yellow

-- Cross marker color (× shown on every screen NOT holding the cursor)
local CROSS_COLOR     = {red = 0.9, green = 0.1, blue = 0.05} -- Red

-- Shared stroke alpha for all overlay shapes (circle and crosses)
local OVERLAY_STROKE_ALPHA = 0.9  -- High opacity so the border reads against any background

-- Mouse spotlight ring parameters (circle shown on the screen that holds the cursor)
local SPOTLIGHT_RADIUS_PX   = 60    -- Outer ring radius around the cursor center
local SPOTLIGHT_STROKE_PX   = 6     -- Ring stroke width
local SPOTLIGHT_FILL_ALPHA  = 0.40  -- Fill opacity for the ring
local SPOTLIGHT_DURATION_S  = 5     -- Max seconds before auto-dismiss (overridden by mouse move)
local SPOTLIGHT_PADDING_PX  = 12    -- Canvas padding so the stroke is never clipped

-- Cross marker parameters (shown centered on every screen that does NOT hold the cursor)
local CROSS_ARM_HALF_PX  = 60   -- Half-length of each arm; total span = 120 px
local CROSS_ARM_WIDTH_PX = 14   -- Thickness of each bar
local CROSS_STROKE_PX    = 6    -- Border stroke width, matches the circle ring
local CROSS_FILL_ALPHA   = 0.40 -- Fill opacity for the cross markers
local CROSS_PADDING_PX   = 12   -- Canvas padding so strokes are never clipped

-- Tap and teleport timing
local SPOTLIGHT_TAP_DELAY_SEC       = 0.05 -- Delay before arming the mouseMoved tap; prevents
                                           -- a programmatic warp from immediately dismissing spotlight
local SPOTLIGHT_TELEPORT_DURATION_S = 3    -- Shorter duration when triggered by teleport

-- Mouse/display work is a child of the shortcut bindings lifecycle. Admission
-- closes before native cleanup starts, while these exact owners stay published
-- until every process, timer, eventtap, and canvas capability settles
local DEFAULT_ACTION_PARENT = "shortcut_bindings"
local _mouse_scopes = {}
local _next_mouse_owner_id = 0
local _mirror_operations = {}
local _spotlight_operations = {}





-- =============================================
-- =============================================
-- ======= 1/ Exact Lifecycle Ownership ========
-- =============================================
-- =============================================

--- Allocates one stable identity for an owned native capability.
--- @return integer id Monotonic owner identity.
local function next_mouse_owner_id()
	_next_mouse_owner_id = _next_mouse_owner_id + 1
	return _next_mouse_owner_id
end

--- Resolves one parent-scoped admission generation.
--- @param parent string|nil Stable action parent.
--- @return table scope
local function mouse_scope(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	local scope = _mouse_scopes[scope_id]
	if scope then return scope end
	scope = { id = scope_id, paused = false, generation = 0, boundary_depth = 0 }
	_mouse_scopes[scope_id] = scope
	return scope
end

--- Tests whether a published owner may still cross into business effects.
--- @param operation table Operation identity.
--- @return boolean authorized
local function mouse_operation_is_authorized(operation)
	local scope = operation.scope
	return type(scope) == "table" and scope.paused ~= true
		and operation.authorized == true
		and operation.generation == scope.generation
end

--- Reports cleanup debt without confusing ordinary active work with a refusal.
--- @return boolean pending
local function mouse_cleanup_debt(parent)
	local scope = mouse_scope(parent)
	local mirror = _mirror_operations[scope.id]
	local spotlight = _spotlight_operations[scope.id]
	return (mirror ~= nil and mirror.authorized ~= true)
		or (spotlight ~= nil and spotlight.authorized ~= true)
end

--- Guards every public action against PAUSE and retained cleanup debt.
--- @param label string Diagnostic action label.
--- @return boolean admitted
local function mouse_action_admission_open(label, parent)
	local scope = mouse_scope(parent)
	if scope.paused == true or scope.boundary_depth > 0
		or mouse_cleanup_debt(scope.id) then
		Logger.warn(LOG, "%s refused while mouse actions are quiesced.", tostring(label))
		return false
	end
	return true, scope
end

--- Keeps a synchronous native mutation visible to PAUSE until its call frame
--- returns. A re-entrant pause closes the generation but cannot report settled
--- while the boundary is active; the outer action then observes the lost epoch
--- and publishes no follow-up effect.
--- @param scope table Parent scope.
--- @param callback function Native mutation.
--- @return boolean ok
--- @return any result_or_error
--- @return boolean current
local function invoke_mouse_native_boundary(scope, callback)
	local generation = scope.generation
	scope.boundary_depth = scope.boundary_depth + 1
	local ok, result_or_error = xpcall(callback, debug.traceback)
	scope.boundary_depth = scope.boundary_depth - 1
	local current = scope.paused ~= true and scope.generation == generation
	return ok, result_or_error, current
end

--- Invokes one business continuation without losing an async throw.
--- @param label string Diagnostic callback label.
--- @param callback function Callback to invoke.
--- @param ... any Callback arguments.
--- @return boolean completed
local function invoke_mouse_callback(label, callback, ...)
	if type(callback) ~= "function" then return true end
	local args = table.pack(...)
	local ok, result_or_error = xpcall(function()
		return callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback failed — %s.", tostring(label),
			tostring(result_or_error))
		return false
	end
	return result_or_error ~= false
end



-- =============================================
-- ===== 1.1) Display Mirror Process Owner =====
-- =============================================

local drain_mirror_terminal

--- Probes exact ShellRunner settlement without treating a non-throw as success.
--- @param operation table Mirror operation.
--- @return boolean settled
local function mirror_handle_is_settled(operation)
	if type(operation.handle) ~= "table"
		or type(operation.handle.isSettled) ~= "function" then
		return false
	end
	local ok, settled = xpcall(operation.handle.isSettled, debug.traceback)
	return ok == true and settled == true
end

--- Releases the logical mirror slot only after exact native settlement.
--- @param operation table Mirror operation.
--- @return boolean settled
local function release_mirror_if_settled(operation)
	if _mirror_operations[operation.parent] ~= operation then return true end
	if operation.acquiring == true or operation.starting == true then return false end
	if operation.handle == nil then
		if operation.acquisition_finished ~= true then return false end
		_mirror_operations[operation.parent] = nil
		return true
	end
	if operation.settled ~= true and not mirror_handle_is_settled(operation) then
		return false
	end
	operation.settled = true
	if operation.start_committed == true then drain_mirror_terminal(operation) end
	if _mirror_operations[operation.parent] == operation then
		_mirror_operations[operation.parent] = nil
	end
	return true
end

--- Publishes one committed mirror result exactly once.
--- @param exit_code integer Process exit code.
--- @param stdout string Process standard output.
--- @param stderr string Process standard error.
local function publish_mirror_result(exit_code, stdout, stderr)
	if exit_code ~= 0 then
		Logger.error(LOG, "toggle_display_mirror: Python exited with code %s — %s.",
			tostring(exit_code), (tostring(stderr):gsub("%s+$", "")))
		return
	end
	local result = (stdout or ""):match("(%S+)")
	if result == "mirror_enabled" then
		Logger.success(LOG, "Display mirroring enabled.")
	elseif result == "mirror_disabled" then
		Logger.success(LOG, "Display mirroring disabled.")
	elseif result == "single_screen" then
		Logger.info(LOG, "Display mirror toggle: single screen — nothing to do.")
	else
		Logger.error(LOG, "toggle_display_mirror: unexpected Python output: '%s'.",
			(tostring(stdout):gsub("\n", " ")))
	end
end

--- Delivers a buffered terminal only after start committed and authority remains.
--- @param operation table Mirror operation.
--- @return boolean delivered
drain_mirror_terminal = function(operation)
	if operation.terminal_delivered == true then return true end
	if operation.terminal_seen ~= true or operation.starting == true
		or operation.start_committed ~= true then
		return false
	end
	operation.terminal_delivered = true
	local terminal = operation.pending_terminal or { n = 0 }
	operation.pending_terminal = nil
	if _mirror_operations[operation.parent] ~= operation
		or not mouse_operation_is_authorized(operation) then
		return true
	end
	return invoke_mouse_callback("Display mirror terminal", publish_mirror_result,
		table.unpack(terminal, 1, terminal.n))
end

--- Buffers one ShellRunner terminal and fences hostile duplicates.
--- @param operation table Mirror operation.
--- @param ... any ShellRunner terminal arguments.
local function receive_mirror_terminal(operation, ...)
	if operation.terminal_seen == true then
		Logger.debug(LOG, "Ignoring duplicate display mirror completion.")
		return
	end
	operation.terminal_seen = true
	operation.pending_terminal = table.pack(...)
	if operation.starting ~= true and operation.start_committed == true then
		drain_mirror_terminal(operation)
	end
	release_mirror_if_settled(operation)
end

--- Registers the exact ShellRunner settlement observer before start dispatch.
--- @param operation table Mirror operation.
--- @return boolean registered
local function observe_mirror_settlement(operation)
	if operation.observing == true then return true end
	if type(operation.handle) ~= "table"
		or type(operation.handle.onSettled) ~= "function" then
		return false
	end
	operation.observing = true
	local ok, registered = xpcall(function()
		return operation.handle.onSettled(function()
			operation.settled = true
			if operation.start_committed == true then drain_mirror_terminal(operation) end
			release_mirror_if_settled(operation)
		end)
	end, debug.traceback)
	if not ok or registered ~= true then
		operation.observing = false
		Logger.error(LOG, "Display mirror settlement observer refused — %s.",
			tostring(ok and registered or registered))
		return false
	end
	return true
end

--- Terminates the same mirror handle until its settlement is proven.
--- @param operation table Mirror operation.
--- @param boundary string Diagnostic lifecycle boundary.
--- @return boolean settled
local function settle_mirror_operation(operation, boundary)
	if not operation or _mirror_operations[operation.parent] ~= operation then return true end
	operation.authorized = false
	if release_mirror_if_settled(operation) then return true end
	if type(operation.handle) ~= "table"
		or type(operation.handle.terminate) ~= "function" then
		Logger.error(LOG, "%s cannot terminate the display mirror process.",
			tostring(boundary))
		return false
	end
	local ok, accepted, state = xpcall(operation.handle.terminate, debug.traceback)
	if release_mirror_if_settled(operation) then return true end
	observe_mirror_settlement(operation)
	if not ok or accepted ~= true or state ~= "settled" then
		Logger.error(LOG, "%s retained the exact display mirror process: %s (%s).",
			tostring(boundary), tostring(ok and accepted or accepted), tostring(state))
	end
	return false
end

--- Constructs, publishes, observes, and then starts the mirror process.
--- @param operation table Mirror operation published by the public action.
--- @param tmpfile string Python source path.
--- @return boolean committed
local function start_mirror_process(operation, tmpfile)
	operation.acquiring = true
	local call_ok, handle_or_error = xpcall(function()
		return ShellRunner.spawn(PYTHON_BIN, { tmpfile }, function(...)
			receive_mirror_terminal(operation, ...)
		end)
	end, debug.traceback)
	operation.acquiring = false
	operation.acquisition_finished = true
	if call_ok and type(handle_or_error) == "table" then
		operation.handle = handle_or_error
	end
	if not call_ok or type(operation.handle) ~= "table"
		or type(operation.handle.start) ~= "function"
		or type(operation.handle.terminate) ~= "function"
		or type(operation.handle.isSettled) ~= "function"
		or type(operation.handle.onSettled) ~= "function" then
		operation.authorized = false
		settle_mirror_operation(operation, "display mirror construction rollback")
		release_mirror_if_settled(operation)
		Logger.error(LOG, "toggle_display_mirror: process construction failed — %s.",
			tostring(handle_or_error))
		return false
	end
	if not observe_mirror_settlement(operation) then
		settle_mirror_operation(operation, "display mirror observer rollback")
		return false
	end
	if _mirror_operations[operation.parent] ~= operation
		or not mouse_operation_is_authorized(operation) then
		settle_mirror_operation(operation, "display mirror pre-start rollback")
		return false
	end

	operation.starting = true
	local start_ok, started = xpcall(operation.handle.start, debug.traceback)
	operation.starting = false
	if not start_ok or started ~= true
		or _mirror_operations[operation.parent] ~= operation
		or not mouse_operation_is_authorized(operation) then
		operation.authorized = false
		settle_mirror_operation(operation, "display mirror start rollback")
		Logger.error(LOG, "toggle_display_mirror: process start refused — %s.",
			tostring(start_ok and started or started))
		return false
	end
	operation.start_committed = true
	drain_mirror_terminal(operation)
	release_mirror_if_settled(operation)
	return true
end



-- =========================================
-- ===== 1.2) Spotlight Resource Owner =====
-- =========================================

local cleanup_spotlight_operation

--- Tests whether a spotlight remains the current authorized identity.
--- @param operation table Spotlight operation.
--- @return boolean authorized
local function spotlight_is_authorized(operation)
	return _spotlight_operations[operation.parent] == operation
		and mouse_operation_is_authorized(operation)
end

--- Releases a terminal spotlight owner after every resource is gone.
--- @param operation table Spotlight operation.
--- @return boolean settled
local function release_spotlight_if_settled(operation)
	if _spotlight_operations[operation.parent] ~= operation then return true end
	if operation.acquisitions ~= 0
		or operation.arm_timer ~= nil or operation.timeout_timer ~= nil
		or operation.move_tap ~= nil or next(operation.canvases) ~= nil then
		return false
	end
	_spotlight_operations[operation.parent] = nil
	return true
end

--- Retires one exact timer slot after TimerScheduler proves settlement.
--- @param operation table Spotlight operation.
--- @param field string Owner field containing the slot.
--- @param slot table Timer slot identity.
local function retire_spotlight_timer(operation, field, slot)
	if operation[field] == slot then operation[field] = nil end
	slot.committed = false
	slot.settled = true
	release_spotlight_if_settled(operation)
end

--- Observes a timer retained after an accepted-pending or refused cancellation.
--- @param operation table Spotlight operation.
--- @param field string Owner field containing the slot.
--- @param slot table Timer slot identity.
--- @return boolean registered
local function observe_spotlight_timer(operation, field, slot)
	if slot.observing == true then return true end
	if type(slot.handle) ~= "table" then return false end
	slot.observing = true
	local ok, registered = xpcall(function()
		return TimerScheduler.onSettled(slot.handle, function()
			retire_spotlight_timer(operation, field, slot)
		end)
	end, debug.traceback)
	if not ok or registered ~= true then
		slot.observing = false
		Logger.error(LOG, "%s timer settlement observer refused — %s.",
			tostring(slot.label), tostring(ok and registered or registered))
		return false
	end
	return true
end

--- Cancels one exact timer and retains the same slot on refusal.
--- @param operation table Spotlight operation.
--- @param field string Owner field containing the slot.
--- @return boolean settled
local function cancel_spotlight_timer(operation, field)
	local slot = operation[field]
	if not slot then return true end
	slot.discard = true
	slot.committed = false
	if type(slot.handle) ~= "table" then
		if slot.acquiring == true then return false end
		retire_spotlight_timer(operation, field, slot)
		return true
	end
	local ok, settled = xpcall(function()
		return TimerScheduler.cancel(slot.handle)
	end, debug.traceback)
	if ok and settled == true then
		retire_spotlight_timer(operation, field, slot)
		return true
	end
	observe_spotlight_timer(operation, field, slot)
	Logger.error(LOG, "%s timer cleanup retained the exact handle — %s.",
		tostring(slot.label), tostring(ok and settled or settled))
	return false
end

--- Schedules one spotlight timer with buffered acquisition and exact settlement.
--- @param operation table Spotlight operation.
--- @param field string Owner field for the timer slot.
--- @param delay number Delay in seconds.
--- @param label string Diagnostic timer label.
--- @param callback function Authorized business callback.
--- @return boolean committed
local function schedule_spotlight_timer(operation, field, delay, label, callback)
	if not spotlight_is_authorized(operation) or operation[field] ~= nil then return false end
	local slot = {
		id = next_mouse_owner_id(),
		label = label,
		committed = false,
		discard = false,
		due = false,
		delivered = false,
		acquiring = true,
	}
	operation[field] = slot
	local function deliver_due()
		if slot.delivered == true or slot.acquiring == true then return end
		slot.delivered = true
		if slot.committed == true and slot.discard ~= true
			and spotlight_is_authorized(operation) then
			invoke_mouse_callback(label, callback)
		end
	end
	local call_ok, handle, committed = xpcall(function()
		return TimerScheduler.after(delay, function()
			slot.due = true
			deliver_due()
		end)
	end, debug.traceback)
	slot.acquiring = false
	if call_ok and type(handle) == "table" then slot.handle = handle end
	if not call_ok or type(slot.handle) ~= "table" or committed ~= true
		or not spotlight_is_authorized(operation) then
		slot.discard = true
		cancel_spotlight_timer(operation, field)
		Logger.error(LOG, "%s timer acquisition refused — %s.",
			tostring(label), tostring(call_ok and committed or handle))
		return false
	end
	slot.committed = true
	if slot.due == true then deliver_due() end
	return true
end

--- Stops the exact mouse watcher and retains every refusal for retry.
--- @param operation table Spotlight operation.
--- @param boundary string Diagnostic lifecycle boundary.
--- @return boolean settled
local function release_spotlight_tap(operation, boundary)
	local tap = operation.move_tap
	if not tap then return true end
	local ok, result_or_error = xpcall(function()
		if type(tap.stop) ~= "function" then error("mouse eventtap has no stop method") end
		local result = tap:stop()
		if result == nil or result == false then return result end
		if type(tap.isEnabled) ~= "function" then error("mouse eventtap has no state probe") end
		if tap:isEnabled() ~= false then return false end
		return true
	end, debug.traceback)
	if not ok or result_or_error ~= true or operation.tap_starting == true then
		Logger.error(LOG, "%s retained the exact spotlight eventtap — %s.",
			tostring(boundary), tostring(result_or_error))
		return false
	end
	if operation.move_tap == tap then operation.move_tap = nil end
	return true
end

--- Deletes one exact spotlight canvas after its native call returns normally.
--- @param operation table Spotlight operation.
--- @param entry table Canvas owner identity.
--- @param boundary string Diagnostic lifecycle boundary.
--- @return boolean settled
local function release_spotlight_canvas(operation, entry, boundary)
	if operation.canvases[entry.id] ~= entry then return true end
	local ok, result_or_error = xpcall(function()
		if type(entry.canvas.delete) ~= "function" then error("canvas has no delete method") end
		local result = entry.canvas:delete()
		-- The native canvas contract returns nil on success. Explicit false is a
		-- refusal, while a non-throwing nil is accepted only when visibility is
		-- observably gone
		if result == false then return false end
		if type(entry.canvas.isShowing) ~= "function" then
			error("canvas has no visibility probe")
		end
		if entry.canvas:isShowing() ~= false then return false end
		return true
	end, debug.traceback)
	if not ok or result_or_error ~= true or entry.activating == true then
		Logger.error(LOG, "%s retained spotlight canvas '%s' — %s.",
			tostring(boundary), tostring(entry.label), tostring(result_or_error))
		return false
	end
	if operation.canvases[entry.id] == entry then operation.canvases[entry.id] = nil end
	return true
end

--- Fences and releases all spotlight resources without short-circuiting siblings.
--- @param operation table Spotlight operation.
--- @param boundary string Diagnostic lifecycle boundary.
--- @return boolean settled
cleanup_spotlight_operation = function(operation, boundary)
	if not operation or _spotlight_operations[operation.parent] ~= operation then return true end
	operation.authorized = false
	local arm_settled = cancel_spotlight_timer(operation, "arm_timer")
	local timeout_settled = cancel_spotlight_timer(operation, "timeout_timer")
	local tap_settled = release_spotlight_tap(operation, boundary)
	local canvases_settled = true
	local canvas_snapshot = {}
	for _, entry in pairs(operation.canvases) do
		canvas_snapshot[#canvas_snapshot + 1] = entry
	end
	for _, entry in ipairs(canvas_snapshot) do
		if release_spotlight_canvas(operation, entry, boundary) ~= true then
			canvases_settled = false
		end
	end
	local owner_settled = release_spotlight_if_settled(operation)
	if arm_settled ~= true or timeout_settled ~= true or tap_settled ~= true
		or canvases_settled ~= true or owner_settled ~= true then
		Logger.error(LOG, "%s left exact spotlight cleanup debt.", tostring(boundary))
		return false
	end
	Logger.debug(LOG, "Mouse spotlight dismissed.")
	return true
end





-- ============================================
-- ============================================
-- ======= 2/ Mouse & Display Utilities =======
-- ============================================
-- ============================================

--- Teleports the mouse cursor to the center of the next screen (cycles through all screens).
--- Shows a 1-second spotlight at the destination so the cursor is easy to locate.
--- Notifies the user when only one screen is available.
--- @return boolean committed
function M.teleport_mouse(parent)
	local admitted, scope = mouse_action_admission_open("Mouse teleport", parent)
	if not admitted then return false end
	local ok_cur, current = pcall(hs.mouse.getCurrentScreen)
	if not ok_cur or not current then
		Logger.warn(LOG, "teleport_mouse: could not determine current screen.")
		return false
	end

	local ok_screens, all = pcall(hs.screen.allScreens)
	if not ok_screens or type(all) ~= "table" then
		Logger.error(LOG, "teleport_mouse: could not enumerate screens.")
		return false
	end
	if #all < 2 then
		notifications.notify(i18n.get("shortcuts.no_other_monitor"), nil, "warning")
		Logger.info(LOG, "teleport_mouse: single screen — nothing to do.")
		return true
	end

	-- Find the next screen in the list, wrapping around
	local target     = nil
	local current_id = current:id()
	for i, s in ipairs(all) do
		if s:id() == current_id then
			target = all[(i % #all) + 1]
			break
		end
	end
	if not target then target = all[1] end

	local f = target:frame()
	local move_ok, moved, current_after_move = invoke_mouse_native_boundary(scope,
		function()
			return MouseControl.setPos(
				f.x + math.floor(f.w / 2),
				f.y + math.floor(f.h / 2)
			)
		end)

	if move_ok and moved == true and current_after_move then
		Logger.info(LOG, "Mouse teleported to screen '%s'.", target:name() or "unknown")
		-- Brief spotlight so the cursor is immediately visible at its new location
		return M.spotlight_mouse(SPOTLIGHT_TELEPORT_DURATION_S, scope.id) == true
	else
		Logger.error(LOG, "teleport_mouse: failed to set mouse position.")
	end
	return false
end

--- Locks the screen immediately using the system screensaver engine.
--- @return boolean committed
function M.lock_screen(parent)
	local admitted, scope = mouse_action_admission_open("Screen lock", parent)
	if not admitted then return false end
	Logger.start(LOG, "Locking screen…")
	local ok, result_or_error, current = invoke_mouse_native_boundary(scope,
		hs.caffeinate.lockScreen)
	if ok and current then
		Logger.success(LOG, "Screen locked.")
		return true
	else
		Logger.error(LOG, "lock_screen: failed — %s.", tostring(result_or_error))
	end
	return false
end

--- Opens the macOS Character Viewer (emoji picker) via the system shortcut.
--- Mirrors Windows' native Win + . behaviour for cross-platform parity.
--- @return boolean committed
function M.open_emoji_picker(parent)
	local admitted, scope = mouse_action_admission_open("Emoji picker", parent)
	if not admitted then return false end
	Logger.start(LOG, "Opening emoji picker…")
	local ok, result_or_error, current = invoke_mouse_native_boundary(scope, function()
		return SyntheticInput.emit_key_stroke({"ctrl", "cmd"}, "space", 0)
	end)
	if ok and result_or_error == true and current then
		Logger.success(LOG, "Emoji picker triggered.")
		return true
	else
		Logger.error(LOG, "open_emoji_picker: failed — %s.", tostring(result_or_error))
	end
	return false
end

--- Toggles display mirroring using CoreGraphics via an inline Python script.
--- CGBeginDisplayConfiguration / CGConfigureDisplayMirrorOfDisplay are the
--- official public APIs for this; the hs.eventtap Cmd+F1 approach is unreliable
--- because macOS maps that shortcut through the media-key layer, which Hammerspoon
--- cannot dependably replicate.
--- @return boolean committed
function M.toggle_display_mirror(parent)
	local admitted, scope = mouse_action_admission_open("Display mirror toggle", parent)
	if not admitted then return false end
	if _mirror_operations[scope.id] ~= nil then
		Logger.warn(LOG, "Display mirror toggle refused while an earlier toggle remains owned.")
		return false
	end
	Logger.start(LOG, "Toggling display mirror via CoreGraphics…")
	local operation = {
		id = next_mouse_owner_id(),
		parent = scope.id,
		scope = scope,
		generation = scope.generation,
		authorized = true,
		acquiring = false,
		acquisition_finished = false,
		starting = false,
		start_committed = false,
		terminal_seen = false,
		terminal_delivered = false,
		settled = false,
	}
	_mirror_operations[scope.id] = operation

	local py = [[
import ctypes, sys
CG = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
cg = ctypes.cdll.LoadLibrary(CG)
cg.CGGetOnlineDisplayList.restype = ctypes.c_int32
cg.CGMainDisplayID.restype        = ctypes.c_uint32
cg.CGDisplayIsInMirrorSet.restype = ctypes.c_bool
MAX = 16
n   = ctypes.c_uint32(0)
ids = (ctypes.c_uint32 * MAX)()
cg.CGGetOnlineDisplayList(MAX, ids, ctypes.byref(n))
count = n.value
if count < 2:
    print("single_screen")
    sys.exit(0)
main      = cg.CGMainDisplayID()
mirroring = any(cg.CGDisplayIsInMirrorSet(ids[i]) for i in range(count) if ids[i] != main)
cfg = ctypes.c_void_p()
cg.CGBeginDisplayConfiguration(ctypes.byref(cfg))
if mirroring:
    for i in range(count):
        if ids[i] != main:
            cg.CGConfigureDisplayMirrorOfDisplay(cfg, ids[i], 0)
    cg.CGCompleteDisplayConfiguration(cfg, 1)
    print("mirror_disabled")
else:
    for i in range(count):
        if ids[i] != main:
            cg.CGConfigureDisplayMirrorOfDisplay(cfg, ids[i], main)
    cg.CGCompleteDisplayConfiguration(cfg, 1)
    print("mirror_enabled")
]]

	local tmpfile  = "/tmp/_hs_mirror_toggle.py"
	local ok_write, write_result = pcall(function()
		local f = io.open(tmpfile, "w")
		if not f then error("io.open failed") end
		local wrote, write_error = f:write(py)
		if not wrote then
			pcall(function() f:close() end)
			error(write_error or "file write refused")
		end
		local closed, close_error = f:close()
		if closed ~= true then error(close_error or "file close refused") end
		return true
	end)
	if not ok_write or write_result ~= true then
		operation.authorized = false
		operation.acquisition_finished = true
		release_mirror_if_settled(operation)
		Logger.error(LOG, "toggle_display_mirror: could not write Python script to temp file.")
		return false
	end

	-- Asynchronous: a Python interpreter start plus a display-configuration round
	-- trip is hundreds of milliseconds, and this runs from a shortcut — the
	-- blocking form froze every keystroke for that whole window.
	return start_mirror_process(operation, tmpfile)
end

--- Publishes one canvas before showing it so every partial acquisition is owned.
--- @param operation table Spotlight operation.
--- @param label string Diagnostic canvas label.
--- @param frame table Canvas frame.
--- @param element table Canvas element.
--- @return boolean committed
local function acquire_spotlight_canvas(operation, label, frame, element)
	if not spotlight_is_authorized(operation) then return false end
	operation.acquisitions = operation.acquisitions + 1
	local create_ok, canvas_or_error = xpcall(function()
		return hs.canvas.new(frame)
	end, debug.traceback)
	if create_ok and canvas_or_error ~= nil and canvas_or_error ~= false then
		local entry = {
			id = next_mouse_owner_id(),
			label = label,
			canvas = canvas_or_error,
			activating = true,
		}
		operation.canvases[entry.id] = entry
		operation.acquisitions = operation.acquisitions - 1
		if not spotlight_is_authorized(operation) then
			entry.activating = false
			return false
		end
		local configure_ok, configured = xpcall(function()
			canvas_or_error[1] = element
			if not spotlight_is_authorized(operation) then return false end
			local level_result = canvas_or_error:level(hs.canvas.windowLevels.overlay)
			if level_result == nil or level_result == false
				or not spotlight_is_authorized(operation) then
				return false
			end
			local show_result = canvas_or_error:show()
			if show_result == nil or show_result == false
				or not spotlight_is_authorized(operation) then
				return false
			end
			if type(canvas_or_error.isShowing) ~= "function" then
				error("canvas has no visibility probe")
			end
			return canvas_or_error:isShowing()
		end, debug.traceback)
		entry.activating = false
		if not configure_ok or configured ~= true then
			Logger.error(LOG, "spotlight_mouse: failed to show %s canvas — %s.",
				tostring(label), tostring(configured))
			return false
		end
		return true
	end
	operation.acquisitions = operation.acquisitions - 1
	if not create_ok or canvas_or_error == nil or canvas_or_error == false then
		Logger.error(LOG, "spotlight_mouse: failed to create %s canvas — %s.",
			tostring(label), tostring(canvas_or_error))
		return false
	end
	return false
end

--- Builds and shows one red × marker under the common spotlight owner.
--- @param operation table Spotlight operation.
--- @param screen userdata Screen receiving the cross.
--- @return boolean committed
local function create_cross_canvas(operation, screen)
	local frame_ok, f = xpcall(function() return screen:frame() end, debug.traceback)
	if not frame_ok or type(f) ~= "table" then
		Logger.error(LOG, "spotlight_mouse: could not read a cross screen frame.")
		return false
	end
	local H    = CROSS_ARM_HALF_PX
	local W    = CROSS_ARM_WIDTH_PX
	local pad  = CROSS_PADDING_PX
	local hw   = W / 2
	local side = H * 2 + pad * 2
	local cx   = f.x + math.floor((f.w - side) / 2)
	local cy   = f.y + math.floor((f.h - side) / 2)

	local ox  = side / 2
	local oy  = side / 2
	local sq2 = math.sqrt(2)

	-- Each × arm points along a 45° diagonal. Its tip edges remain perpendicular
	-- so the marker keeps flat square ends at every display scale
	local tip_far  = (H + hw) / sq2
	local tip_near = (H - hw) / sq2
	local concave  = hw * sq2

	local points = {
		{x = ox + tip_near, y = oy - tip_far },
		{x = ox + tip_far,  y = oy - tip_near},
		{x = ox + concave,  y = oy            },
		{x = ox + tip_far,  y = oy + tip_near},
		{x = ox + tip_near, y = oy + tip_far },
		{x = ox,            y = oy + concave  },
		{x = ox - tip_near, y = oy + tip_far },
		{x = ox - tip_far,  y = oy + tip_near},
		{x = ox - concave,  y = oy            },
		{x = ox - tip_far,  y = oy - tip_near},
		{x = ox - tip_near, y = oy - tip_far },
		{x = ox,            y = oy - concave  },
	}

	return acquire_spotlight_canvas(operation, "cross", {
		x = cx,
		y = cy,
		w = side,
		h = side,
	}, {
		type = "segments",
		closed = true,
		action = "strokeAndFill",
		fillColor = {
			red = CROSS_COLOR.red,
			green = CROSS_COLOR.green,
			blue = CROSS_COLOR.blue,
			alpha = CROSS_FILL_ALPHA,
		},
		strokeColor = {
			red = CROSS_COLOR.red,
			green = CROSS_COLOR.green,
			blue = CROSS_COLOR.blue,
			alpha = OVERLAY_STROKE_ALPHA,
		},
		strokeWidth = CROSS_STROKE_PX,
		coordinates = points,
	})
end

--- Constructs and starts the mouse-move watcher after the warp grace period.
--- @param operation table Spotlight operation.
--- @return boolean committed
local function arm_spotlight_move_tap(operation)
	if not spotlight_is_authorized(operation) then return false end
	operation.acquisitions = operation.acquisitions + 1
	local create_ok, tap_or_error = xpcall(function()
		return hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function()
			if spotlight_is_authorized(operation) then
				cleanup_spotlight_operation(operation, "spotlight mouse movement")
			end
			return false
		end)
	end, debug.traceback)
	if create_ok and tap_or_error ~= nil and tap_or_error ~= false then
		operation.move_tap = tap_or_error
	end
	operation.acquisitions = operation.acquisitions - 1
	if not create_ok or tap_or_error == nil or tap_or_error == false then
		if not spotlight_is_authorized(operation) then
			cleanup_spotlight_operation(operation, "spotlight eventtap construction rollback")
			return false
		end
		Logger.warn(LOG, "spotlight_mouse: could not create move watcher — timeout only.")
		return true
	end
	if not spotlight_is_authorized(operation) then
		cleanup_spotlight_operation(operation, "spotlight eventtap pre-start rollback")
		return false
	end

	operation.tap_starting = true
	local start_ok, started = xpcall(function()
		if type(tap_or_error.start) ~= "function" then
			error("mouse eventtap has no start method")
		end
		local start_result = tap_or_error:start()
		if start_result == nil or start_result == false then return false end
		if type(tap_or_error.isEnabled) ~= "function" then
			error("mouse eventtap has no state probe")
		end
		return tap_or_error:isEnabled()
	end, debug.traceback)
	operation.tap_starting = false
	if not start_ok or started ~= true or not spotlight_is_authorized(operation) then
		operation.authorized = false
		cleanup_spotlight_operation(operation, "spotlight eventtap start rollback")
		Logger.error(LOG, "spotlight_mouse: move watcher start refused — %s.",
			tostring(started))
		return false
	end
	return true
end

--- Shows a yellow filled ring and red cross markers under one exact owner.
--- @param duration_s number|nil Override for the auto-dismiss delay.
--- @return boolean committed
function M.spotlight_mouse(duration_s, parent)
	local admitted, scope = mouse_action_admission_open("Mouse spotlight", parent)
	if not admitted then return false end
	local prior_spotlight = _spotlight_operations[scope.id]
	if prior_spotlight ~= nil
		and cleanup_spotlight_operation(prior_spotlight,
			"spotlight replacement") ~= true then
		return false
	end

	local operation = {
		id = next_mouse_owner_id(),
		parent = scope.id,
		scope = scope,
		generation = scope.generation,
		authorized = true,
		acquisitions = 0,
		canvases = {},
		arm_timer = nil,
		timeout_timer = nil,
		move_tap = nil,
	}
	_spotlight_operations[scope.id] = operation
	local duration = type(duration_s) == "number" and duration_s > 0
		and duration_s or SPOTLIGHT_DURATION_S
	local position_ok, position = xpcall(hs.mouse.absolutePosition, debug.traceback)
	if not position_ok or type(position) ~= "table"
		or type(position.x) ~= "number" or type(position.y) ~= "number" then
		operation.authorized = false
		cleanup_spotlight_operation(operation, "spotlight position rollback")
		Logger.error(LOG, "spotlight_mouse: failed to read mouse position.")
		return false
	end

	local radius = SPOTLIGHT_RADIUS_PX
	local padding = SPOTLIGHT_PADDING_PX
	local diameter = radius * 2
	if not acquire_spotlight_canvas(operation, "circle", {
		x = math.floor(position.x) - radius - padding,
		y = math.floor(position.y) - radius - padding,
		w = diameter + padding * 2,
		h = diameter + padding * 2,
	}, {
		type = "oval",
		fillColor = {
			red = SPOTLIGHT_COLOR.red,
			green = SPOTLIGHT_COLOR.green,
			blue = SPOTLIGHT_COLOR.blue,
			alpha = SPOTLIGHT_FILL_ALPHA,
		},
		strokeColor = {
			red = SPOTLIGHT_COLOR.red,
			green = SPOTLIGHT_COLOR.green,
			blue = SPOTLIGHT_COLOR.blue,
			alpha = OVERLAY_STROKE_ALPHA,
		},
		strokeWidth = SPOTLIGHT_STROKE_PX,
		frame = { x = padding, y = padding, w = diameter, h = diameter },
	}) then
		operation.authorized = false
		cleanup_spotlight_operation(operation, "spotlight circle rollback")
		return false
	end

	local current_screen_id = nil
	local current_ok, current_screen = xpcall(hs.mouse.getCurrentScreen, debug.traceback)
	if current_ok and current_screen then
		local id_ok, screen_id = xpcall(function() return current_screen:id() end,
			debug.traceback)
		if id_ok then current_screen_id = screen_id end
	end
	local screens_ok, screens = xpcall(hs.screen.allScreens, debug.traceback)
	if not screens_ok or type(screens) ~= "table" then
		operation.authorized = false
		cleanup_spotlight_operation(operation, "spotlight screen inventory rollback")
		Logger.error(LOG, "spotlight_mouse: failed to enumerate screens.")
		return false
	end
	local cross_count = 0
	for _, screen in ipairs(screens) do
		local id_ok, screen_id = xpcall(function() return screen:id() end,
			debug.traceback)
		if not id_ok then
			operation.authorized = false
			cleanup_spotlight_operation(operation, "spotlight screen identity rollback")
			return false
		end
		if screen_id ~= current_screen_id then
			if not create_cross_canvas(operation, screen) then
				operation.authorized = false
				cleanup_spotlight_operation(operation, "spotlight cross rollback")
				return false
			end
			cross_count = cross_count + 1
		end
	end

	Logger.debug(LOG,
		"Mouse spotlight shown at (%.0f, %.0f); %d cross(es); %.1fs duration.",
		position.x, position.y, cross_count, duration)
	if not schedule_spotlight_timer(operation, "arm_timer",
		SPOTLIGHT_TAP_DELAY_SEC, "Spotlight arm", function()
			arm_spotlight_move_tap(operation)
		end) then
		operation.authorized = false
		cleanup_spotlight_operation(operation, "spotlight arm rollback")
		return false
	end
	if not schedule_spotlight_timer(operation, "timeout_timer",
		duration, "Spotlight timeout", function()
			cleanup_spotlight_operation(operation, "spotlight timeout")
		end) then
		operation.authorized = false
		cleanup_spotlight_operation(operation, "spotlight timeout rollback")
		return false
	end
	return true
end





-- ========================================
-- ========================================
-- ======= 3/ Bindings Child Owner ========
-- ========================================
-- ========================================

--- Fences and joins every mirror and spotlight capability without short-circuiting.
--- @param boundary string Diagnostic lifecycle boundary.
--- @return boolean settled
local function settle_mouse_actions(boundary, parent)
	local scope = mouse_scope(parent)
	local mirror = _mirror_operations[scope.id]
	local spotlight = _spotlight_operations[scope.id]
	local mirror_settled = true
	local spotlight_settled = true
	if mirror then
		mirror.authorized = false
		mirror_settled = settle_mirror_operation(mirror, boundary)
	end
	if spotlight then
		spotlight.authorized = false
		spotlight_settled = cleanup_spotlight_operation(spotlight, boundary)
	end
	return scope.boundary_depth == 0
		and mirror_settled == true and spotlight_settled == true
		and _mirror_operations[scope.id] == nil
		and _spotlight_operations[scope.id] == nil
end

--- Closes admission before quiescing every native mouse/display owner.
--- @return boolean settled
function M.pause_mouse_actions(parent)
	local scope = mouse_scope(parent)
	if scope.paused ~= true then
		scope.paused = true
		scope.generation = scope.generation + 1
	end
	return settle_mouse_actions("mouse action pause", scope.id) == true
end

--- Reopens admission only after all pre-pause capabilities have settled.
--- Interrupted user actions are deliberately not replayed.
--- @return boolean settled
function M.resume_mouse_actions(parent)
	local scope = mouse_scope(parent)
	if scope.paused ~= true and not mouse_cleanup_debt(scope.id) then return true end
	if scope.paused ~= true then
		scope.paused = true
		scope.generation = scope.generation + 1
	end
	if settle_mouse_actions("mouse action resume cleanup", scope.id) ~= true then
		return false
	end
	scope.generation = scope.generation + 1
	scope.paused = false
	return true
end

--- Stops the child owner for Bindings.stop().
--- @return boolean settled
function M.stop_mouse_actions(parent)
	local scope = mouse_scope(parent)
	if scope.paused ~= true then
		scope.paused = true
		scope.generation = scope.generation + 1
	end
	return settle_mouse_actions("mouse action stop", scope.id) == true
end

--- Reports whether PAUSE currently closes mouse/display admission.
--- @return boolean paused
function M.is_mouse_actions_paused(parent)
	return mouse_scope(parent).paused == true
end

--- Reports active work and exact cleanup debt for lifecycle composition.
--- @return boolean pending
function M.has_pending_mouse_action(parent)
	local scope = mouse_scope(parent)
	return _mirror_operations[scope.id] ~= nil
		or _spotlight_operations[scope.id] ~= nil
		or scope.boundary_depth > 0
end

return M
