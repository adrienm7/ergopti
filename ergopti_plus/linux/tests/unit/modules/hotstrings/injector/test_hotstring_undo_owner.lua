--- tests/unit/modules/hotstrings/injector/test_hotstring_undo_owner.lua

--- ==============================================================================
--- MODULE: Hotstring Undo Destination And Privacy
--- DESCRIPTION:
--- Executes Main's actual character and control callbacks, then the real
--- injector, clipboard, focus guard and logger against controlled native ports.
--- The initial expansion ACK is scripted; Undo output and refusal are real Lua.
--- ==============================================================================
local helpers = require("tests.helpers")
local Fixture = require("tests.support.text_owner_fixture")

--- Extracts the actual two callbacks without reproducing their Undo protocol.
--- @param environment table Controlled callback dependencies.
--- @return function character
--- @return function control
--- @return function undo Current Undo receipt.
local function main_callbacks(environment)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local source = file:read("*a"); assert(file:close())
	local first = assert(source:find("\tlocal function handle_char(", 1, true))
	local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
	local body = "local _undoable; local on_char; " .. source:sub(first, last - 1)
	first = assert(source:find("\tlocal function handle_control(", 1, true))
	last = assert(source:find("\n\tlocal on_control = input_capture_gate.guard(handle_control)", first, true))
	body = body .. source:sub(first, last - 1)
		.. "\non_char=handle_char; return handle_char,handle_control,function() return _undoable end"
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "actual Main hotstring Undo callbacks", "t", environment)) end
	return chunk()
end

--- Runs a real Undo after the actual Main callback publishes its commit record.
--- @param options table Trigger, private flag and controlled transition boundary.
--- @param body function Receives observations after the control callback.
local function with_undo(options, body)
	Fixture.with(function(guard, state)
		local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server",
			"adapters.keyboard_layout", "modules.hotstrings.injector", "adapters.keyboard_hook", "logger.shim" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local observations = { wire = {}, writes = {}, logs = {}, documents = {
			["/field/original"] = "Z", ["/field/successor"] = "SAFE" }, calls = 0, moved = false }
		local function transition(point)
			if options.boundary == point and not observations.moved then
				observations.moved = true; state.path = "/field/successor"
			end
		end
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_level("trace")
		logger.set_sink(function(line)
			observations.logs[#observations.logs + 1] = line
			if line:find("Undo: restoring", 1, true) then transition("undo-log") end
		end)
		package.loaded["logger.shim"] = logger
		local commands, clipboard = {}, "SAVED"
		package.loaded["adapters.shell_runner"] = {
			has_command = function() return true end,
			exec_checked = function() transition("clipboard-read"); return true, clipboard end,
			with_exact_stdin = function(_, text)
				local command = "undo-clipboard-" .. tostring(#commands + 1)
				commands[#commands + 1] = { command = command, text = text }; return command
			end,
			run = function(command)
				for _, item in ipairs(commands) do
					if command == item.command then
						clipboard = item.text; observations.writes[#observations.writes + 1] = item.text
						if item.text == options.trigger then transition("clipboard-write") end
						return true
					end
				end
				return false
			end,
		}
		package.loaded["infra.display_server"] = { is_wayland = function() return false end,
			is_x11 = function() return true end, kind = function() return "x11" end }
		package.loaded["adapters.keyboard_hook"] = { held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end, held_forwarded_keys = function() return {} end,
			emergency_stop = function() observations.stopped = true end }
		local injector
		local passed, failure = pcall(function()
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} } })
			helpers.load_module("adapters.clipboard")
			injector = helpers.load_module("modules.hotstrings.injector")
			injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
				observations.wire[#observations.wire + 1] = code .. ":" .. value
				if value == 1 then
					local text = observations.documents[state.path]
					if code == 14 then text = text:sub(1, -2)
					elseif code == 47 then text = text .. clipboard
					elseif code == 24 then text = text .. "o"
					elseif code == 37 then text = text .. "k" end
					observations.documents[state.path] = text
				end
				return true
			end })
			injector._set_nanosleep_for_test(function(seconds)
				if seconds == .03 then transition("erase-settle") end
			end)
			local wrapped = setmetatable({ inject = function(...)
				observations.calls = observations.calls + 1
				if observations.calls == 1 then return { ok = true, cleanup_ok = true } end
				local _, _, private, _, publication = ...
				observations.private, observations.publication = private, publication
				observations.result = injector.inject(...); return observations.result
			end }, { __index = injector })
			local environment = setmetatable({ secure_focus_guard = guard,
				script_actions = { is_paused = function() return false end },
				Monotonic = { now_ms = function() return state.now end }, _cached_app_id = "owned-editor",
				WordReset = { observe_key = function() return false end, apply_typed_newline = function() return false end },
				terminators_mod = { is_terminator = function() return false end },
				RepeatKey = { is_enabled = function() return false end }, opts = { dry_run = false },
				keylogger = { is_password_app = function() return false end, suppress = function() end,
					unsuppress = function() end, on_keydown = function() end, record_hotstring = function() end,
					-- The physical Backspace that requests the Undo is a manual correction.
					record_correction = function() observations.corrections = (observations.corrections or 0) + 1 end },
				engine = { reset = function() end, apply_expansion = function() end, on_char = function()
					return { trigger = options.trigger, replacement = "ZZ", backspace_count = 1,
						is_private = options.private == true }
				end }, Logger = logger, injector = wrapped,
			}, { __index = _G })
			local character, control, undo = main_callbacks(environment)
			character("x", 30)
			helpers.assert_type(undo(), "table", "Main must arm the Undo through its real expansion ACK path")
			control("backspace", {})
			helpers.assert_eq(observations.corrections, 1, "the Undo Backspace still counts as one manual correction")
			observations.undo = undo(); observations.clipboard = clipboard
			body(observations)
		end)
		if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not passed then error(failure, 0) end
	end)
