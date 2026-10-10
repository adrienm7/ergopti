--- tests/unit/modules/llm/test_ai_runtime_selection_install.lua

--- ==============================================================================
--- MODULE: AI Runtimes Install Only On Backend Selection
--- DESCRIPTION:
--- The app no longer bundles Ollama, and neither AI runtime may be fetched at
--- startup, when the AI is enabled with another backend, or after an update.
--- These cases drive the real resolver, both dependency checkers and the menu's
--- selection router against a fake filesystem and recorded native tasks:
--- 1. The resolver order (Ollama.app, ~/Applications, Homebrew, Ergopti's own
---    Application Support copy, PATH) and the retired ERGOPTI_OLLAMA_BIN.
--- 2. Boot checks and non-selection checks settle "missing" without a task.
--- 3. The first selection installs exactly once; a re-selection reuses it.
--- 4. The Ollama offer: accept downloads into the folder the resolver then
---    finds, decline opens the website and keeps the AI off with a message,
---    and a checksum failure surfaces the localized error.
--- 5. The typing path never reaches runtime detection.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/Users/fixture"
local PATH_DIR = "/fixture/path/bin"
local MANAGED_DIR = HOME .. "/Library/Application Support/Ergopti/ollama"
local MANAGED_BIN = MANAGED_DIR .. "/ollama"
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
		new = function(_, callback, _stream, args)
			local task = { args = args, done = callback }
			function task.setStreamingCallback() return true end
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

