--- tests/unit/modules/llm/backends/test_dependency_bootstrap_pause_ownership_native_ownership.lua

--- Behavioral regression for HS-012 dependency bootstrap ownership. The real
--- ScriptControl, TimerScheduler, and TaskLifecycle run over faithful native
--- doubles; the class-wide inventory matrix separately drives both identities
--- through false/nil/throw rollback settlement.

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.backends.dependency_bootstrap_pause_ownership_fixture"] = nil
local Fixture = require("tests.support.modules.llm.backends.dependency_bootstrap_pause_ownership_fixture")
local get_upvalue = Fixture.get_upvalue
local load_fixture = Fixture.load_fixture
local set_upvalue = Fixture.set_upvalue





helpers.describe("HS-012 dependency bootstrap native ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw", "pending" }) do
		helpers.it("keeps readonly provisioning admission closed until failed native acquisition cleanup " .. mode, function()
			local fixture = load_fixture({ start_mode = "false", terminate_mode = mode })
			helpers.assert_eq(fixture.checker.provisioning_idle(), true)
			helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
			helpers.assert_eq(fixture.checker.provisioning_idle(), false)
			local task = fixture.tasks[1]
			local stops = task.terminate_calls
			helpers.assert_eq(fixture.checker.provisioning_idle(), false)
			helpers.assert_eq(task.terminate_calls, stops, "a readonly query cannot manufacture terminal acknowledgement")
			task:complete(143, "", "exact native completion")
			helpers.assert_eq(fixture.checker.provisioning_idle(), true)
			helpers.assert_eq(fixture.daemon_calls, 0)
		end)
	end

	helpers.it("keeps provisioning admission closed over retained initial timer cleanup", function()
		local fixture = load_fixture({ timer_start_mode = "false", timer_stop_mode = "false" })
		helpers.assert_eq(fixture.checker.schedule_initial_check(), false)
		helpers.assert_eq(fixture.checker.provisioning_idle(), false)
		helpers.assert_eq(fixture.owner.pause(), false)
		helpers.assert_eq(fixture.checker.provisioning_idle(), false)
		fixture.timer_stop_mode = "true"
		helpers.assert_eq(fixture.owner.pause(), true)
		helpers.assert_eq(fixture.checker.provisioning_idle(), true)
		helpers.assert_eq(#fixture.tasks, 0)
	end)

	helpers.it("registers actual checker admission with real ScriptControl", function()
		local fixture = load_fixture({ real_script_control = true })
		helpers.assert_true(fixture.control.pause_all())
		helpers.assert_true(fixture.control.is_paused())
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		helpers.assert_eq(#fixture.tasks, 0)
		helpers.assert_eq(fixture.ui_calls, 0)
		helpers.assert_true(fixture.control.resume_all())
		helpers.assert_true(fixture.control.stop())
	end)

	helpers.it("fails admission closed throughout PAUSED and transitions", function()
		local fixture = load_fixture()
		fixture.paused = true
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		fixture.paused = false
		fixture.transition = true
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		helpers.assert_eq(#fixture.tasks, 0)
		helpers.assert_eq(#fixture.timers, 0)
		helpers.assert_eq(fixture.ui_calls, 0)
		helpers.assert_eq(fixture.checker.get_state(), "pending")
	end)

	helpers.it("rejects cached-state mutation while PAUSED", function()
		local fixture = load_fixture({
			start_mode = "false",
			terminate_mode = "sync_true",
		})
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		helpers.assert_eq(fixture.checker.get_state(), "failed")
		fixture.paused = true
		helpers.assert_eq(fixture.checker.reset_bootstrap_state(), false)
		helpers.assert_eq(fixture.checker.get_state(), "failed")
	end)

	helpers.it("never writes into a progress session owned by another operation", function()
		local fixture = load_fixture()
		fixture.ui_active = true
		fixture.ui_session = 41
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.tasks[1]:chunk("OLLAMA_INSTALLING\n", "installer detail")
		fixture.tasks[1]:complete(1, "", "foreign-session failure")
		helpers.assert_eq(fixture.ui_calls, 0)
		helpers.assert_eq(fixture.checker.get_state(), "failed")
	end)

	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a mutated task after start " .. start_mode, function()
			local fixture = load_fixture({
				start_mode = start_mode,
				terminate_mode = "false",
			})
			helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_true(fixture.tasks[1].started,
				"the faithful start double mutates before refusing")
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1)
			fixture.transition = true
			helpers.assert_eq(fixture.owner.pause(), false,
				"PAUSED cannot publish while the exact task has no terminal callback")
			fixture.tasks[1]:complete(143, "", "late")
			fixture.tasks[1]:complete(0, "OLLAMA_INSTALLING", "duplicate")
			helpers.assert_eq(fixture.daemon_calls, 0)
			helpers.assert_eq(fixture.ui_calls, 0)
			helpers.assert_true(fixture.owner.pause())
		end)
	end

	for _, terminate_mode in ipairs({ "false", "nil", "throw", "pending" }) do
		helpers.it("waits for exact completion after terminate " .. terminate_mode, function()
			local fixture = load_fixture({ terminate_mode = terminate_mode })
			helpers.assert_true(fixture.checker.check_and_install_deps())
			fixture.epoch = 1
			fixture.transition = true
			helpers.assert_eq(fixture.owner.pause(), false)
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1)
			fixture.tasks[1]:chunk("OLLAMA_INSTALLING\n", "late stream")
			fixture.tasks[1]:complete(143, "", "late completion")
			fixture.tasks[1]:complete(0, "OLLAMA_READY", "duplicate")
			helpers.assert_eq(fixture.daemon_calls, 0)
			helpers.assert_eq(fixture.ui_calls, 0)
			helpers.assert_true(fixture.owner.pause())
		end)
	end

	helpers.it("replays only the committed task after exact RESUMED epoch", function()
		local fixture = load_fixture({ terminate_mode = "pending" })
		helpers.assert_true(fixture.checker.check_and_install_deps())
		local old_task = fixture.tasks[1]
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_eq(fixture.owner.pause(), false)
		old_task:complete(143, "", "stopped")
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false

		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 2)
		old_task:complete(0, "OLLAMA_INSTALLING", "duplicate")
		helpers.assert_eq(fixture.daemon_calls, 0)
		fixture.tasks[2]:complete(0, "", "")
		helpers.assert_eq(fixture.daemon_calls, 1)
		helpers.assert_eq(fixture.checker.get_state(), "ready")
	end)

	--- Pauses the running Ollama task, removes Ollama, then resumes and replays.
	--- @param fixture table Loaded Ollama fixture with one running task.
	--- @param binary table The resolver double the checker captured.
	local function pause_remove_and_replay(fixture, binary)
		local old_task = fixture.tasks[#fixture.tasks]
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_eq(fixture.owner.pause(), false)
		old_task:complete(143, "", "stopped")
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false
		binary.resolve = function() return nil, "no executable Ollama binary was found", nil end
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		resume_timer:fire()
	end

	helpers.it("never replays a found executable's fast path as a download", function()
		local fixture = load_fixture({ terminate_mode = "pending" })
		local binary = package.loaded["modules.llm.ollama_binary"]
		binary.managed_install_dir = function() return "/fixture/managed/ollama" end
		helpers.assert_true(fixture.checker.check_and_install_deps())
		helpers.assert_eq(fixture.tasks[1].args[6], "")
		pause_remove_and_replay(fixture, binary)
		helpers.assert_eq(#fixture.tasks, 1,
			"a fast path had no consent: its replay must not download Ollama")
		helpers.assert_eq(fixture.checker.get_state(), "missing")
	end)

	helpers.it("replays an accepted download as the same download", function()
		local fixture = load_fixture({ terminate_mode = "pending" })
		local binary = package.loaded["modules.llm.ollama_binary"]
		binary.managed_install_dir = function() return "/fixture/managed/ollama" end
		binary.resolve = function() return nil, "no executable Ollama binary was found", nil end
		helpers.assert_true(fixture.checker.install_for_selection())
		helpers.assert_eq(fixture.tasks[1].args[6], "/fixture/managed/ollama")
		pause_remove_and_replay(fixture, binary)
		helpers.assert_eq(#fixture.tasks, 2)
		helpers.assert_eq(fixture.tasks[2].args[6], "/fixture/managed/ollama",
			"the user's accepted download resumes after the pause")
	end)

	helpers.it("rejects a resume-stage callback from a different epoch", function()
		local fixture = load_fixture({ terminate_mode = "sync_true" })
		local controller = get_upvalue(fixture.checker.configure_pause_owner,
			"_pause_controller")
		helpers.assert_not_nil(controller,
			"the real checker must retain its production pause controller")
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		fixture.epoch = 3
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 1)
		helpers.assert_eq(controller.current_for_test(), nil,
			"an epoch-lost replay must terminalize its exact token")
		helpers.assert_eq(fixture.checker.get_state(), "failed")
		local timer_count = #fixture.timers
		helpers.assert_true(fixture.owner.resume())
		helpers.assert_eq(#fixture.timers, timer_count,
			"an epoch-lost replay must not require another global resume edge")
	end)

	helpers.it("replays an owned auto-hide timer without relaunching its backend task", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.tasks[1]:chunk("OLLAMA_INSTALLING\n", "")
		fixture.tasks[1]:complete(0, "OLLAMA_INSTALLING\n", "")
		helpers.assert_eq(#fixture.tasks, 1)
		local first_hide = fixture.timers[#fixture.timers]
		helpers.assert_eq(first_hide.delay, 1.5)

		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_true(fixture.owner.pause())
		helpers.assert_eq(first_hide.running_state, false)
		fixture.paused = true
		fixture.transition = false
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 1,
			"hide replay must remain backend-local timer work")
		local replayed_hide = fixture.timers[#fixture.timers]
		helpers.assert_eq(replayed_hide.delay, 1.5)
		helpers.assert_true(replayed_hide ~= first_hide)
	end)

	helpers.it("retains the exact initial timer when start rollback refuses", function()
		local fixture = load_fixture({
			timer_start_mode = "false",
			timer_stop_mode = "false",
		})
		helpers.assert_eq(fixture.checker.schedule_initial_check(), false)
		helpers.assert_eq(#fixture.timers, 1)
		helpers.assert_true(fixture.timers[1].running_state)
		helpers.assert_eq(#fixture.tasks, 0)
		helpers.assert_eq(fixture.owner.pause(), false)
		fixture.timer_stop_mode = "true"
		helpers.assert_true(fixture.owner.pause())
		helpers.assert_eq(fixture.timers[1].running_state, false)
	end)

	for _, backend in ipairs({ "ollama", "mlx" }) do
		for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(backend .. " defers a fired one-shot after native stop "
				.. stop_mode, function()
				local fixture = load_fixture({
					backend = backend,
					timer_stop_mode = stop_mode,
				})
				helpers.assert_true(fixture.checker.schedule_initial_check())
				local initial_timer = fixture.timers[1]
				initial_timer:fire()
				helpers.assert_eq(#fixture.tasks, 0,
					"business cannot start while the fired native timer remains live")
				helpers.assert_true(initial_timer.running_state)
				local stop_calls = initial_timer.stop_calls
				initial_timer.callback()
				helpers.assert_eq(#fixture.tasks, 0,
					"duplicate native delivery must remain cleanup-only")
				helpers.assert_true(initial_timer.stop_calls > stop_calls,
					"duplicate delivery must retry the same native handle")

				fixture.timer_stop_mode = "true"
				helpers.assert_true(require("adapters.timer_scheduler").retryCleanup())
				helpers.assert_eq(initial_timer.running_state, false)
				helpers.assert_eq(#fixture.tasks, 1,
					"exact settlement releases one authorized bootstrap delivery")
				initial_timer.callback()
				helpers.assert_eq(#fixture.tasks, 1,
					"late delivery cannot launch a sibling task")
			end)
		end
	end

	helpers.it("replays only after a fired resume timer exactly settles", function()
		local fixture = load_fixture({ terminate_mode = "sync_true" })
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		fixture.timer_stop_mode = "false"
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 1,
			"a live resume timer cannot publish replay")
		fixture.timer_stop_mode = "true"
		helpers.assert_true(require("adapters.timer_scheduler").retryCleanup())
		helpers.assert_eq(#fixture.tasks, 2)
		fixture.tasks[2]:complete(0, "", "")
	end)

	for _, backend in ipairs({ "ollama", "mlx" }) do
		for _, stop_mode in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it(backend .. " publishes timer acquisition before reentrant PAUSE with stop "
				.. stop_mode, function()
				local fixture = load_fixture({
					backend = backend,
					timer_stop_mode = stop_mode,
				})
				fixture.timer_start_hook = function()
					fixture.timer_start_hook = nil
					fixture.transition = true
					fixture.pause_during_timer_start = fixture.owner.pause()
				end
				helpers.assert_eq(fixture.checker.schedule_initial_check(), false)
				helpers.assert_eq(fixture.pause_during_timer_start, false)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(#fixture.timers, 1)
				if stop_mode == "true" then
					helpers.assert_eq(fixture.timers[1].running_state, false)
				else
					helpers.assert_true(fixture.timers[1].running_state)
					fixture.timer_stop_mode = "true"
					helpers.assert_true(fixture.owner.pause())
					helpers.assert_eq(fixture.timers[1].running_state, false)
				end
			end)
		end
	end

	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " rolls back a resume stage interrupted inside timer start",
			function()
				local fixture = load_fixture({
					backend = backend,
					terminate_mode = "sync_true",
				})
				helpers.assert_true(fixture.checker.check_and_install_deps())
				fixture.epoch = 1
				fixture.transition = true
				helpers.assert_true(fixture.owner.pause())
				fixture.paused = true
				fixture.transition = false
				fixture.epoch = 2
				fixture.transition = true
				fixture.timer_start_hook = function()
					fixture.timer_start_hook = nil
					fixture.pause_during_resume_start = fixture.owner.pause()
				end
				helpers.assert_eq(fixture.owner.resume(), false)
				helpers.assert_eq(fixture.pause_during_resume_start, false)
				helpers.assert_eq(#fixture.tasks, 1)
				local resume_timer = fixture.timers[#fixture.timers]
				helpers.assert_eq(resume_timer.running_state, false)
				resume_timer:fire()
				helpers.assert_eq(#fixture.tasks, 1)
			end)
	end
end)

helpers.describe("HS-193 dependency bootstrap replay refusal", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " consumes a committed token after replay refuses", function()
			local fixture = load_fixture({ backend = backend })
			local controller = get_upvalue(fixture.checker.configure_pause_owner,
				"_pause_controller")
			helpers.assert_not_nil(controller,
				"the real checker must retain its production pause controller")
			local completions = {}
			helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end))
			local marker = backend == "mlx" and "VENV_SYNC_RAN\n" or "OLLAMA_INSTALLING\n"
			fixture.tasks[1]:chunk(marker, "")
			fixture.tasks[1]:complete(0, marker, "")
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], true)
			helpers.assert_eq(fixture.checker.get_state(), "ready")

			fixture.epoch = 1
			fixture.transition = true
			helpers.assert_true(fixture.owner.pause())
			fixture.paused = true
			fixture.transition = false
			fixture.epoch = 2
			fixture.transition = true
			helpers.assert_true(fixture.owner.resume())
			local resume_stage = fixture.timers[#fixture.timers]
			fixture.paused = false
			fixture.transition = false
			fixture.timer_start_mode = "false"
			resume_stage:fire()

			helpers.assert_eq(controller.current_for_test(), nil,
				"a replay refusal must produce a terminal token instead of parked intent")
			helpers.assert_eq(fixture.checker.get_state(), "ready",
				"auto-hide replay failure must not poison completed dependencies")
			local timer_count = #fixture.timers
			fixture.timer_start_mode = "true"
			helpers.assert_true(fixture.owner.resume())
			helpers.assert_eq(#fixture.timers, timer_count,
				"a consumed replay failure must not require another global resume edge")
		end)
	end
end)

helpers.describe("HS-117 dependency checker callback symmetry", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " queues the shared completion signature exactly once", function()
			local fixture = load_fixture({ backend = backend })
			local completions = {}
			local function record(label)
				return function(ok)
					completions[#completions + 1] = { label = label, ok = ok }
				end
			end

			helpers.assert_true(fixture.checker.check_and_install_deps(record("first")))
			helpers.assert_true(fixture.checker.check_and_install_deps(record("second")))
			helpers.assert_eq(#fixture.tasks, 1,
				"a second waiter must join the live bootstrap, not start a sibling")
			helpers.assert_eq(#completions, 0,
				"dispatch acceptance is not business completion")

			fixture.tasks[1]:complete(0, "", "")

			helpers.assert_eq(#completions, 2)
			helpers.assert_eq(completions[1].label, "first")
			helpers.assert_eq(completions[2].label, "second")
			helpers.assert_eq(completions[1].ok, true)
			helpers.assert_eq(completions[2].ok, true)
		end)

		helpers.it(backend .. " reports terminal bootstrap failure through the shared callback", function()
			local fixture = load_fixture({ backend = backend })
			local completions = {}
			helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end))

			fixture.tasks[1]:complete(1, "", "fixture failure")

			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)
		end)

		helpers.it(backend .. " settles the callback when bootstrap preflight refuses", function()
			local fixture = load_fixture({ backend = backend })
			local resolver_name = backend == "mlx"
				and "resolve_bootstrap_script_path" or "resolve_project_root"
			helpers.assert_true(set_upvalue(fixture.check_impl,
				resolver_name, function() return nil end))
			local completions = {}

			helpers.assert_eq(fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end), false)

			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)
		end)
	end
