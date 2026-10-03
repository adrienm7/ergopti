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
--- tap-hold manager's action runner. {TICK} turns the scripted whole-second
--- clock (ERGOPTI_E2E_CLOCK=seconds) over to the next second, no time passing.
--- Selection-only tokens {SELECT}, {TAPKEY}, {WRAP} exercise the real hook
--- consumption callback when ERGOPTI_E2E_TAP_WRAP selects a scenario. A private
--- compiled neutral config is explicitly enabled through its real owners;
--- only PRIMARY and the focused field/action effects are desktop models.
--- Prints SCREEN <quoted text> and, for selection scenarios, TAP_WRAP receipts.
--- ==============================================================================

local CONFIG, DEVICE, SCRIPT = arg[1], arg[2], arg[3]
local MAGIC_REPEAT = os.getenv("ERGOPTI_E2E_MAGIC_REPEAT") or "none"
local TAP_COLLISION = MAGIC_REPEAT:match("^tap%-") ~= nil
if MAGIC_REPEAT ~= "none" then CONFIG = "../_shared/modules/hotstrings/magickey.toml" end
arg = { "--device", DEVICE, "--config", CONFIG }
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path

-- On a Windows checkout the daemon's POSIX edges (HOME, /tmp, mkdir -p, sh
-- and coreutils) are emulated for this test process as tests/run.lua does for
-- the unit suite; install() does nothing anywhere else.
require("tests.win_compat").install()

-- ERGOPTI_E2E_CLOCK=seconds: the daemon's clock is the whole-second os.time()
-- it falls back to without luv, held still and turned over only by {TICK}, so
-- a scenario can put a second boundary between two keys typed together.
-- Installed before the first module loads, since infra.monotonic chooses its
-- source once. "system" leaves the clock as the machine has it.
-- Selection scenarios exercise the real consumption callback, isolating only
-- the desktop's PRIMARY selection, focused field and action side effects.
local TAP_WRAP = os.getenv("ERGOPTI_E2E_TAP_WRAP") or "none"
local selection = { primary = "", reads = 0, attempts = 0, queued = 0, executed = 0, focused = false }
local selection_config = nil
if TAP_WRAP ~= "none" or MAGIC_REPEAT ~= "none" then
	local modes = { accepted = true, unassigned = true, modified = true, refused = true, reopened = true }
	assert(TAP_WRAP == "none" or modes[TAP_WRAP], "unknown tap/wrap scenario")
	local Paths = require("infra.config_paths")
	local original = Paths.config
	selection_config = os.tmpname()
	local template = assert(io.open("_generated/config_template.toml", "rb"))
	local file = assert(io.open(selection_config, "wb"))
	assert(file:write(template:read("*a")))
	assert(file:close())
	template:close()
	Paths.config = function(relative)
		if relative == "config.toml" then return selection_config end
		return original(relative)
	end
end

local CLOCK = os.getenv("ERGOPTI_E2E_CLOCK") or "system"
local clock_seconds = nil
if CLOCK == "seconds" then
	package.preload["luv"] = function() error("the scripted clock runs the daemon without luv") end
	local system_time = os.time
	clock_seconds = system_time()
	os.time = function(date)
		if date ~= nil then return system_time(date) end
		return clock_seconds
	end
elseif CLOCK ~= "system" then
	error("ERGOPTI_E2E_CLOCK must be system or seconds, not " .. CLOCK)
end

local Codes = require("infra.evdev_codes")

--- @param text string
--- @return table UTF-8 characters.
local function chars(text)
	local out = {}
	for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = c end
	return out
end

