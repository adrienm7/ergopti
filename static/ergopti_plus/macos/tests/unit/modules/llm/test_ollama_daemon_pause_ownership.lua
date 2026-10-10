--- tests/unit/modules/llm/test_ollama_daemon_pause_ownership.lua

--- ==============================================================================
--- MODULE: Ollama Daemon Pause Ownership Regression
--- DESCRIPTION:
--- Drives the real Ollama controller through ScriptControl while one foreground
--- serve owner and the original post-RESUMED staging timers are still owned.
--- Historical case names remain stable; kill/readiness-delay targets are rehomed
--- to the accepted foreground protocol, never represented by fake task aliases.
--- Refusal and reordered-terminal cases prove PAUSED cannot be published over a
--- live startup pipeline and that only pre-pause intent is restored afterward.
--- ==============================================================================

local helpers = require("tests.helpers")
local nonce_counter = 41000

--- Loads real ScriptControl and ApiOllama over exact observable native doubles.
--- @return table fixture
local function load_fixture()
	nonce_counter = nonce_counter + 1
	local nonce = string.format("%032x", nonce_counter)
	local function frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. nonce .. " " .. role .. "\n" end
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
		tasks = {}, terminate_mode = "true", start_mode = "true",
		start_hook = nil, complete_during_start = false, active_on_start = true,
	}
	function shell.spawn(executable, args, on_done, on_chunk, environment, private, owned)
		helpers.assert_eq(executable, "/bin/sh")
		helpers.assert_eq(args[1], "-c")
		helpers.assert_eq(args[2], "exec /fixture/native-owner --caller-nonce '" .. nonce .. "' --owned-stdin")
		helpers.assert_eq(args[2]:find("pkill", 1, true), nil)
		helpers.assert_eq(args[2]:find("nohup", 1, true), nil)
		helpers.assert_eq(type(on_chunk), "function")
		helpers.assert_eq(private, true)
		helpers.assert_eq(owned, true)
		local task = {
			kind = "serve", start_calls = 0, terminate_calls = 0, completion_calls = 0,
			attempted = false, settled = false, observers = {}, active = false, ready = false,
		}
		function task.isSettled() return task.settled end
		function task.wasStartAttempted() return task.attempted end
		function task.onSettled(observer)
			if task.settled then observer() else task.observers[#task.observers + 1] = observer end
			return true
		end
		function task.emit(value) on_chunk(task, value, "") end
		function task.publish_ready()
			helpers.assert_true(task.active, "READY input follows this exact task's ACTIVE input")
			helpers.assert_eq(task.ready, false)
			task.ready = true
			task.emit(frame("READY"))
		end
		function task.complete()
			task.completion_calls = task.completion_calls + 1
			if task.settled then on_done(task.ready and 0 or 78, "", ""); return end
			task.settled = true
			-- Fixed fixture wire inputs, independent of any parser output. Before
			-- READY only the original refusal status78 is admitted by this protocol.
			local status = task.ready and 0 or 78
			on_done(status, frame("RETIRED " .. tostring(status)), "")
			local pending = task.observers; task.observers = {}
			for _, observer in ipairs(pending) do observer() end
		end
		function task.start()
			task.start_calls = task.start_calls + 1
			task.attempted = true
			if shell.active_on_start then task.active = true; task.emit(frame("ACTIVE")) end
			local hook = shell.start_hook; shell.start_hook = nil
			if type(hook) == "function" then shell.start_hook_result = hook(task) end
			if shell.complete_during_start then task.complete() end
			if shell.start_mode == "throw" then error("serve start exploded") end
			if shell.start_mode == "false" then return false end
			if shell.start_mode == "nil" then return nil end
			return true
		end
		function task.terminate()
			task.terminate_calls = task.terminate_calls + 1
			local mode = shell.terminate_mode
			if mode:find("^sync_", 1, false) then task.complete(); mode = mode:gsub("^sync_", "") end
			if mode == "throw" then error("task terminate exploded") end
			if mode == "false" then return false, "refused" end
			if mode == "nil" then return nil end
			if mode == "pending" then return true, "pending" end
			if not task.attempted then
				task.settled = true
				local pending = task.observers; task.observers = {}
				for _, observer in ipairs(pending) do observer() end
			else task.complete() end
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
				isSettled = function() return true end,
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
		resolve = function() return "/fixture/ollama", nil, "native_managed" end,
	}
	package.loaded["modules.llm.ollama_server_command"] = {
		build = function(_, _, _, kind, caller_nonce)
			helpers.assert_eq(kind, "native_managed")
			helpers.assert_eq(caller_nonce, nonce)
			return "exec /fixture/native-owner --caller-nonce '" .. nonce .. "' --owned-stdin"
		end,
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
	local hs_overrides = {
		host = { uuid = function() return nonce:sub(1, 8) .. "-" .. nonce:sub(9, 12) .. "-"
			.. nonce:sub(13, 16) .. "-" .. nonce:sub(17, 20) .. "-" .. nonce:sub(21, 32) end },
	}
	local api = helpers.load_with_stubs("modules.llm.api_ollama", hs_overrides)

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
	local script_control = helpers.load_with_stubs("modules.shortcuts.script_control", hs_overrides)
	return {
		api = api,
		hooks = hooks,
		script_control = script_control,
		scheduler = scheduler,
		shell = shell,
		frame = frame,
	}
end

helpers.describe("HS-012 Ollama daemon-start pause ownership", function()
	helpers.it("reports startup admission only after exact native publication or cleanup", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.api.startup_idle(), true)
		helpers.assert_eq(#fixture.shell.tasks, 0, "the admission query must be read-only")
		helpers.assert_true(fixture.api.ensure_running())
		local original = fixture.shell.tasks[1]
		helpers.assert_eq(#fixture.shell.tasks, 1)
		helpers.assert_eq(#fixture.scheduler.handles, 0, "start acceptance must not invent a readiness timer")
		helpers.assert_eq(fixture.api.startup_idle(), false)
		local ready = fixture.frame("READY")
		original.emit(ready:sub(1, #ready - 1))
		helpers.assert_eq(fixture.api.startup_idle(), false, "partial READY cannot publish")
		original.ready = true
		original.emit("\n")
		helpers.assert_eq(fixture.api.startup_idle(), true,
			"an acknowledged published daemon permits readonly admission without terminating it")
		helpers.assert_eq(original.terminate_calls, 0)
		helpers.assert_eq(fixture.api.migration_idle(), false, "READY does not retire foreground custody")
		original.complete()
		helpers.assert_true(fixture.api.migration_idle())
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps readonly startup admission closed after failed acquisition and terminate " .. mode, function()
			local fixture = load_fixture()
			fixture.shell.start_mode, fixture.shell.terminate_mode = "false", mode
			local settlements = {}
			helpers.assert_eq(fixture.api.ensure_running({
				is_authorized = function() return true end,
				on_settled = function(committed, reason) settlements[#settlements + 1] = { committed, reason } end,
			}), false)
			helpers.assert_eq(#settlements, 1)
			helpers.assert_eq(settlements[1][1], false,
				"a terminal refusal does not itself acknowledge native cleanup")
			helpers.assert_eq(fixture.api.startup_idle(), false)
			local original = fixture.shell.tasks[1]
			local calls = original.terminate_calls
			helpers.assert_eq(fixture.api.startup_idle(), false)
			helpers.assert_eq(original.terminate_calls, calls,
				"readonly admission must not retry or mutate the owned native task")
			helpers.assert_eq(#fixture.shell.tasks, 1)
			helpers.assert_eq(#fixture.scheduler.handles, 0)
			original.complete()
			helpers.assert_eq(fixture.api.startup_idle(), true)
			helpers.assert_eq(#settlements, 1)
			helpers.assert_eq(#fixture.shell.tasks, 1)
		end)
	end

	helpers.it("keeps kill-task start owned until a reentrant PAUSE can retry", function()
		-- Historical kill-stage name now exercises the sole native start boundary.
		local fixture = load_fixture()
		fixture.shell.start_hook = function() return fixture.script_control.pause_all() end
		helpers.assert_eq(fixture.api.ensure_running(), false,
			"the outer start must reject a candidate superseded while start was on-stack")
		helpers.assert_true(fixture.shell.start_hook_result)
		helpers.assert_eq(fixture.script_control.is_paused(), false)
		helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
			"PAUSED cannot publish from inside the native start boundary")
		helpers.assert_eq(fixture.shell.tasks[1].terminate_calls, 1,
			"the outer unwind must settle the exact foreground task once")
		helpers.assert_eq(#fixture.shell.tasks, 1)
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.script_control.is_paused())
	end)

	helpers.it("keeps launch-timer acquisition owned until a reentrant PAUSE can retry", function()
		-- Native READY delivery replaces the deliberately removed readiness timer.
		local fixture = load_fixture()
		local armed, pause_result = false, nil
		local settlements = {}
		helpers.assert_true(fixture.api.ensure_running({
			is_authorized = function()
				if armed then armed = false; pause_result = fixture.script_control.pause_all() end
				return true
			end,
			on_settled = function(value) settlements[#settlements + 1] = value end,
		}))
		armed = true
		local original = fixture.shell.tasks[1]
		original.publish_ready()
		helpers.assert_true(pause_result)
		helpers.assert_eq(#settlements, 1)
		helpers.assert_eq(settlements[1], false, "stale native READY cannot publish readiness under PAUSE")
		helpers.assert_eq(#fixture.shell.tasks, 1)
		helpers.assert_eq(#fixture.scheduler.handles, 0, "native READY cannot create a delay owner")
		local paused_verdict
		helpers.assert_true(fixture.api.ensure_running({
			is_authorized = function() return true end,
			on_settled = function(value) paused_verdict = value end,
		}))
		helpers.assert_eq(paused_verdict, false,
			"a READY callback superseded by PAUSE cannot republish its retired owner")
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.script_control.is_paused())
	end)

	helpers.it("keeps serve-task start owned until a reentrant PAUSE can retry", function()
		local fixture = load_fixture()
		fixture.shell.start_hook = function(task)
			helpers.assert_true(task.active, "this branch has already delivered ACTIVE")
			return fixture.script_control.pause_all()
		end
		helpers.assert_eq(fixture.api.ensure_running(), false)
		local original = fixture.shell.tasks[1]
		helpers.assert_true(fixture.shell.start_hook_result)
		helpers.assert_eq(fixture.script_control.is_paused(), false)
		helpers.assert_true(fixture.script_control.is_pause_transition_pending(),
			"PAUSED cannot publish while serve start can still activate natively")
		helpers.assert_eq(original.terminate_calls, 1,
			"the outer unwind must settle the exact serve candidate")
		helpers.assert_eq(#fixture.shell.tasks, 1)
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.script_control.is_paused())
	end)

	for _, kind in ipairs({ "kill", "serve" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("does not resurrect a synchronously completed " .. kind
				.. " task after start " .. mode, function()
				local fixture = load_fixture()
				fixture.shell.terminate_mode, fixture.shell.start_mode = "throw", mode
				-- Preserve both receiving families: before ACTIVE vs after ACTIVE.
				fixture.shell.active_on_start = kind == "serve"
				fixture.shell.complete_during_start = true
				helpers.assert_eq(fixture.api.ensure_running(), false)
				local terminal_task = fixture.shell.tasks[1]
				helpers.assert_eq(terminal_task.kind, "serve")
				helpers.assert_eq(terminal_task.start_calls, 1)
				helpers.assert_eq(terminal_task.completion_calls, 1,
					"positive control completes the exact refused task synchronously")
				helpers.assert_eq(terminal_task.terminate_calls, 0,
					"RETIRED plus physical completion retires without synthetic termination")
				helpers.assert_true(fixture.api.startup_idle())
				helpers.assert_eq(#fixture.scheduler.handles, 0)
				fixture.shell.start_mode, fixture.shell.complete_during_start = "true", false
				fixture.shell.active_on_start = true
				helpers.assert_true(fixture.api.ensure_running(),
					"a settled predecessor must admit a later successful acquisition")
				helpers.assert_eq(#fixture.shell.tasks, 2, "one new foreground owner follows exact old retirement")
				helpers.assert_true(fixture.shell.tasks[2] ~= terminal_task)
				helpers.assert_eq(fixture.shell.tasks[2].start_calls, 1)
				helpers.assert_eq(#fixture.scheduler.handles, 0)
				fixture.shell.tasks[2].complete()
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins a late stale-process task after terminate " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.api.ensure_running())
			local stale_task = fixture.shell.tasks[1]
			helpers.assert_eq(stale_task.kind, "serve", "stale debt is the exact owned foreground task")
			fixture.shell.terminate_mode = mode
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending())
			helpers.assert_eq(stale_task.terminate_calls, 2, "pause and inverse retry the same original owner")
			helpers.assert_eq(#fixture.scheduler.handles, 0)
			helpers.assert_eq(#fixture.shell.tasks, 1)
			stale_task.complete()
			helpers.assert_eq(#fixture.scheduler.handles, 1, "exact settlement stages ACTIVE rollback restoration")
			stale_task.complete()
			helpers.assert_eq(#fixture.scheduler.handles, 1, "duplicate terminal delivery cannot stage a sibling")
			fixture.shell.terminate_mode = "true"
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, 2)
			fixture.scheduler.handles[2].fire()
			helpers.assert_eq(#fixture.shell.tasks, 2, "resume restores one distinct foreground owner only")
			helpers.assert_true(fixture.shell.tasks[2] ~= stale_task)
			helpers.assert_eq(fixture.shell.tasks[2].kind, "serve")
			fixture.shell.tasks[2].complete()
		end)
	end

	for _, mode in ipairs({ "sync_false", "sync_nil", "sync_throw" }) do
		helpers.it("accepts synchronous kill settlement before outer " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.api.ensure_running())
			local original = fixture.shell.tasks[1]
			fixture.shell.terminate_mode = mode
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_eq(#fixture.scheduler.handles, 0)
			helpers.assert_true(original.settled)
			original.complete()
			helpers.assert_eq(#fixture.scheduler.handles, 0, "duplicate retirement under PAUSED remains inert")
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, 1)
			helpers.assert_eq(#fixture.shell.tasks, 1, "resume acceptance cannot prelaunch a sibling")
			fixture.scheduler.handles[1].fire()
			helpers.assert_eq(#fixture.shell.tasks, 2)
			fixture.shell.tasks[2].complete()
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("waits for a due launch timer whose stop returns " .. mode, function()
			-- This is the existing post-RESUMED intent timer, never a readiness timer.
			local fixture = load_fixture()
			helpers.assert_true(fixture.api.ensure_running())
			local original = fixture.shell.tasks[1]
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(original.settled)
			helpers.assert_true(fixture.script_control.resume_all())
			local launch_timer = fixture.scheduler.handles[1]
			fixture.scheduler.cancel_mode = mode
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending())
			helpers.assert_eq(#fixture.scheduler.cancel_calls, 2)
			helpers.assert_true(fixture.scheduler.cancel_calls[1] == launch_timer
				and fixture.scheduler.cancel_calls[2] == launch_timer)
			launch_timer.fire()
			launch_timer.fire()
			helpers.assert_eq(#fixture.shell.tasks, 1, "due timer debt cannot start any new foreground owner")
			helpers.assert_true(fixture.scheduler.cancel_calls[3] == launch_timer
				and fixture.scheduler.cancel_calls[4] == launch_timer)
			fixture.scheduler.cancel_mode = "true"
			launch_timer.fire()
			helpers.assert_eq(launch_timer.timer, nil)
			helpers.assert_eq(#fixture.shell.tasks, 1, "stale settlement cannot execute the old timer body")
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, 2)
			launch_timer.fire()
			helpers.assert_eq(#fixture.scheduler.handles, 2)
			fixture.scheduler.handles[2].fire()
			helpers.assert_eq(#fixture.shell.tasks, 2)
			fixture.shell.tasks[2].complete()
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences an unpublished serve task after terminate " .. mode, function()
			local fixture = load_fixture()
			local pause_result
			fixture.shell.start_hook = function()
				fixture.shell.terminate_mode = mode
				pause_result = fixture.script_control.pause_all()
			end
			helpers.assert_eq(fixture.api.ensure_running(), false)
			local serve_task = fixture.shell.tasks[1]
			helpers.assert_true(pause_result)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending())
			helpers.assert_eq(serve_task.terminate_calls, 1, "outer unwind alone attempts original termination")
			helpers.assert_eq(fixture.api.ensure_running(), false)
			helpers.assert_eq(#fixture.shell.tasks, 1, "a cleanup retry cannot construct any sibling")
			helpers.assert_true(fixture.shell.tasks[1] == serve_task)
			helpers.assert_eq(serve_task.terminate_calls, 2)
			serve_task.complete()
			helpers.assert_eq(serve_task.completion_calls, 1)
			helpers.assert_eq(#fixture.scheduler.handles, 1)
			serve_task.complete()
			helpers.assert_eq(serve_task.completion_calls, 2)
			helpers.assert_eq(#fixture.scheduler.handles, 1)
			fixture.shell.terminate_mode = "true"
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
		end)
	end

	for _, mode in ipairs({ "sync_false", "sync_nil", "sync_throw" }) do
		helpers.it("accepts synchronous serve settlement before outer " .. mode, function()
			local fixture = load_fixture()
			local pause_result
			fixture.shell.start_hook = function()
				fixture.shell.terminate_mode = mode
				pause_result = fixture.script_control.pause_all()
			end
			helpers.assert_eq(fixture.api.ensure_running(), false)
			helpers.assert_true(pause_result)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.script_control.is_pause_transition_pending())
			helpers.assert_eq(#fixture.shell.tasks, 1)
			helpers.assert_true(fixture.shell.tasks[1].settled)
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			local handles_before_resume = #fixture.scheduler.handles
			helpers.assert_true(fixture.script_control.resume_all())
			helpers.assert_eq(#fixture.scheduler.handles, handles_before_resume + 1)
			fixture.scheduler.handles[#fixture.scheduler.handles].fire()
			helpers.assert_eq(#fixture.shell.tasks, 2)
			fixture.shell.tasks[2].complete()
		end)
	end

	helpers.it("does not terminate or restore an already-published daemon", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.api.ensure_running())
		local published_serve = fixture.shell.tasks[1]
		published_serve.publish_ready()
		helpers.assert_true(fixture.api.startup_idle())
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_eq(published_serve.terminate_calls, 0)
		helpers.assert_true(fixture.script_control.resume_all())
		helpers.assert_eq(#fixture.shell.tasks, 1, "pause cannot invent another foreground owner")
		helpers.assert_eq(#fixture.scheduler.handles, 0, "published daemon owes no restoration timer")
		published_serve.complete()
	end)

	helpers.it("stages ensure_running calls made after PAUSED", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_true(fixture.api.ensure_running())
		helpers.assert_eq(#fixture.shell.tasks, 0)
		helpers.assert_true(fixture.script_control.resume_all())
		helpers.assert_eq(#fixture.scheduler.handles, 1)
		helpers.assert_eq(#fixture.shell.tasks, 0, "only actual post-RESUMED delivery acquires a task")
		fixture.scheduler.handles[1].fire()
		helpers.assert_eq(#fixture.shell.tasks, 1)
		helpers.assert_eq(#fixture.scheduler.handles, 1, "native start adds no readiness timer")
		helpers.assert_eq(fixture.api.startup_idle(), false)
		fixture.shell.tasks[1].publish_ready()
		helpers.assert_true(fixture.api.startup_idle())
		fixture.shell.tasks[1].complete()
	end)

	helpers.it("fences sibling ensure_running during the pause transaction", function()
		local fixture = load_fixture()
		fixture.hooks.remote_pause = function()
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(fixture.api.ensure_running())
		end
		helpers.assert_true(fixture.script_control.pause_all())
		helpers.assert_eq(#fixture.shell.tasks, 0)
		helpers.assert_true(fixture.script_control.resume_all())
		helpers.assert_eq(#fixture.scheduler.handles, 1, "restore exactly one fenced acquisition intent")
		fixture.scheduler.handles[1].fire()
		helpers.assert_eq(#fixture.shell.tasks, 1)
		fixture.shell.tasks[1].complete()
	end)
end)

return true
