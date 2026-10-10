-- Exercise the actual MLX checker and native hs.task on a cold private home.
local config = assert(hs.json.read(assert(os.getenv("ERGOPTI_COLD_BOOTSTRAP_CONFIG"))))
local driver, shared = config.driver, config.shared
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. shared .. "/?.lua;" .. shared .. "/?/init.lua;"
	.. shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path

local result = { version = 1, runtime = "native Hammerspoon", tasks = 0 }
local owner = {}
_G.ergopti_cold_bootstrap_owner = owner
local function publish()
	assert(hs.json.write(result, config.result, true, true))
end
local function guarded(callback)
	return function(...)
		local ok, error = xpcall(callback, debug.traceback, ...)
		if not ok then result.error = tostring(error); publish() end
	end
end

guarded(function()
	assert(hs.processInfo.arch == "arm64", "Cold MLX acceptance requires native arm64")
	assert(os.getenv("HOME") == config.home)
	assert(hs.fs.attributes(config.venv) == nil, "Cold venv already exists")
	assert(hs.fs.attributes(config.uv_root) == nil, "Cold uv cache already exists")
	-- The inherited kernel sandbox denies stock runtimes. Resolve through the
	-- actual production adapter; no fake Python edge can qualify native receiving.
	local python = require("adapters.python_interpreter")
	for _, path in ipairs(config.denied_runtime_paths) do
		local file = io.open(path, "rb")
		if file then file:close(); error("Cold sandbox allowed a stock runtime read") end
	end
	local selected, state = python.resolve()
	assert(selected == nil and state.kind == "python_missing", "Production resolver is not cold")
	result.native_python_candidates_count = #python.native_candidates()
	assert(result.native_python_candidates_count == 0, "Production resolver found a stock native Python")
	result.absent_python_selected = true
	result.python_state = state.kind
	result.python_resolver = "unmodified production resolver"
	result.denied_runtime_paths = config.denied_runtime_paths
	-- Presentation alone is replaced; tasks, files, hashes, timers, environment,
	-- runtime resolution and process ownership remain genuine production ports.
	local session, visible = 0, false
	package.loaded["ui.download_window"] = {
		show = function() session = session + 1; visible = true; return true end,
		hide = function() visible = false; return true end,
		is_active = function() return visible end,
		session_id = function() return session end,
		append_log = function() end, set_detail = function() end,
		set_step = function() end, set_progress = function() end,
		set_error = function() result.ui_failure = true end,
	}
	local native_pty = require("adapters.native_bootstrap_pty")
	local prepare = native_pty.prepare
	native_pty.prepare = function(...)
		local handle, ready = prepare(...)
		assert(ready == true and handle ~= nil, "Native source admission refused")
		local request = assert(hs.json.decode(handle.input))
		assert(request.source_path == driver .. "/modules/llm/ensure-mlx-deps.sh")
		assert(handle.executable == config.helper and handle.arguments[1] == "--managed-pty-worker")
		result.native_cli = handle.arguments
		result.source_sha256 = request.source_sha256
		result.nonce = request.nonce
		result.receipt_path = request.receipt_path
		local settle = handle.settle
		handle.settle = function(code)
			local file = assert(io.open(request.receipt_path, "rb"))
			local bytes = file:read(4097); file:close()
			result.physical_receipt = assert(hs.json.decode(bytes))
			result.worker_status = code
			local retired = settle(code)
			result.receipt_retired = retired == true
			result.receipt_removed = hs.fs.symlinkAttributes(request.receipt_path) == nil
			return retired
		end
		return handle, ready
	end
	local native_new = hs.task.new
	hs.task.new = function(executable, done, stream, arguments)
		assert(executable == config.helper, "Cold caller selected an unexpected native executable")
		assert(arguments[1] == "--managed-pty-worker", "Cold caller selected a Python PTY")
		result.tasks = result.tasks + 1
		local task = native_new(executable, done, stream, arguments)
		owner.task = task
		return task
	end
	local lifecycle = require("adapters.task_lifecycle")
	local start = lifecycle.start
	lifecycle.start = function(task, label)
		local started = start(task, label)
		if started then result.worker_pid = task:pid() end
		return started
	end
	owner.checker = require("modules.llm.mlx_deps_checker")
	assert(owner.checker.install_for_selection(guarded(function(success)
		result.success = success == true
		result.state = owner.checker.get_state()
		result.runtime_installed = owner.checker.runtime_installed()
		publish()
	end)) == true, "Cold selection refused")
end)()
