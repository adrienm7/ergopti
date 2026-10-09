--- modules/shortcuts/actions/system_pixel.lua

--- ==============================================================================
--- MODULE: Shortcuts — System Actions — Pixel Color & Screenshots
--- DESCRIPTION:
--- Pixel color copy and screenshot helpers extracted from system.lua.
--- Merged back into the system module table at load time.
---
--- FEATURES & RATIONALE:
--- 1. Pixel Sampling: Uses an inline Python PNG decoder to read per-pixel color
---    via screencapture, since Hammerspoon exposes no native pixel color API.
--- 2. Screenshot Wrapper: Spawns the native screencapture tool asynchronously
---    so the main thread is never blocked during a user-driven screenshot.
---    It captures to an owned file and announces success only after the image
---    is read back from the clipboard (see screen_capture_flow).
--- 3. Parent-scoped lifecycle: the fixed shortcuts run under the
---    "shortcut_bindings" parent and the gesture actions under "gestures", each
---    with its own admission generation, so pausing one feature never fences or
---    settles the other's work. One capture runs at a time, whatever its parent.
--- ==============================================================================

local M = {}

local hs            = hs
local pasteboard    = hs.pasteboard
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local FileSystem    = require("adapters.file_system")
local TaskLifecycle = require("adapters.task_lifecycle")
local PythonInterpreter = require("adapters.python_interpreter")
local CaptureFlow   = require("modules.shortcuts.actions.screen_capture_flow")

local LOG = "shortcuts.actions.system"

-- Absolute paths: the interactive layer must not inherit its binaries from PATH,
-- which differs between a login shell and the Hammerspoon process. The Python
-- is resolved per read by adapters.python_interpreter: only an interpreter this
-- Mac runs natively, never one macOS would start under Rosetta.
local SCREENCAPTURE_BIN = "/usr/sbin/screencapture"

-- GC root for live hs.task objects. A task not referenced from a GC root can be
-- collected mid-run, which kills the subprocess so its completion callback never
-- fires. Canonical spelling recognised by tests/unit/meta/test_gc_retention.lua;
-- entries are released when the callback runs or the launch is refused.
local _active_tasks = {}

-- The parent of a call that names none: the fixed shortcuts of bindings.lua.
local DEFAULT_ACTION_PARENT = "shortcut_bindings"

-- Pixel/screenshot work is a child of one parent lifecycle: the shortcut
-- bindings or the gesture actions. Each parent scope has its own logical
-- admission fence, closed before native termination, while this one slot
-- retains the exact task of whichever scope owns it until its completion
-- callback proves settlement.
local _current_operation = nil
local _next_operation_id = 0
local _pixel_scopes = {}

