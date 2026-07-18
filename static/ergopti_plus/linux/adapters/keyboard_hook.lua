--- adapters/keyboard_hook.lua

--- ==============================================================================
--- MODULE: KeyboardHook Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the KeyboardHook port contract defined in
--- static/ergopti_plus/_shared/core/ports/KeyboardHook.spec.js. Bridges the
--- domain-level on_char/on_key callbacks to the Linux input subsystem via
--- libinput debug-events (observe mode) or evtest --grab (intercept mode).
--- Delegates evdev struct decoding and keycode→character mapping to the
--- modules.hotstrings.input_reader module, and device discovery to
--- modules.hotstrings.device_finder.
---
--- FEATURES & RATIONALE:
--- 1. Dual mode: "observe" (intercept=false, default) reads from libinput
---    debug-events without consuming events; "intercept" (intercept=true)
---    calls evtest --grab which acquires EVIOCGRAB, suppressing delivery
---    to the desktop — required for tap-hold detection. Re-injection is
---    handled by the injector module via ydotool uinput.
--- 2. Subprocess architecture: the blocking evdev read loop runs in a
---    child process (libinput debug-events or evtest); the Lua daemon
---    reads parsed events line-by-line from a pipe, avoiding the need for
---    luv async I/O or native C bindings.
--- 3. Context tracking: refreshContext() calls getFocused() on the
---    WindowInfo adapter to update the cached {appId, windowTitle} context.
--- 4. Idempotent lifecycle: start() while already running is a no-op;
---    stop() while already stopped is safe. The subprocess is killed on stop.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.keyboard_hook"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Subprocess handle (io.popen pipe) for the evdev reader child process.
-- Nil when stopped; a file handle when running.
local _pipe     = nil

-- Callbacks set by the caller via M.start().
local _on_char      = nil   -- function(char_string, evdev_scancode)
local _on_key       = nil   -- function(key_name_string)
local _on_physical  = nil   -- function(evdev_scancode, key_name, char_or_nil)

-- Cached foreground window context (updated via refreshContext).
local _context  = { appId = "", windowTitle = "" }

-- Running flag — set after the subprocess is successfully launched.
local _running  = false

-- The device path resolved at start() time (e.g. "/dev/input/event3").
local _device   = nil

-- Layout name resolved at start() time ("qwerty" or "azerty").
local _layout   = "qwerty"

-- Intercept mode flag.
local _intercept = false

-- Modifier tracking — updated by _pump_one() on each KEY_DOWN/KEY_UP.
local _shift_held = false
local _ctrl_held  = false
local _alt_held   = false


-- =========================================
-- =========================================
-- ======= 2/ Input Reader Wiring ==========
-- =========================================
-- =========================================

-- Lazy-load the input_reader module (it loads keycode tables at require time).
local _input_reader = nil

local function _get_input_reader()
	if _input_reader then return _input_reader end
	local ok, mod = pcall(require, "modules.hotstrings.input_reader")
	if ok then
		_input_reader = mod
	else
		Logger.error(LOG, "Cannot load input_reader — keyboard hook will be inactive.")
	end
	return _input_reader
end


-- =========================================
-- =========================================
-- ======= 3/ Subprocess Management ========
-- =========================================
-- =========================================

--- Checks whether a binary is available on the system PATH.
--- @param binary_name string e.g. "libinput" or "evtest".
--- @return boolean
local function _binary_exists(binary_name)
	local check = io.popen("which " .. binary_name .. " 2>/dev/null", "r")
	if not check then return false end
	local result = check:read("*l")
	check:close()
	return result ~= nil and result ~= ""
end

--- Launches the evdev reader subprocess and begins piping events to callbacks.
--- Uses libinput debug-events for observe mode, evtest --grab for intercept.
local function _start_subprocess()
	local ir = _get_input_reader()
	if not ir then return false end

	-- Verify the required binary exists before shelling out.
	local binary = _intercept and "evtest" or "libinput"
	if not _binary_exists(binary) then
		Logger.error(LOG, "start_subprocess(): '%s' binary not found. Install %s.",
			binary, _intercept and "evtest" or "libinput-tools")
		return false
	end

	-- Build the shell command.
	local cmd
	if _intercept then
		-- evtest --grab acquires exclusive access (EVIOCGRAB).
		-- Output goes to stderr; redirect to stdout so we can read it.
		cmd = string.format("evtest --grab '%s' 2>&1", _device:gsub("'", "'\\''"))
	else
		-- libinput debug-events filters to a single device, outputs to stdout.
		cmd = string.format("libinput debug-events --device '%s' 2>/dev/null", _device:gsub("'", "'\\''"))
	end

	Logger.info(LOG, "Launching subprocess: %s", cmd)

	local ok, pipe = pcall(io.popen, cmd, "r")
	if not ok or not pipe then
		Logger.error(LOG, "start_subprocess(): io.popen failed — %s.", tostring(pipe))
		return false
	end

	_pipe = pipe
	return true
