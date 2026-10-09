--- tests/unit/ui/menu/menu_llm/download/test_pause_reentry.lua

--- ==============================================================================
--- MODULE: MLX Download Pause Reentry
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture
local assert_cancelled = fixture_support.assert_cancelled
local launch_detached_download = fixture_support.launch_detached_download

helpers.describe("MLX download pause and reentry", function()
	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 retains launcher construction debt after PAUSE " .. mode,
			function()
				with_fixture({
					requirement_lifecycle = true,
					launcher = {
						pause_on_construct = "requirement",
						terminate = mode,
					},
				}, function(fixture)
					helpers.assert_eq(fixture.controls.pull(), false)
					helpers.assert_eq(
						fixture.records.reentrant_launcher_construction_pause, false,
						"PAUSE cannot publish while launcher construction is on-stack")
					assert_cancelled(fixture, "script_paused")
					local exact_launcher = fixture.controls.latest("launcher")
					helpers.assert_type(exact_launcher, "table")
					helpers.assert_nil(fixture.deps.active_tasks.download,
						"an exact stopped proof settles a candidate that never started")
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
					helpers.assert_eq(exact_launcher:complete(0), false,
						"late completion from the settled candidate must stay inert")
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
				end)
			end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 revalidates launcher rollback after PAUSE " .. mode,
			function()
				with_fixture({
					requirement_lifecycle = true,
					launcher = {
						start = "false",
						mutate_on_start = true,
						pause_after_terminate = "requirement",
						terminate = mode,
					},
				}, function(fixture)
					helpers.assert_eq(fixture.controls.pull(), false)
					helpers.assert_eq(
						fixture.records.reentrant_launcher_termination_pause, false,
						"PAUSE cannot publish during exact launcher rollback")
					local refusal_icons = 0
					for _, label in ipairs(fixture.records.callback_labels) do
						if label == "MLX launcher-refusal icon reset" then
							refusal_icons = refusal_icons + 1
						end
					end
					helpers.assert_eq(refusal_icons, 0,
						"rollback PAUSE must fence failure UI")
					local exact_launcher = fixture.controls.latest("launcher")
					helpers.assert_eq(fixture.deps.active_tasks.download, exact_launcher)
					helpers.assert_eq(fixture.records.requirement_settlements or 0, 0)
					exact_launcher:complete(0)
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
				end)
			end)
	end

	helpers.it("HS-012 rejects a truthy launcher start already proven stopped", function()
		with_fixture({launcher = {
			{running_after_start = false},
			{},
		}}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			assert_cancelled(fixture, "launcher_start_refused")
			helpers.assert_nil(fixture.deps.active_tasks.download)
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}))
		end)
	end)

	helpers.it("HS-012 rejects a truthy regular tail start already proven stopped", function()
		with_fixture({
			requirement_lifecycle = true,
			tail = {running_after_start = false},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			helpers.assert_eq(launcher:complete(0), false)
			assert_cancelled(fixture, "tail_task_start_refused")
			helpers.assert_nil(fixture.deps.active_tasks.download_tail)
			fixture.controls.fire(0.25)
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}))
		end)
	end)

	for _, probe_mode in ipairs({"nil", "throw", "non_boolean"}) do
		helpers.it("HS-012 fails closed on launcher liveness probe " .. probe_mode,
			function()
				with_fixture({launcher = {
					{
						running_probe = probe_mode,
						terminate = "false",
					},
					{},
				}}, function(fixture)
					helpers.assert_eq(fixture.controls.pull(), false)
					assert_cancelled(fixture, "launcher_start_refused")
					local exact_launcher = fixture.controls.latest("launcher")
					helpers.assert_eq(fixture.deps.active_tasks.download, exact_launcher,
						"an inconclusive liveness probe must retain the exact task")
					helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}), false)
					exact_launcher:complete(0)
					helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}))
				end)
			end)
	end

	helpers.it("HS-012 fails closed on regular tail non-boolean liveness", function()
		with_fixture({
			requirement_lifecycle = true,
			tail = {running_probe = "non_boolean", terminate = "false"},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			helpers.assert_eq(launcher:complete(0), false)
			assert_cancelled(fixture, "tail_task_start_refused")
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, exact_tail)
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), false)
			exact_tail:complete(0)
			fixture.controls.fire(0.25)
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}))
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 consumes stopped proof after launcher terminate " .. mode,
			function()
				with_fixture({launcher = {
					terminate = mode,
					terminate_stops = true,
				}}, function(fixture)
					helpers.assert_true(fixture.controls.pull())
					helpers.assert_true(fixture.controls.window.on_cancel())
					helpers.assert_nil(fixture.deps.active_tasks.download)
					helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}))
				end)
			end)

		helpers.it("HS-012 consumes stopped proof after tail terminate " .. mode,
			function()
				with_fixture({
					requirement_lifecycle = true,
					tail = {terminate = mode, terminate_stops = true},
				}, function(fixture)
					helpers.assert_true(fixture.controls.pull())
					launch_detached_download(fixture)
					fixture.controls.requirement_child.partial.pid = nil
					helpers.assert_true(fixture.controls.window.on_cancel())
					helpers.assert_nil(fixture.deps.active_tasks.download_tail)
					helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}))
				end)
			end)
	end

	helpers.it("HS-012 fences launcher terminal UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_update_icon = "MLX launcher-failure icon reset",
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			helpers.assert_eq(launcher:complete(1), false)
			helpers.assert_eq(fixture.records.reentrant_update_icon_pause, false,
				"PAUSE cannot publish from inside the launcher terminal callback")
			assert_cancelled(fixture, "script_paused")
			helpers.assert_eq(#fixture.records.completions, 0,
				"a PAUSE-revoked terminal cannot update the download window")
			helpers.assert_eq(#fixture.records.notifications, 0,
				"a PAUSE-revoked terminal cannot notify after owner removal")
			helpers.assert_nil(fixture.controls.latest("tail"))
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences buffered launcher terminal UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_update_icon = "MLX launcher-failure icon reset",
			launcher = {complete_on_start = true, complete_code = 1},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			helpers.assert_eq(fixture.records.reentrant_update_icon_pause, false,
				"PAUSE cannot publish while buffered terminal work is replayed")
			assert_cancelled(fixture, "script_paused")
			helpers.assert_eq(#fixture.records.completions, 0)
			helpers.assert_eq(#fixture.records.notifications, 0)
			helpers.assert_nil(fixture.controls.latest("tail"))
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences launcher stdout UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_window_update = "requirement",
			launcher = {complete_on_terminate = true},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			helpers.assert_eq(launcher:emit("launcher business\n"), false)
			helpers.assert_eq(fixture.records.reentrant_window_update_pause, false,
				"PAUSE cannot publish while launcher stdout is on-stack")
			assert_cancelled(fixture, "script_paused")
			local progress_icons = 0
			for _, label in ipairs(fixture.records.callback_labels) do
				if label == "MLX download progress icon" then
					progress_icons = progress_icons + 1
				end
			end
			helpers.assert_eq(progress_icons, 0,
				"the revoked stdout callback cannot publish its UI successor")
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences buffered launcher stdout after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_window_update = "requirement",
			launcher = {
				stream_on_start = "launcher business\n",
				complete_on_terminate = true,
			},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			helpers.assert_eq(fixture.records.reentrant_window_update_pause, false,
				"PAUSE cannot publish while buffered stdout is replayed")
			assert_cancelled(fixture, "script_paused")
			local progress_icons = 0
			for _, label in ipairs(fixture.records.callback_labels) do
				if label == "MLX download progress icon" then
					progress_icons = progress_icons + 1
				end
			end
			helpers.assert_eq(progress_icons, 0)
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences tail stdout UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_window_update = "requirement",
			pid_alive = false,
			tail = {complete_on_terminate = true},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")
			fixture.controls.requirement_child.partial.pid = nil
			helpers.assert_eq(tail:emit("__BYTES__:99\n"), false)
			helpers.assert_eq(fixture.records.reentrant_window_update_pause, false,
				"PAUSE cannot publish while tail stdout is on-stack")
			assert_cancelled(fixture, "script_paused")
			local progress_icons = 0
			for _, label in ipairs(fixture.records.callback_labels) do
				if label == "MLX download progress icon" then
					progress_icons = progress_icons + 1
				end
			end
			helpers.assert_eq(progress_icons, 0,
				"the revoked tail callback cannot publish its UI successor")
		end)
	end)

	helpers.it("HS-012 fences tail terminal successor after nested PAUSE", function()
		local plan = {
			requirement_lifecycle = true,
			pid_alive = false,
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")
			fixture.controls.requirement_child.partial.pid = nil
			plan.pause_on_logger_callback = "MLX download freshness check"
			plan.logger_pause_record = "reentrant_tail_terminal_pause"
			helpers.assert_eq(tail:complete(0), false)
			helpers.assert_eq(fixture.records.reentrant_tail_terminal_pause, false,
				"PAUSE cannot publish while the tail terminal callback is on-stack")
			assert_cancelled(fixture, "script_paused")
			local live_tail_done = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 0.5 and timer.live == true then
					live_tail_done = live_tail_done + 1
				end
			end
			helpers.assert_eq(live_tail_done, 0,
				"the revoked terminal cannot retain a business successor")
		end)
	end)

	for _, action in ipairs({"cancel", "retry"}) do
		helpers.it("HS-012 keeps regular " .. action
			.. " UI callback joined through nested PAUSE", function()
			with_fixture({
				requirement_lifecycle = true,
				pause_on_update_icon = "MLX download cancellation icon reset",
				launcher = {complete_on_terminate = true},
			}, function(fixture)
				helpers.assert_true(fixture.controls.pull())
				local result
				if action == "cancel" then
					result = fixture.controls.window.on_cancel()
				else
					result = fixture.controls.window.on_retry()
				end
				helpers.assert_eq(result, false)
				helpers.assert_eq(
					fixture.records.reentrant_update_icon_pause, false,
					"nested PAUSE must wait for the complete UI callback")
				assert_cancelled(fixture, "script_paused")
				helpers.assert_eq(#fixture.records.notifications, 0)
				helpers.assert_eq(#fixture.records.completions, 0)
				local retry_timers = 0
				for _, timer in ipairs(fixture.records.timers) do
					if timer.delay == 0.05 then retry_timers = retry_timers + 1 end
				end
				helpers.assert_eq(retry_timers, 0,
					"nested PAUSE must fence the retry successor")
				helpers.assert_eq(fixture.records.requirement_settlements, 1)
			end)
		end)
	end

	for _, action in ipairs({"cancel", "retry"}) do
		helpers.it("HS-012 keeps reattach " .. action
			.. " UI callback joined through nested PAUSE", function()
			local plan = {
				pid_alive = true,
				tail = {complete_on_terminate = true},
			}
			if action == "cancel" then
				plan.pause_on_update_icon = "MLX reattach completion icon reset"
				plan.update_icon_pause_kind = "reattach"
			else
				plan.tail.pause_after_terminate = "reattach"
			end
			with_fixture(plan, function(fixture)
				helpers.assert_true(fixture.controls.reattach())
				local result
				if action == "cancel" then
					result = fixture.controls.window.on_cancel()
				else
					result = fixture.controls.window.on_retry()
				end
				helpers.assert_eq(result, false)
				local pause_result
				if action == "cancel" then
					pause_result = fixture.records.reentrant_update_icon_pause
				else
					pause_result = fixture.records.reentrant_tail_termination_pause
				end
				helpers.assert_eq(pause_result, false,
					"reattach PAUSE must wait for the complete UI callback")
				helpers.assert_eq(#fixture.records.notifications, 0,
					"a paused callback cannot publish a terminal notification")
				helpers.assert_eq(#fixture.records.completions, 0,
					"a paused callback cannot publish terminal window state")
				helpers.assert_nil(fixture.controls.latest("launcher"),
					"a paused retry cannot start its regular download successor")
			end)
		end)
	end

	helpers.it("HS-012 rejects a truthy stopped reattach tail before retry", function()
		local plan = {
			pid_alive = true,
			tail = {running_after_start = false},
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local stopped_tail = fixture.controls.latest("tail")
			helpers.assert_true(fixture.deps.active_tasks.download_tail ~= stopped_tail,
				"the stopped task cannot remain the monitor sentinel")
			helpers.assert_true(fixture.controls.window.on_retry())
			plan.pid_alive = false
			fixture.controls.fire(0.25)
			helpers.assert_not_nil(fixture.controls.latest("launcher"),
				"retry must hand off after the stopped tail is cleared")
		end)
	end)

	helpers.it("HS-012 retains reattach tail on non-boolean liveness", function()
		local plan = {
			pid_alive = true,
			tail = {running_probe = "non_boolean", terminate = "false"},
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, exact_tail,
				"inconclusive liveness must retain the exact tail debt")
			helpers.assert_true(fixture.controls.window.on_retry())
			plan.pid_alive = false
			fixture.controls.exit_code = 1
			exact_tail:complete(0)
			fixture.controls.fire(0.25)
			helpers.assert_not_nil(fixture.controls.latest("launcher"),
				"the retry may hand off only after the exact tail settles")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 consumes stopped reattach tail after terminate " .. mode,
			function()
				local plan = {
					pid_alive = true,
					tail = {terminate = mode, terminate_stops = true},
				}
				with_fixture(plan, function(fixture)
					helpers.assert_true(fixture.controls.reattach())
					local exact_tail = fixture.controls.latest("tail")
					helpers.assert_true(fixture.controls.window.on_retry())
					helpers.assert_true(
						fixture.deps.active_tasks.download_tail ~= exact_tail,
						"exact stopped tail must yield to the monitor sentinel")
					plan.pid_alive = false
					fixture.controls.fire(0.25)
					helpers.assert_not_nil(fixture.controls.latest("launcher"))
				end)
			end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 releases a cancelled retry timer after late " .. mode
			.. " stop debt settles", function()
			with_fixture({
				requirement_lifecycle = true,
				launcher = {complete_on_terminate = true},
				timer_by_delay = {
					[0.05] = {stop = mode},
				},
			}, function(fixture)
				helpers.assert_true(fixture.controls.pull())
				helpers.assert_true(fixture.controls.window.on_retry())
				local retry_timer
				for _, timer in ipairs(fixture.records.timers) do
					if timer.delay == 0.05 then retry_timer = timer break end
				end
				helpers.assert_not_nil(retry_timer)
				helpers.assert_eq(fixture.controls.window.on_cancel(), false)
				helpers.assert_eq(fixture.records.requirement_settlements or 0, 0,
					"the exact refused timer must remain registered")
				retry_timer.behavior.stop = "success"
				fixture.controls.fire(0.05)
				helpers.assert_eq(fixture.records.requirement_settlements, 1,
					"late exact settlement must release the revoked owner")
			end)
		end)
	end

	for _, dispatch in ipairs({"sync", "async"}) do
		for _, terminal in ipairs({"success", "failure"}) do
			helpers.it("HS-012 keeps " .. dispatch .. " server " .. terminal
				.. " terminal joined through callback return", function()
				local plan = {
					requirement_lifecycle = true,
					pause_in_terminal = terminal,
					pid_alive = false,
				}
				if dispatch == "sync" then plan.server_sync = terminal end
				with_fixture(plan, function(fixture)
					helpers.assert_true(fixture.controls.pull())
					launch_detached_download(fixture)
					fixture.controls.finish_download(0)
					if dispatch == "async" then
						if terminal == "success" then
							helpers.assert_true(fixture.controls.server_success())
						else
							helpers.assert_true(
								fixture.controls.server_cancel("server_failed"))
						end
					end
					helpers.assert_eq(fixture.records.reentrant_server_terminal_pause,
						false,
						"terminal PAUSE must wait for the complete server callback")
					helpers.assert_eq(fixture.records.server_terminal_mutations, 1)
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
					helpers.assert_true(fixture.controls.requirement_pause_join(),
						"PAUSE may publish only after the callback mutation returns")
				end)
			end)
		end
	end

	helpers.it("HS-012 joins a requirement PAUSE re-entered by synchronous tail completion",
		function()
			local plan = {
				requirement_lifecycle = true,
				pid_alive = false,
				tail = {
					complete_on_start = true,
					pause_after_complete_on_start = true,
					terminate = "false",
				},
			}
			with_fixture(plan, function(fixture)
				helpers.assert_true(fixture.controls.pull())
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				helpers.assert_eq(fixture.records.reentrant_requirement_pause, false)
				assert_cancelled(fixture, "script_paused")
				local poll_or_timeout = 0
				for _, timer in ipairs(fixture.records.timers) do
					if timer.delay == 3 or timer.delay == 30 then
						poll_or_timeout = poll_or_timeout + 1
					end
				end
				helpers.assert_eq(poll_or_timeout, 0,
					"a revoked synchronous tail cannot arm poll or timeout successors")
				fixture.controls.fire(0.25)
				helpers.assert_eq(fixture.records.requirement_settlements, 1)
			end)
		end)

	helpers.it("HS-012 retains a poll timer published before reentrant PAUSE", function()
		local plan = {
			requirement_lifecycle = true,
			pid_alive = false,
			tail = { terminate = "false" },
			timer_by_delay = {
				[3] = { pause_on_start = true, stop = "false" },
			},
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			helpers.assert_eq(fixture.records.reentrant_timer_pause, false)
			assert_cancelled(fixture, "script_paused")
			local poll
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 then poll = timer break end
			end
			helpers.assert_not_nil(poll)
			helpers.assert_true(poll.live,
				"the refused exact stop must retain the poll candidate")

			poll.behavior.stop = "success"
			helpers.assert_eq(fixture.controls.requirement_pause_join(), false,
				"the tail still owns physical settlement after the timer joins")
			helpers.assert_eq(poll.live, false)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)
end)
