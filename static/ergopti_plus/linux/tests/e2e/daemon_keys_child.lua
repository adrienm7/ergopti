--- tests/e2e/daemon_keys_child.lua

--- ==============================================================================
--- MODULE: One Daemon Run Against A Scripted Keyboard
--- DESCRIPTION:
--- Runs the REAL ergopti_hotstrings.lua main() with only the operating-system
--- edges replaced: the keyboard hook hands its callbacks to a script instead of
--- /dev/input, uinput writes into a model of the focused text field, the output
--- layout is an identity table, and the event loop plays the script and
--- returns. Everything between — the engine, the config loader, the undo, the
--- injector's erase arithmetic, the queueing — is production code.
---
--- Usage (from the driver root): luajit tests/e2e/daemon_keys_child.lua
---   <config.toml> <device-file> "<script>"
--- Script tokens: plain characters are typed; {BS} {ESC} {LEFT} {ENTER} are
--- the control keys, and {CBS} is Ctrl+Backspace, which deletes the word
--- before the caret. The hook forwards every physical key to the application
--- BEFORE calling back, and the model does the same. {PUMP} runs one idle tick
--- of the daemon's loop and {TAP} runs the tap action "select_all" through the
--- tap-hold manager's action runner.
--- Prints one line: SCREEN <quoted text>.
--- ==============================================================================

local CONFIG, DEVICE, SCRIPT = arg[1], arg[2], arg[3]
arg = { "--device", DEVICE, "--config", CONFIG }
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path

-- On a Windows checkout the daemon's POSIX edges (HOME, /tmp, mkdir -p, sh
-- and coreutils) are emulated for this test process as tests/run.lua does for
-- the unit suite; install() does nothing anywhere else.
require("tests.win_compat").install()

local Codes = require("infra.evdev_codes")

--- @param text string
--- @return table UTF-8 characters.
local function chars(text)
	local out = {}
	for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = c end
	return out
end

local screen, code_of, char_of, next_code = {}, {}, {}, 1000
local function code_for(c)
	if not code_of[c] then
		code_of[c] = next_code
		char_of[next_code] = c
		next_code = next_code + 1
	end
	return code_of[c]
end

