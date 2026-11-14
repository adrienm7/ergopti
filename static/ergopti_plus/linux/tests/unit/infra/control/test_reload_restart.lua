--- tests/unit/infra/control/test_reload_restart.lua

--- ==============================================================================
--- MODULE: Reload As A Daemon Restart (Linux)
--- DESCRIPTION:
--- The Reload owner restarts the daemon once, joins a request made while a
--- restart is in flight, postpones on native cleanup debt and fails loudly
--- when no restart can be requested (reload-is-a-restart-2026-10-24).
--- ==============================================================================

local helpers = require("tests.helpers")
local ReloadRestart = require("core.lifecycle.engine.reload.restart")

--- Builds a gestures fake whose cleanup answers can be refused.
local function gestures(windows_ok, programs_ok)
	return {
		stop_window_switches = function() return windows_ok end,
		stop_programs = function() return programs_ok end,
	}
end

helpers.describe("Linux Reload is a daemon restart (reload-is-a-restart-2026-10-24)", function()
	helpers.it("postpones a reentrant reload while restart admission is running (reload-reentrant)", function()
		local calls, nested, perform, in_flight, abandon = 0, nil, nil, nil, nil
		local timing = { mark = function() end, clear = function() end }
		perform, in_flight, abandon = ReloadRestart.new({ timing = timing, restart = function()
			calls = calls + 1
			if calls == 1 then
				nested = { perform("nested") }
				helpers.assert_true(in_flight(), "quit must see admission in progress")
				helpers.assert_eq({ abandon() }, { false, "restart admission in progress" })
			end
			return true
		end })
		helpers.assert_eq(perform("outer"), true)
		helpers.assert_eq(calls, 1, "reentrant admission must not launch a second restart")
		helpers.assert_eq(nested, { false, "postponed" })
	end)

	helpers.it("clears reload admission after cleanup raises (reload-reentrant)", function()
		local first = true
		local perform = ReloadRestart.new({ timing = { mark = function() end, clear = function() end },
			gestures = { stop_window_switches = function()
				if first then first = false; error("cleanup failed") end
				return true
			end, stop_programs = function() return true end }, restart = function() return true end })
		helpers.assert_eq(pcall(perform, "first"), false)
		helpers.assert_eq(perform("retry"), true, "a raised cleanup must not strand admission")
	end)

	helpers.it("requests one restart and joins a later request", function()
		local reasons = {}
		local perform = ReloadRestart.new({ gestures = gestures(true, true),
			restart = function(reason) reasons[#reasons + 1] = reason; return true end })
		helpers.assert_eq(perform("the tray menu"), true)
		helpers.assert_eq(perform("SIGHUP"), true, "a request during the restart joins it")
		helpers.assert_eq(#reasons, 1, "the daemon restarts once")
		helpers.assert_eq(reasons[1], "reload")
	end)

	helpers.it("reports a restart in flight so the tray's Quit can be refused (quit-admission)", function()
		local answers = { false, true }
		local perform, in_flight = ReloadRestart.new({ restart = function() return table.remove(answers, 1) end })
		helpers.assert_eq(in_flight(), false)
		perform("the tray menu")
		helpers.assert_eq(in_flight(), false, "a refused restart leaves nothing in flight")
		perform("the tray menu")
		helpers.assert_eq(in_flight(), true)
	end)

	helpers.it("(quit-wins-over-reload) abandons the restart in flight through its cancel", function()
		local cancels, answers = 0, { false, true }
		local perform, in_flight, abandon = ReloadRestart.new({ restart = function() return true end,
			cancel = function() cancels = cancels + 1; return table.remove(answers, 1), "refused" end })
		helpers.assert_eq(abandon(), true, "nothing in flight is nothing to cancel")
		helpers.assert_eq(cancels, 0)
		perform("the tray menu")
		local ok, detail = abandon()
		helpers.assert_eq({ ok, detail }, { false, "refused" })
		helpers.assert_eq(in_flight(), true, "a refused cancellation leaves the restart in flight")
		helpers.assert_eq(abandon(), true)
		helpers.assert_eq(in_flight(), false)
		helpers.assert_eq(perform("SIGHUP"), true, "a reload may be requested again after the abandon")
	end)

	helpers.it("(linux-reload-budget) stamps the request before the restart and retires a refused or abandoned one", function()
		local events = {}
		local timing = { mark = function() events[#events + 1] = "mark" end,
			clear = function() events[#events + 1] = "clear" end }
		local answers = { false, true }
		local perform, _, abandon = ReloadRestart.new({ timing = timing,
			restart = function() events[#events + 1] = "restart"; return table.remove(answers, 1) end,
			cancel = function() return true end })
		perform("the tray menu")
		helpers.assert_eq(events, { "mark", "restart", "clear" }, "a refused restart retires its stamp")
		events = {}
		perform("the tray menu")
		helpers.assert_eq(events, { "mark", "restart" }, "the successor reads the stamp of a requested restart")
		abandon()
		helpers.assert_eq(events, { "mark", "restart", "clear" }, "an abandoned restart retires its stamp")
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
