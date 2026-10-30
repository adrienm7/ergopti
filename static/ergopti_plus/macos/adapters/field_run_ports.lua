--- adapters/field_run_ports.lua

--- ==============================================================================
--- MODULE: Field Run Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of infra/field_run.lua: files and the folder watcher, the
--- timers and the log ring, the configuration guard, and one runner per step
--- kind over the driver's own owners (the Debug field checks, the diagnostics
--- snapshot, the Ollama and MLX install and download flows).
---
--- FEATURES & RATIONALE:
--- 1. Real paths only. A runner calls the entry the menu calls: the field check
---    engine over adapters/field_check_ports.lua, ui.healthcheck.core, the
---    runtime selection router (runtime_install_offer, the only grantor of a
---    runtime install), and the AI menu's models manager for the downloads.
---    Nothing is replaced by a stand-in.
--- 2. Runtimes stay, models go. An Ollama or MLX runtime installs where the
---    menu installs it and is kept, as a selection would keep it; a model the
---    run downloaded is removed again when it was not there before, and a
---    model that was already there is left in place. The model is the
---    catalogue's smallest one (infra/field_run.lua M.smallest_model). The MLX
---    step also puts back the active-model file the served model overwrote: a
---    step leaves the configuration as it found it, and config_guard only
---    reports what a step failed to put back.
--- 3. Privacy: step codes and reports carry closed tokens, counts and catalogue
---    names; the diagnostics report is the share projection a bug report uses.
--- 4. Configuration guard: config.toml and its sibling files are compared byte
---    for byte, the hs.settings preferences by their JSON encoding. Runtime
---    state a module declares as such (the Karabiner lease's used-token ledger)
---    is neither compared nor put back: rewinding it would undo that module's
---    own invariants. Putting back a file the live preferences were loaded
---    from asks for a reload (outcome.reload) through the termination
---    coordinator, since the byte rewrite does not reach the running state.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Json = require("json")
local FileSystem = require("adapters.file_system")
local ShellRunner = require("adapters.shell_runner")
local Timer = require("adapters.timer_scheduler")
local TextUtils = require("text_utils")

local LOG = "adapters.field_run_ports"

-- The personal files the configuration guard protects, by config_paths key.
local GUARDED_FILES = {
	"ConfigTomlPath", "KarabinerConfigPath", "MlxActiveModelPath", "PersonalTomlPath", "PersonalInfoTomlPath",
}

-- The guarded files the running driver holds in memory once loaded: putting
-- one back under it needs a reload for the live state to read it again.
local LIVE_STATE_FILES = { ConfigTomlPath = true, PersonalTomlPath = true, PersonalInfoTomlPath = true }

-- Seconds between two model listings while the Ollama server comes up, and how many.
local LISTING_RETRY_SECONDS = 2
local LISTING_ATTEMPTS = 20

-- Seconds between two looks at the owned runtime while its metadata hint is
-- pending, and how many: an install changes the files the hint keys on, so
-- resolve() answers nil until the new hint settles.
local RESOLVE_RETRY_SECONDS = 1
local RESOLVE_ATTEMPTS = 30





-- ===========================
-- ===========================
-- ======= 1/ Files ==========
-- ===========================
-- ===========================

--- Creates a folder and its parents.
--- @param path string Absolute folder.
--- @return boolean ready
local function make_dir(path)
	ShellRunner.exec("/bin/mkdir -p " .. TextUtils.shell_quote(path))
	local ok, mode = pcall(hs.fs.attributes, path, "mode")
	return ok and mode == "directory"
end





-- ======================================
-- ======================================
-- ======= 2/ Configuration guard =======
-- ======================================
-- ======================================

--- Lists the preferences modules own as runtime state, which the guard skips.
--- @return table runtime_keys Set of preference keys.
local function runtime_setting_keys()
	local runtime_keys = {}
	for _, key in ipairs(require("platform.remap.lease_controller").RUNTIME_SETTING_KEYS) do
		runtime_keys[key] = true
	end
	return runtime_keys
end

--- Captures the guarded files and preferences.
--- @return table snapshot
local function config_snapshot()
	local ConfigPaths = require("infra.config_paths")
	local Storage = require("adapters.storage")
	local snapshot = { files = {}, settings = {}, runtime_keys = runtime_setting_keys() }
	for _, key in ipairs(GUARDED_FILES) do
		local path = ConfigPaths.get(key)
		if type(path) ~= "string" or path == "" then error("config path " .. key .. " is unresolved", 0) end
		local content, status = FileSystem.read_with_status(path)
		if status ~= "ok" and status ~= "absent" then error("config file " .. key .. " is unreadable", 0) end
		snapshot.files[#snapshot.files + 1] = { key = key, path = path, status = status, content = content }
	end
	for _, key in ipairs(Storage.keys()) do
		if not snapshot.runtime_keys[key] then snapshot.settings[key] = Json.encode(Storage.get(key)) end
	end
	return snapshot
end

--- Puts back every guarded file and preference a step changed.
--- @param snapshot table From config_snapshot().
--- @return table outcome { restored = { names }, failed = { names }, reload = boolean }
local function config_restore(snapshot)
	local Storage = require("adapters.storage")
	local outcome = { restored = {}, failed = {}, reload = false }
	local function note(ok, name)
		local list = ok and outcome.restored or outcome.failed
		list[#list + 1] = name
	end
	for _, file in ipairs(snapshot.files) do
		local content, status = FileSystem.read_with_status(file.path)
		if status ~= file.status or content ~= file.content then
			Logger.warn(LOG, "The field run changed %s; putting it back.", file.key)
			local put_back
			if file.status == "absent" then
				put_back = FileSystem.delete(file.path) == true
			else
				put_back = FileSystem.write(file.path, file.content) == true
			end
			note(put_back, file.key)
			if put_back and LIVE_STATE_FILES[file.key] then outcome.reload = true end
		end
	end
	local current = {}
	for _, key in ipairs(Storage.keys()) do
		if not snapshot.runtime_keys[key] then current[key] = Json.encode(Storage.get(key)) end
	end
	for key, encoded in pairs(snapshot.settings) do
		if current[key] ~= encoded then
			Logger.warn(LOG, "The field run changed the preference %s; putting it back.", key)
			note(Storage.set(key, Json.decode(encoded)) == true, "setting_" .. key)
		end
	end
	for key in pairs(current) do
		if snapshot.settings[key] == nil then
			Logger.warn(LOG, "The field run added the preference %s; removing it.", key)
			note(Storage.delete(key) == true, "setting_" .. key)
		end
	end
	table.sort(outcome.restored)
	table.sort(outcome.failed)
	return outcome
end





-- =================================
-- =================================
-- ======= 3/ Checks runners =======
-- =================================
-- =================================

--- Runs one Debug field check over the real ports.
local function run_field_check(step, finish)
	local Engine = require("infra.field_check")
	local started = Engine.run(step.check, require("adapters.field_check_ports").new(), function(result)
		local codes = {}
		for _, item in ipairs(result.steps) do
			if item.state == Engine.STATE_FAIL then codes[#codes + 1] = "fail_" .. item.id end
		end
		finish(result.passed and "pass" or "fail", codes, result)
	end)
	if not started then finish("fail", { Engine.is_running() and "check_busy" or "check_refused" }) end
end

--- Collects the diagnostics snapshot as the Debug menu's bug report does, and
--- keeps its share projection.
local function run_diagnostics(finish)
	local Core = require("ui.healthcheck.core")
	local schema = Core.config().schema
	local snapshot = Core.run({ complete_local = true })
	local issues = type(snapshot.sections) == "table" and snapshot.sections.issues or {}
	local safe = require("healthcheck.share").snapshot(snapshot, schema)
	finish("pass", { "warnings_" .. tostring(issues.warn_count or 0), "errors_" .. tostring(issues.err_count or 0) },
		safe)
end





-- =============================
-- =============================
-- ======= 4/ AI runners =======
-- =============================
-- =============================

--- The catalogue's smallest model for a backend, an installed one first.
--- @param backend string "ollama" or "mlx".
--- @param installed function|nil fn(model) -> boolean.
--- @return table|nil model
local function smallest_model(backend, installed)
	local path = require("infra.paths").shared_llm_path("models.json")
	local text = path and FileSystem.read(path) or nil
	if type(text) ~= "string" then return nil end
	return require("infra.field_run").smallest_model(Json.decode(text), backend, installed)
end

--- The AI menu's models manager, or nil before the menu exists.
local function models_manager()
	local menu = package.loaded["ui.menu.menu_llm"]
	return type(menu) == "table" and type(menu.active_models_manager) == "function"
		and menu.active_models_manager() or nil
end

--- Whether this Mac can run MLX, as the selection router decides it.
local function mlx_supported()
	local ok, supported = pcall(function() return require("modules.llm.backend_detector").mlx_support() end)
	return ok and supported ~= false
end

--- Calls back with the owned Ollama runtime once its metadata hint settles.
--- The step after an install read the pending hint as an absent runtime and
--- skipped (field run of 2026-10-30 19:17: runtime_installed, then
--- runtime_absent); a hint still pending after the bound reads as absent.
--- @param callback function fn(path|nil, source|nil, pending).
local function settled_ollama_binary(callback)
	local Binary = require("modules.llm.ollama_binary")
	local attempts = 0
	local function look()
		attempts = attempts + 1
		local _, _, state = Binary.native_candidate()
		if state == "pending" and attempts < RESOLVE_ATTEMPTS then
			return Timer.after(RESOLVE_RETRY_SECONDS, look)
		end
		local path, _, source = Binary.resolve()
		callback(path, source, state == "pending")
	end
	look()
end

--- Installs or reuses the Ollama runtime through the selection router, as the
--- install button of the AI menu does. An Ollama of another origin (the app,
--- Homebrew) is reused: the router would offer to replace it with the native
--- runtime in a modal dialog, which is a person's choice.
local function ollama_runtime(finish)
	local Binary = require("modules.llm.ollama_binary")
	local Deps = require("modules.llm.ollama_deps_checker")
	local path, _, source = Binary.resolve()
	local before = Deps.runtime_available()
	local function settle(ok)
		if ok ~= true then return finish("fail", { "install_failed", "state_" .. tostring(Deps.get_state()) }) end
		settled_ollama_binary(function(now_path, now_source, pending)
			if not now_path then
				return finish("fail", { before and "runtime_reused" or "runtime_installed",
					pending and "metadata_pending" or "runtime_unresolved" })
			end
			finish("pass", { before and "runtime_reused" or "runtime_installed" }, { source = tostring(now_source) })
		end)
	end
	local accepted
	if path and require("core.llm.ollama_runtime_choice").classify(source) == "foreign" then
		accepted = Deps.check_and_install_deps(settle)
	else
		accepted = require("ui.menu.menu_llm.runtime_install_offer").install_ollama(settle)
	end
	if accepted ~= true then finish("fail", { "install_refused" }) end
end

--- Asks the Ollama server whether it holds a model, starting it once when it
--- does not answer and waiting for it to come up.
--- @param model string Ollama model name.
--- @param callback function fn(installed|nil, started_server).
local function ollama_listing(model, callback)
	local Api = require("modules.llm.api_ollama")
	local started, attempts = false, 0
	local function ask()
		attempts = attempts + 1
		Api.forget_local_models()
		Api.verify_local_model(model, function(installed)
			if installed ~= nil or attempts >= LISTING_ATTEMPTS then return callback(installed, started) end
			if not started then
				started = true
				Api.ensure_running()
			end
			Timer.after(LISTING_RETRY_SECONDS, ask)
		end)
	end
	ask()
end

--- Pulls the smallest catalogue model through the AI menu's download window
--- and checks the server lists it. The model stays installed: the maintainer's
--- shared connection paid its download once, and the next run's pull only
--- compares the manifest.
local function ollama_model(finish)
	local manager = models_manager()
	if not manager then return finish("skip", { "ai_menu_absent" }) end
	settled_ollama_binary(function(path, _, pending)
		if not path then return finish("skip", { pending and "metadata_pending" or "runtime_absent" }) end
		local model = smallest_model("ollama")
		if not model then return finish("fail", { "no_catalogue_model" }) end
		local report = { model = model.runtime_name, download_gb = model.download_gb }
		ollama_listing(model.runtime_name, function(before, started_server)
			if before == nil then return finish("fail", { "server_unreachable" }, report) end
			report.started_server = started_server
			local codes = { before and "model_preexisting" or "model_absent" }
			manager.pull_ollama_model(model.runtime_name, function()
				ollama_listing(model.runtime_name, function(listed)
					if listed ~= true then
						codes[#codes + 1] = "not_listed_after_pull"
						return finish("fail", codes, report)
					end
					codes[#codes + 1] = "pulled"
					codes[#codes + 1] = "model_kept"
					finish("pass", codes, report)
				end)
			end, function(reason)
				codes[#codes + 1] = "pull_" .. tostring(reason)
				finish("fail", codes, report)
			end)
		end)
	end)
end

--- Bootstraps or reuses the MLX environment through the selection router, as
--- selecting the MLX backend does; a failure opens the router's repair offer.
local function mlx_runtime(finish)
	if not mlx_supported() then return finish("skip", { "mlx_unsupported_here" }) end
	local Deps = require("modules.llm.mlx_deps_checker")
	local before = Deps.runtime_installed()
	local accepted = require("ui.menu.menu_llm.runtime_install_offer").select_mlx(function(ok)
		if ok == true then return finish("pass", { before and "runtime_reused" or "runtime_installed" }) end
		local cause = Deps.get_failure_cause()
		finish("fail", { "bootstrap_failed", "cause_" .. tostring(type(cause) == "table" and cause.kind or "unknown") })
	end)
	if accepted ~= true then finish("fail", { "bootstrap_refused" }) end
end

--- Captures the MLX active-model file the model server writes when it starts
--- and returns the function that puts it back. The download ends by serving
--- the new model, whose launcher records that model there, so a step that left
--- it would hand the user's next MLX server a model the step removes again.
--- @return function restore fn() -> code: "active_model_kept",
---   "active_model_restored" or "active_model_restore_failed".
local function keep_mlx_active_model()
	local path = require("infra.config_paths").get("MlxActiveModelPath")
	if type(path) ~= "string" or path == "" then error("config path MlxActiveModelPath is unresolved", 0) end
	local content, status = FileSystem.read_with_status(path)
	if status ~= "ok" and status ~= "absent" then error("the MLX active-model file is unreadable", 0) end
	return function()
		local now, now_status = FileSystem.read_with_status(path)
		if now_status == status and now == content then return "active_model_kept" end
		local ok
		if status == "absent" then ok = FileSystem.delete(path) == true else ok = FileSystem.write(path, content) == true end
		if not ok then
			Logger.error(LOG, "The MLX model step could not put the active-model file back.")
			return "active_model_restore_failed"
		end
		Logger.info(LOG, "The MLX model step put the active-model file back (%s).",
			status == "absent" and "removed" or "rewritten")
		return "active_model_restored"
	end
end

--- Downloads the smallest catalogue MLX model, stops the server its download
--- starts and puts the active-model file back as it found it. The model stays
--- in the cache: removing it made every run download it again (about 380 MB
--- over the maintainer's shared connection), while a complete cache only costs
--- the next run a metadata check.
local function mlx_model(finish)
	if not mlx_supported() then return finish("skip", { "mlx_unsupported_here" }) end
	local manager = models_manager()
	if not manager then return finish("skip", { "ai_menu_absent" }) end
	if not require("modules.llm.mlx_deps_checker").runtime_installed() then
		return finish("skip", { "runtime_not_ready" })
	end
	local Llm = require("modules.llm")
	-- The download ends by serving the new model: with MLX predicting, that
	-- would replace the user's own model.
	if Llm.get_backend() == "mlx" and Llm.get_runtime_llm_enabled() == true then
		return finish("skip", { "mlx_backend_in_use" })
	end
	local model = smallest_model("mlx", function(candidate) return manager.mlx_model_installed(candidate.name) end)
	if not model then return finish("fail", { "no_catalogue_model" }) end
	local report = { model = model.name, download_gb = model.download_gb }
	local before = manager.mlx_model_installed(model.name)
	local codes = { before and "model_preexisting" or "model_absent" }
	local restore_active_model = keep_mlx_active_model()
	local function settle(passed)
		local restored = restore_active_model()
		codes[#codes + 1] = restored
		finish(passed and restored ~= "active_model_restore_failed" and "pass" or "fail", codes, report)
	end
	manager.pull_mlx_model(model.name, function()
		codes[#codes + 1] = "downloaded_and_served"
		require("ui.menu.menu_llm").stop_mlx_server(function(stopped)
			codes[#codes + 1] = stopped and "server_stopped" or "server_stop_refused"
			codes[#codes + 1] = "model_kept"
			settle(stopped)
		end)
	end, function(reason)
		codes[#codes + 1] = "download_" .. tostring(reason)
		settle(false)
	end)
end

local AI_RUNNERS = {
	ollama_runtime = ollama_runtime,
	ollama_model = ollama_model,
	mlx_runtime = mlx_runtime,
	mlx_model = mlx_model,
}

--- Runs one declared step.
--- @param step table Step declaration.
--- @param finish function fn(verdict, codes, report).
local function run_step(step, finish)
	if step.kind == "field_check" then return run_field_check(step, finish) end
	if step.kind == "diagnostics" then return run_diagnostics(finish) end
	local runner = AI_RUNNERS[step.id]
	if not runner then error("no runner for step " .. tostring(step.id), 0) end
	return runner(finish)
end





-- ==========================
-- ==========================
-- ======= 5/ Factory =======
-- ==========================
-- ==========================

--- Builds the ports of a developer runtime.
--- @param root string Clone root (infra/dev_source.lua).
--- @return table ports
function M.new(root)
	assert(type(root) == "string" and root:sub(1, 1) == "/", "field run ports need the clone root")
	local declaration = root .. require("infra.dev_source").DRIVER_SUBPATH .. "/data/field_run.json"
	return {
		read_declaration = function() return FileSystem.read(declaration) end,
		read = function(path) return FileSystem.read_with_status(path) end,
		write = function(path, text) return FileSystem.write(path, text) == true end,
		remove = FileSystem.delete,
		exists = function(path) return FileSystem.exists(path) == true end,
		make_dir = make_dir,
		watch = function(path, callback) return hs.pathwatcher.new(path, callback) end,
		after = Timer.after,
		cancel = Timer.cancel,
		now_ms = function() return hs.timer.absoluteTime() / 1e6 end,
		-- Every AI flow shows its progress in the one shared download window
		progress_mark = function() return require("ui.download_window").progress_mark() end,
		iso_now = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
		log_ring = Logger.ring_buffer_snapshot,
		config_snapshot = config_snapshot,
		config_restore = config_restore,
		reload_driver = function(reason) return require("infra.termination_coordinator").request_reload(reason) end,
		run_step = run_step,
	}
end

return M