package.preload["adapters.keyboard_layout"] = function()
	return {
		refresh = function() return true end,
		is_ready = function() return true end,
		source = function() return "scripted" end,
		resolve = function(c) return { keycode = code_for(c), level = 1, mods = {} } end,
		plan = function(text)
			local plan = {}
			for _, c in ipairs(chars(text)) do plan[#plan + 1] = { keycode = code_for(c), level = 1, mods = {} } end
			return plan
		end,
		shortcut_keycode = function(_, us_code) return us_code end,
		_set_table_for_test = function() end,
	}
end

package.preload["adapters.uinput_writer"] = function()
	return {
		is_available = function() return true end,
		open = function() return true end,
		close = function() return true end,
		is_open = function() return true end,
		sync = function() return true end,
		emit = function(code, value)
			if value == 1 then
				if code == Codes.KEY_BACKSPACE then table.remove(screen)
				elseif code == Codes.KEY_ENTER then screen[#screen + 1] = "\n"
				elseif char_of[code] then screen[#screen + 1] = char_of[code] end
			end
			return true
		end,
	}
end

local callbacks = {}
local hook = require("adapters.keyboard_hook")
hook.start = function(options)
	callbacks = options
	if CONFIG:match("[/\\]daemon_keys%.toml$") then
		local config = require("modules.hotstrings.hotstrings_config")
		assert(config.set_all_sections("daemon_keys", true), "the scripted catalogue must be explicitly selected")
	end
end
hook.isRunning = function() return true end
hook.get_mode = function() return "scripted" end
hook.held_text_modifier_codes = function() return {} end
hook.emergency_stop = function(why) print("EMERGENCY STOP: " .. tostring(why)) end
-- The script is the keyboard: an idle tick of the loop has no device to read.
hook.pump = function() return 0 end

-- ERGOPTI_E2E_MENU_ROWS=<file>: build the REAL tray menu with every module
-- loaded, count its rows through a recording indicator (no GTK needed), and
-- write the count. The menu once held 103 058 rows — eight seconds of GTK at
-- every rebuild — and nothing measured it.
local MENU_ROWS_FILE = os.getenv("ERGOPTI_E2E_MENU_ROWS")
if MENU_ROWS_FILE then
	arg[#arg + 1] = "--tray"
	package.preload["platform.tray.appindicator"] = function()
		local function count(items)
			local n = 0
			for _, item in ipairs(items or {}) do
				n = n + 1 + (type(item.menu) == "table" and count(item.menu) or 0)
			end
			return n
		end
		local live = false
		return {
			is_available = function() return true end,
			create = function() live = true; return true end,
			set_icon = function() return true end,
			set_menu = function(items)
				local fh = io.open(MENU_ROWS_FILE, "w")
				fh:write(tostring(count(items)), "\n")
				fh:close()
				return true
			end,
			pump = function() return 0 end,
			destroy = function() live = false end,
			is_live = function() return live end,
		}
	end
end

-- Everything that needs a desktop is switched off; the daemon loads each of
-- these optionally and runs without it. ERGOPTI_E2E_LLM keeps the prediction
-- engine, which the demo configuration loads: its cancel path runs on every
-- Backspace and once wiped the hotstring buffer.
local WITH_LLM = os.getenv("ERGOPTI_E2E_LLM") == "1"
for _, name in ipairs(MENU_ROWS_FILE and {} or { "ui.tooltip.preview", "ui.tooltip.llm", "adapters.tray_menu",
	"ui.menu.menu_builder", "modules.updater.manager",
	"modules.gestures.manager", "adapters.window_info", "adapters.process_lifecycle",
	"ui.webview_manager",
	"infra.file_watchers", "ui.wpm.widget", "modules.keylogger.system_metrics", "adapters.notifier" }) do
	package.preload[name] = function() error("disabled for the daemon key scenarios") end
end
if not MENU_ROWS_FILE and not WITH_LLM then
	package.preload["modules.llm.prediction_engine"] = function() error("disabled for the daemon key scenarios") end
end

-- ERGOPTI_E2E_GESTURE_PUMP=fails: a touchpad reader whose pump throws. The
-- same module is the action catalogue the tap-holds run their actions
-- through, and it types "<action>" on the screen for each one it runs. The
-- daemon's loop guard once dropped the whole module when the pump failed, and
-- every tap action died with the reader (gesture-pump-keeps-actions).
if os.getenv("ERGOPTI_E2E_GESTURE_PUMP") == "fails" then
	package.preload["modules.gestures.manager"] = function()
		return {
			init = function() return true end,
			is_enabled = function() return true end,
			set_enabled = function() return true end,
			pump = function() error("touchpad read failed") end,
			stop_reading = function() screen[#screen + 1] = "[reader stopped]" end,
			get_action_names = function() return { "select_all" } end,
			get_executable_action_names = function() return { "select_all" } end,
			execute_action = function(action) screen[#screen + 1] = "<" .. action .. ">" end,
		}
	end
end

-- The action runner the daemon hands the tap-hold manager, kept so {TAP} can
-- run a tap action through it exactly as a tap would.
local tap_executor = nil
local TapHold = require("platform.remap.tap_hold_manager")
local real_tap_hold_init = TapHold.init
TapHold.init = function(options)
	tap_executor = options.execute_action
	return real_tap_hold_init(options)
end

-- A focused ordinary text field, conclusively.
package.preload["adapters.secure_field_detector"] = function()
	return {
		invalidateFocus = function() return 1 end,
		refresh = function() return true, "insecure" end,
		isSecureField = function() return false end,
		getVerdict = function() return "insecure" end,
		currentEpoch = function() return 1 end,
		isSecureApp = function() return false end,
		isUrlBar = function() return false end,
	}
end

local CONTROL = { BS = "backspace", CBS = "backspace", ESC = "escape", LEFT = "left" }
-- The shortcut modifiers the hook reports held with each control key.
local CONTROL_MODS = { CBS = { ctrl = true } }

package.preload["adapters.event_loop"] = function()
	-- Keep the real deferred queue: boot schedules crash reporting before the
	-- loop begins, and dropping that boundary would conceal startup failures.
	local adapter = dofile("adapters/event_loop.lua")
	adapter.run = function(loop)
		adapter._run_idle_tick()
		local i = 1
		while i <= #SCRIPT do
			local token = SCRIPT:match("^{(%u+)}", i)
			if token == "PUMP" then
				-- One idle tick of the daemon's own loop.
				i = i + #token + 2
				loop.onIdle()
				adapter._run_idle_tick()
			elseif token == "TAP" then
				i = i + #token + 2
				local ran = pcall(tap_executor, "select_all", "tap_hold")
				if not ran then screen[#screen + 1] = "[tap failed]" end
			elseif token then
				i = i + #token + 2
				if token == "BS" then table.remove(screen) end
				if token == "CBS" then
					-- As GTK and Qt apply it: the spaces before the caret, then the word.
					while screen[#screen] == " " do table.remove(screen) end
					while #screen > 0 and screen[#screen] ~= " " do table.remove(screen) end
				end
				if token == "ENTER" then
					screen[#screen + 1] = "\n"
					callbacks.onChar("\n", Codes.KEY_ENTER)
				else
					callbacks.onKey(CONTROL[token], { mods = CONTROL_MODS[token] or {} })
				end
			else
				local c = SCRIPT:match("^[%z\1-\127\194-\244][\128-\191]*", i)
				i = i + #c
				screen[#screen + 1] = c
				callbacks.onChar(c, 30)
			end
		end
		print(string.format("SCREEN %q", table.concat(screen)))
	end
	return adapter
end

dofile("ergopti_hotstrings.lua")