local screen, code_of, char_of, next_code = {}, {}, {}, 1000
local repeat_state = { reads = 0, attempts = 0, dispatched = 0, origins = 0, decisions = 0,
	raw = 0, group = 0, origin_name = "fixture keyboard", compose_failed = false }
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
			if MAGIC_REPEAT ~= "none" and value == 1 and char_of[code] == "★" then
				repeat_state.attempts = repeat_state.attempts + 1
				if MAGIC_REPEAT == "injection" and repeat_state.attempts == 2 then return false end
			end
			if value == 1 then
				if code == Codes.KEY_BACKSPACE then table.remove(screen)
				elseif code == Codes.KEY_ENTER then screen[#screen + 1] = "\n"
				elseif char_of[code] then
					if selection.focused then screen = {}; selection.focused = false end
					screen[#screen + 1] = char_of[code]
				end
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
hook.get_mode = function() return MAGIC_REPEAT ~= "none" and "intercept" or "scripted" end
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

if TAP_WRAP ~= "none" or TAP_COLLISION then
	local Clipboard = require("adapters.clipboard")
	Clipboard.read_primary = function()
		selection.reads = selection.reads + 1
		return true, selection.primary
	end
	package.preload["modules.gestures.manager"] = function()
		return {
			init = function() return true end,
			is_assignable = function(id) return id == "send_text" end,
			get_executable_action_names = function() return { "send_text" } end,
			execute_action = function(action, binding)
				selection.executed = selection.executed + 1
				selection.action, selection.binding = action, binding
				-- The action replaces the focused selection; PRIMARY retains its
				-- historical bytes, as X11 applications may do after replacement.
				screen = chars("replacement")
				selection.focused = false
				return true
			end,
		}
	end
	local TapKeys = require("modules.shortcuts.tap_keys")
	local initialize = TapKeys.init
	TapKeys.init = function(options)
		local defer = options.defer
		options.defer = function(fn)
			selection.attempts = selection.attempts + 1
			if TAP_WRAP == "refused" then return false end
			local queued = defer(fn)
			if queued == true then selection.queued = selection.queued + 1 end
			return queued
		end
		return initialize(options)
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

-- Keep the actual pause and inhibition owners; observe their construction and
-- vary only desktop boundaries while the native reader delivers a held press.
local repeat_controller, repeat_gate
if MAGIC_REPEAT ~= "none" then
	local Actions = require("modules.shortcuts.script_actions")
	local make_actions = Actions.new
	Actions.new = function(options)
		repeat_controller = make_actions(options)
		return repeat_controller
	end
	local Gate = require("infra.input_capture_gate")
	local make_gate = Gate.new
	Gate.new = function(options)
		repeat_gate = make_gate(options)
		return repeat_gate
	end
	local Source = require("modules.hotstrings.magic_key_source")
	local initialize = Source.init
	Source.init = function(options)
		local dispatch = options.dispatch_char
		options.dispatch_char = function(...)
			repeat_state.dispatched = repeat_state.dispatched + 1
			return dispatch(...)
		end
		return initialize(options)
	end
	local Finder = require("modules.hotstrings.device_finder")
	Finder.physical_sources = function(paths)
		repeat_state.origins = repeat_state.origins + 1
		return { { path = paths[1], physical = MAGIC_REPEAT ~= "untrusted",
			sysfs = "/fixture/native-keyboard", name = repeat_state.origin_name } }
	end
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
		if MAGIC_REPEAT ~= "none" then
			local Source = require("modules.hotstrings.magic_key_source")
			assert(require("modules.hotstrings.hotstrings_config").set_all_sections("magickey", true),
				"the real magic-key category must acknowledge activation")
			assert(Source.set("KeyJ"), "the real source owner must acknowledge the key")
			local choice_ok, choice_reason, before_bytes, native = nil, nil, nil, 36
			if TAP_COLLISION then
				local Keys = require("modules.shortcuts.tap_keys")
				local Master = require("modules.shortcuts.manager")
				assert(Master.set_enabled(MAGIC_REPEAT ~= "tap-off"))
				assert(Keys.set_action("number_row_left", MAGIC_REPEAT == "tap-none" and "none" or "send_text"))
				for _, key in ipairs(Keys.keys()) do if key.id == "number_row_left" then native = key.linux end end
				local file = assert(io.open(selection_config, "rb")); before_bytes = file:read("*a"); file:close()
				choice_ok, choice_reason = Source.set("Backquote")
				if MAGIC_REPEAT ~= "tap-choice" and MAGIC_REPEAT ~= "tap-none" then
					-- Model previously stored/hand-edited conflicting intent through the
					-- actual preference publication owner, never a guessed live flag.
					assert(require("infra.hotstring_preferences").set("hotstrings.magic_key_source", "Backquote"))
				end
				if MAGIC_REPEAT == "tap-paused" then repeat_controller.toggle_pause() end
			end
			local Capture = require("adapters.xkb_capture")
			local primed, chosen = false, 0
			-- Count origin publications during this press, excluding boot probes.
			repeat_state.origins = 0
			Capture._set_backend({
				create = function() return {} end,
				destroy = function() end,
				source_group = function() return repeat_state.group, 1 end,
				key_sym = function(_, code) return TAP_COLLISION and code == 37 and 0xffe3 or 0x6a end,
				key_utf8 = function()
					if not primed then
						primed = true
						hook.physical_source_receipt()
					end
					repeat_state.reads = repeat_state.reads + 1
					if repeat_state.reads == 1 and MAGIC_REPEAT == "compose-first" then
						repeat_state.compose_failed = true
					elseif repeat_state.reads == 2 then
						if MAGIC_REPEAT == "compose-first" then repeat_state.compose_failed = false
						elseif MAGIC_REPEAT == "paused" then repeat_controller.toggle_pause()
						elseif MAGIC_REPEAT == "group" then repeat_state.group = 1
						elseif MAGIC_REPEAT == "source" then assert(Source.set("KeyQ"))
						elseif MAGIC_REPEAT == "inhibited" then assert(repeat_gate.acquire("repeat-fixture", 1))
						elseif MAGIC_REPEAT == "origin" then
							repeat_state.origin_name = "replacement keyboard"
							hook.physical_source_receipt()
						elseif MAGIC_REPEAT == "compose" then repeat_state.compose_failed = true end
					elseif repeat_state.reads == 3 then
						if MAGIC_REPEAT == "paused" then repeat_controller.toggle_pause()
						elseif MAGIC_REPEAT == "group" then repeat_state.group = 0
						elseif MAGIC_REPEAT == "inhibited" then assert(repeat_gate.release("repeat-fixture", 1)) end
						repeat_state.compose_failed = false
					end
					return "j"
				end,
				sym_utf8 = function(_, sym) return sym end,
				update_key = function() end,
				compose_feed = function() end,
				compose_status = function() return "nothing" end,
				compose_reset = function()
					if repeat_state.compose_failed then error("fixture compose retirement refused") end
				end,
			})
			assert(Capture.load("fixture keymap"))
			local refused = {}
			if MAGIC_REPEAT == "capture" or MAGIC_REPEAT == "tap-choice" then
				assert(Source.capture({ on_chosen = function() chosen = chosen + 1 end,
					on_refused = function(reason) refused[#refused + 1] = reason end }))
			end
			local stream = { { type = 1, code = native, value = 1 }, { type = 1, code = native, value = 2 },
				{ type = 1, code = native, value = 2 }, { type = 1, code = native, value = 0 } }
			if MAGIC_REPEAT == "tap-modified" then
				table.insert(stream, 1, { type = 1, code = 29, value = 1 })
				stream[#stream + 1] = { type = 1, code = 29, value = 0 }
			end
			hook._test_drive(stream, {
				liveXkb = true,
				onChar = callbacks.onChar, onKey = callbacks.onKey,
				onPhysical = callbacks.onPhysical, onHold = callbacks.onHold,
				onConsume = function(detail)
					repeat_state.decisions = repeat_state.decisions + 1
					return callbacks.onConsume(detail)
				end,
				onEmitRaw = function()
					repeat_state.raw = repeat_state.raw + 1
					return true
				end,
			}, true)
			adapter._run_idle_tick()
			print(string.format("MAGIC_REPEAT decisions=%d dispatched=%d attempts=%d origins=%d raw=%d chosen=%d",
				repeat_state.decisions, repeat_state.dispatched, repeat_state.attempts,
				repeat_state.origins, repeat_state.raw, chosen))
			if TAP_COLLISION then
				local file = assert(io.open(selection_config, "rb")); local after_bytes = file:read("*a"); file:close()
				local Keys = require("modules.shortcuts.tap_keys")
				print(string.format("TAP_COLLISION choice=%s reason=%s source=%s tap=%s queued=%d executed=%d bytes=%s captured=%s",
					tostring(choice_ok), tostring(choice_reason), Source.get(), Keys.get_action("number_row_left"),
					selection.queued, selection.executed, tostring(before_bytes == after_bytes), tostring(refused[1])))
			end
			assert(MAGIC_REPEAT == "tap-choice" or #refused == 0, "an unrelated capture must not be refused")
			print(string.format("SCREEN %q", table.concat(screen)))
			Capture._reset_backend()
			return
		end
		if TAP_WRAP ~= "none" then
			local Shortcuts = require("modules.shortcuts.manager")
			assert(Shortcuts.set_enabled(true), "the real shortcut owner must acknowledge activation")
			assert(Shortcuts.set_wrap_on_type_enabled(true), "the real wrap owner must acknowledge activation")
			if TAP_WRAP ~= "unassigned" then
				assert(require("modules.shortcuts.tap_keys").set_action("number_row_left", "send_text"),
					"the real tap-key owner must acknowledge the assignment")
			end
		end
		adapter._run_idle_tick()
		local i = 1
		while i <= #SCRIPT do
			local token = SCRIPT:match("^{(%u+)}", i)
			if token == "SELECT" then
				i = i + #token + 2
				callbacks.onClick()
				selection.primary = selection.primary == "" and "selected" or "fresh"
				screen = chars(selection.primary)
				selection.focused = true
			elseif token == "TAPKEY" then
				i = i + #token + 2
				local consumed = callbacks.onConsume({ code = 41, char = "(",
					mods = TAP_WRAP == "modified" and { shift = true } or {} })
				if not consumed then
					if selection.focused then screen = {}; selection.focused = false end
					screen[#screen + 1] = "("
				end
				adapter._run_idle_tick()
			elseif token == "WRAP" then
				i = i + #token + 2
				if not callbacks.onConsume({ code = 10, char = "(", mods = { shift = true } }) then
					if selection.focused then screen = {}; selection.focused = false end
					screen[#screen + 1] = "("
				end
			elseif token == "PUMP" then
				-- One idle tick of the daemon's own loop.
				i = i + #token + 2
				loop.onIdle()
				adapter._run_idle_tick()
			elseif token == "TAP" then
				i = i + #token + 2
				local ran = pcall(tap_executor, "select_all", "tap_hold")
				if not ran then screen[#screen + 1] = "[tap failed]" end
			elseif token == "TICK" then
				i = i + #token + 2
				if not clock_seconds then error("{TICK} needs ERGOPTI_E2E_CLOCK=seconds") end
				clock_seconds = clock_seconds + 1
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
		if TAP_WRAP ~= "none" then
			print(string.format("TAP_WRAP attempts=%d queued=%d executed=%d reads=%d action=%s binding=%s",
				selection.attempts, selection.queued, selection.executed, selection.reads,
				selection.action or "none", selection.binding or "none"))
		end
		print(string.format("SCREEN %q", table.concat(screen)))
	end
	return adapter
end

dofile("ergopti_hotstrings.lua")

if selection_config then
	os.remove(selection_config)
	os.remove(selection_config .. ".tmp")
end