end

--- Kills the evdev reader subprocess.
local function _stop_subprocess()
	if _pipe then
		Logger.debug(LOG, "Closing evdev reader subprocess.")
		-- Force-close the pipe; the child process receives SIGPIPE.
		pcall(function() _pipe:close() end)
		_pipe = nil
	end
end


-- =========================================
-- =========================================
-- ======= 4/ Event Parsing ================
-- =========================================
-- =========================================

-- libinput debug-events output format:
--   event3  KEYBOARD_KEY  +1.234s  KEY_A (30) pressed
--   event3  KEYBOARD_KEY  +1.456s  KEY_A (30) released
--
-- evtest output format (stderr, redirected to stdout via 2>&1):
--   Event: time 123.456, type 1 (EV_KEY), code 30 (KEY_A), value 1

-- The KEY_NAME → integer code map and the hardcoded layout tables that used to
-- live here were removed. The layout tables were triplicated copies of
-- _shared/data/keycodes/evdev.json (already loaded by input_reader). Character
-- resolution now delegates to input_reader.resolve_char() — single source

--- Extracts the keycode from a libinput line.
--- e.g. "event3  KEYBOARD_KEY  +1.234s  KEY_A (30) pressed" → 30
local function _parse_libinput_line(line)
	local name, code = line:match("KEYBOARD_KEY%s+%S+%s+KEY_(%w+)%s+%((%d+)%)")
	if name then
		local value = line:match("pressed$") and "down" or (line:match("released$") and "up" or nil)
		return { name = "KEY_" .. name, code = tonumber(code), value = value }
	end
	return nil
end

--- Extracts the keycode from an evtest line.
--- e.g. "Event: time 123.456, type 1 (EV_KEY), code 30 (KEY_A), value 1"
local function _parse_evtest_line(line)
	local code, name = line:match("code%s+(%d+)%s+%(KEY_(%w+)%)")
	if code then
		local value = line:match("value%s+(%d+)")
		local val_name = value == "1" and "down" or (value == "0" and "up" or nil)
		return { name = "KEY_" .. name, code = tonumber(code), value = val_name }
	end
	return nil
end

-- Forward declaration: _pump_one (below) resolves the typed character via
-- _resolve_char, which is defined further down. Declaring the local here means
-- _pump_one binds THIS local (assigned by the later `function _resolve_char`)
-- instead of a nil global — Lua does not hoist `local function`
-- (project-lua-closure-before-local-nil-global).
local _resolve_char

