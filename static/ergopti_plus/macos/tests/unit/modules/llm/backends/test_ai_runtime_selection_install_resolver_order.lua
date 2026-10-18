--- tests/unit/modules/llm/backends/test_ai_runtime_selection_install_resolver_order.lua

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
package.loaded["tests.support.modules.llm.backends.ai_runtime_selection_install_fixture"] = nil
local Fixture = require("tests.support.modules.llm.backends.ai_runtime_selection_install_fixture")
local CANDIDATES = Fixture.CANDIDATES
local DEFAULT_ENV = Fixture.DEFAULT_ENV
local MANAGED_BIN = Fixture.MANAGED_BIN
local MANAGED_DIR = Fixture.MANAGED_DIR
local MLX_VENV = Fixture.MLX_VENV
local NATIVE_BIN = Fixture.NATIVE_BIN
local STUBBED_MODULES = Fixture.STUBBED_MODULES
local WINDOW_STUB = Fixture.WINDOW_STUB
local fake_fs = Fixture.fake_fs
local load_mlx_checker = Fixture.load_mlx_checker
local load_ollama_checker = Fixture.load_ollama_checker
local new_state = Fixture.new_state
local scoped = Fixture.scoped
local with_environment = Fixture.with_environment





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
		helpers.assert_eq(daemon.calls, 0, "stock client provisioning grants no daemon ownership")
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(checker.get_daemon_state(), "pending")
		helpers.assert_eq(checker.is_daemon_ready(), false)
		helpers.assert_eq(#state.daemon_tasks, 0)
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

	helpers.it("native provisioning waits for its exact authorized complete READY frame", scoped(function()
		local state = new_state()
		state.native_hint = true
		state.executables[NATIVE_BIN] = true
		local daemon = { calls = 0 }
		local checker = load_ollama_checker(state, daemon)
		local resolved, resolution_error, source = require("modules.llm.ollama_binary").resolve()
		helpers.assert_eq(resolved, NATIVE_BIN)
		helpers.assert_nil(resolution_error)
		helpers.assert_eq(source, "native_managed", "only the native source kind may launch this owner")
		local results = {}
		local ok, primary = xpcall(function()
			helpers.assert_true(checker.install_for_selection(function(value) results[#results + 1] = value end))
			helpers.assert_eq(state.tasks[1].args[5], NATIVE_BIN)
			helpers.assert_eq(state.tasks[1].args[6], "")
			state.tasks[1].done(0, "", "")
			helpers.assert_eq(daemon.calls, 1)
			helpers.assert_eq(#state.daemon_tasks, 1)
			helpers.assert_eq(#results, 0, "accepted startup is not daemon READY")
			helpers.assert_eq(checker.get_state(), "ready")
			helpers.assert_eq(checker.get_daemon_state(), "pending")
			local ready = state.daemon_frame("READY")
			state.daemon_tasks[1].emit(state.daemon_frame("ACTIVE") .. ready:sub(1, 18))
			local partial_result_count = #results
			local partial_ready = checker.is_daemon_ready()
			-- Drain the original remaining frame before evaluating its observations.
			state.daemon_tasks[1].emit(ready:sub(19))
			helpers.assert_eq(partial_result_count, 0, "a partial READY frame cannot publish success")
			helpers.assert_eq(partial_ready, false)
			helpers.assert_eq(results, { true })
			helpers.assert_eq(checker.get_daemon_state(), "ready")
			helpers.assert_true(checker.is_daemon_ready())
		end, debug.traceback)
		local closed, cleanup = xpcall(function()
			for _, task in ipairs(state.daemon_tasks) do
				if not task.settled then helpers.assert_true(task.complete()) end
				helpers.assert_true(task.settled)
			end
			helpers.assert_true(state.api.startup_idle(), "physical exit alone cannot join native lifecycle custody")
			helpers.assert_true(state.api.migration_idle(), "the original shared RETIRED frame must join settlement")
		end, debug.traceback)
		if not ok then error(primary, 0) end
		if not closed then error(cleanup, 0) end
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

	helpers.it("(ollama-install-stream-error) retains a split streamed failure when completion has no bytes", scoped(function()
		local state = new_state()
		local checker = load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		local task = state.tasks[1]
		helpers.assert_type(task.stream, "function", "the production bootstrap must expose its streaming callback")
		task.stream(task, "", "archive extraction failed: no space ")
		task.stream(task, "", "left on device\n")
		task.done(1, "", "")
		helpers.assert_eq(checker.get_state(), "failed")
		helpers.assert_eq(checker.get_failure_message(), "archive extraction failed: no space left on device")
	end))

	helpers.it("(ollama-install-stream-error) uses a localized fallback only when no diagnostic exists", scoped(function()
		local state = new_state()
		local checker = load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		state.tasks[1].done(1, "", "")
		helpers.assert_eq(checker.get_failure_message(), require("infra.i18n").get("download_window.error_unknown"))
	end))

	helpers.it("(ollama-install-stream-error) retains the first full cause before trailing progress markers", scoped(function()
		local state = new_state()
		local checker = load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		local task = state.tasks[1]
		helpers.assert_type(task.stream, "function")
		task.stream(task, "", "archive extraction failed: no space left on device\n")
		task.stream(task, "OLLAMA_DOWNLOAD_PROGRESS 98\n", "")
		task.done(1, "", "")
		helpers.assert_eq(checker.get_failure_message(), "archive extraction failed: no space left on device")
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
