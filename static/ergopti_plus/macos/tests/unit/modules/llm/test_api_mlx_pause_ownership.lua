--- tests/unit/modules/llm/test_api_mlx_pause_ownership.lua

--- ==============================================================================
--- MODULE: MLX Warmup Pause Ownership Regression Tests
--- DESCRIPTION:
--- Exercises the real MLX controller, discovery state machine, HttpClient,
--- TimerScheduler, and ShellRunner against native-shaped asynchronous doubles.
--- Pause must fence every late completion before reporting exact settlement,
--- retain each refused capability for retry, and restart only a warmup that was
--- active before the pause transaction began.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE_NAMES = {
	"adapters.http_client",
	"adapters.json_codec",
	"adapters.shell_runner",
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.notifications",
	"modules.llm.api_mlx",
	"modules.llm.api_mlx_discovery",
	"modules.llm.api_mlx_fetch",
	"modules.llm.api_mlx_inference",
	"modules.llm.warmup_controller",
	"modules.shortcuts.script_control",
}

--- Captures every module slot replaced by the native ownership harness.
--- @return table saved Exact package cache and global Hammerspoon state.
local function snapshot_modules()
	local saved = { global_hs = rawget(_G, "hs"), modules = {} }
	for name, module in pairs(package.loaded) do saved.modules[name] = module end
	return saved
end

--- Restores the package cache even when an assertion raises.
--- @param saved table Snapshot returned by snapshot_modules().
local function restore_modules(saved)
	for name in pairs(package.loaded) do package.loaded[name] = nil end
	for name, module in pairs(saved.modules) do package.loaded[name] = module end
	_G.hs = saved.global_hs
end

--- Returns the exact refusal value selected by one adversarial mode.
--- @param mode string One of success, false, nil, or throw.
--- @param message string Stable thrown-error text.
--- @param success_value any Value returned on success.
--- @return any result Selected native result.
local function native_result(mode, message, success_value)
	if mode == "throw" then error(message) end
	if mode == "false" then return false end
	if mode == "nil" then return nil end
	return success_value
end

