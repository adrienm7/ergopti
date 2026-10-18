--- tests/support/modules/llm/backends/ai_runtime_selection_install_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_ai_runtime_selection_install
--- DESCRIPTION:
--- Prelude shared by the test_ai_runtime_selection_install_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/Users/fixture"
local PATH_DIR = "/fixture/path/bin"
local MANAGED_DIR = HOME .. "/Library/Application Support/Ergopti/ollama"
local MANAGED_BIN = MANAGED_DIR .. "/ollama"
local NATIVE_DIR = HOME .. "/Library/Application Support/Ergopti/ollama-native-http"
local NATIVE_BIN = NATIVE_DIR .. "/ollama"
local MLX_VENV = HOME .. "/Library/Application Support/Ergopti/mlx-venv"

local CANDIDATES = {
	{ path = "/Applications/Ollama.app/Contents/Resources/ollama", source = "app" },
	{ path = HOME .. "/Applications/Ollama.app/Contents/Resources/ollama", source = "user_app" },
	{ path = "/opt/homebrew/bin/ollama", source = "homebrew" },
	{ path = "/usr/local/bin/ollama", source = "homebrew" },
	{ path = MANAGED_BIN, source = "managed" },
	{ path = PATH_DIR .. "/ollama", source = "path" },
}

local function set_upvalue(fn, wanted, replacement)
	for index = 1, 200 do
		local name = debug.getupvalue(fn, index)
		if not name then break end
		if name == wanted then
			debug.setupvalue(fn, index, replacement)
			return true
		end
	end
	return false
end

--- Runs a callback with a fixed HOME, PATH and launcher environment.
local function with_environment(env, callback)
	local original = os.getenv
	os.getenv = function(name)
		if env[name] ~= nil then
			if env[name] == false then return nil end
			return env[name]
		end
		return original(name)
	end
	local ok, err = xpcall(callback, debug.traceback)
	os.getenv = original
	if not ok then error(err, 0) end
end

local DEFAULT_ENV = {
	HOME = HOME,
	PATH = PATH_DIR,
	ERGOPTI_CONFIG_DIR = "/Applications/ErgoptiPlus.app/Contents/Resources/static",
	ERGOPTI_OLLAMA_BIN = false,
}

