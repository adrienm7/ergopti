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
--- the control keys. The hook forwards every physical key to the application
--- BEFORE calling back, and the model does the same.
--- Prints one line: SCREEN <quoted text>.
--- ==============================================================================

local CONFIG, DEVICE, SCRIPT = arg[1], arg[2], arg[3]
arg = { "--device", DEVICE, "--config", CONFIG }
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path

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
hook.start = function(options) callbacks = options end
hook.isRunning = function() return true end
hook.get_mode = function() return "scripted" end
hook.held_text_modifier_codes = function() return {} end
hook.emergency_stop = function(why) print("EMERGENCY STOP: " .. tostring(why)) end

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

local CONTROL = { BS = "backspace", ESC = "escape", LEFT = "left" }

package.preload["adapters.event_loop"] = function()
	return {
		run = function()
			local i = 1
			while i <= #SCRIPT do
				local token = SCRIPT:match("^{(%u+)}", i)
				if token then
					i = i + #token + 2
					if token == "BS" then table.remove(screen) end
					if token == "ENTER" then
						screen[#screen + 1] = "\n"
						callbacks.onChar("\n", Codes.KEY_ENTER)
					else
						callbacks.onKey(CONTROL[token])
					end
				else
					local c = SCRIPT:match("^[%z\1-\127\194-\244][\128-\191]*", i)
					i = i + #c
					screen[#screen + 1] = c
					callbacks.onChar(c, 30)
				end
			end
			print(string.format("SCREEN %q", table.concat(screen)))
		end,
		stop = function() end,
	}
end

dofile("ergopti_hotstrings.lua")