end)

helpers.describe("HS-118 dependency bootstrap auto-hide refusal", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " closes its progress session when auto-hide acquisition refuses",
			function()
				local fixture = load_fixture({ backend = backend })
				local completions = {}
				helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
					completions[#completions + 1] = ok
				end))
				local marker = backend == "mlx" and "VENV_SYNC_RAN\n" or "OLLAMA_INSTALLING\n"
				fixture.tasks[1]:chunk(marker, "")
				helpers.assert_true(fixture.ui_active,
					"the real-sync marker must claim the progress surface")

				fixture.timer_start_hook = function(timer)
					if timer.delay ~= 1.5 then return end
					fixture.timer_start_hook = nil
					fixture.timer_start_mode = "false"
					fixture.timer_stop_mode = "false"
				end
				fixture.tasks[1]:complete(0, marker, "")

				helpers.assert_eq(fixture.checker.get_state(), "ready")
				helpers.assert_eq(#completions, 1)
				helpers.assert_eq(completions[1], true)
				helpers.assert_eq(fixture.ui_hide_calls, 1,
					"timer refusal must fall back to closing the exact owned session")
				helpers.assert_eq(fixture.ui_active, false)
				local refused_hide = fixture.timers[#fixture.timers]
				helpers.assert_eq(refused_hide.delay, 1.5)
				helpers.assert_true(refused_hide.running_state,
					"the native timer debt stays owned even though the UI is closed")
			end)

		helpers.it(backend .. " never hides a replacement session after auto-hide refusal",
			function()
				local fixture = load_fixture({ backend = backend })
				helpers.assert_true(fixture.checker.check_and_install_deps())
				local marker = backend == "mlx" and "VENV_SYNC_RAN\n" or "OLLAMA_INSTALLING\n"
				fixture.tasks[1]:chunk(marker, "")
				fixture.timer_start_hook = function(timer)
					if timer.delay ~= 1.5 then return end
					fixture.timer_start_hook = nil
					fixture.ui_session = fixture.ui_session + 1
					fixture.timer_start_mode = "false"
					fixture.timer_stop_mode = "false"
				end

				fixture.tasks[1]:complete(0, marker, "")

				helpers.assert_eq(fixture.checker.get_state(), "ready")
				helpers.assert_eq(fixture.ui_hide_calls, 0,
					"the fallback may close only the session claimed by this checker")
				helpers.assert_true(fixture.ui_active,
					"the replacement operation's progress surface must remain visible")
			end)
	end
end)
