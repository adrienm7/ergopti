--- tests/unit/ui/menu/menu_llm/test_mlx_download_terminal_contract.lua

--- ==============================================================================
--- MODULE: MLX Download Dispatch
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture
local assert_cancelled = fixture_support.assert_cancelled

local function assert_revoked_cleanup_timer_owned(fixture)
	local cleanup
	for _, timer in ipairs(fixture.records.timers) do
		if timer.delay == 0.25 and timer.live == true then cleanup = timer end
	end
	helpers.assert_not_nil(cleanup,
		"revocation must retain one live cleanup timer for the exact PID owner")
	for _, timer in ipairs(fixture.records.timers) do
		if timer.live == true then
			helpers.assert_true(timer.delay ~= 3 and timer.delay ~= 30,
				"revocation must not authorize poll/timeout business successors")
		end
	end
end

helpers.describe("HS-024 MLX download terminal owner", function()
	helpers.it("HS-265 quotes the exact fresh download log in the Terminal command", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local session = fixture.controls.files["/tmp/hs_mlx_active_download.json"]
			helpers.assert_type(session, "string", "download session must be published")
			local log_path = session:match('"log_path":"([^"]+)"')
			helpers.assert_type(log_path, "string", "published session must identify its exact log")
			helpers.assert_type(fixture.controls.window, "table")
			helpers.assert_eq(fixture.controls.window.terminal_cmd, "tail -f '" .. log_path .. "'",
				"the generated safe path must still use the literal-argument command contract")
		end)
	end)

	helpers.it("HS-265 quotes the restored download log in the Terminal command", function()
		with_fixture({ pid_alive = true }, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			helpers.assert_type(fixture.controls.window, "table")
			helpers.assert_eq(fixture.controls.window.terminal_cmd,
				"tail -f '/tmp/hs_mlx_dl_reattach.log'",
				"reattach must use the same literal-argument contract as a fresh download")
		end)
	end)

	helpers.it("routes menubar abort state through the owning window session", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			helpers.assert_type(fixture.controls.window, "table")
			helpers.assert_type(fixture.controls.window.on_abort, "function")
			helpers.assert_type(fixture.controls.window.on_retry_start, "function")
			helpers.assert_eq(fixture.controls.window.on_abort(), true)
			helpers.assert_eq(fixture.controls.window.on_retry_start(), true)
			helpers.assert_eq(fixture.records.download_aborts, 1)
			helpers.assert_eq(fixture.records.download_retry_starts, 1)
		end)
	end)

	helpers.it("HS-024 rejects a busy slot through one failure terminal", function()
		with_fixture({}, function(fixture)
			fixture.deps.active_tasks.download = {marker = "existing"}
			helpers.assert_eq(fixture.controls.pull(), false)
			assert_cancelled(fixture, "busy")
		end)
	end)

	helpers.it("HS-024 user cancellation revokes late launcher success", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			helpers.assert_type(fixture.controls.window.on_cancel, "function")
			fixture.controls.window.on_cancel()
			assert_cancelled(fixture, "user_cancelled")

			launcher:complete(0)
			fixture.controls.fire(0.25)
			helpers.assert_eq(fixture.records.server_starts, 0)
			helpers.assert_eq(#fixture.records.cancels, 1)
		end)
	end)

	for _, failure in ipairs({
		{name = "python open", plan = {fail_open = "python"}, reason = "python_file_open_failed"},
		{name = "launcher open", plan = {fail_open = "launcher"}, reason = "launcher_file_open_failed"},
		{name = "launcher constructor false", plan = {launcher = {construct = "false"}}, reason = "launcher_construction_failed"},
		{name = "launcher constructor nil", plan = {launcher = {construct = "nil"}}, reason = "launcher_construction_failed"},
		{name = "launcher constructor throw", plan = {launcher = {construct = "throw"}}, reason = "launcher_construction_failed"},
		{name = "launcher start false", plan = {launcher = {start = "false"}}, reason = "launcher_start_refused"},
		{name = "launcher start nil", plan = {launcher = {start = "nil"}}, reason = "launcher_start_refused"},
		{name = "launcher start throw", plan = {launcher = {start = "throw"}}, reason = "launcher_start_refused"},
		{name = "sync completion then refused start", plan = {launcher = {
			stream_on_start = "__DLPID__:4242\n", complete_on_start = true,
			complete_code = 0, start = "false",
		}}, reason = "launcher_start_refused"},
	}) do
		helpers.it("HS-024 settles " .. failure.name .. " exactly once", function()
			with_fixture(failure.plan, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), false)
				assert_cancelled(fixture, failure.reason)
				local launcher = fixture.controls.latest("launcher")
				if launcher then launcher:complete(0) end
				helpers.assert_eq(#fixture.records.cancels, 1)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

	helpers.it("HS-024 launcher process failure settles once", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			fixture.controls.latest("launcher"):complete(1)
			assert_cancelled(fixture, "launcher_failed")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 tail " .. mode .. " refusal retains the same cleanup owner", function()
			local plan = {tail = {
				start = mode,
				stream_on_start = "__BYTES__:99\n",
				mutate_on_start = true,
			}, pid_alive = true}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), true)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				local stale_tail = fixture.controls.latest("tail")
				assert_cancelled(fixture, "tail_task_start_refused")
				helpers.assert_eq(#fixture.records.updates, 0,
					"a refused tail cannot publish its synchronous stream")
				local session_path = "/tmp/hs_mlx_active_download.json"
				local retained_session = fixture.controls.files[session_path]
				helpers.assert_type(retained_session, "string")
				helpers.assert_eq(retained_session:find('"model":"B"', 1, true) ~= nil, true)
				helpers.assert_eq(retained_session:find('"repo":"org/model"', 1, true) ~= nil, true)

				local second_cancels = 0
				local accepted = fixture.obj.pull_model("C", "org/other", nil, function(reason)
					second_cancels = second_cancels + 1
					helpers.assert_eq(reason, "busy")
				end, {is_current = function() return true end})
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(second_cancels, 1)
				helpers.assert_eq(fixture.controls.files[session_path], retained_session,
					"a busy successor cannot replace the live owner's session")

				plan.pid_alive = false
				assert_revoked_cleanup_timer_owned(fixture)
				fixture.controls.fire(0.25)
				helpers.assert_nil(fixture.controls.files[session_path])
				local tail_count = #fixture.controls.tasks.tail
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function(reason)
					second_cancels = second_cancels + 1
					helpers.assert_eq(reason, "busy")
				end, {is_current = function() return true end}), false,
					"a vanished PID cannot settle the still-live refused tail task")
				helpers.assert_eq(second_cancels, 2)
				helpers.assert_eq(#fixture.controls.tasks.tail, tail_count,
					"the refused tail must block every sibling until its exact terminal")

				stale_tail:complete(0)
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
					{is_current = function() return true end}), true)
				local successor_session = fixture.controls.files[session_path]
				helpers.assert_type(successor_session, "string")
				helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)
				helpers.assert_eq(successor_session:find('"repo":"org/other"', 1, true) ~= nil, true)

				stale_tail:emit("__BYTES__:100\n")
				helpers.assert_eq(#fixture.records.updates, 0,
					"late refused-tail chunks must remain inert")
				helpers.assert_eq(fixture.controls.files[session_path], successor_session,
					"a late callback cannot remove the successor's exact session")
				helpers.assert_eq(#fixture.records.cancels, 1)
				helpers.assert_eq(fixture.records.successes, 0)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 launcher " .. mode
			.. " refusal discards synchronous business stream", function()
			with_fixture({launcher = {
				start = mode,
				stream_on_start = "launcher business\n",
				mutate_on_start = true,
			}}, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), false)
				helpers.assert_eq(#fixture.records.updates, 0)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("late launcher business\n")
				helpers.assert_eq(#fixture.records.updates, 0)
			end)
		end)
	end

	helpers.it("HS-024 replays committed launcher and tail streams once", function()
		with_fixture({
			launcher = {stream_on_start = "launcher business\n"},
			tail = {stream_on_start = "__BYTES__:99\n"},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			helpers.assert_eq(#fixture.records.updates, 1)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			helpers.assert_eq(#fixture.records.updates, 2)
			launcher:emit("late launcher business\n")
			helpers.assert_eq(#fixture.records.updates, 2)
			local tail = fixture.controls.latest("tail")
			tail:complete(0)
			tail:emit("__BYTES__:100\n")
			helpers.assert_eq(#fixture.records.updates, 2)
		end)
	end)

	helpers.it("HS-024 drops a synchronous stream delivered after terminal", function()
		with_fixture({launcher = {
			start = "success",
			complete_on_start = true,
			complete_code = 1,
			stream_on_start = "post-terminal business\n",
			stream_after_complete_on_start = true,
		}}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			helpers.assert_eq(#fixture.records.updates, 0)
		end)
	end)

	helpers.it("HS-024 tail construction refusal retains the detached owner", function()
		local plan = {tail = {construct = "nil"}, pid_alive = true}
		with_fixture(plan, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			assert_cancelled(fixture, "tail_task_construction_failed")
			local session_path = "/tmp/hs_mlx_active_download.json"
			local retained_session = fixture.controls.files[session_path]
			helpers.assert_type(retained_session, "string")
			helpers.assert_eq(retained_session:find('"model":"B"', 1, true) ~= nil, true)
			helpers.assert_eq(retained_session:find('"repo":"org/model"', 1, true) ~= nil, true)

			local second_cancels = 0
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function(reason)
				second_cancels = second_cancels + 1
				helpers.assert_eq(reason, "busy")
			end, {is_current = function() return true end}), false)
			helpers.assert_eq(second_cancels, 1)
			helpers.assert_eq(fixture.controls.files[session_path], retained_session,
				"a busy successor cannot replace the live owner's session")

			plan.pid_alive = false
			assert_revoked_cleanup_timer_owned(fixture)
			fixture.controls.fire(0.25)
			helpers.assert_nil(fixture.controls.files[session_path])
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), true)
			local successor_session = fixture.controls.files[session_path]
			helpers.assert_type(successor_session, "string")
			helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)
			helpers.assert_eq(successor_session:find('"repo":"org/other"', 1, true) ~= nil, true)

			launcher:complete(0)
			helpers.assert_eq(fixture.controls.files[session_path], successor_session,
				"a late callback cannot remove the successor's exact session")
			helpers.assert_eq(#fixture.records.cancels, 1)
			helpers.assert_eq(fixture.records.successes, 0)
			helpers.assert_eq(fixture.records.server_starts, 0)
		end)
	end)

	helpers.it("HS-024 failed detached download has one terminal", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			fixture.controls.finish_download(1)
			assert_cancelled(fixture, "process_failed")
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_eq(#fixture.records.cancels, 1)
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 server dispatch " .. mode .. " refusal cannot publish", function()
			with_fixture({server_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), true)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				fixture.controls.finish_download(0)
				assert_cancelled(fixture, "server_start_refused")
				helpers.assert_eq(fixture.records.saves, 0)
			end)
		end)
	end

	helpers.it("HS-024 buffers synchronous server success until dispatch commits", function()
		with_fixture({server_mode = "false", server_sync = "success"}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			fixture.controls.finish_download(0)
			assert_cancelled(fixture, "server_start_refused")
		end)
	end)

	helpers.it("HS-024 success and duplicate callbacks settle once without child publication", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			fixture.controls.finish_download(0)
			helpers.assert_eq(fixture.records.successes, 0)
			fixture.controls.server_success()
			fixture.controls.server_cancel("late")
			fixture.controls.server_success()
			helpers.assert_eq(fixture.records.successes, 1)
			helpers.assert_eq(#fixture.records.cancels, 0)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_nil(fixture.records.runtime_model)
			helpers.assert_eq(fixture.records.saves, 0)
		end)
	end)
end)
