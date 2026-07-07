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
local _on_char  = nil   -- function(char_string)
local _on_key   = nil   -- function(key_name_string)

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

local _KEYCODE_MAP = nil

--- Builds a reverse map: KEY_NAME → integer code from the input_reader tables.
local function _build_keycode_map()
	if _KEYCODE_MAP then return _KEYCODE_MAP end
	local ir = _get_input_reader()
	if not ir then return {} end

	-- The input_reader doesn't export a key-name map directly, but we can
	-- build one from the KEY_* constants it defines. Since those are local,
	-- we replicate the ones we need for libinput/evtest parsing.
	_KEYCODE_MAP = {
		KEY_ESC = 1, KEY_1 = 2, KEY_2 = 3, KEY_3 = 4, KEY_4 = 5,
		KEY_5 = 6, KEY_6 = 7, KEY_7 = 8, KEY_8 = 9, KEY_9 = 10,
		KEY_0 = 11, KEY_MINUS = 12, KEY_EQUAL = 13,
		KEY_BACKSPACE = 14, KEY_TAB = 15,
		KEY_Q = 16, KEY_W = 17, KEY_E = 18, KEY_R = 19, KEY_T = 20,
		KEY_Y = 21, KEY_U = 22, KEY_I = 23, KEY_O = 24, KEY_P = 25,
		KEY_LEFTBRACE = 26, KEY_RIGHTBRACE = 27,
		KEY_ENTER = 28, KEY_LEFTCTRL = 29,
		KEY_A = 30, KEY_S = 31, KEY_D = 32, KEY_F = 33, KEY_G = 34,
		KEY_H = 35, KEY_J = 36, KEY_K = 37, KEY_L = 38, KEY_SEMICOLON = 39,
		KEY_APOSTROPHE = 40, KEY_GRAVE = 41,
		KEY_LEFTSHIFT = 42, KEY_BACKSLASH = 43,
		KEY_Z = 44, KEY_X = 45, KEY_C = 46, KEY_V = 47, KEY_B = 48,
		KEY_N = 49, KEY_M = 50, KEY_COMMA = 51, KEY_DOT = 52, KEY_SLASH = 53,
		KEY_RIGHTSHIFT = 54, KEY_KPASTERISK = 55,
		KEY_LEFTALT = 56, KEY_SPACE = 57, KEY_CAPSLOCK = 58,
		KEY_F1 = 59, KEY_F2 = 60, KEY_F3 = 61, KEY_F4 = 62,
		KEY_F5 = 63, KEY_F6 = 64, KEY_F7 = 65, KEY_F8 = 66,
		KEY_F9 = 67, KEY_F10 = 68, KEY_F11 = 87, KEY_F12 = 88,
		KEY_RIGHTCTRL = 97, KEY_RIGHTALT = 100,
		KEY_HOME = 102, KEY_UP = 103, KEY_PAGEUP = 104,
		KEY_LEFT = 105, KEY_RIGHT = 106,
		KEY_END = 107, KEY_DOWN = 108, KEY_PAGEDOWN = 109,
		KEY_INSERT = 110, KEY_DELETE = 111,
	}
	return _KEYCODE_MAP
end

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

	-- Only forward keydown events (value == "down").
	if ev.value ~= "down" then return true end

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

	-- Skip modifier keys — track their state instead of forwarding.
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

	-- Reset modifier state on non-modifier keypress.
	_shift_held = false
	_ctrl_held = false
	_alt_held = false

	-- Resolve the character from the layout table.
	if ch and _on_char then
		pcall(_on_char, ch)
	end

	return true
end

-- Cached layout tables for character resolution.
local _layout_unshifted = nil
local _layout_shifted = nil