--- Pumps one line from the subprocess pipe and dispatches to callbacks.
--- Returns true if more data is available, false if pipe is closed.
local function _pump_one()
	if not _pipe then return false end

	-- Non-blocking read of one line (or nil if no data / EOF).
	local line = _pipe:read("*l")
	if not line then
		-- EOF or error — the subprocess exited.
		Logger.warn(LOG, "Subprocess pipe closed — reader exited.")
		_running = false
		_pipe = nil
		return false
	end

	-- Parse the line based on the mode.
	local ev = _intercept and _parse_evtest_line(line) or _parse_libinput_line(line)
	if not ev or not ev.value then return true end  -- skip non-key events and releases

	-- Process modifier key releases so shift/ctrl/alt state is tracked from
	-- real key transitions, not treated as a per-key one-shot that force-resets
	-- after every printable character. Without this, holding Shift across
	-- multiple letters mis-cases all but the first character.
	if ev.value ~= "down" then
		if ev.name == "KEY_LEFTSHIFT" or ev.name == "KEY_RIGHTSHIFT" then
			_shift_held = false
		elseif ev.name == "KEY_LEFTCTRL" or ev.name == "KEY_RIGHTCTRL" then
			_ctrl_held = false
		elseif ev.name == "KEY_LEFTALT" or ev.name == "KEY_RIGHTALT" then
			_alt_held = false
		end
		return true
	end

	-- Preserve the evdev code before any character translation.  This is the
	-- layout-independent physical key identity needed by the hardware heatmap;
	-- it must never be inferred back from the produced character (AZERTY,
	-- dead keys and shortcuts make that lossy).  Synthetic ydotool output is
	-- produced by a different virtual device and therefore never reaches this
	-- physical-device hook.
	-- A modifier is still a physical input event, but never a logical character.
	-- Do not ask the layout resolver about it: a resolver/test stub may map its
	-- numeric evdev code and create a phantom typed character before the
	-- modifier branch below can return.
	local is_modifier = ev.name == "KEY_LEFTSHIFT" or ev.name == "KEY_RIGHTSHIFT"
		or ev.name == "KEY_LEFTCTRL" or ev.name == "KEY_RIGHTCTRL"
		or ev.name == "KEY_LEFTALT" or ev.name == "KEY_RIGHTALT"
	local physical_char = nil
	if not is_modifier then physical_char = _resolve_char(ev.code) end
	if _on_physical and type(ev.code) == "number" and ev.code > 0 then
		pcall(_on_physical, ev.code, ev.name, physical_char)
	end

	-- Check if it's a control key that should be forwarded via on_key.
	local control_keys = {
		KEY_BACKSPACE = "backspace",
		KEY_ENTER     = "enter",
		KEY_TAB       = "tab",
		KEY_ESC       = "escape",
		KEY_UP        = "up",
		KEY_DOWN      = "down",
		KEY_LEFT      = "left",
		KEY_RIGHT     = "right",
		KEY_HOME      = "home",
		KEY_END       = "end",
		KEY_PAGEUP    = "pageup",
		KEY_PAGEDOWN  = "pagedown",
		KEY_DELETE    = "delete",
		KEY_INSERT    = "insert",
		KEY_F1 = "f1", KEY_F2 = "f2", KEY_F3 = "f3", KEY_F4 = "f4",
		KEY_F5 = "f5", KEY_F6 = "f6", KEY_F7 = "f7", KEY_F8 = "f8",
		KEY_F9 = "f9", KEY_F10 = "f10", KEY_F11 = "f11", KEY_F12 = "f12",
	}

	local ctrl_name = control_keys[ev.name]
	if ctrl_name then
		if _on_key then
			pcall(_on_key, ctrl_name)
		end
		return true
	end

	-- Skip modifier keys — track their state from key transitions.
	-- Shift/Ctrl/Alt held state is now maintained by processing both down
	-- events (set true) and release events (set false) at the top of
	-- _pump_one, so holding a modifier across multiple letters correctly
	-- shifts all of them instead of only the first.
	if ev.name == "KEY_LEFTSHIFT" or ev.name == "KEY_RIGHTSHIFT" then
		_shift_held = true
		return true
	end
	if ev.name == "KEY_LEFTCTRL" or ev.name == "KEY_RIGHTCTRL" then
		_ctrl_held = true
		return true
	end
	if ev.name == "KEY_LEFTALT" or ev.name == "KEY_RIGHTALT" then
		_alt_held = true
		return true
	end
	if ev.name == "KEY_CAPSLOCK" then return true end

	-- Resolve the typed character from the layout table using the CURRENT shift
	-- state. A prior bug left `ch` unassigned here, so no character ever
	-- reached on_char — hotstrings, keylogger and the LLM got zero input and the
	-- whole daemon was inert. Shift state is now carried across multiple keys
	-- (cleared only by the actual Shift release, processed above) so a held
	-- Shift correctly capitalises every letter while held.
	local ch = physical_char

	if ch and _on_char then
		pcall(_on_char, ch, ev.code)
	end

	return true
end

--- Resolves a keycode to a character using the input_reader's layout tables
--- (which are loaded from _shared/data/keycodes/evdev.json). Returns nil for
--- non-printable keys. This replaces the triplicated hardcoded tables that
--- were previously inlined here.
function _resolve_char(code)
	local ir = _get_input_reader()
	if not ir or not ir.resolve_char then return nil end
	return ir.resolve_char(code, _layout, _shift_held)
end


-- =========================================
-- =========================================
-- ======= 5/ Context Helpers ==============
-- =========================================
-- =========================================

local function _read_context()
	local ok, window_info = pcall(require, "adapters.window_info")
	if not ok then return end
	local ok2, info = pcall(window_info.getFocused)
	if ok2 and type(info) == "table" then
		_context.appId       = info.appId or ""
		_context.windowTitle = info.windowTitle or ""
	end
end


-- =========================================
-- =========================================
-- ======= 6/ Event Pump (Poll) ============
-- =========================================
-- =========================================

--- Pumps all available events from the subprocess pipe.
--- Should be called periodically (e.g., from a luv idle callback or a timer).
--- NOTE: _pump_one() uses blocking pipe:read("*l") — on systems without luv,
--- this will block the event loop until input arrives. Consider running in a
--- coroutine or using luv async handles for a fully non-blocking design.
function M.pump()
	if not _running or not _pipe then return end
	-- Pump up to 50 lines per call to avoid blocking the event loop.
	for _ = 1, 50 do
		if not _pump_one() then break end
	end
