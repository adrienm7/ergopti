--- tests/unit/modules/llm/test_mlx_warmup_gated_on_disable.lua

--- ==============================================================================
--- MODULE: Regression — api_mlx self-retry warmup stops on pause/disable (M-3)
--- DESCRIPTION:
--- api_mlx.warmup() has its own self-rescheduling retry chain (TimerScheduler.after
--- 2s) that is gated only on _is_ready/_load_failed/_warmup_in_flight. Before M-3,
--- calling pause_all() bumped warmup_controller._warmup_gen (stopping the scheduled
--- chain) but left api_mlx's own retry free to keep POSTing through the pause and
--- fire the "server ready" notification mid-pause.
---
--- Fix: api_mlx.stop_warmup() sets _warmup_stopped=true + bumps _warmup_gen; the
--- early check in M.warmup() short-circuits any pending retry. resume_warmup()
--- clears the flag. script_control.pause_all() calls stop_warmup(); resume_all()
--- calls resume_warmup() before re-arming warmup_controller.
---
--- Tests (all source-level; no hs.http stub needed):
---   1. api_mlx exports stop_warmup and resume_warmup.
---   2. M.warmup() has a _warmup_stopped guard.
---   3. script_control.pause_all source calls api.stop_warmup.
---   4. script_control.resume_all source calls api.resume_warmup.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src(rel_path)
	local path = helpers.driver_root() .. rel_path
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, rel_path .. " must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end





-- =======================================================================
-- ======================================================================
-- ======= 1/ api_mlx exports stop_warmup and resume_warmup (M-3) =======
-- ======================================================================
-- =======================================================================

helpers.describe("M-3: api_mlx self-retry gate (source — public API)", function()

	helpers.it("api_mlx.lua defines M.stop_warmup", function()
		local src = read_src("modules/llm/api_mlx.lua")
		helpers.assert_true(src:find("function M%.stop_warmup", 1, false) ~= nil
			or src:find("M.stop_warmup", 1, true) ~= nil,
			"api_mlx must expose M.stop_warmup() so pause_all can stop the self-retry chain")
	end)

	helpers.it("api_mlx.lua defines M.resume_warmup", function()
		local src = read_src("modules/llm/api_mlx.lua")
		helpers.assert_true(src:find("function M%.resume_warmup", 1, false) ~= nil
			or src:find("M.resume_warmup", 1, true) ~= nil,
			"api_mlx must expose M.resume_warmup() so resume_all can re-enable the retry chain")
	end)

	helpers.it("api_mlx.lua has a _warmup_stopped guard in M.warmup()", function()
		local src = read_src("modules/llm/api_mlx.lua")
		helpers.assert_true(src:find("_warmup_stopped", 1, true) ~= nil,
			"M.warmup() must check _warmup_stopped to short-circuit mid-pause retries")
	end)
end)





-- =====================================================================================
-- ====================================================================================
-- ======= 2/ script_control.lua calls stop/resume_warmup on pause/resume (M-3) =======
-- ====================================================================================
-- =====================================================================================

helpers.describe("M-3: script_control wires api_mlx stop/resume (source)", function()

	helpers.it("pause_all calls api.stop_warmup", function()
		local src = read_src("modules/shortcuts/script_control.lua")
		-- The pause block must call stop_warmup() on the api_mlx handle
		helpers.assert_true(src:find("stop_warmup", 1, true) ~= nil,
			"script_control.pause_all must call api.stop_warmup() to halt the api_mlx self-retry chain (M-3)")
	end)

	helpers.it("resume_all calls api.resume_warmup", function()
		local src = read_src("modules/shortcuts/script_control.lua")
		helpers.assert_true(src:find("resume_warmup", 1, true) ~= nil,
			"script_control.resume_all must call api.resume_warmup() to re-enable the api_mlx self-retry chain (M-3)")
	end)

	helpers.it("resume_warmup appears before schedule_warmup_with_retry in resume_all", function()
		local src = read_src("modules/shortcuts/script_control.lua")
		local resume_pos = src:find("resume_warmup", 1, true)
		local sched_pos  = src:find("schedule_warmup_with_retry", 1, true)
		helpers.assert_true(resume_pos ~= nil and sched_pos ~= nil,
			"both resume_warmup and schedule_warmup_with_retry must be present")
		helpers.assert_true(resume_pos < sched_pos,
			"resume_warmup() must be called BEFORE schedule_warmup_with_retry in resume_all")
	end)
end)
