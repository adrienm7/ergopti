--- tests/unit/infra/logger/test_hold_attribution.lua

--- ==============================================================================
--- MODULE: Slow-callback report — phase attribution
--- DESCRIPTION:
--- A timer callback that holds the main thread for a second is reported with
--- the long phases that ran inside it (phase_stats ring), so the next log says
--- not only which callback stalled but which step of it. Shorter holds (250 ms
--- and more) are only counted for the periodic phase summary.
--- ==============================================================================

local helpers = require("tests.helpers")

local NS_PER_MS = 1000000

--- Runs `body` over a fresh logger installed on a scripted clock.
--- @param body function Receives (Logger, clock, captured, PhaseStats).
local function with_capture(body)
	local saved_logger = package.loaded["infra.logger"]
	package.loaded["infra.logger"] = nil
	local Fresh = require("infra.logger")
	helpers.admit_logger_privacy(Fresh)
	local PhaseStats = require("infra.phase_stats")
	PhaseStats.reset()
	local hs = _G.hs
	local saved = {
		doAfter = hs.timer.doAfter, doEvery = hs.timer.doEvery, new = hs.timer.new,
		delayed_new = hs.timer.delayed and hs.timer.delayed.new or nil,
		absoluteTime = hs.timer.absoluteTime, print = _G.print, execute = hs.execute,
	}
	local clock = { now = 0 }
	-- A scripted shell: each command costs 45 ms of the scripted clock.
	hs.execute = function() clock.now = clock.now + 45 * NS_PER_MS; return "", true, "exit", 0 end
	hs.timer.absoluteTime = function() return clock.now end
	hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end
	local captured = {}
	Fresh.set_sink(function(line) captured[#captured + 1] = line end)
	Fresh.set_level("DEBUG")
	Fresh.install_runtime_error_capture()
	local ok, err = pcall(body, Fresh, clock, captured, PhaseStats)
	Fresh.set_sink(nil)
	hs.timer.doAfter, hs.timer.doEvery, hs.timer.new = saved.doAfter, saved.doEvery, saved.new
	hs.timer.absoluteTime = saved.absoluteTime
	hs.execute = saved.execute
	if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
	_G.print = saved.print
	PhaseStats.reset()
	package.loaded["infra.logger"] = saved_logger
	if not ok then error(err, 0) end
end

helpers.describe("slow-callback report: phase attribution", function()
	helpers.it("names the long phases that ran inside a reported hold", function()
		with_capture(function(_, clock, captured, PhaseStats)
			hs.timer.doAfter(0, function()
				clock.now = clock.now + 100 * NS_PER_MS
				PhaseStats.add("toml.parse", 700 * NS_PER_MS)
				clock.now = clock.now + 1100 * NS_PER_MS
			end)
			local report
			for _, line in ipairs(captured) do
				if line:find("held the main thread", 1, true) then report = line end
			end
			helpers.assert_true(report ~= nil, "a 1.2 s hold is reported")
			helpers.assert_true(report:find("Phases inside the hold: toml.parse=700.0 ms", 1, true) ~= nil,
				"the report names the phase")
			helpers.assert_true(report:find(" Lua heap %d+%->%d+ MB%.$") ~= nil,
				"the report gives the Lua heap before and after, so a collection inside the hold shows")
		end)
	end)

	helpers.it("counts a 250 ms hold for the summary and names it at INFO, not as a warning", function()
		with_capture(function(_, clock, captured, PhaseStats)
			hs.timer.doAfter(0, function() clock.now = clock.now + 300 * NS_PER_MS end)
			for _, line in ipairs(captured) do
				helpers.assert_true(not line:find("held the main thread", 1, true), "no report below 1 s")
			end
			local named
			for _, line in ipairs(captured) do
				if line:find("Main-thread hold of 300 ms", 1, true) then named = line end
			end
			helpers.assert_true(named ~= nil and named:find("test_hold_attribution.lua", 1, true) ~= nil,
				"a 250 ms to 1 s hold is named once at INFO with its callback site")
			helpers.assert_eq(PhaseStats.counter("runtime.timer_hold_over_250ms"), 1)
			helpers.assert_eq(PhaseStats.counter("runtime.timer_hold_over_1000ms"), 0)
		end)
	end)
	helpers.it("names the synchronous shell forks inside a hold by program only", function()
		with_capture(function(_, clock, captured)
			hs.timer.doAfter(0, function()
				hs.execute("mkdir -p '/Users/someone/private dir'")
				hs.execute("LC_ALL=C /bin/ls -led '/Users/someone/file'")
				hs.execute("'/Users/someone/my script.sh' --flag")
				clock.now = clock.now + 1100 * NS_PER_MS
			end)
			local report
			for _, line in ipairs(captured) do
				if line:find("held the main thread", 1, true) then report = line end
			end
			helpers.assert_true(report ~= nil, "a 1.2 s hold is reported")
			for _, phase in ipairs({ "shell.mkdir=45.0 ms", "shell.ls=45.0 ms", "shell.other=45.0 ms" }) do
				helpers.assert_true(report:find(phase, 1, true) ~= nil, "the report names " .. phase .. ": " .. report)
			end
			helpers.assert_true(report:find("someone", 1, true) == nil, "no path reaches the report")
		end)
	end)
end)
