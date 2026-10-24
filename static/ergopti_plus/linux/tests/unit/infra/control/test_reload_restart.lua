--- tests/unit/infra/control/test_reload_restart.lua

--- ==============================================================================
--- MODULE: Reload As A Daemon Restart (Linux)
--- DESCRIPTION:
--- The Reload owner restarts the daemon once, joins a request made while a
--- restart is in flight, postpones on native cleanup debt and fails loudly
--- when no restart can be requested (reload-is-a-restart-2026-10-24).
--- ==============================================================================

local helpers = require("tests.helpers")
local ReloadRestart = require("infra.reload_restart")

--- Builds a gestures fake whose cleanup answers can be refused.
local function gestures(windows_ok, programs_ok)
	return {
		stop_window_switches = function() return windows_ok end,
		stop_programs = function() return programs_ok end,
	}
end

helpers.describe("Linux Reload is a daemon restart (reload-is-a-restart-2026-10-24)", function()
	helpers.it("requests one restart and joins a later request", function()
		local reasons = {}
		local perform = ReloadRestart.new({ gestures = gestures(true, true),
			restart = function(reason) reasons[#reasons + 1] = reason; return true end })
		helpers.assert_eq(perform("the tray menu"), true)
		helpers.assert_eq(perform("SIGHUP"), true, "a request during the restart joins it")
		helpers.assert_eq(#reasons, 1, "the daemon restarts once")
		helpers.assert_eq(reasons[1], "reload")
	end)

	helpers.it("postpones on window or program cleanup debt without restarting", function()
		for _, case in ipairs({ { false, true }, { true, false } }) do
			local restarted = 0
			local perform = ReloadRestart.new({ gestures = gestures(case[1], case[2]),
				restart = function() restarted = restarted + 1; return true end })
			local started, why = perform("the tray menu")
			helpers.assert_eq(started, false)
			helpers.assert_eq(why, "postponed")
			helpers.assert_eq(restarted, 0)
		end
	end)

	helpers.it("fails, and may be asked again, when no restart can be requested", function()
		local answers = { false, true }
		local perform = ReloadRestart.new({ restart = function() return table.remove(answers, 1) end })
		local started, why = perform("the paths editor")
		helpers.assert_eq(started, false)
		helpers.assert_eq(why, "failed")
		helpers.assert_eq(perform("the paths editor"), true, "a refused restart leaves nothing in flight")
	end)

	helpers.it("treats a raising restart as a failure", function()
		local perform = ReloadRestart.new({ restart = function() error("systemctl exploded") end })
		local started, why = perform("SIGHUP")
		helpers.assert_eq(started, false)
		helpers.assert_eq(why, "failed")
	end)
end)

return true