end

helpers.describe("Main Undo retains its original expansion authority", function()
	for _, trigger in ipairs({ "ok", "☃" }) do
		helpers.it("restores the original trigger on the stable " .. (trigger == "ok" and "native" or "clipboard") .. " route (undo-owner)", function()
			with_undo({ trigger = trigger }, function(state)
				helpers.assert_true(state.result.ok and state.result.cleanup_ok)
				helpers.assert_eq(state.documents["/field/original"], trigger)
				helpers.assert_eq(state.documents["/field/successor"], "SAFE")
				helpers.assert_eq(state.clipboard, "SAVED")
				helpers.assert_eq(state.undo, nil)
			end)
		end)
	end
	for _, boundary in ipairs({ "undo-log", "clipboard-read", "clipboard-write", "erase-settle" }) do
		helpers.it("refuses a successor text field at " .. boundary .. " (undo-owner)", function()
			with_undo({ trigger = "☃", boundary = boundary }, function(state)
				helpers.assert_true(state.moved, "the controlled boundary must actually execute")
				helpers.assert_eq(state.documents["/field/successor"], "SAFE", "Undo must never erase or type into another field")
				helpers.assert_eq(state.result.ok, false)
				helpers.assert_eq(state.result.cleanup_ok, true)
				helpers.assert_eq(state.stopped, nil, "a healthy destination refusal must not stop the keyboard")
				helpers.assert_eq(state.clipboard, "SAVED")
				helpers.assert_eq(state.undo, nil)
			end)
		end)
	end
	helpers.it("keeps the private trigger out of the actual injector trace (undo-owner)", function()
		with_undo({ trigger = "★PRIVATE_UNDO★", private = true }, function(state)
			helpers.assert_true(state.result.ok)
			helpers.assert_eq(table.concat(state.logs, "\n"):find("★PRIVATE_UNDO★", 1, true), nil,
				"a private trigger must not reach the persistent logger")
			helpers.assert_true(state.private, "the private classification must survive the Undo commit record")
			helpers.assert_eq(state.documents["/field/original"], "★PRIVATE_UNDO★")
		end)
	end)
end)