--- Builds one faithful native timer surface for the real TimerScheduler.
--- @param state table Mutable harness observations.
--- @return table timer_stub Hammerspoon timer surface.
local function make_timer_stub(state)
	local timer_stub = {
		secondsSinceEpoch = function() return state.now end,
		doAfter = function() error("MLX ownership must use TimerScheduler.after") end,
	}

	function timer_stub.new(delay, callback)
		local running = false
		local native = {}
		local queued_stop_mode = table.remove(state.timer_stop_modes, 1)
		local entry = {
			delay = delay,
			callback = callback,
			native = native,
			stop_calls = 0,
			stop_mode = queued_stop_mode or state.next_timer_stop_mode,
		}
		state.next_timer_stop_mode = nil
		function native:start()
			local mode = table.remove(state.timer_start_modes, 1)
				or state.next_timer_start_mode or "success"
			state.next_timer_start_mode = nil
			local mutated_mode = mode:match("^mutate_(.+)$")
			if mutated_mode then
				running = true
				mode = mutated_mode
			end
			local result = native_result(mode,
				"synthetic timer start failure", self)
			if result ~= false and result ~= nil then running = true end
			return result
		end
		function native:running() return running end
		function native:stop()
			entry.stop_calls = entry.stop_calls + 1
			local result = native_result(entry.stop_mode or state.timer_stop_mode,
				"synthetic timer stop failure", self)
			if result ~= false and result ~= nil then running = false end
			return result
		end
		function entry.fire(force)
			if force == true or running then callback() end
		end
		state.timers[#state.timers + 1] = entry
		return native
	end

	return timer_stub
end

--- Builds native HTTP tasks whose cancellation can refuse after dispatch.
--- @param state table Mutable harness observations.
--- @return table http_stub Hammerspoon HTTP surface.
local function make_http_stub(state)
	local http_stub = {}

	local function dispatch(method, url, callback, body)
		local task = {}
		local request = {
			method = method,
			url = url,
			body = body,
			callback = callback,
			task = task,
			cancel_calls = 0,
		}
		function task:cancel()
			request.cancel_calls = request.cancel_calls + 1
			return native_result(state.http_cancel_mode,
				"synthetic HTTP cancel failure", true)
		end
		function request.deliver(status, body)
			callback(status, body or "", {})
		end
		state.http_requests[#state.http_requests + 1] = request
		return task
	end

	function http_stub.asyncPost(url, body, _headers, callback)
		return dispatch("POST", url, callback, body)
	end
	function http_stub.asyncGet(url, _headers, callback)
		return dispatch("GET", url, callback)
	end
	function http_stub.encodeForQuery(value) return tostring(value or "") end
	return http_stub
end

--- Builds native subprocesses for the real ShellRunner owner.
--- @param state table Mutable harness observations.
--- @return table task_stub Hammerspoon task surface.
local function make_task_stub(state)
	local task_stub = {}
	function task_stub.new(executable, on_done, third, fourth)
		local args = fourth or third
		local native = {}
		local entry = {
			executable = executable,
			args = args,
			on_done = on_done,
			start_calls = 0,
			terminate_calls = 0,
			native = native,
		}
		function native:start()
			entry.start_calls = entry.start_calls + 1
			return self
		end
		function native:terminate()
			entry.terminate_calls = entry.terminate_calls + 1
			return native_result(state.task_terminate_mode,
				"synthetic task terminate failure", self)
		end
		function entry.complete(exit_code, stdout, stderr)
			on_done(exit_code or 0, stdout or "", stderr or "")
		end
		state.tasks[#state.tasks + 1] = entry
		return native
	end
	return task_stub
end

--- Loads the real asynchronous ownership stack against controllable natives.
--- @param fn function Test body receiving { api, discovery, state }.
local function with_real_mlx_stack(fn)
	local saved = snapshot_modules()
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = nil end

	local state = {
		now = 1000,
		script_paused = false,
		pause_epoch = 0,
		timer_stop_mode = "success",
		timer_start_modes = {},
		timer_stop_modes = {},
		http_cancel_mode = "success",
		task_terminate_mode = "success",
		timers = {},
		http_requests = {},
		tasks = {},
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return state.script_paused end,
		get_pause_epoch = function() return state.pause_epoch end,
	}

	local api
	local discovery
	local ok, err = xpcall(function()
		api = helpers.load_with_stubs("modules.llm.api_mlx", {
			timer = make_timer_stub(state),
			http = make_http_stub(state),
			task = make_task_stub(state),
		})
		discovery = package.loaded["modules.llm.api_mlx_discovery"]
		helpers.assert_not_nil(discovery,
			"positive control must load the real MLX discovery module")
		fn({ api = api, discovery = discovery, state = state })
	end, debug.traceback)
	restore_modules(saved)
	if not ok then error(err, 0) end
end

--- Returns only native HTTP requests matching one route fragment.
--- @param state table Harness state.
--- @param fragment string Literal URL fragment.
--- @return table[] requests Matching request records.
local function requests_matching(state, fragment)
	local matches = {}
	for _, request in ipairs(state.http_requests) do
		if request.url:find(fragment, 1, true) then matches[#matches + 1] = request end
	end
	return matches
end

--- Installs the non-MLX inventory surfaces needed to exercise the real
--- ScriptControl transaction without starting its eventtap.
local function install_script_control_dependencies(options)
	options = options or {}
	local function settled() return true end
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["adapters.event_provenance"] = {}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	}
	local fence
	package.loaded["adapters.synthetic_input"] = {
		when_idle = function(callback) callback(); return true end,
		acquire_admission_fence = function()
			fence = { active = true }
			return fence
		end,
		release_admission_fence = function(token)
			if token ~= fence or token.active ~= true then return false end
			token.active = false
			fence = nil
			return true
		end,
	}
	package.loaded["infra.keycodes"] = {
		F13_KARABINER_RETURN = 106,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE = 108,
		BACKSPACE = 51,
		RETURN = 36,
		ESCAPE = 53,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.gestures.actions"] = {
		get_label = function(name) return name end,
		execute_single = settled,
		SG_NAMES = { "none", "script_pause_toggle" },
		AX_NAMES = {},
	}
	package.loaded["modules.llm.warmup_controller"] = options.warmup_controller or {
		pause_warmup = settled,
		resume_warmup = options.warmup_controller_resume or settled,
	}
	package.loaded["modules.llm.api_ollama"] = {
		pause_warmup = settled,
		resume_warmup = settled,
	}
	package.loaded["modules.llm.api_remote"] = {
		pause_warmup = settled,
		resume_warmup = settled,
	}
	package.loaded["ui.wpm.wpm_menubar"] = { is_running = function() return false end }
	package.loaded["ui.wpm.wpm_widget"] = { is_running = function() return false end }
	package.loaded["platform.remap.onboarding"] = { stop = settled }
	package.loaded["ui.tooltip"] = { hide_forced = settled }
	package.loaded["modules.keylogger"] = { resync_context = settled }
end

--- Initialises the real shared WarmupController without giving it a timer.
--- This models the menu path, which calls MLX warmup directly: the controller
--- participates in pause/resume but has no pending intention that could mask a
--- missing MLX-owned recovery trigger.
--- @param env table Real MLX harness environment.
--- @return table controller Initialised WarmupController module.
local function init_idle_real_warmup_controller(env)
	package.loaded["modules.llm.warmup_controller"] = nil
	local controller = require("modules.llm.warmup_controller")
	helpers.assert_true(controller.init({
		core_llm = {
			is_backend_ready = env.api.is_ready,
			is_backend_load_failed = env.api.is_load_failed,
			get_current_model = function() return "fixture-model" end,
			get_backend = function() return "mlx" end,
			get_active_profile = function() return nil end,
			warmup_model = env.api.warmup,
		},
		get_llm_enabled = function() return true end,
	}))
	return controller
end

helpers.describe("HS-012 real MLX warmup HTTP ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the warmup POST and intention after " .. mode .. " cancellation", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				env.state.http_cancel_mode = mode

				helpers.assert_true(env.api.warmup("fixture-model", nil),
					"positive control must dispatch a real HttpClient warmup")
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 1)
				local late = warmup_requests[1]

				helpers.assert_eq(env.api.pause_warmup(), false,
					"pause may not publish over non-exact POST cancellation")
				helpers.assert_eq(late.cancel_calls, 1,
					"pause must attempt the exact warmup task once")
				helpers.assert_eq(env.api.resume_warmup(), false,
					"resume must retain the same POST while its native task is still live")
				helpers.assert_eq(late.cancel_calls, 2,
					"cleanup retry must target the same warmup task, never a sibling")

				late.deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_eq(env.api.is_ready(), false,
					"the real HttpClient generation must fence a late warmup response")
				helpers.assert_true(env.api.resume_warmup(),
					"the exact task terminal must settle the debt despite the old cancel refusal")
				helpers.assert_eq(late.cancel_calls, 2,
					"a terminal task must be retired without a meaningless third cancellation")
				warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"one terminally settled predecessor must restore the exact intention once")
				helpers.assert_true(warmup_requests[2].task ~= late.task,
					"the restored warmup must own a distinct successor task")
				late.deliver(200, [[{"choices":[{"text":"duplicate"}]}]])
				helpers.assert_eq(env.api.is_ready(), false,
					"a duplicate predecessor callback may not consume or publish the successor")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
					"a duplicate predecessor callback may not dispatch a sibling")

				env.state.http_cancel_mode = "success"
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.resume_warmup())
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
					"duplicate resume must not replay a consumed intention")
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	helpers.it("joins discovery through the public warmup pause owner", function()
		with_real_mlx_stack(function(env)
			helpers.assert_true(env.api.warmup("fixture-model", nil))
			helpers.assert_eq(#env.state.timers, 1,
				"warmup must enter the real discovery timer path")
			env.state.timers[1].fire()
			helpers.assert_eq(#env.state.tasks, 1,
				"the discovery continuation must dispatch one real ShellRunner task")
			local stale_task = env.state.tasks[1]
			env.state.task_terminate_mode = "false"

			helpers.assert_eq(env.api.pause_warmup(), false,
				"api_mlx must propagate discovery task refusal to the pause registry")
			helpers.assert_eq(env.api.resume_warmup(), false)
			env.state.task_terminate_mode = "success"
			helpers.assert_eq(env.api.resume_warmup(), false,
				"accepted SIGTERM is not exact settlement before task completion")
			stale_task.complete(0, [[{"data":[]}]], "")
			helpers.assert_eq(#env.state.http_requests, 0,
				"the late discovery completion must stay fenced by api_mlx pause")

			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(#env.state.timers, 2,
				"the active pre-pause discovery intention must restart exactly once")
			helpers.assert_eq(#env.state.tasks, 1,
				"the successor remains deferred until its new timer fires")
			helpers.assert_true(env.api.stop_warmup())
		end)
	end)

	helpers.it("never resurrects an inactive or explicitly stopped warmup", function()
		with_real_mlx_stack(function(env)
			local original_is_discovered = env.discovery.is_discovered
			env.discovery.is_discovered = function() return true end

			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(#env.state.http_requests, 0,
				"an inactive pre-pause owner must not invent a warmup request")

			helpers.assert_true(env.api.stop_warmup())
			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(env.api.warmup("disabled-model", nil), false,
				"pause/resume must preserve an explicit pre-pause stop")
			helpers.assert_eq(#env.state.http_requests, 0,
				"a stopped LLM backend must remain free of warmup POSTs")
			env.discovery.is_discovered = original_is_discovered
		end)
	end)

	helpers.it("stages active restart behind the real ScriptControl RESUMED commit", function()
		with_real_mlx_stack(function(env)
			local original_is_discovered = env.discovery.is_discovered
			env.discovery.is_discovered = function() return true end
			helpers.assert_true(env.api.warmup("fixture-model", nil))
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
				"positive control must own a real warmup POST before pause")

			install_script_control_dependencies()
			package.loaded["modules.shortcuts.script_control"] = nil
			local script_control = require("modules.shortcuts.script_control")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false,
				"real ScriptControl must publish RESUMED before MLX activation")
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
				"resume owner may not dispatch native MLX work inside resume_all")

			local staged = env.state.timers[#env.state.timers]
			helpers.assert_eq(staged.delay, 0,
				"active MLX intent must own one exact next-tick stage")
			local timer_count = #env.state.timers
			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(#env.state.timers, timer_count,
				"duplicate resume must not arm a sibling stage")
			staged.fire()
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
				"epoch-matched post-commit stage must restart exactly once")
			helpers.assert_true(env.api.stop_warmup())
			env.discovery.is_discovered = original_is_discovered
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins the staged timer when a later ScriptControl owner returns " .. mode, function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))
				local failures_left = 1
				install_script_control_dependencies({
					warmup_controller_resume = function()
						if failures_left == 0 then return true end
						failures_left = failures_left - 1
						return native_result(mode, "later resume owner exploded", true)
					end,
				})
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				env.state.timer_stop_mode = mode
				helpers.assert_eq(script_control.resume_all(), false,
					"later owner refusal must roll the staged MLX resume back")
				helpers.assert_true(script_control.is_paused())
				local stale_stage = env.state.timers[#env.state.timers]
				stale_stage.fire(true)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"late staged callback must stay inert after logical rollback")

				env.state.timer_stop_mode = "success"
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= stale_stage,
					"retry must replace the exact settled stage, not reuse its callback")
				retry_stage.fire()
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
					"retry may restore the active intention exactly once")
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("reoffers the committed warmup after " .. mode .. " timeout acquisition", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				install_script_control_dependencies()
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false,
					"positive control must commit the real global resume")
				local committed_stage = env.state.timers[#env.state.timers]

				env.state.next_timer_start_mode = mode
				committed_stage.fire()
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"refused warmup timeout acquisition must not dispatch a POST")
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= committed_stage,
					"post-commit refusal must retain intent through one successor stage")
				helpers.assert_eq(retry_stage.delay, 2,
					"retry must use the bounded warmup backoff, never synchronous recursion")

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"settled retry must dispatch the retained warmup exactly once")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				local timer_count = #env.state.timers
				helpers.assert_true(env.api.resume_warmup())
				helpers.assert_eq(#env.state.timers, timer_count,
					"consumed retry intent must not arm a duplicate stage")
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("recovers mutated timeout debt without a controller timer after " .. mode .. " rollback", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				package.loaded["modules.llm.warmup_controller"] = nil
				local real_controller = require("modules.llm.warmup_controller")
				helpers.assert_true(real_controller.init({
					core_llm = {
						is_backend_ready = env.api.is_ready,
						is_backend_load_failed = env.api.is_load_failed,
						get_current_model = function() return "fixture-model" end,
						get_backend = function() return "mlx" end,
						get_active_profile = function() return nil end,
						warmup_model = env.api.warmup,
					},
					get_llm_enabled = function() return true end,
				}))
				install_script_control_dependencies({
					warmup_controller = real_controller,
				})
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				local committed_stage = env.state.timers[timer_count + 1]
				helpers.assert_eq(committed_stage.delay, 0)
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"real WarmupController pending=false must not invent a retry timer")

				env.state.next_timer_start_mode = "mutate_" .. mode
				env.state.next_timer_stop_mode = mode
				committed_stage.fire()
				local timeout_debt = env.state.timers[#env.state.timers]
				helpers.assert_true(timeout_debt ~= committed_stage,
					"mutating start refusal must retain the exact hard-timeout candidate")
				helpers.assert_true(timeout_debt.native:running(),
					"positive control must prove native activation preceded the refusal")
				helpers.assert_true(timeout_debt.stop_calls >= 2,
					"acquisition rollback and MLX quiesce must both retry the same owner")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"no POST successor may overlap retained timeout debt")
				helpers.assert_eq(#env.state.timers, timer_count + 2,
					"cleanup debt must suppress every native retry instead of adding a sibling")

				timeout_debt.stop_mode = "success"
				timeout_debt.fire(true)
				helpers.assert_eq(timeout_debt.native:running(), false,
					"late native delivery must first prove exact predecessor settlement")
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= timeout_debt,
					"settlement observer must own the retry without an external controller")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"settlement notification alone may not dispatch native HTTP work")

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"one MLX-owned retry must re-offer the retained intent exactly once")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("recovers an internal HttpClient timeout debt after " .. mode .. " rollback", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				local real_controller = init_idle_real_warmup_controller(env)
				install_script_control_dependencies({ warmup_controller = real_controller })
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				local committed_stage = env.state.timers[timer_count + 1]
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"idle real controller must leave MLX as the only restart owner")

				-- The API hard timeout commits; only HttpClient's own timeout
				-- activates and then refuses, including its exact rollback.
				env.state.timer_start_modes = { "success", "mutate_" .. mode }
				env.state.timer_stop_modes = { "success", mode }
				committed_stage.fire()
				local api_timeout = env.state.timers[#env.state.timers - 1]
				local http_timeout_debt = env.state.timers[#env.state.timers]
				helpers.assert_eq(api_timeout.native:running(), false,
					"API timeout must settle so only the private HttpClient debt remains")
				helpers.assert_true(http_timeout_debt.native:running(),
					"positive control must retain HttpClient's activated native timeout")
				helpers.assert_true(http_timeout_debt.stop_calls >= 2,
					"HttpClient and MLX quiesce must retry the same private capability")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"private timeout debt must block HTTP dispatch and every sibling retry")
				helpers.assert_eq(#env.state.timers, timer_count + 3)

				http_timeout_debt.stop_mode = "success"
				http_timeout_debt.fire(true)
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= http_timeout_debt,
					"HttpClient settlement must trigger the retained MLX snapshot itself")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"private HttpClient settlement may produce exactly one warmup successor")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("recovers an internal Discovery timer debt after " .. mode .. " rollback", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				local real_controller = init_idle_real_warmup_controller(env)
				install_script_control_dependencies({ warmup_controller = real_controller })
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				local committed_stage = env.state.timers[timer_count + 1]

				-- Re-enter the real discovery path. Its initial poll timer is the
				-- only owner allowed to remain after activation cleanup refuses.
				env.discovery.is_discovered = original_is_discovered
				env.state.timer_start_modes = { "mutate_" .. mode }
				env.state.timer_stop_modes = { mode }
				committed_stage.fire()
				local discovery_debt = env.state.timers[#env.state.timers]
				helpers.assert_true(discovery_debt.native:running(),
					"positive control must retain Discovery's native poll timer")
				helpers.assert_true(discovery_debt.stop_calls >= 3,
					"dispatch, quiesce, and composite observer must retry one exact poll")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)
				helpers.assert_eq(#env.state.tasks, 0,
					"no curl successor may overlap the retained discovery timer")
				helpers.assert_eq(#env.state.timers, timer_count + 2)

				env.discovery.is_discovered = function() return true end
				discovery_debt.stop_mode = "success"
				discovery_debt.fire(true)
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= discovery_debt,
					"Discovery composite settlement must re-offer the MLX snapshot")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"settled discovery may produce exactly one warmup successor")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retries one clean post-commit stage acquisition after " .. mode, function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				local real_controller = init_idle_real_warmup_controller(env)
				install_script_control_dependencies({ warmup_controller = real_controller })
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				local committed_stage = env.state.timers[timer_count + 1]

				-- Warmup acquisition fails cleanly, then the first delayed stage
				-- acquisition fails cleanly too. One bounded acquisition retry owns
				-- the only future continuation; no external controller timer exists.
				env.state.timer_start_modes = { mode, mode, "success" }
				committed_stage.fire()
				local refused_stage = env.state.timers[#env.state.timers - 1]
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_eq(refused_stage.delay, 2,
					"positive control must hit the delayed-stage acquisition refusal")
				helpers.assert_eq(refused_stage.native:running(), false,
					"the refused stage must be clean, not settlement debt")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_true(retry_stage.native:running(),
					"one bounded MLX-owned acquisition retry must remain live")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"clean acquisition retry may restore the snapshot exactly once")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end
