--- tests/unit/modules/hotstrings/injector/test_injector_sleep_ceiling.lua

--- ==============================================================================
--- MODULE: Injector Sleep Ceiling Without FFI
--- DESCRIPTION:
--- The injector's pause refuses a wait above the shared timer ceiling on every
--- fallback, not only through the FFI nanosleep binding.
---
--- ROOT CAUSE ENCODED:
--- Only the FFI path checked MAX_TIMER_DELAY_MS (through infra/native_sleep).
--- Without FFI, luv.sleep received 2^53 + 4096 ms, or NaN, unchanged, and the
--- sleep command was forked with it: a wait that never ends, accepted as an
--- ordinary pause (L105). The pause is reached through the selected-output
--- ports the injector hands out, the seam production uses.
--- ==============================================================================

local helpers = require("tests.helpers")

local ABOVE_CEILING = 2 ^ 53 + 4096
local INJECTOR = "modules.hotstrings.injector"
local SELECTED = "modules.hotstrings.selected_output"

--- Loads the injector with a chosen luv and returns its pause.
--- @param luv table|false Fake luv module, or false for a runtime without it.
--- @return function sleep_ms, table injector
local function pause_with(luv)
	local saved_selected, saved_injector = package.loaded[SELECTED], package.loaded[INJECTOR]
	package.loaded[SELECTED] = { new = function(_, _, ports) return ports end }
	local ok, result = pcall(function()
		local injector = helpers.load_module_with_dependency(INJECTOR, "luv", luv)
		injector._set_nanosleep_for_test(false)
		local ports = injector.prepare_selected("x", { current = function() return true end })
		return { sleep = ports.sleep, injector = injector }
	end)
	package.loaded[SELECTED], package.loaded[INJECTOR] = saved_selected, saved_injector
	if not ok then error(result, 0) end
	return result.sleep, result.injector
end

--- Runs body with os.execute recorded, restoring it afterwards.
--- @param body function Receives the array of recorded commands.
local function recording_execute(body)
	local real, commands = os.execute, {}
	os.execute = function(command) commands[#commands + 1] = tostring(command); return true end
	local ok, err = pcall(body, commands)
	os.execute = real
	if not ok then error(err, 0) end
end

helpers.describe("injector: the no-FFI pause keeps the timer ceiling (L105)", function()
	helpers.it("refuses an over-ceiling or NaN wait before luv.sleep sees it", function()
		local waits = {}
		local sleep_ms, injector = pause_with({ sleep = function(ms) waits[#waits + 1] = ms end })
		for _, ms in ipairs({ ABOVE_CEILING, 0 / 0, math.huge }) do
			local ok, err = pcall(sleep_ms, ms)
			helpers.assert_true(not ok, "a " .. tostring(ms) .. " ms pause must be refused")
			helpers.assert_true(tostring(err):find("timer ceiling", 1, true) ~= nil, "refusal names the ceiling: " .. tostring(err))
		end
		helpers.assert_eq(#waits, 0, "luv.sleep never receives a refused wait")
		sleep_ms(5)
		helpers.assert_eq(waits, { 5 }, "an ordinary pause still reaches luv.sleep")
		injector._set_nanosleep_for_test(nil)
	end)

	helpers.it("refuses an over-ceiling wait before the sleep command is forked", function()
		local sleep_ms, injector = pause_with(false)
		recording_execute(function(commands)
			local ok = pcall(sleep_ms, ABOVE_CEILING)
			helpers.assert_true(not ok, "an over-ceiling pause must be refused")
			helpers.assert_eq(#commands, 0, "no sleep command runs for a refused wait")
			sleep_ms(5)
			helpers.assert_eq(commands, { "sleep 0.005" }, "an ordinary pause still forks the fallback")
		end)
		injector._set_nanosleep_for_test(nil)
	end)
end)
