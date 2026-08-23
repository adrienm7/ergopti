--- tests/unit/modules/llm/test_ollama_daemon_pause_ownership.lua

--- ==============================================================================
--- MODULE: Ollama Daemon Pause Ownership Regression
--- DESCRIPTION:
--- Drives the real Ollama controller through ScriptControl while stale-process
--- tasks, launch timers, and unpublished serve tasks are still native-owned.
--- Refusal and reordered-terminal cases prove PAUSED cannot be published over a
--- live startup pipeline and that only pre-pause intent is restored afterward.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads real ScriptControl and ApiOllama over exact observable native doubles.
--- @return table fixture
local function load_fixture()
	local scheduler = { handles = {}, cancel_mode = "true", cancel_calls = {} }
	local hooks = {}

	--- Drains one timer's settlement observers exactly once.
	--- @param handle table Timer handle.
	local function settle_timer(handle)
		if handle.timer == nil then return end
		handle.timer = nil
		local observers = handle.observers
		handle.observers = {}
		for _, observer in ipairs(observers) do observer() end
	end

	function scheduler.cancel(handle)
		scheduler.cancel_calls[#scheduler.cancel_calls + 1] = handle
		if scheduler.cancel_mode == "throw" then error("timer stop exploded") end
		if scheduler.cancel_mode == "false" then return false end
		if scheduler.cancel_mode == "nil" then return nil end
		settle_timer(handle)
		return true
	end

	function scheduler.onSettled(handle, observer)
		if handle.timer == nil then observer(); return true end
		handle.observers[#handle.observers + 1] = observer
		return true
	end

	function scheduler.after(_, callback)
		local handle = {
			timer = {},
			committed = true,
			fired = false,
			observers = {},
		}
		function handle.fire()
			if handle.timer == nil then return end
			if handle.fired then
				pcall(scheduler.cancel, handle)
				return
			end
			handle.fired = true
			handle.committed = false
			pcall(scheduler.cancel, handle)
			callback()
		end
		scheduler.handles[#scheduler.handles + 1] = handle
		local hook = scheduler.after_hook
		if type(hook) == "function" then
			scheduler.after_hook = nil
			scheduler.after_hook_result = hook(handle)
		end
		return handle, true
	end

	local shell = {
		tasks = {},
		terminate_mode = "true",
		kill_start_hook = nil,
		serve_start_hook = nil,
		start_modes = { kill = "true", serve = "true" },
		complete_during_start = {},
	}
	function shell.spawn(_, args, on_done)
		local kind = tostring(args and args[2]):find("pkill", 1, true) and "kill" or "serve"
		local task = {
			kind = kind,
			start_calls = 0,
			terminate_calls = 0,
			completion_calls = 0,
		}
		function task.complete()
			task.completion_calls = task.completion_calls + 1
			on_done(0, "", "")
		end
		function task.start()
			task.start_calls = task.start_calls + 1
			local hook = nil
			if kind == "kill" then
				hook = shell.kill_start_hook
			else
				hook = shell.serve_start_hook
			end
			if type(hook) == "function" then
				if kind == "kill" then shell.kill_start_hook = nil else shell.serve_start_hook = nil end
				shell.start_hook_result = hook(task)
			end
			if shell.complete_during_start[kind] == true then task.complete() end
			local mode = shell.start_modes[kind]
			if mode == "throw" then error(kind .. " start exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			return true
		end
		function task.terminate()
			task.terminate_calls = task.terminate_calls + 1
			local mode = shell.terminate_mode
			if mode:find("^sync_", 1, false) then
				task.complete()
				mode = mode:gsub("^sync_", "")
			end
			if mode == "throw" then error("task terminate exploded") end
			if mode == "false" then return false, "refused" end
			if mode == "nil" then return nil end
			if mode == "pending" then return true, "pending" end
			return true, "settled"
		end
		shell.tasks[#shell.tasks + 1] = task
		return task
	end

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.notifications"] = { notify = function() return true end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["adapters.http_client"] = {
		new = function()
			return {
				cancel = function() return true end,
				isActive = function() return false end,
				get = function() return true end,
				post = function() return true end,
				onSettled = function(observer) observer(); return true end,
			}
		end,
	}
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["adapters.shell_runner"] = shell
	package.loaded["adapters.storage"] = { get = function() return nil end }
	package.loaded["adapters.json_codec"] = {
		encode = function() return "{}" end,
		decode = function() return {} end,
	}
	package.loaded["modules.llm.ollama_binary"] = {
		resolve = function() return "/fixture/ollama" end,
	}
	package.loaded["modules.llm.ollama_server_command"] = {
		build = function() return "exec /fixture/ollama serve" end,
	}
	package.loaded["modules.llm.progressive_reveal"] = {}
	package.loaded["modules.llm.parser"] = {}
	package.loaded["modules.llm.profiles"] = {}
	package.loaded["modules.llm.api_common"] = {
		DEFAULT_DEDUPLICATION_ENABLED = true,
		OLLAMA_KEEP_ALIVE = "5m",
		get_retry_policy = function() return 1, 0, 0 end,
	}
	package.loaded["modules.keylogger"] = {
		resync_context = function() return true end,
		log_shortcut = function() return true end,
	}
	package.loaded["modules.shortcuts.script_control"] = nil
	package.loaded["modules.llm.api_ollama"] = nil
	local api = helpers.load_with_stubs("modules.llm.api_ollama")

	package.loaded["modules.llm.api_ollama"] = api
	package.loaded["modules.llm.api_mlx"] = {
		pause_warmup = function() return true end,
		resume_warmup = function() return true end,
	}
	package.loaded["modules.llm.warmup_controller"] = {
		pause_warmup = function() return true end,
		resume_warmup = function() return true end,
	}
	package.loaded["modules.llm.api_remote"] = {
		pause_warmup = function()
			if hooks.remote_pause then hooks.remote_pause() end
			return true
		end,
		resume_warmup = function() return true end,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.gestures.actions"] = {
		SG_NAMES = {}, AX_NAMES = {},
		get_label = function(value) return value end,
		execute_single = function() return true end,
	}
	package.loaded["adapters.event_provenance"] = {}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	}
	local admission = nil
	package.loaded["adapters.synthetic_input"] = {
		when_idle = function(callback) callback(); return true end,
		acquire_admission_fence = function()
			if admission ~= nil then return nil end
			admission = {}
			return admission
		end,
		release_admission_fence = function(token)
			if token ~= admission then return false end
			admission = nil
			return true
		end,
	}
	package.loaded["ui.wpm.wpm_menubar"] = { is_running = function() return false end }
	package.loaded["ui.wpm.wpm_widget"] = { is_running = function() return false end }
	package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
	package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
	local script_control = helpers.load_with_stubs("modules.shortcuts.script_control")
	return {
		api = api,
		hooks = hooks,
		script_control = script_control,
		scheduler = scheduler,
		shell = shell,
	}
end

helpers.describe("HS-012 Ollama daemon-start pause ownership", function()
	helpers.it("keeps kill-task start owned until a reentrant PAUSE can retry", function()
		local fixture = load_fixture()
		fixture.shell.kill_start_hook = function()
			return fixture.script_control.pause_all()
		end
		helpers.assert_eq(fixture.api.ensure_running(), false,
			"the outer start must reject a candidate superseded while start was on-stack")
		helpers.assert_true(fixture.shell.start_hook_result)
		helpers.assert_eq(fixture.script_control.is_paused(), false)
		helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
			"PAUSED cannot publish from inside the native start boundary")
		helpers.assert_eq(fixture.shell.tasks[1].terminate_calls, 1,
			"the outer unwind must settle the exact kill task once")
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.script_control.is_paused())
	end)

	helpers.it("keeps launch-timer acquisition owned until a reentrant PAUSE can retry", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.api.ensure_running())
		fixture.scheduler.after_hook = function()
			return fixture.script_control.pause_all()
		end
		fixture.shell.tasks[1].complete()
		local launch_timer = fixture.scheduler.handles[1]
		helpers.assert_true(fixture.scheduler.after_hook_result)
		helpers.assert_eq(fixture.script_control.is_paused(), false)
		helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
			"the unreturned TimerScheduler.after frame must keep PAUSE pending")
		helpers.assert_eq(launch_timer.timer, nil,
			"the stale launch candidate must be compensated exactly after unwind")
		helpers.assert_eq(#fixture.shell.tasks, 1,
			"no serve task may be constructed from the stale timer transaction")
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.script_control.is_paused())
	end)

	helpers.it("keeps serve-task start owned until a reentrant PAUSE can retry", function()
		local fixture = load_fixture()
		fixture.shell.serve_start_hook = function()
			return fixture.script_control.pause_all()
		end
		helpers.assert_true(fixture.api.ensure_running())
		fixture.shell.tasks[1].complete()
		fixture.scheduler.handles[1].fire()
		local serve_task = fixture.shell.tasks[2]
		helpers.assert_true(fixture.shell.start_hook_result)
		helpers.assert_eq(fixture.script_control.is_paused(), false)
		helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
			"PAUSED cannot publish while serve start can still activate natively")
		helpers.assert_eq(serve_task.terminate_calls, 1,
			"the outer unwind must settle the exact serve candidate")
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.script_control.is_paused())
	end)

	for _, kind in ipairs({ "kill", "serve" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("does not resurrect a synchronously completed " .. kind
				.. " task after start " .. mode, function()
				local fixture = load_fixture()
				fixture.shell.terminate_mode = "throw"
				fixture.shell.start_modes[kind] = mode
				fixture.shell.complete_during_start[kind] = true
				if kind == "kill" then
					helpers.assert_eq(fixture.api.ensure_running(), false)
					local terminal_task = fixture.shell.tasks[1]
					helpers.assert_eq(terminal_task.start_calls, 1)
					helpers.assert_eq(terminal_task.completion_calls, 1,
						"positive control must complete the exact refused task synchronously")
					helpers.assert_eq(terminal_task.terminate_calls, 0,
						"a terminal callback must retire the task without synthetic termination")

					fixture.shell.start_modes[kind] = "true"
					fixture.shell.complete_during_start[kind] = false
					helpers.assert_true(fixture.api.ensure_running(),
						"a settled predecessor must admit a later successful acquisition")
					helpers.assert_eq(#fixture.shell.tasks, 2)
					helpers.assert_true(fixture.shell.tasks[2] ~= terminal_task,
						"the retry must own a distinct native task identity")
					helpers.assert_eq(fixture.shell.tasks[2].start_calls, 1)
				else
					helpers.assert_true(fixture.api.ensure_running())
					fixture.shell.tasks[1].complete()
					fixture.scheduler.handles[1].fire()
					helpers.assert_true(fixture.api.ensure_running(),
						"a completed refused serve start must leave no retained sibling fence")
					helpers.assert_eq(#fixture.shell.tasks, 3)
				end
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins a late stale-process task after terminate " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.api.ensure_running())
			local stale_task = fixture.shell.tasks[1]
			helpers.assert_eq(stale_task.kind, "kill")
			fixture.shell.terminate_mode = mode
			helpers.assert_true(fixture.script_control.pause_all(),
				"pause_all returns drain admission, not the synchronous nested commit verdict")
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
				"the refused kill and inverse must remain visible as exact transition debt")
			helpers.assert_eq(stale_task.terminate_calls, 2,
				"pause and its inverse must both retry the same stale-process task")
			helpers.assert_eq(#fixture.scheduler.handles, 0,
				"a fenced kill completion may not pre-arm a launch timer")

			stale_task.complete()
			helpers.assert_eq(#fixture.scheduler.handles, 1,
				"exact task settlement must stage one ACTIVE rollback restoration")
			stale_task.complete()
			helpers.assert_eq(#fixture.scheduler.handles, 1,
				"duplicate task completion must remain inert")

			fixture.shell.terminate_mode = "true"
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_eq(fixture.script_control.is_pause_transition_pending(), false)
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, 2)
			fixture.scheduler.handles[2].fire()
			helpers.assert_eq(#fixture.shell.tasks, 2,
				"resume must restore exactly one pre-pause daemon-start intent")
			helpers.assert_true(fixture.shell.tasks[2] ~= stale_task,
				"the resumed pipeline must never recycle the terminal predecessor identity")
		end)
	end

	for _, mode in ipairs({ "sync_false", "sync_nil", "sync_throw" }) do
		helpers.it("accepts synchronous kill settlement before outer " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.api.ensure_running())
			fixture.shell.terminate_mode = mode
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_eq(#fixture.scheduler.handles, 0,
				"a synchronous stale-process terminal may not schedule launch under PAUSED")
			fixture.shell.tasks[1].complete()
			helpers.assert_eq(#fixture.scheduler.handles, 0)
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, 1)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("waits for a due launch timer whose stop returns " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.api.ensure_running())
			fixture.shell.tasks[1].complete()
			local launch_timer = fixture.scheduler.handles[1]
			fixture.scheduler.cancel_mode = mode
			helpers.assert_true(fixture.script_control.pause_all(),
				"pause_all returns drain admission even when the nested timer join refuses")
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
				"the exact launch timer and inverse debt must keep publication pending")
			helpers.assert_eq(#fixture.scheduler.cancel_calls, 2,
				"pause and rollback must each retry the launch timer")
			helpers.assert_true(fixture.scheduler.cancel_calls[1] == launch_timer
				and fixture.scheduler.cancel_calls[2] == launch_timer,
				"both cleanup attempts must retain the same timer identity")
			launch_timer.fire()
			helpers.assert_eq(#fixture.shell.tasks, 1,
				"a due timer with live native ownership may not spawn serve")
			launch_timer.fire()
			helpers.assert_eq(#fixture.shell.tasks, 1)
			helpers.assert_true(fixture.scheduler.cancel_calls[3] == launch_timer
				and fixture.scheduler.cancel_calls[4] == launch_timer,
				"repeated native delivery may only retry the retained timer")

			fixture.scheduler.cancel_mode = "true"
			launch_timer.fire()
			helpers.assert_eq(launch_timer.timer, nil,
				"the fifth identity-matched stop must be exact terminal proof")
			helpers.assert_eq(#fixture.shell.tasks, 1,
				"stale settlement may restore intent but never run the old launch body")
			helpers.assert_eq(#fixture.scheduler.handles, 2)
			launch_timer.fire()
			helpers.assert_eq(#fixture.scheduler.handles, 2,
				"duplicate native delivery must not stage a sibling")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences an unpublished serve task after terminate " .. mode, function()
			local fixture = load_fixture()
			local pause_result = nil
			fixture.shell.serve_start_hook = function()
				fixture.shell.terminate_mode = mode
				pause_result = fixture.script_control.pause_all()
			end
			helpers.assert_true(fixture.api.ensure_running())
			fixture.shell.tasks[1].complete()
			fixture.scheduler.handles[1].fire()
			local serve_task = fixture.shell.tasks[2]
			helpers.assert_true(pause_result,
				"pause_all returns drain admission even when the nested serve join refuses")
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
				"the unpublished serve task must remain exact transition debt")
			helpers.assert_eq(serve_task.terminate_calls, 1,
				"the nested PAUSE must leave termination to the exact outer unwind")
			helpers.assert_eq(fixture.api.ensure_running(), false,
				"a sibling daemon start must remain fenced while that task is live")
			helpers.assert_eq(#fixture.shell.tasks, 2,
				"cleanup retry may not construct a sibling serve or kill task")
			helpers.assert_true(fixture.shell.tasks[2] == serve_task,
				"the cleanup ledger must retain the original serve identity")
			helpers.assert_eq(serve_task.terminate_calls, 2,
				"the sibling refusal must retry that same exact task")
			serve_task.complete()
			helpers.assert_eq(serve_task.completion_calls, 1)
			helpers.assert_eq(#fixture.scheduler.handles, 2)
			serve_task.complete()
			helpers.assert_eq(serve_task.completion_calls, 2,
				"duplicate native terminal delivery is observable but logically inert")
			helpers.assert_eq(#fixture.scheduler.handles, 2)
		end)
	end

	for _, mode in ipairs({ "sync_false", "sync_nil", "sync_throw" }) do
		helpers.it("accepts synchronous serve settlement before outer " .. mode, function()
			local fixture = load_fixture()
			local pause_result = nil
			fixture.shell.serve_start_hook = function()
				fixture.shell.terminate_mode = mode
				pause_result = fixture.script_control.pause_all()
			end
			helpers.assert_true(fixture.api.ensure_running())
			fixture.shell.tasks[1].complete()
			fixture.scheduler.handles[1].fire()
			helpers.assert_true(pause_result,
				"pause_all accepts the drain while native start keeps publication pending")
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending())
			helpers.assert_true(fixture.script_control.pause_all(),
				"a retry after the start frame unwinds may publish PAUSED")
			helpers.assert_true(fixture.script_control.is_paused())
		local handles_before_resume = #fixture.scheduler.handles
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, handles_before_resume + 1)
		end)
	end

	helpers.it("does not terminate or restore an already-published daemon", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.api.ensure_running())
		fixture.shell.tasks[1].complete()
		fixture.scheduler.handles[1].fire()
		local published_serve = fixture.shell.tasks[2]
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_eq(published_serve.terminate_calls, 0)
		helpers.assert_true(fixture.script_control.resume_all())
		helpers.assert_eq(#fixture.shell.tasks, 2,
			"pause must not invent restore intent for a published daemon")
	end)

	helpers.it("stages ensure_running calls made after PAUSED", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.api.ensure_running())
		helpers.assert_eq(#fixture.shell.tasks, 0,
			"a backend setter under PAUSED may not construct the kill task")
		helpers.assert_true(fixture.script_control.resume_all())
		helpers.assert_eq(#fixture.scheduler.handles, 1)
		fixture.scheduler.handles[1].fire()
		helpers.assert_eq(#fixture.shell.tasks, 1)
	end)

	helpers.it("fences sibling ensure_running during the pause transaction", function()
		local fixture = load_fixture()
		fixture.hooks.remote_pause = function()
			helpers.assert_eq(fixture.script_control.is_paused(), false,
				"the sibling must exercise the window before PAUSED is published")
			helpers.assert_true(fixture.api.ensure_running())
		end
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_eq(#fixture.shell.tasks, 0,
			"a later pause owner may not construct an Ollama startup sibling")
		helpers.assert_true(fixture.script_control.resume_all())
		helpers.assert_eq(#fixture.scheduler.handles, 1,
			"the fenced acquisition intent must be restored exactly once")
	end)
end)

return true