end)

helpers.describe("HS-012 MLX endpoint reset joins predecessor owners", function()
	helpers.it("discards an old staged snapshot before a model switch", function()
		with_real_mlx_stack(function(env)
			local original_is_discovered = env.discovery.is_discovered
			env.discovery.is_discovered = function() return true end
			helpers.assert_true(env.api.warmup("old-model", nil))
			env.state.script_paused = true
			env.state.pause_epoch = 1
			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			local old_stage = env.state.timers[#env.state.timers]
			env.state.script_paused = false

			helpers.assert_true(env.api.reset_endpoints())
			old_stage.fire(true)
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
				"reset must fence the pre-switch staged callback")
			helpers.assert_true(env.api.warmup("new-model", nil),
				"committed global resume must admit the successor identity")

			env.state.script_paused = true
			env.state.pause_epoch = 2
			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			local new_stage = env.state.timers[#env.state.timers]
			env.state.script_paused = false
			new_stage.fire()
			local requests = requests_matching(env.state, "/v1/completions")
			helpers.assert_eq(#requests, 3)
			helpers.assert_true(requests[3].body:find("new-model", 1, true) ~= nil,
				"the next pause may replay only the successor model snapshot")
			helpers.assert_true(requests[3].body:find("old-model", 1, true) == nil)
			helpers.assert_true(env.api.stop_warmup())
			env.discovery.is_discovered = original_is_discovered
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps the old port authoritative after " .. mode .. " reset refusal", function()
			with_real_mlx_stack(function(env)
				local old_port = env.api.get_port()
				local old_url = env.api.get_base_url()
				local original_reset = env.api.reset_endpoints
				env.api.reset_endpoints = function()
					return native_result(mode, "synthetic endpoint reset failure", true)
				end
				helpers.assert_eq(env.api.set_port(old_port + 1), false)
				helpers.assert_eq(env.api.get_port(), old_port,
					"set_port must not publish a successor address over reset debt")
				helpers.assert_eq(env.api.get_base_url(), old_url)
				env.api.reset_endpoints = original_reset
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact PGID guard after " .. mode .. " timer cancellation", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.api.reset_endpoints())
				local predecessor = env.state.timers[#env.state.timers]
				local timer_count = #env.state.timers
				env.state.timer_stop_mode = mode
				helpers.assert_eq(env.api.reset_endpoints(), false)
				helpers.assert_eq(#env.state.timers, timer_count,
					"a refused PGID cancel must block its replacement")
				predecessor.fire(true)
				env.state.timer_stop_mode = "success"
				helpers.assert_true(env.api.reset_endpoints())
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"one successor PGID guard may arm after exact retry")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates discovery reset " .. mode .. " and blocks the PGID successor", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				local predecessor = env.state.timers[1]
				env.state.timer_stop_mode = mode
				helpers.assert_eq(env.api.reset_endpoints(), false)
				helpers.assert_eq(#env.state.timers, 1,
					"discovery debt must block the new PGID timeout")
				predecessor.fire(true)
				env.state.timer_stop_mode = "success"
				helpers.assert_true(env.api.reset_endpoints())
				helpers.assert_eq(#env.state.timers, 2)
				helpers.assert_eq(#env.state.tasks, 0,
					"late predecessor poll must remain inert after reset generation change")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("refuses PGID successor publication after " .. mode .. " warmup cancellation", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("old-model", nil))
				local old_request = requests_matching(env.state, "/v1/completions")[1]
				local timer_count = #env.state.timers
				env.state.http_cancel_mode = mode

				helpers.assert_eq(env.api.reset_endpoints(), false)
				helpers.assert_eq(#env.state.timers, timer_count,
					"reset refusal must not arm the new PGID timeout over old HTTP debt")
				old_request.deliver(200, [[{"choices":[{"text":"late"}]}]])
				helpers.assert_eq(env.api.is_ready(), false,
					"late predecessor POST must remain generation-fenced")

				env.state.http_cancel_mode = "success"
				helpers.assert_true(env.api.reset_endpoints())
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"one PGID guard may arm only after every predecessor joined")
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end
end)

helpers.describe("HS-012 real MLX discovery timer ownership", function()
	helpers.it("does not re-enter callbacks synchronously when paused or quiesced", function()
		with_real_mlx_stack(function(env)
			local callbacks = 0
			env.state.script_paused = true
			helpers.assert_eq(env.discovery.discover(function() callbacks = callbacks + 1 end), false)
			helpers.assert_eq(callbacks, 0,
				"paused refusal must not re-enter the rejected warmup callback")
			env.state.script_paused = false
			helpers.assert_true(env.discovery.stop())
			helpers.assert_eq(env.discovery.discover(function() callbacks = callbacks + 1 end), false)
			helpers.assert_eq(callbacks, 0,
				"quiesced refusal must not re-enter the rejected warmup callback")
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and retries a poll timer after " .. mode .. " cancellation", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				helpers.assert_eq(#env.state.timers, 1,
					"positive control must arm the real discovery timer")
				local stale_timer = env.state.timers[1]
				env.state.timer_stop_mode = mode

				helpers.assert_eq(env.discovery.stop(), false)
				stale_timer.fire(true)
				helpers.assert_eq(#env.state.tasks, 0,
					"a logically revoked timer may never dispatch its curl successor")
				helpers.assert_eq(env.discovery.resume(), false,
					"the exact timer debt must survive until native stop settles")

				env.state.timer_stop_mode = "success"
				helpers.assert_true(env.discovery.resume())
				stale_timer.fire(true)
				helpers.assert_eq(#env.state.tasks, 0,
					"a late native delivery stays inert after cleanup retry")
				helpers.assert_true(env.discovery.discover(function() end))
				helpers.assert_eq(#env.state.timers, 2,
					"one successor may arm only after the predecessor settled")
				helpers.assert_true(env.discovery.stop())
			end)
		end)
	end
end)

helpers.describe("HS-192 MLX discovery callback withdrawal", function()
	helpers.it("fans out every waiter queued behind one real probe", function()
		with_real_mlx_stack(function(env)
			local first_calls = 0
			local second_calls = 0
			helpers.assert_true(env.discovery.discover(function() first_calls = first_calls + 1 end))
			helpers.assert_true(env.discovery.discover(function() second_calls = second_calls + 1 end))

			env.state.timers[1].fire()
			env.state.tasks[1].complete(0, [[{"data":[]}]], "")
			local completion_probe = requests_matching(env.state, "/v1/completions")[1]
			helpers.assert_not_nil(completion_probe)
			completion_probe.deliver(200, [[{"choices":[]}]])

			helpers.assert_eq(first_calls, 1)
			helpers.assert_eq(second_calls, 1)
		end)
	end)

	helpers.it("withdraws identity-matched waiters after concurrent index shifts", function()
		with_real_mlx_stack(function(env)
			helpers.assert_true(env.discovery.discover())
			local stale_timer = env.state.timers[1]
			stale_timer.stop_mode = "false"
			helpers.assert_eq(env.discovery.reset(), false,
				"positive control must retain one stale poll timer")

			local original_stop = stale_timer.native.stop
			stale_timer.native.stop = function()
				coroutine.yield("cancel_pending")
				return false
			end
			local a_calls = 0
			local b_calls = 0
			local waiter_a = coroutine.create(function()
				return env.discovery.discover(function() a_calls = a_calls + 1 end)
			end)
			local waiter_b = coroutine.create(function()
				return env.discovery.discover(function() b_calls = b_calls + 1 end)
			end)

			local ok_a, state_a = coroutine.resume(waiter_a)
			local ok_b, state_b = coroutine.resume(waiter_b)
			helpers.assert_eq(ok_a, true)
			helpers.assert_eq(ok_b, true)
			helpers.assert_eq(state_a, "cancel_pending")
			helpers.assert_eq(state_b, "cancel_pending")
			local done_a, accepted_a = coroutine.resume(waiter_a)
			local done_b, accepted_b = coroutine.resume(waiter_b)
			helpers.assert_eq(done_a, true)
			helpers.assert_eq(done_b, true)
			helpers.assert_eq(accepted_a, false)
			helpers.assert_eq(accepted_b, false)

			stale_timer.stop_mode = "success"
			stale_timer.native.stop = original_stop
			helpers.assert_true(env.discovery.discover(),
				"one fresh cycle must start after the retained timer settles")
			env.state.timers[#env.state.timers].fire()
			env.state.tasks[#env.state.tasks].complete(0, [[{"data":[]}]], "")
			local completion_probe = requests_matching(env.state, "/v1/completions")[1]
			helpers.assert_not_nil(completion_probe,
				"positive control must reach the real completion-route probe")
			completion_probe.deliver(200, [[{"choices":[]}]])

			helpers.assert_eq(a_calls, 0)
			helpers.assert_eq(b_calls, 0,
				"a refused waiter shifted to another index must not fire from a future cycle")
		end)
	end)
end)

helpers.describe("HS-012 real MLX discovery task and POST ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins the poll task across " .. mode .. " termination and late completion", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				env.state.timers[1].fire()
				helpers.assert_eq(#env.state.tasks, 1,
					"positive control must dispatch the real ShellRunner poll task")
				local stale_task = env.state.tasks[1]
				env.state.task_terminate_mode = mode

				helpers.assert_eq(env.discovery.stop(), false)
				helpers.assert_eq(env.discovery.resume(), false)
				env.state.task_terminate_mode = "success"
				helpers.assert_eq(env.discovery.resume(), false,
					"SIGTERM acceptance remains pending until the exact completion callback")
				stale_task.complete(0, [[{"data":[]}]], "")
				helpers.assert_true(env.discovery.resume())
				helpers.assert_eq(#env.state.http_requests, 0,
					"a task completion from the revoked generation must not start POST probes")
			end)
		end)

		helpers.it("retains the discovery POST after " .. mode .. " cancellation", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				env.state.timers[1].fire()
				env.state.tasks[1].complete(0, [[{"data":[]}]], "")
				local probes = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#probes, 1,
					"positive control must dispatch the real discovery HttpClient POST")
				local stale_probe = probes[1]
				env.state.http_cancel_mode = mode

				helpers.assert_eq(env.discovery.stop(), false)
				helpers.assert_eq(stale_probe.cancel_calls, 1,
					"stop must attempt the exact discovery POST once")
				helpers.assert_eq(env.discovery.resume(), false,
					"resume must retain the same discovery POST while its task is still live")
				helpers.assert_eq(stale_probe.cancel_calls, 2,
					"cleanup retry must target the same discovery task, never a sibling")

				stale_probe.deliver(200, [[{"choices":[]}]])
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"a late POST callback must not dispatch another candidate route")
				helpers.assert_eq(env.discovery.is_discovered(), false,
					"a revoked probe callback must not publish route readiness")
				helpers.assert_true(env.discovery.resume(),
					"the exact task terminal must settle discovery despite the old cancel refusal")
				helpers.assert_eq(stale_probe.cancel_calls, 2,
					"a terminal discovery task must not be cancelled again")
				stale_probe.deliver(200, [[{"choices":[]}]])
				helpers.assert_true(env.discovery.resume(),
					"duplicate terminal delivery and resume must remain idempotent")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"settling cleanup debt alone must never create a successor POST")
				env.state.http_cancel_mode = "success"
			end)
		end)
	end
end)

return true