--- Resolves a keycode to a character using the active layout.
--- Returns nil for non-printable keys.
local function _resolve_char(code)
	-- Load layout tables from input_reader if not cached.
	if not _layout_unshifted then
		local ir = _get_input_reader()
		if not ir then return nil end

		-- Access the LAYOUTS table from input_reader's module scope.
		-- Since it's local, we rebuild a minimal table using the hardcoded fallbacks.
		-- This is a pragmatic bridge until input_reader exports a public API.
		local layouts = {
			qwerty = {
				unshifted = {
					[2]="1",[3]="2",[4]="3",[5]="4",[6]="5",[7]="6",[8]="7",[9]="8",[10]="9",[11]="0",
					[12]="-",[13]="=",[16]="q",[17]="w",[18]="e",[19]="r",[20]="t",
					[21]="y",[22]="u",[23]="i",[24]="o",[25]="p",[26]="[",[27]="]",
					[30]="a",[31]="s",[32]="d",[33]="f",[34]="g",[35]="h",[36]="j",[37]="k",[38]="l",
					[39]=";",[40]="'",[44]="z",[45]="x",[46]="c",[47]="v",[48]="b",
					[49]="n",[50]="m",[51]=",",[52]=".",[53]="/",[57]=" ",
				},
				shifted = {
					[2]="!",[3]="@",[4]="#",[5]="$",[6]="%",[7]="^",[8]="&",[9]="*",[10]="(", [11]=")",
					[12]="_",[13]="+",[16]="Q",[17]="W",[18]="E",[19]="R",[20]="T",
					[21]="Y",[22]="U",[23]="I",[24]="O",[25]="P",[26]="{",[27]="}",
					[30]="A",[31]="S",[32]="D",[33]="F",[34]="G",[35]="H",[36]="J",[37]="K",[38]="L",
					[39]=":",[40]='"',[44]="Z",[45]="X",[46]="C",[47]="V",[48]="B",
					[49]="N",[50]="M",[51]="<",[52]=">",[53]="?",[57]=" ",
				}
			},
			azerty = {
				unshifted = {
					[2]="&",[3]="é",[4]='"',[5]="'",[6]="(",[7]="-",[8]="è",[9]="_",[10]="ç",[11]="à",
					[12]=")",[13]="=",[16]="a",[17]="z",[18]="e",[19]="r",[20]="t",
					[21]="y",[22]="u",[23]="i",[24]="o",[25]="p",
					[30]="q",[31]="s",[32]="d",[33]="f",[34]="g",[35]="h",[36]="j",[37]="k",[38]="l",
					[39]="m",[40]="ù",[44]="w",[45]="x",[46]="c",[47]="v",[48]="b",
					[49]="n",[50]=",",[51]=";",[52]=":",[53]="!",[57]=" ",
				},
				shifted = {
					[2]="1",[3]="2",[4]="3",[5]="4",[6]="5",[7]="6",[8]="7",[9]="8",[10]="9",[11]="0",
					[12]="°",[13]="+",[16]="A",[17]="Z",[18]="E",[19]="R",[20]="T",
					[21]="Y",[22]="U",[23]="I",[24]="O",[25]="P",
					[30]="Q",[31]="S",[32]="D",[33]="F",[34]="G",[35]="H",[36]="J",[37]="K",[38]="L",
					[39]="M",[40]="%",[44]="W",[45]="X",[46]="C",[47]="V",[48]="B",
					[49]="N",[50]="?",[51]=".",[52]="/",[53]="§",[57]=" ",
				}
			}
		}
		local lt = layouts[_layout] or layouts["qwerty"]
		_layout_unshifted = lt.unshifted
		_layout_shifted = lt.shifted
	end
	-- Use shifted table when Shift is held; unshifted otherwise.
	local table_to_use = _shift_held and _layout_shifted or _layout_unshifted
	return table_to_use[code]
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
--- @param opts table|nil { intercept?, layout?, onChar?, onKey?, device? }
---              intercept boolean   Grab the device (needs root). Default false.
---              layout    string    "qwerty" or "azerty". Default "qwerty".
---              onChar    function  Called with (char_string) for printable keys.
---              onKey     function  Called with (key_name) for control keys.
---              device    string    Override /dev/input/eventN path.
function M.start(opts)
	if _running then
		Logger.debug(LOG, "start() called while already running — no-op.")
		return
	end

	local options = type(opts) == "table" and opts or {}
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end
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

--- Re-reads the foreground application identity and caches it.
function M.refreshContext()
	_read_context()
end

--- Returns the last-known foreground application identity.
--- @return table { appId: string, windowTitle: string }
function M.getContext()
	return { appId = _context.appId, windowTitle = _context.windowTitle }
end

return M
