--- tests/support/modules/llm/mlx/api_mlx_pause_ownership_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_api_mlx_pause_ownership
--- DESCRIPTION:
--- Prelude shared by the test_api_mlx_pause_ownership_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
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
	package.loaded["modules.keystats"] = { resync_context = settled }
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

return {
	MODULE_NAMES = MODULE_NAMES,
	init_idle_real_warmup_controller = init_idle_real_warmup_controller,
	install_script_control_dependencies = install_script_control_dependencies,
	make_http_stub = make_http_stub,
	make_task_stub = make_task_stub,
	make_timer_stub = make_timer_stub,
	native_result = native_result,
	requests_matching = requests_matching,
	restore_modules = restore_modules,
	snapshot_modules = snapshot_modules,
	with_real_mlx_stack = with_real_mlx_stack,
}