end


-- =========================================
-- =========================================
-- ======= 7/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Starts the keyboard hook. Idempotent — safe to call while already running.
--- @param opts table|nil { intercept?, layout?, onChar?, onKey?, onPhysical?, device? }
---              intercept boolean   Grab the device (needs root). Default false.
---              layout    string    "qwerty" or "azerty". Default "qwerty".
---              onChar    function  Called with (char_string, evdev_scancode) for printable keys.
---              onKey     function  Called with (key_name) for control keys.
---              onPhysical function  Called with (evdev_scancode, key_name, char_or_nil) for every physical keydown.
---              device    string    Override /dev/input/eventN path.
function M.start(opts)
	if _running then
		Logger.debug(LOG, "start() called while already running — no-op.")
		return
	end

	local options = type(opts) == "table" and opts or {}
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end
	if type(options.onPhysical) == "function" then _on_physical = options.onPhysical end
	if type(options.layout) == "string"  then _layout   = options.layout end
	_intercept = options.intercept == true

	-- Resolve the device path.
	if type(options.device) == "string" and options.device ~= "" then
		_device = options.device
	else
		-- Auto-detect via device_finder.
		local ok_df, df = pcall(require, "modules.hotstrings.device_finder")
		if ok_df and df.find_keyboard then
			_device = df.find_keyboard()
		end
		if not _device then
			Logger.error(LOG, "start(): no keyboard device found (set --device or check /proc/bus/input/devices).")
			return
		end
	end

	-- Refresh the foreground context before starting.
	_read_context()

	-- Launch the evdev reader subprocess.
	if not _start_subprocess() then
		Logger.error(LOG, "start(): failed to launch evdev reader subprocess.")
		_device = nil
		return
	end

	_running = true
	Logger.success(LOG, "Keyboard hook started (device=%s layout=%s intercept=%s).",
		_device, _layout, tostring(_intercept))
end

--- Stops the keyboard hook. Safe to call when not running.
function M.stop()
	if not _running then return end
	_stop_subprocess()
	_device  = nil
	_running = false
	Logger.info(LOG, "Keyboard hook stopped.")
end

--- Returns true if the keyboard hook is currently active.
--- @return boolean
function M.isRunning()
	return _running
end

--- Returns the active capture mode: "intercept" (evtest --grab / EVIOCGRAB,
--- physical events suppressed from the desktop) or "observe" (libinput
--- debug-events, non-consuming). The mode reflects the `intercept` opt passed to
--- the most recent start(). Callers use this to decide whether hotstring
--- replacement can safely own the output stream: replacement is only race-free
--- in "intercept" mode, where physical keys never reach the app directly. In
--- "observe" mode the daemon does NOT grab, so physical keys typed during an
--- injection still reach the app and can interleave with the synthetic
--- backspace+replacement stream (the "abcd"→"acd" corruption). Flipping the
--- default to "intercept" additionally requires lossless raw-event pass-through
--- (re-emitting EVERY physical event — modifiers, control keys, key-repeat and
--- releases included — through the single ydotool/uinput channel), which must be
--- validated on real evdev+ydotool hardware before it can become the default.
--- @return string "intercept" | "observe"
function M.get_mode()
	return _intercept and "intercept" or "observe"
end

--- Re-reads the foreground application identity and caches it.
function M.refreshContext()
	_read_context()
end

--- Returns the last-known foreground application identity.
--- @return table { appId: string, windowTitle: string }
function M.getContext()
	return { appId = _context.appId, windowTitle = _context.windowTitle }
end

--- Test hook (test_keyboard_hook_pump.lua): injects a mock event pipe + on_char
--- callback and pumps a single event, without a real evtest/libinput subprocess
--- (which needs a Linux binary + device). Guards the input pipeline — that a
--- printable keydown actually resolves to a character and reaches on_char.
--- @param mock_pipe table   Object exposing read("*l") → one event line.
--- @param on_char_cb function Called with the resolved character and evdev code.
--- @param intercept boolean  true = parse evtest lines, false = libinput lines.
--- @param on_physical_cb function|nil Called with physical key metadata.
--- @return boolean The _pump_one return value.
function M._test_inject_and_pump(mock_pipe, on_char_cb, intercept, on_physical_cb)
	_pipe = mock_pipe
	_on_char = on_char_cb
	_on_physical = on_physical_cb
	_intercept = intercept and true or false
	return _pump_one()
end

return M
