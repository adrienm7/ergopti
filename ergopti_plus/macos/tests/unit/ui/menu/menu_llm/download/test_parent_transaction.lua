--- tests/unit/ui/menu/menu_llm/download/test_parent_transaction.lua

--- ==============================================================================
--- MODULE: MLX Download Parent Transaction
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture
local launch_detached_download = fixture_support.launch_detached_download

local function assert_switcher_failure(fixture, reason)
	helpers.assert_eq(fixture.records.gates, {false, true},
		"the real switcher must reopen predictions exactly once")
	helpers.assert_eq(fixture.records.requirement_successes, 0)
	helpers.assert_eq(#fixture.records.requirement_failures, 1)
	if reason ~= nil then
		helpers.assert_eq(fixture.records.requirement_failures[1], reason)
	end
	helpers.assert_eq(fixture.state.llm_model, "A")
	helpers.assert_eq(fixture.state.llm_model_mlx, "A")
	helpers.assert_eq(fixture.records.menus or 0, 0)
end

helpers.describe("MLX download parent transaction", function()
	helpers.it("HS-024 releases the real switcher gate when the logical slot is busy", function()
		with_fixture({real_switcher = true}, function(fixture)
			fixture.deps.active_tasks.download = {marker = "existing"}
			helpers.assert_eq(fixture.switcher.switch_model("B"), false)
			assert_switcher_failure(fixture, "busy")
		end)
	end)

	for _, failure in ipairs({
		{name = "python open", plan = {fail_open = "python"}, reason = "python_file_open_failed"},
		{name = "launcher open", plan = {fail_open = "launcher"}, reason = "launcher_file_open_failed"},
		{name = "launcher construction", plan = {launcher = {construct = "nil"}}, reason = "launcher_construction_failed"},
		{name = "launcher start", plan = {launcher = {start = "false"}}, reason = "launcher_start_refused"},
	}) do
		helpers.it("HS-024 routes " .. failure.name .. " through the real switcher", function()
			failure.plan.real_switcher = true
			with_fixture(failure.plan, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				assert_switcher_failure(fixture, failure.reason)
			end)
		end)
	end

	helpers.it("HS-024 routes user cancellation through the real switcher once", function()
		with_fixture({real_switcher = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.window.on_cancel()
			assert_switcher_failure(fixture, "user_cancelled")
			fixture.controls.latest("launcher"):complete(0)
			helpers.assert_eq(#fixture.records.requirement_failures, 1)
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 routes tail start " .. mode .. " through the real switcher", function()
			with_fixture({real_switcher = true, tail = {start = mode}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "tail_task_start_refused")
			end)
		end)
	end

	helpers.it("HS-024 routes launcher and detached process exits through the real switcher", function()
		with_fixture({real_switcher = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			fixture.controls.latest("launcher"):complete(1)
			assert_switcher_failure(fixture, "launcher_failed")
		end)
		with_fixture({real_switcher = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.finish_download(1)
			assert_switcher_failure(fixture, "process_failed")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 routes server start " .. mode .. " through the real switcher", function()
			with_fixture({real_switcher = true, server_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				fixture.controls.finish_download(0)
				assert_switcher_failure(fixture, "server_start_refused")
			end)
		end)
	end

	helpers.it("HS-024 leaves identity publication to the real parent transaction", function()
		with_fixture({real_switcher = true, save_mode = "false"}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.finish_download(0)
			helpers.assert_eq(fixture.records.gates, {false})
			fixture.controls.server_success()
			fixture.controls.server_success()
			helpers.assert_eq(fixture.records.gates, {false, true})
			helpers.assert_eq(fixture.records.requirement_successes, 1)
			helpers.assert_eq(#fixture.records.requirement_failures, 0)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_eq(fixture.state.llm_model_mlx, "A")
			helpers.assert_eq(fixture.records.runtime_model, "A")
			helpers.assert_eq(fixture.records.saves, 2,
				"the parent must attempt candidate persistence and exact rollback")
		end)
	end)

	for _, boundary in ipairs({
		{kind = "python", field = "write_modes", reason = "python_file_write_failed"},
		{kind = "python", field = "close_modes", reason = "python_file_write_failed"},
		{kind = "launcher", field = "write_modes", reason = "launcher_file_write_failed"},
		{kind = "launcher", field = "close_modes", reason = "launcher_file_write_failed"},
		{kind = "session", field = "write_modes", reason = "session_write_failed"},
		{kind = "session", field = "close_modes", reason = "session_write_failed"},
	}) do
		for _, mode in ipairs({"false", "nil", "throw"}) do
			helpers.it(string.format("HS-024 settles %s %s refusal through the real switcher",
				boundary.kind, mode), function()
				local plan = {real_switcher = true}
				plan[boundary.field] = {[boundary.kind] = mode}
				with_fixture(plan, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), false)
					assert_switcher_failure(fixture, boundary.reason)
				end)
			end)
		end
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 settles atomic session publication " .. mode .. " refusal", function()
			with_fixture({real_switcher = true, rename_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				assert_switcher_failure(fixture, "session_write_failed")
			end)
		end)

		helpers.it("HS-024 settles launcher chmod " .. mode .. " refusal", function()
			with_fixture({real_switcher = true, chmod_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				assert_switcher_failure(fixture, "launcher_chmod_failed")
			end)
		end)
	end

	for _, boundary in ipairs({"write", "close", "rename"}) do
		for _, mode in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-024 retains detached cleanup after session PID "
				.. boundary .. " " .. mode .. " refusal", function()
				local plan = {real_switcher = true, pid_alive = true}
				if boundary == "rename" then
					plan.rename_sequence = {"success", mode}
				else
					plan[boundary .. "_modes"] = {session = {"success", mode}}
				end
				with_fixture(plan, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), true)
					fixture.controls.latest("launcher"):emit("__DLPID__:4242\n")
					assert_switcher_failure(fixture, "session_pid_write_failed")
					local second_cancels = 0
					helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function()
						second_cancels = second_cancels + 1
					end, {is_current = function() return true end}), false)
					helpers.assert_eq(second_cancels, 1)
				end)
			end)
		end
	end

	for _, behavior in ipairs({
		{construct = "false"}, {construct = "nil"}, {construct = "throw"},
		{start = "false"}, {start = "nil"}, {start = "throw"},
		{start = "throw_after_start"}, {fire_on_start = true},
	}) do
		helpers.it("HS-024 settles refused critical timer acquisition", function()
			with_fixture({real_switcher = true, timer_sequence = {behavior}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "poll_timer_refused")
			end)
		end)
	end

	helpers.it("HS-024 settles timeout timer acquisition after the poll commits", function()
		with_fixture({real_switcher = true, timer_sequence = {{}, {construct = "nil"}}},
			function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "timeout_timer_refused")
			end)
	end)

	helpers.it("HS-024 settles a refused poll reschedule", function()
		with_fixture({real_switcher = true,
			timer_sequence = {{}, {}, {construct = "nil"}}}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.fire(3)
			assert_switcher_failure(fixture, "poll_timer_refused")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 discovers a late PID after launcher cancellation " .. mode, function()
			local plan = {real_switcher = true, launcher = {terminate = mode},
				kill_mode = mode, pid_alive = true}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				local launcher = fixture.controls.latest("launcher")
				fixture.controls.window.on_cancel()
				assert_switcher_failure(fixture, "user_cancelled")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				local second_cancels = 0
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function()
					second_cancels = second_cancels + 1
				end, {is_current = function() return true end}), false)
				helpers.assert_eq(second_cancels, 1)
				plan.pid_alive = false
				fixture.controls.fire(0.25)
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
					{is_current = function() return true end}), true)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

	helpers.it("HS-024 keeps one logical terminal across double Retry", function()
		with_fixture({real_switcher = true,
			launcher = {{complete_on_terminate = true}, {}}}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			local old_launcher = fixture.controls.latest("launcher")
			helpers.assert_eq(fixture.controls.window.on_retry(), true)
			helpers.assert_eq(fixture.controls.window.on_retry(), false)
			helpers.assert_eq(fixture.records.gates, {false})
			helpers.assert_eq(#fixture.records.requirement_failures, 0)
			fixture.controls.fire(0.05)
			helpers.assert_eq(#fixture.controls.tasks.launcher, 2)
			old_launcher:complete(0)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4343\n")
			launcher:complete(0)
			fixture.controls.finish_download(0)
			fixture.controls.server_success()
			helpers.assert_eq(fixture.records.gates, {false, true})
			helpers.assert_eq(fixture.records.requirement_successes, 1)
			helpers.assert_eq(#fixture.records.requirement_failures, 0)
			helpers.assert_eq(fixture.state.llm_model, "B")
		end)
	end)

	helpers.it("HS-024 lets Cancel revoke a pending Retry handoff", function()
		with_fixture({real_switcher = true,
			launcher = {complete_on_terminate = true}}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			helpers.assert_eq(fixture.controls.window.on_retry(), true)
			fixture.controls.window.on_cancel()
			assert_switcher_failure(fixture, "user_cancelled")
			fixture.controls.fire(0.05)
			helpers.assert_eq(#fixture.controls.tasks.launcher, 1)
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 fences late tail success after cancellation " .. mode, function()
			local plan = {real_switcher = true, tail = {terminate = mode},
				pid_alive = false}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				local tail = fixture.controls.latest("tail")
				fixture.controls.window.on_cancel()
				assert_switcher_failure(fixture, "user_cancelled")
				fixture.controls.exit_code = 0
				tail:complete(0)
				fixture.controls.fire(0.5)
				fixture.controls.fire(0.25)
				helpers.assert_eq(fixture.records.server_starts, 0)
				helpers.assert_eq(fixture.records.requirement_successes, 0)
				helpers.assert_eq(#fixture.records.requirement_failures, 1)
			end)
		end)
	end

	for _, mode in ipairs({"false", "nil"}) do
		helpers.it("HS-024 latches synchronous tail completion before " .. mode .. " start", function()
			with_fixture({real_switcher = true, tail = {
				complete_on_start = true, start = mode,
			}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "tail_task_start_refused")
			end)
		end)
	end

	for _, mode in ipairs({"false", "throw"}) do
		helpers.it("HS-024 handles tail construction " .. mode .. " refusal", function()
			with_fixture({real_switcher = true, tail = {construct = mode}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "tail_task_construction_failed")
			end)
		end)
	end

	for _, server_sync in ipairs({"success", "failure"}) do
		for _, mode in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-024 buffers synchronous server " .. server_sync
				.. " before " .. mode .. " dispatch", function()
				with_fixture({real_switcher = true, server_sync = server_sync,
					server_mode = mode}, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), true)
					launch_detached_download(fixture)
					fixture.controls.finish_download(0)
					assert_switcher_failure(fixture, "server_start_refused")
				end)
			end)
		end
	end
end)
