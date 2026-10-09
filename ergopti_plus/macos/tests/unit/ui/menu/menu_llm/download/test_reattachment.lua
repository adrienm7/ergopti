--- tests/unit/ui/menu/menu_llm/download/test_reattachment.lua

--- ==============================================================================
--- MODULE: MLX Download Reattachment
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture

helpers.describe("MLX download reattachment transaction", function()
	helpers.it("HS-024 reattach reports an interrupted download when its PID is gone", function()
		with_fixture({pid_alive = false}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(#fixture.records.notifications, 1)
			local notification = fixture.records.notifications[1]
			helpers.assert_eq(notification[1], "mlx.download_interrupted")
			helpers.assert_eq(notification[2], "mlx.download_interrupted_body")
			helpers.assert_eq(notification[3], "error")
			helpers.assert_eq(#fixture.records.completions, 0,
				"a failed preflight never claimed a progress presentation")
			helpers.assert_nil(fixture.deps.active_tasks.download_tail)
		end)
	end)

	helpers.it("HS-012 keeps RESUME parked when freshness re-enters PAUSE", function()
		with_fixture({pid_alive = true}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			helpers.assert_true(fixture.controls.pause_reattached_download())
			fixture.controls.fire(3)
			local nested_pause
			helpers.assert_eq(fixture.obj.resume_reattached_download({
				resume_is_current = function()
					nested_pause = fixture.controls.pause_reattached_download()
					return true
				end,
			}), false)
			helpers.assert_eq(nested_pause, false,
				"nested PAUSE must wait for the RESUME freshness callback")
			local live_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					live_poll_timers = live_poll_timers + 1
				end
			end
			helpers.assert_eq(live_poll_timers, 0,
				"a PAUSE-fenced RESUME cannot rearm parked work")
			helpers.assert_true(fixture.obj.resume_reattached_download({
				resume_is_current = function() return true end,
			}))
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					live_poll_timers = live_poll_timers + 1
				end
			end
			helpers.assert_eq(live_poll_timers, 1,
				"a later clean RESUME must rearm exactly one parked poll")
		end)
	end)

	helpers.it("HS-012 revalidates reattachment after a timer start re-enters PAUSE", function()
		with_fixture({
			pid_alive = true,
			timer_by_delay = {
				[3] = {{pause_reattach_on_start = true}, {}},
			},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(fixture.records.reentrant_reattach_pause, false,
				"PAUSE cannot publish inside the exact poll-timer acquisition")
			helpers.assert_nil(fixture.controls.latest("tail"),
				"a paused reattach acquisition cannot start its tail successor")
			helpers.assert_nil(fixture.controls.window,
				"a paused reattach acquisition cannot publish its download window")
			local live_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					live_poll_timers = live_poll_timers + 1
				end
			end
			helpers.assert_eq(live_poll_timers, 0,
				"the rejected acquisition cannot leave a live business successor")
			helpers.assert_true(fixture.obj.has_reattached_download(),
				"the exact parked reattach owner must remain retryable")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"the same PAUSE must settle after acquisition unwinds")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			local retried_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					retried_poll_timers = retried_poll_timers + 1
				end
			end
			helpers.assert_eq(retried_poll_timers, 1,
				"RESUME must retry exactly one parked poll capability")
		end)
	end)

	helpers.it("HS-012 publishes the reattach callback before its PID probe", function()
		with_fixture({
			pid_alive = true,
			pause_reattach_on_pid_probe = true,
		}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(fixture.records.reentrant_reattach_pid_pause, false,
				"PAUSE cannot publish while the exact PID probe remains on-stack")
			helpers.assert_eq(#fixture.records.timers, 0,
				"the paused probe must fence its poll-timer successor")
			helpers.assert_nil(fixture.controls.latest("tail"))
			helpers.assert_nil(fixture.controls.window)
			helpers.assert_true(fixture.obj.has_reattached_download(),
				"the probe must retain the exact parked reattach owner")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"retrying PAUSE after the probe unwinds must settle that owner")
		end)
	end)

	helpers.it("HS-012 parks a poll whose exit probe re-enters PAUSE", function()
		with_fixture({
			pid_alive = true,
			pause_reattach_on_exit_probe = 2,
		}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_type(exact_tail, "table")
			fixture.controls.fire(3)
			helpers.assert_eq(fixture.records.reentrant_reattach_probe_pause, false,
				"PAUSE cannot publish from inside the poll callback")
			local poll_timers = 0
			local live_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 then
					poll_timers = poll_timers + 1
					if timer.live == true then
						live_poll_timers = live_poll_timers + 1
					end
				end
			end
			helpers.assert_eq(poll_timers, 1,
				"the fenced probe must not construct a poll successor")
			helpers.assert_eq(live_poll_timers, 0)
			helpers.assert_eq(fixture.controls.latest("tail"), exact_tail,
				"the parked monitor must retain its exact tail identity")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"retrying the same PAUSE after callback unwind must settle")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			local retried_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					retried_poll_timers = retried_poll_timers + 1
				end
			end
			helpers.assert_eq(retried_poll_timers, 1,
				"RESUME must restore exactly the deferred poll successor")
		end)
	end)

	helpers.it("HS-012 withholds PAUSED while the reattached tail starts", function()
		with_fixture({
			pid_alive = true,
			tail = {pause_reattach_on_start = true},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(fixture.records.reentrant_reattach_tail_pause, false,
				"PAUSE cannot publish while the exact tail start remains on-stack")
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_type(exact_tail, "table")
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, exact_tail)
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"the same tail owner must settle after start unwinds")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			helpers.assert_eq(fixture.controls.latest("tail"), exact_tail,
				"RESUME must retain the exact already-started tail")
		end)
	end)

	helpers.it("HS-012 retries the exact tail-completion timer after nested PAUSE", function()
		with_fixture({
			pid_alive = true,
			timer_by_delay = {
				[0.5] = {{pause_reattach_on_start = true}, {}},
			},
		}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_type(exact_tail, "table")
			helpers.assert_true(exact_tail:complete(0))
			helpers.assert_eq(fixture.records.reentrant_reattach_pause, false,
				"PAUSE cannot publish inside the tail-completion timer acquisition")
			local live_tail_done = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 0.5 and timer.live == true then
					live_tail_done = live_tail_done + 1
				end
			end
			helpers.assert_eq(live_tail_done, 0,
				"the fenced acquisition cannot leave a live tail successor")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"the same tail callback owner must settle after unwind")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 0.5 and timer.live == true then
					live_tail_done = live_tail_done + 1
				end
			end
			helpers.assert_eq(live_tail_done, 1,
				"RESUME must restore exactly the parked tail-completion capability")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 reattach tail " .. mode
			.. " refusal discards synchronous stream", function()
			with_fixture({pid_alive = true, tail = {
				start = mode,
				stream_on_start = "__BYTES__:99\n",
				mutate_on_start = true,
			}}, function(fixture)
				helpers.assert_true(fixture.controls.reattach())
				helpers.assert_eq(#fixture.records.updates, 0)
				local tail = fixture.controls.latest("tail")
				tail:emit("__BYTES__:100\n")
				helpers.assert_eq(#fixture.records.updates, 0,
					"late refused reattach stream must remain inert")
			end)
		end)
	end

	helpers.it("HS-024 replays a committed reattach stream once", function()
		with_fixture({pid_alive = true, tail = {
			stream_on_start = "__BYTES__:99\n",
		}}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			helpers.assert_eq(#fixture.records.updates, 1)
			local tail = fixture.controls.latest("tail")
			tail:complete(0)
			tail:emit("__BYTES__:100\n")
			helpers.assert_eq(#fixture.records.updates, 1,
				"terminal reattach tail must fence late stream")
		end)
	end)

	helpers.it("HS-024 reattach cancellation retains owner and fences late success", function()
		local plan = {pid_alive = true, kill_mode = "false",
			tail = {terminate = "false"}}
		with_fixture(plan, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), true)
			local tail = fixture.controls.latest("tail")
			fixture.controls.window.on_cancel()
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], false)
			tail:complete(0)
			fixture.controls.fire(0.5)
			helpers.assert_eq(fixture.records.server_starts, 0)
			local second_cancels = 0
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function()
				second_cancels = second_cancels + 1
			end, {is_current = function() return true end}), false)
			helpers.assert_eq(second_cancels, 1)
			plan.pid_alive = false
			fixture.controls.fire(0.25)
			helpers.assert_eq(#fixture.records.completions, 1,
				"the revoked reattach owner cannot publish late success")
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), true)
		end)
	end)

	helpers.it("HS-024 reattach async success releases after the exact tail retires", function()
		with_fixture({pid_alive = true}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), true)
			local tail = fixture.controls.latest("tail")
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], true)
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, tail,
				"the terminal owner must retain the still-live exact tail")

			tail:complete(0)
			helpers.assert_nil(fixture.deps.active_tasks.download_tail)
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), true)
			local session_path = "/tmp/hs_mlx_active_download.json"
			local successor_session = fixture.controls.files[session_path]
			helpers.assert_type(successor_session, "string")
			helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)

			tail:complete(0)
			helpers.assert_eq(fixture.controls.files[session_path], successor_session,
				"a duplicate retired-tail callback cannot remove the successor session")
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.server_starts, 0)
		end)
	end)
end)