--- Loads the real Ollama checker (and resolver) over the fake filesystem.
local function load_ollama_checker(state, daemon)
	package.loaded["ui.download_window"] = WINDOW_STUB
	package.loaded["modules.llm.ollama_binary"] = nil
	package.loaded["modules.llm.api_ollama"] = {
		ensure_running = function()
			if daemon then daemon.calls = daemon.calls + 1 end
			return true
		end,
	}
	package.loaded["modules.llm.pty_process_group"] = {
		create = function() return "/tmp/fixture-pty.py" end,
		remove = function() return true end,
	}
	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local checker = helpers.load_with_stubs("modules.llm.ollama_deps_checker", {
		fs = fake_fs(state),
		task = task_api(state),
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
}

local function scoped(callback)
	return function()
		helpers.with_stub_scope(STUBBED_MODULES, function()
			with_environment(DEFAULT_ENV, callback)
		end)
	end
end





-- =================================
-- =================================
-- ======= 1/ Resolver Order =======
-- =================================
-- =================================

helpers.describe("Ollama resolver order (ai-runtime-resolver)", function()
	for index, expected in ipairs(CANDIDATES) do
		helpers.it("resolves " .. expected.source .. " before every later location ("
			.. index .. ")", scoped(function()
			local state = new_state()
			for later = index, #CANDIDATES do
				state.executables[CANDIDATES[later].path] = true
			end
			local Resolver = helpers.load_with_stubs("modules.llm.ollama_binary",
				{ fs = fake_fs(state) })
			local path, err, source = Resolver.resolve()
			helpers.assert_eq(path, expected.path)
			helpers.assert_nil(err)
			helpers.assert_eq(source, expected.source)
		end))
	end

	helpers.it("reports a clear error when no location holds Ollama", scoped(function()
		local Resolver = helpers.load_with_stubs("modules.llm.ollama_binary",
			{ fs = fake_fs(new_state()) })
		local path, err, source = Resolver.resolve()
		helpers.assert_nil(path)
		helpers.assert_nil(source)
		helpers.assert_true(type(err) == "string" and err:find("no executable Ollama", 1, true) ~= nil)
	end))

	helpers.it("ignores a non-executable file and the retired bundled path", function()
		helpers.with_stub_scope(STUBBED_MODULES, function()
			local bundled = "/Applications/ErgoptiPlus.app/Contents/Resources/Tools/Ollama/ollama"
			local env = {}
			for key, value in pairs(DEFAULT_ENV) do env[key] = value end
			env.ERGOPTI_OLLAMA_BIN = bundled
			with_environment(env, function()
				local state = new_state()
				state.executables[bundled] = true
				state.files["/opt/homebrew/bin/ollama"] = true
				local Resolver = helpers.load_with_stubs("modules.llm.ollama_binary",
					{ fs = fake_fs(state) })
				helpers.assert_nil((Resolver.resolve()),
					"neither a bundled launcher path nor a non-executable file may resolve")
			end)
		end)
	end)

	helpers.it("names the managed folder the installer publishes into", scoped(function()
		local Resolver = helpers.load_with_stubs("modules.llm.ollama_binary",
			{ fs = fake_fs(new_state()) })
		helpers.assert_eq(Resolver.managed_install_dir(), MANAGED_DIR)
		helpers.assert_eq(Resolver.managed_executable_path(), MANAGED_BIN)
	end))
end)





-- ==================================================
-- ==================================================
-- ======= 2/ Ollama: Selection-Only Download =======
-- ==================================================
-- ==================================================

helpers.describe("Ollama downloads only on its selection (ai-runtime-ollama)", function()
	helpers.it("settles a boot check as missing without any task", scoped(function()
		local state = new_state()
		local checker = load_ollama_checker(state)
		helpers.assert_true(checker.schedule_initial_check())
		hs.timer.__fire_all()
		helpers.assert_eq(#state.tasks, 0, "boot must never start the installer")
		helpers.assert_eq(checker.get_state(), "missing")
		helpers.assert_true(checker.is_missing())
	end))

	helpers.it("never installs from a plain check (AI enable, model check, update)", scoped(function()
		local state = new_state()
		local checker = load_ollama_checker(state)
		local result
		helpers.assert_true(checker.check_and_install_deps(function(ok) result = ok end))
		helpers.assert_eq(result, false)
		helpers.assert_eq(#state.tasks, 0)
	end))

	helpers.it("reuses a found Ollama without a download folder", scoped(function()
		local state = new_state()
		state.executables[CANDIDATES[1].path] = true
		local checker = load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(#state.tasks, 1)
		helpers.assert_eq(state.tasks[1].args[5], CANDIDATES[1].path)
		helpers.assert_eq(state.tasks[1].args[6], "",
			"a found executable must reach the script's zero-network fast path")
		state.tasks[1].done(0, "", "")
	end))

	helpers.it("never lets a found Ollama's grant reach a later plain check", scoped(function()
		local state = new_state()
		local brew = "/opt/homebrew/bin/ollama"
		state.executables[brew] = true
		local checker = load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(state.tasks[1].args[6], "")
		state.tasks[1].done(0, "", "")

		-- brew uninstall: a later non-selection check must not download.
		state.executables[brew] = nil
		local result
		helpers.assert_true(checker.check_and_install_deps(function(ok) result = ok end))
		helpers.assert_eq(#state.tasks, 1, "a plain check must never download without the offer")
		helpers.assert_eq(result, false)
		helpers.assert_eq(checker.get_state(), "missing")
	end))

	helpers.it("installs once on the first selection and never on re-selection", scoped(function()
		local state = new_state()
		local daemon = { calls = 0 }
		local checker = load_ollama_checker(state, daemon)
		local results = {}
		helpers.assert_true(checker.install_for_selection(function(ok) results[#results + 1] = ok end))
		helpers.assert_eq(#state.tasks, 1)
		helpers.assert_eq(state.tasks[1].args[5], "")
		helpers.assert_eq(state.tasks[1].args[6], MANAGED_DIR,
			"the download must land in the folder the resolver searches")

		-- The verified install publishes the executable, then the task settles.
		state.executables[MANAGED_BIN] = true
		state.tasks[1].done(0, "", "")
		helpers.assert_eq(results[1], true)
		helpers.assert_eq(daemon.calls, 1)
		local Resolver = require("modules.llm.ollama_binary")
		local path, _, source = Resolver.resolve()
		helpers.assert_eq(path, MANAGED_BIN)
		helpers.assert_eq(source, "managed")

		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(state.tasks[2].args[5], MANAGED_BIN)
		helpers.assert_eq(state.tasks[2].args[6], "",
			"a re-selection must reuse the installed runtime, never download again")
		state.tasks[2].done(0, "", "")
	end))

	helpers.it("surfaces a checksum mismatch as the localized error", scoped(function()
		local state = new_state()
		local errors = {}
		local checker = load_ollama_checker(state)
		local window = {}
		for key, value in pairs(WINDOW_STUB) do window[key] = value end
		window.set_error = function(message) errors[#errors + 1] = message end
		package.loaded["ui.download_window"] = window
		checker = load_ollama_checker(state)
		package.loaded["ui.download_window"] = window
		helpers.assert_true(checker.install_for_selection())
		state.tasks[1].done(1, "OLLAMA_INSTALLING\nOLLAMA_ERROR_CHECKSUM\n",
			"[OLLAMA-DEPS] ERROR: Ollama archive SHA-256 checksum mismatch; refusing extraction.\n")
		helpers.assert_eq(checker.get_state(), "failed")
		helpers.assert_eq(checker.get_failure_message(),
			require("infra.i18n").get("ollama.error_checksum"))
		helpers.assert_nil(require("modules.llm.ollama_binary").resolve(),
			"a refused archive must leave nothing for the resolver to find")
	end))
end)





-- ================================================
-- ================================================
-- ======= 3/ MLX: Selection-Only Bootstrap =======
-- ================================================
-- ================================================

helpers.describe("MLX bootstraps only on its selection (ai-runtime-mlx)", function()
	helpers.it("names one venv per layout, as ensure-mlx-deps.sh does", function()
		helpers.with_stub_scope(STUBBED_MODULES, function()
			with_environment(DEFAULT_ENV, function()
				helpers.assert_eq(load_mlx_checker(new_state()).venv_dir(), MLX_VENV,
					"the launcher's read-only bundle keeps the venv in Application Support")
			end)
			local checkout_env = {}
			for key, value in pairs(DEFAULT_ENV) do checkout_env[key] = value end
			checkout_env.ERGOPTI_CONFIG_DIR = false
			with_environment(checkout_env, function()
				local venv = load_mlx_checker(new_state()).venv_dir()
				helpers.assert_type(venv, "string")
				helpers.assert_eq(venv:sub(-#"/.venv"), "/.venv",
					"a checkout keeps the venv beside the driver")
				helpers.assert_true(venv:find("Application Support", 1, true) == nil)
			end)
		end)
	end)

	helpers.it("settles a boot check as missing without any task", scoped(function()
		local state = new_state()
		local checker = load_mlx_checker(state)
		helpers.assert_true(checker.schedule_initial_check())
		hs.timer.__fire_all()
		helpers.assert_eq(#state.tasks, 0, "boot must never run ensure-mlx-deps.sh")
		helpers.assert_eq(checker.get_state(), "missing")
	end))

	helpers.it("reuses an installed runtime at boot without the script", scoped(function()
		local state = new_state()
		state.absent = {}
		state.files[MLX_VENV .. "/bin/python"] = true
		state.files[MLX_VENV .. "/.last_sync_hash"] = true
		local checker = load_mlx_checker(state)
		helpers.assert_true(checker.schedule_initial_check())
		hs.timer.__fire_all()
		helpers.assert_eq(#state.tasks, 0, "an installed runtime (even after an update) is reused")
		helpers.assert_eq(checker.get_state(), "ready")
	end))

	helpers.it("installs once on the first selection and never on re-selection", scoped(function()
		local state = new_state()
		local checker = load_mlx_checker(state)
		local plain
		helpers.assert_true(checker.check_and_install_deps(function(ok) plain = ok end))
		helpers.assert_eq(plain, false)
		helpers.assert_eq(#state.tasks, 0, "a non-selection check never bootstraps")

		local results = {}
		helpers.assert_true(checker.install_for_selection(function(ok) results[#results + 1] = ok end))
		helpers.assert_eq(#state.tasks, 1)
		state.absent = {}
		state.files[MLX_VENV .. "/bin/python"] = true
		state.files[MLX_VENV .. "/.last_sync_hash"] = true
		state.tasks[1].done(0, "", "")
		helpers.assert_eq(checker.get_state(), "ready")

		helpers.assert_true(checker.install_for_selection(function(ok) results[#results + 1] = ok end))
		helpers.assert_eq(#state.tasks, 1, "a re-selection must reuse the installed runtime")
		helpers.assert_eq(results[#results], true)
	end))

	helpers.it("never lets a ready runtime's grant reach a later plain check", scoped(function()
		local state = new_state()
		state.absent = {}
		state.files[MLX_VENV .. "/bin/python"] = true
		state.files[MLX_VENV .. "/.last_sync_hash"] = true
		local checker = load_mlx_checker(state)
		helpers.assert_true(checker.install_for_selection())
		-- Re-selecting a ready runtime takes the early "ready" return.
		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(#state.tasks, 0)

		state.files = {}
		state.absent = {
			[MLX_VENV .. "/bin/python"] = true,
			[MLX_VENV .. "/.last_sync_hash"] = true,
		}
		helpers.assert_true(checker.check_and_install_deps())
		helpers.assert_eq(#state.tasks, 0, "a plain check must never install without a selection")
		helpers.assert_eq(checker.get_state(), "missing")
	end))

	helpers.it("reinstalls a runtime removed after it was ready", scoped(function()
		local state = new_state()
		state.absent = {}
		state.files[MLX_VENV .. "/bin/python"] = true
		state.files[MLX_VENV .. "/.last_sync_hash"] = true
		local checker = load_mlx_checker(state)
		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(#state.tasks, 0)

		-- The user deletes the venv while the app runs.
		state.files = {}
		state.absent = {
			[MLX_VENV .. "/bin/python"] = true,
			[MLX_VENV .. "/.last_sync_hash"] = true,
		}
		local plain
		helpers.assert_true(checker.check_and_install_deps(function(ok) plain = ok end))
		helpers.assert_eq(plain, false, "a plain check must not report a removed runtime ready")
		helpers.assert_eq(checker.get_state(), "missing")
		helpers.assert_eq(#state.tasks, 0, "a plain check still never installs")

		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(#state.tasks, 1, "selecting MLX again must reinstall the removed runtime")
	end))

	helpers.it("rebuilds a broken runtime on the next selection, never before", scoped(function()
		local state = new_state()
		state.absent = {}
		state.files[MLX_VENV .. "/bin/python"] = true
		state.files[MLX_VENV .. "/.last_sync_hash"] = true
		local checker = load_mlx_checker(state)
		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(checker.get_state(), "ready")

		local removed = {}
		local original_remove = os.remove
		os.remove = function(path)
			removed[#removed + 1] = path
			state.files[path] = nil
			state.absent[path] = true
			return true
		end
		local ok, invalidated = pcall(checker.invalidate_runtime)
		os.remove = original_remove
		helpers.assert_true(ok, tostring(invalidated))
		helpers.assert_true(invalidated)
		helpers.assert_eq(removed, { MLX_VENV .. "/.last_sync_hash" },
			"only the sync fingerprint is dropped, so the script rebuilds the whole venv")
		helpers.assert_eq(checker.runtime_installed(), false)
		helpers.assert_eq(checker.get_failure_message(),
			require("infra.i18n").get("mlx.runtime_broken_body"))
		helpers.assert_eq(#state.tasks, 0, "invalidation itself never downloads")

		local plain
		helpers.assert_true(checker.check_and_install_deps(function(result) plain = result end))
		helpers.assert_eq(plain, false)
		helpers.assert_eq(#state.tasks, 0, "a plain check never rebuilds it")

		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(#state.tasks, 1, "the next MLX selection rebuilds the runtime")
	end))
	helpers.it("retains the real bundled network policy when the runtime files are removed", scoped(function()
		local policy_path = helpers.driver_root() .. "modules/llm/network-retry.sh"
		local policy = assert(io.open(policy_path, "r"))
		local policy_bytes = policy:read("*a")
		policy:close()
		helpers.assert_true(policy_bytes:find("apply_system_network", 1, true) ~= nil,
			"the declared fixture dependency is the real shipped network policy")
		local state = new_state()
		state.files = {}
		load_mlx_checker(state)
		local NetworkEnv = require("modules.llm.network_env")
		helpers.assert_eq(NetworkEnv.policy_path(), policy_path)
		local prelude = assert(NetworkEnv.bootstrap_prelude("FIXTURE", helpers.HEALTHY_PYTHON))
		helpers.assert_true(prelude:find(policy_path, 1, true) ~= nil)
		helpers.assert_eq(#state.tasks, 0, "prelude construction itself cannot acquire a task")
	end))

	helpers.it("a fresh fixture refuses a genuinely absent bundled policy before any task", scoped(function()
		local present = new_state()
		load_mlx_checker(present)
		helpers.assert_type(require("modules.llm.network_env").policy_path(), "string")
		local missing = new_state()
		missing.bundled_files = {}
		local checker = load_mlx_checker(missing)
		local NetworkEnv = require("modules.llm.network_env")
		helpers.assert_nil(NetworkEnv.policy_path())
		local prelude, why = NetworkEnv.bootstrap_prelude("FIXTURE", helpers.HEALTHY_PYTHON)
		helpers.assert_nil(prelude)
		helpers.assert_eq(why, "the shared network policy modules/llm/network-retry.sh is missing")
		helpers.assert_eq(checker.install_for_selection(), false)
		helpers.assert_eq(checker.get_state(), "failed")
		helpers.assert_eq(#missing.tasks, 0, "missing policy must refuse before native task creation")
	end))

end)





-- ========================================
-- ========================================
-- ======= 4/ Ollama Download Offer =======
-- ========================================
-- ========================================

helpers.describe("Ollama download offer (ai-runtime-offer)", function()
	local function load_offer(choice_key, record)
		local i18n = require("infra.i18n")
		package.loaded["infra.dialog_util"] = {
			block_alert = function(...)
				record.dialogs = record.dialogs + 1
				record.dialog_args = table.pack(...)
				return i18n.get(choice_key)
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind, on_click)
				record.notices[#record.notices + 1] = { title = title, body = body, kind = kind, on_click = on_click }
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.runtime_install_offer"] = nil
		return helpers.load_with_stubs("ui.menu.menu_llm.runtime_install_offer", {
			fs = fake_fs(record.state),
			task = task_api(record.state),
			urlevent = { openURL = function(url) record.urls[#record.urls + 1] = url return true end },
		})
	end

	local function new_record()
		return { dialogs = 0, notices = {}, urls = {}, state = new_state() }
	end

	helpers.it("accepting downloads into the folder the resolver then finds", scoped(function()
		local record = new_record()
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		local result
		helpers.assert_true(Offer.select_ollama(function(ok) result = ok end))
		helpers.assert_eq(record.dialogs, 1)
		helpers.assert_eq(#record.state.tasks, 1)
		helpers.assert_eq(record.state.tasks[1].args[6], MANAGED_DIR)
		record.state.executables[MANAGED_BIN] = true
		record.state.tasks[1].done(0, "", "")
		helpers.assert_eq(result, true)
		helpers.assert_true(Offer.is_installed("ollama"))

		helpers.assert_true(Offer.select_ollama())
		helpers.assert_eq(record.dialogs, 1, "an installed Ollama is never offered again")
		record.state.tasks[2].done(0, "", "")
	end))

	helpers.it("declining opens the website and keeps the AI off with a message", scoped(function()
		local record = new_record()
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_website", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_eq(Offer.select_ollama(), false)
		helpers.assert_eq(record.dialogs, 1)
		helpers.assert_eq(#record.state.tasks, 0, "a decline never downloads")
		helpers.assert_eq(record.urls[1], "https://ollama.com/download")
		helpers.assert_eq(#record.notices, 1)
		helpers.assert_eq(record.notices[1].body,
			require("infra.i18n").get("ollama.runtime_missing_body"))
	end))

	helpers.it("a found Ollama is reused without asking", scoped(function()
		local record = new_record()
		record.state.executables["/opt/homebrew/bin/ollama"] = true
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_true(Offer.select_ollama())
		helpers.assert_eq(record.dialogs, 0)
		helpers.assert_eq(record.state.tasks[1].args[6], "")
		record.state.tasks[1].done(0, "", "")
	end))

	helpers.it("a boot with the API backend posts no runtime notice", scoped(function()
		local record = new_record()
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = load_ollama_checker(record.state)
		helpers.assert_eq(Offer.notify_if_missing("api"), false)
		helpers.assert_eq(Offer.notify_if_missing("ollama"), true)
		helpers.assert_eq(record.dialogs, 0, "boot never shows the download offer")
		helpers.assert_eq(#record.state.tasks, 0, "boot never downloads")
	end))

	helpers.it("the boot notice of a missing Ollama opens its download offer when clicked", scoped(function()
		local record = new_record()
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_true(Offer.notify_if_missing("ollama"))
		helpers.assert_eq(#record.notices, 1)
		helpers.assert_eq(record.notices[1].body,
			require("infra.i18n").get("ollama.runtime_missing_click"),
			"the notice used to name the menu row to select, with no action of its own")
		-- Called below: a notice without its click fails there.
		helpers.assert_not_nil(record.notices[1].on_click,
			"the notice carries the click that opens its fix")
		helpers.assert_eq(record.dialogs, 0)
		helpers.assert_eq(#record.state.tasks, 0)
		record.notices[1].on_click()
		helpers.assert_eq(record.dialogs, 1, "the click opens the download offer, which asks first")
		helpers.assert_eq(#record.state.tasks, 1, "accepting the offer downloads Ollama")
		helpers.assert_eq(record.state.tasks[1].args[6], MANAGED_DIR)
		record.state.executables[MANAGED_BIN] = true
		record.state.tasks[1].done(0, "", "")

		record.notices[1].on_click()
		helpers.assert_eq(record.dialogs, 1, "a runtime installed since the notice offers nothing")
		helpers.assert_eq(#record.state.tasks, 1)
	end))
end)





-- ====================================
-- ====================================
-- ======= 5/ Trigger Ownership =======
-- ====================================
-- ====================================

helpers.describe("AI runtime triggers stay off the boot and typing paths (ai-runtime-triggers)", function()
	--- Counts `.install_for_selection(` calls in code, ignoring comments and the
	--- two checker definitions, so a new caller anywhere is visible.
	local function count_calls(text)
		local calls = 0
		for line in text:gmatch("[^\n]+") do
			local code = line:gsub("%-%-.*$", "")
			if not code:find("function M.install_for_selection(", 1, true) then
				for _ in code:gmatch("%.install_for_selection%(") do calls = calls + 1 end
			end
		end
		return calls
	end

	helpers.it("only the selection router grants a runtime install", function()
		local everywhere = helpers.read_driver_source("install_for_selection(")
		helpers.assert_not_nil(everywhere)
		local router, router_err = helpers.read_driver_unit("local function mlx_deps()")
		helpers.assert_not_nil(router, router_err)
		helpers.assert_eq(count_calls(router), 2, "the router owns one call per runtime")
		helpers.assert_eq(count_calls(everywhere), 2,
			"no boot, update, model or other-backend path may grant an install")
	end)

	helpers.it("boot schedules no checker for a remote API backend", function()
		local init, init_err = helpers.read_driver_unit("local function start_llm_bootstrap")
		helpers.assert_not_nil(init, init_err)
		local start = init:find("local function start_llm_bootstrap", 1, true)
		local body = init:sub(start, init:find("\nend\n", start, true))
		helpers.assert_true(body:find("and mlx_deps_checker or ollama_deps_checker", 1, true) == nil,
			"a non-MLX backend (API) must not fall through to the Ollama checker")
		helpers.assert_true(body:find("BACKEND_OLLAMA", 1, true) ~= nil)
		helpers.assert_true(body:find("install_for_selection", 1, true) == nil,
			"boot never grants a download")
	end)

	helpers.it("the typing path never probes for a runtime", function()
		for _, banner in ipairs({
			"--- MODULE: LLM Prediction Engine\n",
			"--- MODULE: LLM Streaming Handler\n",
			"--- MODULE: Keymap LLM Bridge\n",
		}) do
			local text, err = helpers.read_driver_unit(banner)
			helpers.assert_not_nil(text, err)
			for _, probe in ipairs({ "ollama_binary", "runtime_install_offer",
				".runtime_available(", ".runtime_installed(", "_deps_checker" }) do
				helpers.assert_true(text:find(probe, 1, true) == nil,
					banner .. " must not reach " .. probe)
			end
		end
	end)
end)
