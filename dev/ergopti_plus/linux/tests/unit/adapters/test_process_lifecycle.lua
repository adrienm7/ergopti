--- tests/unit/adapters/test_process_lifecycle.lua
---
--- ==============================================================================
--- MODULE: Process Snapshot Failures Must Not Synthesize Mass Events
--- DESCRIPTION:
--- A failed `ps` snapshot used to read as an empty machine: the tick diffed it
--- against the last known set, firing a quit callback for EVERY known process,
--- then a launch callback for every one of them when ps recovered. A transient
--- fork failure therefore looked like the whole desktop quitting and relaunching
--- within four seconds.
---
--- These tests drive the real M.start()/M.tick() with a stubbed io.popen and
--- assert on the exact callback sequences.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body with io.popen stubbed to replay canned `ps` outputs.
--- Each entry of outputs is either a string (ps stdout, exit 0) or false (fork
--- failure: io.popen returns nil). Restores io.popen even on failure.
--- @param outputs table Array of string|false.
--- @param body function Receives nothing; reads popen calls in order.
local function with_ps(outputs, body)
	local real_popen = io.popen
	local at = 0
	io.popen = function(cmd)
		at = at + 1
		local out = outputs[at]
		if out == nil then out = outputs[#outputs] end
		if out == false then return nil end
		local lines = {}
		for line in (tostring(out) .. "\n"):gmatch("([^\n]*)\n") do
			lines[#lines + 1] = line
		end
		local pos = 0
		return {
			lines = function()
				return function()
					pos = pos + 1
					return lines[pos]
				end
			end,
			close = function() return true end,
		}
	end
	local ok, err = pcall(body)
	io.popen = real_popen
	if not ok then error(err, 0) end
end

--- Fresh lifecycle module with recording launch/quit callbacks.
--- @return table module, table launched, table quit
local function fresh_lifecycle()
	local M = helpers.load_module("adapters.process_lifecycle")
	local launched, quit = {}, {}
	M.onAppLaunch(function(name) launched[#launched + 1] = name end)
	M.onAppQuit(function(name) quit[#quit + 1] = name end)
	return M, launched, quit
end

local PS_AB = "COMMAND\na\nb\n"
local PS_ABC = "COMMAND\na\nb\nc\n"
local PS_AC = "COMMAND\na\nc\n"

-- process_every = floor(2.0 / 0.25) = 8: the process poll runs on these ticks.
local PROCESS_TICK = 8

helpers.describe("process_lifecycle: a failed snapshot fires nothing (ps-storm)", function()

	helpers.it("ps-storm: a failed ps reports no quits and no launches", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ false }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(#quit, 0,
				"a failed snapshot is not an empty machine — quitting every process is fabricated")
			helpers.assert_eq(#launched, 0,
				"and nothing launched either")
		end)
	end)

	helpers.it("ps-storm: recovery after a failure reports only the real delta", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ false }, function()
				M.tick(PROCESS_TICK)
			end)
			with_ps({ PS_ABC }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(quit, {},
				"no process quit across a ps failure and its recovery")
			helpers.assert_eq(launched, { "c" },
				"only the genuinely new process reports as launched")
		end)
	end)

	helpers.it("ps-storm: empty ps output is a failure, not an empty desktop", function()
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ "COMMAND\n" }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(#quit, 0,
				"a header-only read must not quit every known process")
			helpers.assert_eq(#launched, 0)
		end)
	end)

	helpers.it("ps-storm: a failed start adopts the first snapshot silently", function()
		with_ps({ false }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_AB }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(launched, {},
				"processes already running when ps recovers did not launch")
			helpers.assert_eq(quit, {})
		end)
	end)

	helpers.it("ps-storm: the ordinary diff still reports real launches and quits", function()
		-- Without this, the three cases above pass on a module that never
		-- diffs at all — which is precisely the failure being fenced here,
		-- one level down.
		with_ps({ PS_AB }, function()
			local M, launched, quit = fresh_lifecycle()
			M.start()
			with_ps({ PS_ABC }, function()
				M.tick(PROCESS_TICK)
			end)
			helpers.assert_eq(launched, { "c" }, "a real launch must still fire")
			with_ps({ PS_AC }, function()
				M.tick(PROCESS_TICK)
			end)
			M.stop()
			helpers.assert_eq(quit, { "b" }, "a real quit must still fire")
		end)
	end)

end)