--- Resolves one parent-scoped admission state.
--- @param parent string|nil Stable action parent.
--- @return table scope
local function pixel_scope(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	local scope = _pixel_scopes[scope_id]
	if scope then return scope end
	scope = { id = scope_id, paused = false, generation = 0, terminal_depth = 0 }
	_pixel_scopes[scope_id] = scope
	return scope
end





-- ==============================================
-- ==============================================
-- ======= 1/ Exact Async Task Ownership ========
-- ==============================================
-- ==============================================

--- Tests whether one operation can still publish business effects.
--- @param operation table Operation identity.
--- @return boolean authorized
local function operation_is_authorized(operation)
	return operation.scope.paused ~= true
		and _current_operation == operation
		and operation.authorized == true
		and operation.generation == operation.scope.generation
end

--- Removes the exact capture file owned by one operation. A refused cleanup
--- remains attached to the operation and blocks every successor.
--- @param operation table Operation identity.
--- @return boolean settled
local function remove_temp_capture(operation)
	local path = operation.temp_path
	if type(path) ~= "string" or path == "" then return true end
	local call_ok, removed, detail = xpcall(
		FileSystem.remove_exact, debug.traceback, path)
	if call_ok == true and removed == true then
		operation.temp_path = nil
		return true
	end
	local classify_ok, _, status = xpcall(
		FileSystem.classify_no_follow, debug.traceback, path)
	if classify_ok == true and status == "absent" then
		operation.temp_path = nil
		return true
	end
	Logger.error(LOG, "Pixel capture cleanup retained '%s': %s.",
		path, tostring(call_ok == true and detail or removed))
	return false
end

--- Releases the logical operation after its exact native slot and capture file
--- are both gone.
--- @param operation table Operation identity.
--- @return boolean settled
local function finish_operation(operation)
	if _current_operation == operation and operation.slot == nil
		and operation.acquiring ~= true then
		operation.authorized = false
		if remove_temp_capture(operation) ~= true then return false end
		_current_operation = nil
	end
	return _current_operation ~= operation
end

--- Releases one exact native task identity after its terminal callback.
--- @param operation table Operation identity.
--- @param slot table Phase/task identity.
local function release_task_slot(operation, slot)
	_active_tasks[slot.task] = nil
	if operation.slot == slot then operation.slot = nil end
end

local drain_terminal

--- Receives one native terminal callback, buffering synchronous delivery until
--- TaskLifecycle.start() has committed the external acquisition.
--- @param operation table Operation identity.
--- @param slot table Phase/task identity.
--- @param ... any Native terminal arguments.
local function receive_terminal(operation, slot, ...)
	if slot.terminal_seen == true then
		Logger.debug(LOG, "Ignoring duplicate %s task completion.", tostring(slot.label))
		return
	end
	slot.terminal_seen = true
	slot.pending_terminal = table.pack(...)
	if slot.starting ~= true then drain_terminal(operation, slot) end
end

--- Delivers a buffered terminal exactly once after removing native ownership.
--- @param operation table Operation identity.
--- @param slot table Phase/task identity.
--- @return boolean handled
drain_terminal = function(operation, slot)
	if slot.terminal_delivered == true then return true end
	if slot.terminal_seen ~= true then return false end
	slot.terminal_delivered = true
	local terminal = slot.pending_terminal or { n = 0 }
	slot.pending_terminal = nil
	if slot.accepted ~= true or not operation_is_authorized(operation) then
		release_task_slot(operation, slot)
		finish_operation(operation)
		return true
	end

	slot.callback_active = true
	operation.scope.terminal_depth = operation.scope.terminal_depth + 1
	local callback_ok, callback_result = xpcall(function()
		return slot.on_terminal(table.unpack(terminal, 1, terminal.n))
	end, debug.traceback)
	operation.scope.terminal_depth = operation.scope.terminal_depth - 1
	slot.callback_active = false
	release_task_slot(operation, slot)
	if not callback_ok then
		Logger.error(LOG, "%s terminal handler raised: %s.", tostring(slot.label),
			tostring(callback_result))
	end
	finish_operation(operation)
	return callback_ok and callback_result ~= false
end

--- Best-effort probe used only to distinguish an unstarted task from an
--- ambiguous mutate-then-refuse start. Ambiguity remains owned fail-closed.
--- @param task table|userdata Native task.
--- @return boolean|nil running
local function task_running(task)
	local method_ok, method = pcall(function() return task.isRunning end)
	if not method_ok or type(method) ~= "function" then return nil end
	local probe_ok, running = xpcall(function() return method(task) end,
		debug.traceback)
	if not probe_ok or type(running) ~= "boolean" then return nil end
	return running
end

--- Requests termination without consuming the task before its callback proves
--- exit. false/nil/throw and accepted-but-pending all retain the same slot.
--- @param operation table Operation identity.
--- @param slot table Phase/task identity.
--- @param boundary string Diagnostic boundary.
--- @return boolean settled
local function terminate_task_slot(operation, slot, boundary)
	if slot.terminal_seen == true then
		if slot.starting == true or operation.acquiring == true then return false end
		drain_terminal(operation, slot)
		return operation.slot ~= slot
	end
	local method_ok, terminate_method = pcall(function() return slot.task.terminate end)
	if not method_ok or type(terminate_method) ~= "function" then
		Logger.error(LOG, "%s cannot terminate %s: native method unavailable.",
			tostring(boundary), tostring(slot.label))
		return false
	end
	local terminate_ok, terminate_result = xpcall(function()
		return terminate_method(slot.task)
	end, debug.traceback)
	if not terminate_ok or terminate_result == nil or terminate_result == false then
		Logger.error(LOG, "%s retained exact %s task after termination refusal: %s.",
			tostring(boundary), tostring(slot.label), tostring(terminate_result))
		return false
	end
	-- A hostile/native double may deliver synchronously from terminate().
	if slot.terminal_seen == true then
		if slot.starting == true or operation.acquiring == true then return false end
		drain_terminal(operation, slot)
		return operation.slot ~= slot
	end
	Logger.debug(LOG, "%s termination accepted for %s; awaiting terminal callback.",
		tostring(boundary), tostring(slot.label))
	return false
end

--- Starts one phase while preserving construction/start/terminal ordering.
--- @param operation table Operation identity.
--- @param label string Stable task label.
--- @param executable string Absolute executable path.
--- @param args table Native argv.
--- @param on_terminal function Business terminal, invoked only when authorized.
--- @return boolean accepted
local function start_task_phase(operation, label, executable, args, on_terminal)
	if not operation_is_authorized(operation) then return false end
	local slot = nil
	local preconstruction_terminal = nil
	local acquisition_generation = operation.scope.generation
	operation.acquiring = true
	local constructed, task = xpcall(TaskLifecycle.native, debug.traceback,
		label, executable, function(...)
		if not slot then
			if not preconstruction_terminal then
				preconstruction_terminal = table.pack(...)
			end
			return
		end
		receive_terminal(operation, slot, ...)
	end, args)
	operation.acquiring = false
	if not constructed or not task then
		operation.authorized = false
		finish_operation(operation)
		Logger.error(LOG, "%s task construction failed: %s.",
			tostring(label), tostring(task))
		return false
	end

	slot = {
		task = task,
		label = label,
		on_terminal = on_terminal,
		starting = true,
		accepted = false,
		terminal_seen = false,
		terminal_delivered = false,
	}
	operation.slot = slot
	_active_tasks[task] = true
	if preconstruction_terminal then
		slot.terminal_seen = true
		slot.pending_terminal = preconstruction_terminal
		slot.starting = false
		drain_terminal(operation, slot)
		Logger.error(LOG, "%s task completed during construction; acquisition rejected.",
			tostring(label))
		return false
	end
	if acquisition_generation ~= operation.scope.generation
		or not operation_is_authorized(operation) then
		-- PAUSE/STOP may synchronously re-enter TaskLifecycle.native(). Publish and
		-- pin the returned exact identity before settling it, but never call start()
		-- after the admission epoch was revoked.
		operation.authorized = false
		slot.starting = false
		if task_running(task) == false then
			release_task_slot(operation, slot)
			finish_operation(operation)
		else
			terminate_task_slot(operation, slot,
				label .. " construction rollback")
		end
		Logger.error(LOG, "%s task construction lost lifecycle admission.",
			tostring(label))
		return false
	end

	local start_generation = operation.scope.generation
	operation.acquiring = true
	local start_ok, start_result = xpcall(
		TaskLifecycle.start, debug.traceback, task, label)
	local started = start_ok and start_result == true
	operation.acquiring = false
	slot.starting = false
	if start_generation ~= operation.scope.generation
		or not operation_is_authorized(operation)
		or operation.slot ~= slot then
		operation.authorized = false
		-- A synchronous terminate callback observed while start() was on-stack is
		-- not terminal proof for mutations the hostile start may perform after that
		-- callback returns. Re-probe after the boundary; if still running/ambiguous,
		-- retire the stale terminal and request a fresh exact terminal.
		local running = task_running(task)
		if running == false then
			if slot.terminal_seen == true then
				drain_terminal(operation, slot)
			else
				release_task_slot(operation, slot)
				finish_operation(operation)
			end
		else
			if slot.terminal_seen == true then
				slot.terminal_seen = false
				slot.pending_terminal = nil
			end
			terminate_task_slot(operation, slot, label .. " superseded start rollback")
		end
		finish_operation(operation)
		Logger.error(LOG, "%s task start lost lifecycle admission.", tostring(label))
		return false
	end
	if started ~= true then
		operation.authorized = false
		if slot.terminal_seen == true then
			drain_terminal(operation, slot)
		elseif task_running(task) == false then
			-- A literal non-running probe proves that a clean refusal acquired no
			-- subprocess; only this branch may consume the pin without a terminal.
			_active_tasks[task] = nil
			if operation.slot == slot then operation.slot = nil end
			finish_operation(operation)
		else
			terminate_task_slot(operation, slot, label .. " start rollback")
		end
		Logger.error(LOG, "%s task failed to start.", tostring(label))
		return false
	end
	slot.accepted = true
	if slot.terminal_seen == true then drain_terminal(operation, slot) end
	return true
end

--- Creates one top-level user operation. Concurrent work and cleanup debt are
--- rejected rather than overlapped over an owned capture or clipboard sink,
--- whichever parent owns them.
--- @param scope table Parent scope of the operation.
--- @param label string Stable operation label.
--- @return table|nil operation
local function begin_operation(scope, label)
	if scope.paused == true then
		Logger.warn(LOG, "%s refused while pixel actions are paused.", tostring(label))
		return nil
	end
	if _current_operation then
		if _current_operation.authorized ~= true and _current_operation.slot then
			terminate_task_slot(_current_operation, _current_operation.slot,
				label .. " admission cleanup")
		elseif _current_operation.slot == nil
			and _current_operation.acquiring ~= true then
			finish_operation(_current_operation)
		end
		if not _current_operation then return begin_operation(scope, label) end
		Logger.warn(LOG, "%s refused while prior pixel work remains owned.", tostring(label))
		return nil
	end
	_next_operation_id = _next_operation_id + 1
	local operation = {
		id = _next_operation_id,
		label = label,
		scope = scope,
		generation = scope.generation,
		authorized = true,
		slot = nil,
		acquiring = false,
		temp_path = nil,
	}
	_current_operation = operation
	return operation
end

--- Closes one scope's admission and joins its current task without replaying
--- user work. A sibling scope's task is left untouched.
--- @param scope table Parent scope.
--- @param boundary string Diagnostic boundary.
--- @return boolean settled
local function quiesce(scope, boundary)
	if scope.paused ~= true then scope.generation = scope.generation + 1 end
	scope.paused = true
	local operation = _current_operation
	if not operation or operation.scope ~= scope then return scope.terminal_depth == 0 end
	if operation.authorized == true then
		Logger.warn(LOG, "%s cancelled by %s.", tostring(operation.label), tostring(boundary))
	end
	operation.authorized = false
	if not operation.slot then
		if operation.acquiring == true then return false end
		finish_operation(operation)
		return _current_operation == nil
	end
	return terminate_task_slot(operation, operation.slot, boundary) == true
		and _current_operation == nil and scope.terminal_depth == 0
end






-- =============================================
-- =============================================
-- ======= 2/ Pixel Color Implementation =======
-- =============================================
-- =============================================

--- Reads the hex color of the pixel at (x, y) via a minimal inline Python PNG decoder.
--- Captures a 3×3-pixel region and samples the center pixel.
--- Python is used because Hammerspoon has no native per-pixel color API.
---
--- The result arrives through a callback instead of a return value. This needs a
--- screencapture round trip AND a Python interpreter start — together well over a
--- tenth of a second — and it is triggered by a shortcut, so doing it
--- synchronously held the single Hammerspoon runloop for that whole window: no
--- keystroke was delivered, and a keyboard tap that misses its deadline is
--- disabled outright by macOS. The neighbouring interactive_screenshot in this
--- same file was already async for exactly this reason.
--- @param x number X screen coordinate.
--- @param y number Y screen coordinate.
--- @param on_hex function Called as on_hex(hex_or_nil) with "#a1b2c3" or nil.
local function pixel_hex_at(operation, x, y, on_hex)
	-- The interpreter first: without a native one nothing is captured or
	-- started, and the user is offered the install (hardening-h-no-rosetta).
	local python_bin, python_state = PythonInterpreter.resolve()
	if not python_bin then
		operation.authorized = false
		finish_operation(operation)
		require("ui.python_runtime_offer").offer(python_state)
		return false
	end
	local allocation_ok, tmpfile, allocation_detail = xpcall(
		FileSystem.create_secure_temp_file, debug.traceback)
	if allocation_ok ~= true or type(tmpfile) ~= "string" or tmpfile == "" then
		operation.authorized = false
		finish_operation(operation)
		Logger.error(LOG, "Pixel capture temporary-file allocation failed: %s.",
			tostring(allocation_ok == true and allocation_detail or tmpfile))
		return false
	end
	operation.temp_path = tmpfile
	local safe_x  = math.floor(tonumber(x) or 0) - 1
	local safe_y  = math.floor(tonumber(y) or 0) - 1

	-- argv, not a shell string: the region and the temp path are passed as
	-- separate arguments, so neither can be re-interpreted by /bin/sh.
	local region = string.format("%d,%d,3,3", safe_x, safe_y)

	-- Bare Python source: with argv there is no shell, so the `python3 -c "…"`
	-- wrapper and its quoting are gone and the interpreter receives the program
	-- exactly as written here.
	local py_src = [[
import struct,sys,zlib
try:
  data=open(sys.argv[1],'rb').read()
  w,h=struct.unpack('>II',data[16:24])
  ct=data[25];bpp=4 if ct==6 else 3
  i,chunks=8,b''
  while i<len(data)-12:
    l=struct.unpack('>I',data[i:i+4])[0];t=data[i+4:i+8]
    if t==b'IDAT':chunks+=data[i+8:i+8+l]
    elif t==b'IEND':break
    i+=l+12
  raw=zlib.decompress(chunks)
  cx=w//2;cy=h//2;off=cy*(1+w*bpp)+1+cx*bpp
  r,g,b=raw[off],raw[off+1],raw[off+2]
  print('#%02x%02x%02x' % (r,g,b))
except Exception:
  pass
]]

	return start_task_phase(operation, "Pixel screencapture", SCREENCAPTURE_BIN,
		{ "-x", "-t", "png", "-R", region, tmpfile }, function(cap_code)
		if cap_code ~= 0 then
			Logger.error(LOG, "screencapture exited with code %s — pixel read aborted.",
				tostring(cap_code))
			on_hex(nil)
			return true
		end
		return start_task_phase(operation, "Pixel extractor", python_bin,
			{ "-c", py_src, tmpfile }, function(py_code, stdout)
			local hex = (py_code == 0) and type(stdout) == "string"
				and stdout:match("(#%x%x%x%x%x%x)") or nil
			if hex then
				Logger.done(LOG, "Pixel color read — %s.", hex)
				on_hex(hex)
				return true
			end
			Logger.warn(LOG, "Python pixel extractor returned no valid hex code (exit %s).",
				tostring(py_code))
			on_hex(nil)
			return true
		end)
	end)
end

--- Reads the color of the pixel currently under the mouse cursor and copies it to the clipboard.
--- @param parent string|nil Stable action parent.
--- @return boolean accepted
function M.copy_pixel_color(parent)
	-- Without Screen Recording the capture omits every window, so the color of
	-- the desktop behind them would be copied as if it were the real pixel.
	if not CaptureFlow.ensure_permission("Pixel color read") then return false end
	local operation = begin_operation(pixel_scope(parent), "Pixel color read")
	if not operation then return false end
	Logger.trace(LOG, "Pixel color read started…")
	local ok, pos = pcall(hs.mouse.absolutePosition)
	if not ok or not pos then
		operation.authorized = false
		finish_operation(operation)
		Logger.error(LOG, "copy_pixel_color: failed to read mouse position.")
		return false
	end

	return pixel_hex_at(operation, math.floor(pos.x), math.floor(pos.y), function(hex)
		if not hex then
			notifications.notify(i18n.get("shortcuts.pixel_read_error"), nil, "error")
			return
		end

		local ok_write, write_result = pcall(pasteboard.setContents, hex)
		if not ok_write or write_result ~= true then
			Logger.error(LOG, "Pixel color clipboard write failed — %s.", tostring(write_result))
			notifications.notify(i18n.get("shortcuts.pixel_read_error"), nil, "error")
			return
		end
		notifications.notify(string.format(i18n.get("shortcuts.color_copied"), hex), nil, "success")
	end)
end





-- =========================================
-- =========================================
-- ======= 3/ Interactive Screenshot =======
-- =========================================
-- =========================================

--- Launches the native macOS interactive screenshot tool and copies the result to the clipboard.
--- The capture goes to an owned temporary file rather than `-c`: the file is
--- the proof that an image exists, and the clipboard is filled from it and read
--- back before success is announced.
--- @param parent string|nil Stable action parent.
--- @return boolean accepted True when the capture process was started.
function M.interactive_screenshot(parent)
	if not CaptureFlow.ensure_permission("Interactive screenshot") then return false end
	local operation = begin_operation(pixel_scope(parent), "Interactive screenshot")
	if not operation then return false end
	Logger.trace(LOG, "Interactive screenshot started…")
	local allocation_ok, tmpfile, allocation_detail = xpcall(
		FileSystem.create_secure_temp_file, debug.traceback)
	if allocation_ok ~= true or type(tmpfile) ~= "string" or tmpfile == "" then
		operation.authorized = false
		finish_operation(operation)
		Logger.error(LOG, "Interactive screenshot temporary-file allocation failed: %s.",
			tostring(allocation_ok == true and allocation_detail or tmpfile))
		notifications.notify(i18n.get("shortcuts.screenshot_failed"), nil, "error")
		return false
	end
	operation.temp_path = tmpfile
	local mark = CaptureFlow.clipboard_mark()
	return start_task_phase(operation, "Interactive screenshot", SCREENCAPTURE_BIN,
		-- -t png: the temp file has no extension and the user's screenshot
		-- format preference may name one the clipboard image cannot load.
		{ "-i", "-t", "png", tmpfile },
		function(exit_code, _, stderr)
			local outcome, detail = CaptureFlow.settle({
				path = tmpfile,
				mark = mark,
				exit_code = exit_code,
				stderr = stderr,
				interactive = true,
				destination = "clipboard",
			})
			if outcome == CaptureFlow.OUTCOME_COPIED then
				notifications.notify(i18n.get("shortcuts.screenshot_copied"), nil, "success")
				Logger.done(LOG, "Interactive screenshot copied to the clipboard.")
			elseif outcome == CaptureFlow.OUTCOME_CANCELLED then
				Logger.info(LOG, "Interactive screenshot cancelled (exit code %s).",
					tostring(exit_code))
			else
				Logger.error(LOG, "Interactive screenshot failed: %s.", tostring(detail))
				notifications.notify(i18n.get("shortcuts.screenshot_clipboard_failed"), nil, "error")
			end
			return true
		end)
end





-- ========================================
-- ========================================
-- ======= 4/ Bindings Child Owner ========
-- ========================================
-- ========================================

--- Fences and joins one parent's pixel/screenshot work for a PAUSE attempt.
--- @param parent string|nil Stable action parent.
--- @return boolean settled
function M.pause_pixel_actions(parent)
	return quiesce(pixel_scope(parent), "pixel action pause") == true
end

--- Reopens a parent's admission only after its exact native task has
--- terminated. User actions interrupted by pause are deliberately not replayed.
--- @param parent string|nil Stable action parent.
--- @return boolean settled
function M.resume_pixel_actions(parent)
	local scope = pixel_scope(parent)
	local operation = _current_operation
	if operation and operation.scope == scope then
		operation.authorized = false
		if not operation.slot
			or terminate_task_slot(operation, operation.slot,
				"pixel action resume cleanup") ~= true
			or _current_operation ~= nil then
			scope.paused = true
			return false
		end
	end
	scope.generation = scope.generation + 1
	scope.paused = false
	return true
end

--- Stops the child owner for Bindings.stop(). A later Bindings.start() may call
--- resume_pixel_actions() after this exact cleanup has settled.
--- @param parent string|nil Stable action parent.
--- @return boolean settled
function M.stop_pixel_actions(parent)
	return quiesce(pixel_scope(parent), "pixel action stop") == true
end

--- Diagnostic state for lifecycle composition/tests.
--- @param parent string|nil Stable action parent.
--- @return boolean paused
function M.is_pixel_actions_paused(parent)
	return pixel_scope(parent).paused == true
end

--- Diagnostic ownership query; true includes termination debt.
--- @param parent string|nil Stable action parent.
--- @return boolean pending
function M.has_pending_pixel_action(parent)
	local scope = pixel_scope(parent)
	return (_current_operation ~= nil and _current_operation.scope == scope)
		or scope.terminal_depth ~= 0
end

return M