--- Fake filesystem: executables answer the resolver's stat, absent paths
--- answer nothing, a path holding a known file is a folder, and every other
--- mode query (scripts, roots) exists. Nothing is a link, so lstat answers
--- what stat answers, as on a real Mac without links.
local function fake_fs(state)
	local function attributes(path, attribute)
		if state.bundled_files[path] then
			if attribute == "mode" then return "file" end
			return { mode = "file", permissions = "rw-r--r--" }
		end
		for file in pairs(state.files) do
			if file:sub(1, #path + 1) == path .. "/" then
				if attribute == "mode" then return "directory" end
				return { mode = "directory", permissions = "rwxr-xr-x" }
			end
		end
		if state.executables[path] then
			if attribute == "mode" then return "file" end
			return { mode = "file", permissions = "rwxr-xr-x" }
		end
		if state.files[path] then
			if attribute == "mode" then return "file" end
			return { mode = "file", permissions = "rw-r--r--" }
		end
		if state.absent[path] then return nil end
		if attribute == "mode" then return "file" end
		return nil
	end
	return { attributes = attributes, symlinkAttributes = attributes }
end

local function new_state()
	return {
		executables = {},
		files = {},
		bundled_files = { [helpers.driver_root() .. "modules/llm/network-retry.sh"] = true },
		absent = {
			[MLX_VENV .. "/bin/python"] = true,
			[MLX_VENV .. "/.last_sync_hash"] = true,
		},
		tasks = {},
	}
end

local function task_api(state)
	return {
		new = function(_, callback, stream, args)
			local task = { args = args, done = callback, stream = stream }
			function task:setStreamingCallback(callback) self.stream = callback; return true end
			function task:start() return self end
			function task:terminate() return self end
			state.tasks[#state.tasks + 1] = task
			return task
		end,
	}
end

local WINDOW_STUB = {
	is_active = function() return false end,
	show = function() end, set_step = function() end, set_detail = function() end,
	set_progress = function() end, set_error = function() end,
	append_log = function() end, hide = function() end,
	session_id = function() return 1 end,
}

--- Keeps the real API's five HTTP and daemon owners over literal transports.
--- The native case models receipt delivery; it does not qualify a native image.
local function load_api(state, daemon)
	daemon = daemon or { calls = 0 }
	state.daemon = daemon
	state.host = { uuid = function() return "00000000-0000-0000-0000-0000000a0062" end }
	state.http_clients = {}
	state.daemon_tasks = {}
	state.model_tasks = {}
	state.model_requirement_pending = false
	local nonce = "000000000000000000000000000a0062"
	state.daemon_frame = function(role)
		return "ERGOPTI_MANAGED_DAEMON_V1 " .. nonce .. " " .. role .. "\n"
	end
	package.loaded["adapters.managed_ollama_hint"] = {
		get = function(directory, driver)
			helpers.assert_eq(directory, NATIVE_DIR)
			helpers.assert_eq(driver, helpers.driver_root():gsub("/+$", ""))
			if state.native_hint ~= true then return nil end
			return { candidate = NATIVE_BIN, budgets = { admission = 1, idle = 1, retirement = 1 } }
		end,
	}
	package.loaded["modules.llm.ollama_binary"] = nil
	helpers.load_with_stubs("modules.llm.ollama_binary", { fs = fake_fs(state) })
	package.loaded["adapters.http_client"] = { new = function()
		local client = { settled = true, cancel_calls = 0 }
		function client.isSettled() return client.settled end
		function client.isActive() return false end
		function client.cancel() client.cancel_calls = client.cancel_calls + 1; return client.settled == true end
		function client.get() error("selection fixture must not acquire an HTTP request") end
		function client.post() error("selection fixture must not acquire an HTTP request") end
		function client.onSettled(observer)
			if client.settled ~= true then return false end
			observer(); return true
		end
		state.http_clients[#state.http_clients + 1] = client
		return client
	end }
	package.loaded["adapters.shell_runner"] = { spawn = function(program, args, done, chunk, environment, private, owned)
		helpers.assert_eq(program, "/bin/sh")
		helpers.assert_eq(private, true)
		helpers.assert_eq(owned, true)
		local task = { settled = false, attempted = false, observers = {}, emitted = "" }
		function task.start() task.attempted = true; return true end
		function task.terminate() return true, task.settled and "settled" or "pending" end
		function task.isSettled() return task.settled end
		function task.wasStartAttempted() return task.attempted end
		function task.onSettled(observer)
			if task.settled then observer() else task.observers[#task.observers + 1] = observer end
			return true
		end
		function task.emit(bytes)
			task.emitted = task.emitted .. bytes
			return chunk(task, bytes, "")
		end
		function task.complete()
			if task.settled then return false end
			task.settled = true
			local status = task.emitted:find(state.daemon_frame("READY"), 1, true) and 0 or 78
			done(status, state.daemon_frame("RETIRED " .. status), "")
			local observers = task.observers; task.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end
		state.daemon_tasks[#state.daemon_tasks + 1] = task
		return task
	end }
	package.loaded["modules.llm.ollama_server_command"] = { build = function(binary, _, _, kind, actual_nonce)
		helpers.assert_eq(binary, NATIVE_BIN)
		helpers.assert_eq(kind, "native_managed")
		helpers.assert_eq(actual_nonce, nonce)
		return "exec /fixture/native-runtime --caller-nonce '" .. nonce .. "' --owned-stdin"
	end }
	package.loaded["adapters.json_codec"] = { encode = function() return "{}" end, decode = function() return {} end }
	package.loaded["modules.llm.parser"] = {}
	package.loaded["modules.llm.profiles"] = {}
	package.loaded["modules.llm.progressive_reveal"] = {}
	package.loaded["modules.llm.prediction_engine"] = { on_ollama_daemon_exit = function() return true end }
	-- This selection fixture has no keyboard inference consumer.
	package.loaded["modules.keylogger"] = {}
	package.loaded["adapters.managed_ollama_daemon"] = nil
	package.loaded["modules.llm.api_ollama"] = nil
	local api = helpers.load_with_stubs("modules.llm.api_ollama", {
		fs = fake_fs(state), host = state.host,
	})
	local ensure_running = api.ensure_running
	api.ensure_running = function(...)
		daemon.calls = daemon.calls + 1
		return ensure_running(...)
	end
	state.model_manager = {
		migration_idle = function()
			return next(state.model_tasks) == nil and state.model_requirement_pending == false
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager_ollama"] = state.model_manager
	state.api = api
	return api
end

--- Loads the real Ollama checker (and resolver) over the fake filesystem.
local function load_ollama_checker(state, daemon)
	package.loaded["ui.download_window"] = WINDOW_STUB
	load_api(state, daemon)
	package.loaded["modules.llm.pty_process_group"] = {
		create = function() return "/tmp/fixture-pty.py" end,
		remove = function() return true end,
	}
	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local checker = helpers.load_with_stubs("modules.llm.ollama_deps_checker", {
		fs = fake_fs(state),
		task = task_api(state),
		host = state.host,
	})
	helpers.assert_true(set_upvalue(checker.check_and_install_deps,
		"resolve_project_root", function() return "/repo" end))
	return checker
end

--- Loads the real MLX checker over the fake filesystem.
local function load_mlx_checker(state)
	-- A fresh checker must consume this fixture's filesystem, not a cached
	-- policy admission bound to the preceding fake native table.
	package.loaded["modules.llm.network_env"] = nil
	package.loaded["adapters.file_system"] = nil
	package.loaded["ui.download_window"] = WINDOW_STUB
	package.loaded["modules.llm.pty_process_group"] = {
		create = function() return "/tmp/fixture-pty.py" end,
		remove = function() return true end,
	}
	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	return helpers.load_with_stubs("modules.llm.mlx_deps_checker", {
		fs = fake_fs(state),
		task = task_api(state),
	})
end

local STUBBED_MODULES = {
	"ui.download_window", "modules.llm.ollama_binary", "modules.llm.api_ollama",
	"modules.llm.pty_process_group", "adapters.task_lifecycle",
	"adapters.timer_scheduler", "modules.llm.ollama_deps_checker",
	"modules.llm.mlx_deps_checker", "infra.dialog_util", "infra.notifications",
	"ui.menu.menu_llm.runtime_install_offer",
	"modules.llm.network_env", "adapters.file_system",
	"adapters.managed_ollama_hint", "adapters.managed_ollama_daemon",
	"adapters.http_client", "adapters.shell_runner", "adapters.json_codec",
	"modules.llm.ollama_server_command", "modules.llm.parser", "modules.llm.profiles",
	"modules.llm.progressive_reveal", "modules.llm.prediction_engine",
	"ui.menu.menu_llm.models_manager_ollama", "modules.llm.api_common",
	"modules.llm.ollama_endpoint", "adapters.storage", "adapters.owned_program_runner",
	"platform.remap.lease_helper", "modules.shortcuts.script_control", "modules.keylogger",
	"core.llm.ollama_runtime_choice", "core.llm.managed_ollama_daemon_lifecycle",
	"core.llm.managed_ollama_daemon_receipt", "llm.local_model_policy",
}

local function scoped(callback)
	return function()
		helpers.with_stub_scope(STUBBED_MODULES, function()
			with_environment(DEFAULT_ENV, callback)
		end)
	end
end

return {
	CANDIDATES = CANDIDATES,
	DEFAULT_ENV = DEFAULT_ENV,
	HOME = HOME,
	MANAGED_BIN = MANAGED_BIN,
	MANAGED_DIR = MANAGED_DIR,
	MLX_VENV = MLX_VENV,
	NATIVE_BIN = NATIVE_BIN,
	NATIVE_DIR = NATIVE_DIR,
	PATH_DIR = PATH_DIR,
	STUBBED_MODULES = STUBBED_MODULES,
	WINDOW_STUB = WINDOW_STUB,
	fake_fs = fake_fs,
	load_api = load_api,
	load_mlx_checker = load_mlx_checker,
	load_ollama_checker = load_ollama_checker,
	new_state = new_state,
	scoped = scoped,
	set_upvalue = set_upvalue,
	task_api = task_api,
	with_environment = with_environment,
}
