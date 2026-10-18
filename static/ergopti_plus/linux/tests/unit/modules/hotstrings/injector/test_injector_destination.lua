--- tests/unit/modules/hotstrings/injector/test_injector_destination.lua

--- ==============================================================================
--- MODULE: Clipboard Injection Destination Boundaries
--- DESCRIPTION:
--- Actual Injector, Clipboard, Guard, Detector and policy run against controlled
--- command/output ports. No native input qualification is claimed by these units.
--- ==============================================================================
local helpers = require("tests.helpers")
local fixture = require("tests.support.text_owner_fixture")

--- Runs the complete injection with controlled clipboard I/O and focus changes.
--- @param boundary string Controlled external transition point, or stable.
--- @param body function Receives result, wire, writes, state and stopped count.
local function injection(boundary, body)
	fixture.with(function(guard, state)
		local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server",
			"adapters.keyboard_layout", "modules.hotstrings.injector", "adapters.keyboard_hook", "logger.shim" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local rows, writes, commands, held, stopped = {}, {}, {}, {}, 0
		local errors = {}
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_sink(function() end)
		logger.set_error_observer(function(_, template) errors[#errors + 1] = template end)
		package.loaded["logger.shim"] = logger
		local transitioned = false
		local function transition(point)
			if (boundary == point or point == "write" and (boundary == "restore-false" or boundary == "restore-throw")
				or point == "ctrl-down" and boundary == "cleanup-refusal") and not transitioned then
				transitioned = true
				state.path = "/field/successor"
				if point == "password" then state.role = 40 end
				-- This control delivers revocation to RAM; a new native observation alone
				-- is intentionally not queried by the per-DOWN cached admission.
				if point == "ctrl-down" then guard.invalidate() end
			end
		end
		package.loaded["adapters.shell_runner"] = {
			has_command = function() return true end,
			exec_checked = function() transition("read"); return true, "SAVED" end,
			with_exact_stdin = function(_, text)
				local command = "controlled-clipboard-" .. tostring(#commands + 1)
				commands[#commands + 1] = { command = command, text = text }
				return command
			end,
			run = function(command)
				for _, item in ipairs(commands) do
					if item.command == command then
						writes[#writes + 1] = item.text
						if item.text == "SAVED" and boundary == "restore-false" then return false end
						if item.text == "SAVED" and boundary == "restore-throw" then error("controlled restore transport failure") end
						if item.text == "☃" then transition("write") end
						return true
					end
				end
				return false
			end,
		}
		package.loaded["infra.display_server"] = {
			is_wayland = function() return false end, is_x11 = function() return true end,
			kind = function() return "x11" end,
		}
		package.loaded["adapters.keyboard_hook"] = {
			held_text_modifier_codes = function() return {} end, held_shortcut_modifier_codes = function() return {} end,
			held_forwarded_keys = function() return {} end, emergency_stop = function() stopped = stopped + 1 end,
		}
		local injector
		local ok, detail = pcall(function()
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} } })
			local shortcut = layout.shortcut_keycode
			layout.shortcut_keycode = function(...)
				transition("lookup")
				return shortcut(...)
			end
			helpers.load_module("adapters.clipboard")
			injector = helpers.load_module("modules.hotstrings.injector")
			injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
				if code == 47 and value == 1 then
					if boundary == "native-refusal" then return false end
					if boundary == "native-refusal-revoked" or boundary == "native-throw-revoked" then
						guard.invalidate()
						if boundary == "native-throw-revoked" then error("controlled wire failure") end
						return false
					end
				end
				if boundary == "cleanup-refusal" and code == 29 and value == 0 then return false end
				rows[#rows + 1] = code .. ":" .. value
				held[code] = value == 1 or nil
				if code == 29 and value == 1 then transition("ctrl-down") end
				return true
			end })
			injector._set_nanosleep_for_test(function(seconds)
				if seconds == .03 then transition(boundary == "password" and "password" or "settle") end
				if seconds == .12 then transition("postpaste") end
			end)
			local owner = assert(guard.capture_text_owner())
			transition("before-erase")
			local result = injector.inject(3, "☃", false, nil, owner)
			if boundary ~= "cleanup-refusal" then helpers.assert_eq(held, {}, "original owned UP cleanup always balances the wire") end
			body(result, rows, writes, state, stopped, transitioned, held)
			local real_failure = boundary:find("native-", 1, true) == 1
				or boundary == "cleanup-refusal" or boundary == "restore-false" or boundary == "restore-throw"
			if real_failure then
				helpers.assert_true(#errors > 0, "a real I/O or key cleanup failure reaches the error observer")
			else
				helpers.assert_eq(errors, {}, "a healthy destination refusal never opens the ERROR observer")
			end
		end)
		if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(detail, 0) end
	end)
end

helpers.describe("ordinary clipboard destination admission", function()
	helpers.it("delivers the whole stable replacement and restores the clipboard", function()
		injection("stable", function(result, rows, writes, _, stopped)
			helpers.assert_true(result.ok and result.cleanup_ok)
			helpers.assert_eq(table.concat(rows, " "), "14:1 14:0 14:1 14:0 14:1 14:0 29:1 47:1 47:0 29:0")
			helpers.assert_eq(writes, { "☃", "SAVED" })
			helpers.assert_eq(stopped, 0)
		end)
	end)
	helpers.it("still emergency-stops after an actual paste emission refusal", function()
		injection("native-refusal", function(result, rows, writes, _, stopped)
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, true)
			helpers.assert_eq(table.concat(rows, " "), "14:1 14:0 14:1 14:0 14:1 14:0 29:1 47:0 29:0")
			helpers.assert_eq(writes, { "☃", "SAVED" })
			helpers.assert_eq(stopped, 1, "a real refused wire write still returns the keyboard")
		end)
	end)
	for _, boundary in ipairs({ "native-refusal-revoked", "native-throw-revoked" }) do
		helpers.it("keeps real wire failure authoritative despite revocation at " .. boundary, function()
			injection(boundary, function(result, rows, writes, _, stopped)
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(result.cleanup_ok, true)
				helpers.assert_eq(table.concat(rows, " "), "14:1 14:0 14:1 14:0 14:1 14:0 29:1 47:0 29:0")
				helpers.assert_eq(writes, { "☃", "SAVED" })
				helpers.assert_eq(stopped, 1, "a stale owner never hides a real wire failure")
			end)
		end)
	end
	helpers.it("keeps refused original key-UP debt visible after destination revocation", function()
		injection("cleanup-refusal", function(result, rows, writes, _, stopped, transitioned, held)
			helpers.assert_true(transitioned)
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, false)
			helpers.assert_eq(table.concat(rows, " "), "14:1 14:0 14:1 14:0 14:1 14:0 29:1")
			helpers.assert_eq(held, { [29] = true }, "the output port refused the exact outstanding original UP")
			helpers.assert_eq(writes, { "☃", "SAVED" })
			helpers.assert_eq(stopped, 1, "a refused cleanup can never masquerade as a healthy focus change")
		end)
	end)
	for _, boundary in ipairs({ "restore-false", "restore-throw" }) do
		helpers.it("keeps clipboard restoration failure authoritative at " .. boundary, function()
			injection(boundary, function(result, rows, writes, _, stopped, transitioned)
				helpers.assert_true(transitioned, "the destination expires after staging")
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(result.error, "clipboard restoration failed")
				helpers.assert_eq(result.cleanup_ok, true, "native key cleanup alone remains acknowledged")
				helpers.assert_eq(table.concat(rows, " "), "14:1 14:0 14:1 14:0 14:1 14:0")
				helpers.assert_eq(writes, { "☃", "SAVED" }, "restoration was attempted but not acknowledged")
				helpers.assert_eq(stopped, 1, "a real clipboard restoration failure is never downgraded to a focus refusal")
			end)
		end)
	end
	for _, point in ipairs({ "before-erase", "read", "write", "settle", "lookup", "password", "postpaste", "ctrl-down" }) do
		helpers.it("refuses a successor at " .. point .. " while preserving original cleanup", function()
			injection(point, function(result, rows, writes, _, stopped, transitioned)
				helpers.assert_true(transitioned, "the actual requested blocking boundary must run")
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(result.cleanup_ok, true)
				local expected = point == "before-erase" and "" or "14:1 14:0 14:1 14:0 14:1 14:0"
				if point == "postpaste" then expected = expected .. " 29:1 47:1 47:0 29:0" end
				if point == "ctrl-down" then expected = expected .. " 29:1 29:0" end
				helpers.assert_eq(table.concat(rows, " "), expected,
					"a changed destination gets no new paste DOWN; already delivered text is not rolled back")
				helpers.assert_eq(writes, (point == "before-erase" or point == "read") and {} or { "☃", "SAVED" })
				helpers.assert_eq(stopped, 0, "destination refusal never emergency-stops a healthy keyboard")
			end)
		end)
	end
end)
