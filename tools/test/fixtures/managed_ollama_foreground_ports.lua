--- tools/test/fixtures/managed_ollama_foreground_ports.lua
--- Share explicit controlled ports for the canonical API/manager receiving fixtures.
--- Actual task, HTTP and SDK qualification remains outside this Lua model.
local M = {}
M.NONCE = "0123456789abcdef0123456789abcdef"
M.BINARY, M.LOG, M.PORT = "/private/owned/ollama", "/private/logs/today.log", 45678
M.LAUNCH = "exec /native/python -I /source/serve.py"

function M.new(root, production, options)
	package.path = production .. "/static/ergopti_plus/macos/?.lua;"
		.. production .. "/static/ergopti_plus/_shared/lua/?.lua;"
		.. production .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	local path = root .. "/static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_ollama.lua"
	local file = assert(io.open(path, "rb")); local source = assert(file:read("*a")); assert(file:close())
	local body = assert(source:match("\t\tstart_restart = function%(%)\n(.-)\n\t\tend\n\n\t\tstart_probe"),
		"The canonical manager must delegate restart through its owned foreground callback")
	local text_utils = assert(loadfile(production .. "/static/ergopti_plus/macos/infra/text_utils.lua"))()
	local BINARY, LOG, PORT, LAUNCH = M.BINARY, M.LOG, M.PORT, M.LAUNCH
	local state = { calls = {}, tasks = {}, errors = {}, retries = 0, pull_calls = 0,
		operation = {}, live = true, notices = {} }
	local modules, cache = {}, {}
	local logger = { today_log_path = function() return LOG end,
		error = function(_, _, ...) state.errors[#state.errors + 1] = table.pack(...) end }
	for _, name in ipairs({ "debug", "warn", "info", "success" }) do logger[name] = function() end end
	modules["infra.logger"] = logger
	modules["infra.text_utils"] = text_utils
	modules["infra.notifications"] = { notify = function() return true end }
	modules["infra.i18n"] = { get = function(key) return key end }
	modules["modules.llm.parser"], modules["modules.llm.profiles"] = {}, {}
	modules["modules.llm.progressive_reveal"], modules["llm.local_model_policy"] = {}, {}
	modules["modules.llm.api_common"] = { DEFAULT_DEDUPLICATION_ENABLED = true,
		get_retry_policy = function() return 1, 0, 0 end }
	modules["adapters.json_codec"] = { encode = function() return "{}" end, decode = function() return {} end }
	modules["adapters.http_client"] = { new = function()
		return { cancel = function() return true end, isActive = function() return false end,
			isSettled = function() return true end, onSettled = function(callback) callback(); return true end }
	end }
	modules["adapters.timer_scheduler"] = { after = function() error("No restart delay or detached timer is admitted") end }
	modules["modules.llm.ollama_endpoint"] = {
		read_port_override = function() return PORT end, get_default_port = function() return PORT end,
	}
	modules["modules.llm.ollama_binary"] = { resolve = function()
		if options.absent then return nil, "absent-binary" end
		return BINARY, nil, options.foreign and "path" or "native_managed"
	end }
	modules["modules.llm.ollama_server_command"] = { build = function(binary, log, port, kind, nonce)
		state.calls[#state.calls + 1] = { binary, log, port, kind, nonce }
		if options.refused then return nil, "guarded-unavailable" end
		return LAUNCH
	end }
	modules["adapters.managed_ollama_pull"] = { handles = function()
		state.pull_calls = state.pull_calls + 1; return options.pull_supported
	end }
	modules["platform.remap.lease_helper"], modules.json = {}, {}
	modules["adapters.shell_runner"] = { spawn = function(executable, arguments, done, streaming, environment, private, owned)
		local task = { executable = executable, arguments = arguments, streaming = streaming,
			environment = environment, private = private, owned = owned, attempted = false,
			settled = false, observers = {}, terminate_calls = 0 }
		function task.start()
			task.attempted = true
			if options.start then return options.start(task) end
			return true
		end
		function task.wasStartAttempted() return task.attempted end
		function task.isSettled() return task.settled end
		function task.terminate()
			task.terminate_calls = task.terminate_calls + 1
			if options.terminate then return options.terminate(task) end
			return true, "pending"
		end
		function task.onSettled(callback) task.observers[#task.observers + 1] = callback; return true end
		function task.emit(value) return streaming(task, value, "") end
		function task.complete(...)
			local status, stdout, stderr = ...
			if select("#", ...) == 0 then status, stdout, stderr = 0, "", "" end
			task.settled = true
			done(status, stdout, stderr)
			for _, callback in ipairs(task.observers) do callback() end
		end
		state.tasks[#state.tasks + 1] = task
		return task
	end }
	local environment = setmetatable({
		hs = { host = { uuid = function() return "01234567-89ab-cdef-0123-456789abcdef" end } },
		package = { loaded = {} },
	}, { __index = _G })
	local owned_paths = {
		["modules.llm.api_ollama"] = "macos/modules/llm/api_ollama.lua",
		["adapters.managed_ollama_daemon"] = "macos/adapters/managed_ollama_daemon.lua",
		["adapters.owned_program_runner"] = "macos/adapters/owned_program_runner.lua",
		["core.llm.ollama_runtime_choice"] = "_shared/lua/core/llm/ollama_runtime_choice.lua",
		["core.llm.managed_ollama_daemon_receipt"] = "_shared/lua/core/llm/managed_ollama_daemon_receipt.lua",
		["core.llm.managed_ollama_daemon_lifecycle"] = "_shared/lua/core/llm/managed_ollama_daemon_lifecycle.lua",
	}
	function environment.require(name)
		if modules[name] then return modules[name] end
		if cache[name] then return cache[name] end
		local relative = assert(owned_paths[name], "Unexpected restart receiving dependency: " .. name)
		local value = assert(loadfile(root .. "/static/ergopti_plus/" .. relative, "t", environment))()
		cache[name] = value
		return value
	end
	state.api = environment.require("modules.llm.api_ollama")
	local manager_environment = setmetatable({
		require = environment.require, operation = state.operation,
		owns_operation = function() return state.live end,
		retain_current_waiters = function() return true end,
		observe_command_settlement = function(handle) state.observed = handle; return true end,
		schedule_retry = function() state.retries = state.retries + 1; return true end,
		notify_start_failure = function(key) state.notices[#state.notices + 1] = key; return true end,
		settle_operation = function(value, reason)
			state.live = false; state.result, state.reason = value, reason; return true
		end,
	}, { __index = _G })
	state.restart = assert(load("return function()\n" .. body .. "\nend", path .. "#foreground-restart", "t", manager_environment))()
	return state
end

return M
