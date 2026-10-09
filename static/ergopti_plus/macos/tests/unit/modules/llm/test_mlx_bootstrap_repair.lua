--- tests/unit/modules/llm/test_mlx_bootstrap_repair.lua

--- ==============================================================================
--- MODULE: MLX Bootstrap Failure And Repair Regression Tests
--- DESCRIPTION:
--- Maintainer report (dev.152, Homebrew install): "MLX bootstrap failed, exit
--- 1, cause inconnue", then "pas d'autorisation pour un truc" and no retry any
--- more, then "MLX packages are not importable from the installed runtime".
--- These cases drive the real dependency checker, selection router, repair
--- offer and diagnosis over a fake filesystem, recorded native tasks and a
--- recorded dialog:
--- 1. A failed bootstrap names the cause its streamed output proves, never
---    "cause inconnue": the completion only receives what was not streamed.
--- 2. A permission failure names the path and what the repair button does.
--- 3. A runtime whose import probe failed never reads as installed, even when
---    its fingerprint cannot be removed, and the next selection repairs it.
--- 4. A failure offers its repair button, and a selection after it retries.
--- 5. The repair only ever removes the venv Ergopti owns.
--- 6. A Mac that cannot run MLX is told so and offered Ollama.
--- 7. A runtime that is not installed is announced with the button that
---    installs it, never with the menu row to select; a failed install names
---    its cause and retries with the repair button.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/Users/fixture"
local APP_SUPPORT = HOME .. "/Library/Application Support/Ergopti"
local MLX_VENV = APP_SUPPORT .. "/mlx-venv"
local LAUNCHER_ENV = {
	HOME = HOME,
	ERGOPTI_CONFIG_DIR = "/Applications/ErgoptiPlus.app/Contents/Resources/static",
}

local OWNED = {
	"infra.logger", "infra.i18n", "infra.locale", "locale.core",
	"infra.dialog_util", "infra.notifications", "infra.deferred_work",
	"adapters.shell_runner", "adapters.task_lifecycle", "adapters.timer_scheduler",
	"ui.download_window", "modules.llm.pty_process_group", "modules.llm.ollama_binary",
	"modules.llm.ollama_deps_checker", "modules.llm.backend_detector",
	"modules.llm.mlx_bootstrap_diagnosis", "modules.llm.mlx_deps_checker",
	"ui.menu.menu_llm.runtime_install_offer", "ui.menu.menu_llm.mlx_repair_offer",
	"adapters.python_interpreter", "ui.python_runtime_offer",
	"adapters.file_system", "modules.llm.network_env", "modules.llm.opaque_network_admission",
	"adapters.native_bootstrap_pty",
}

-- The closing lines ensure-mlx-deps.sh prints after any failed uv sync: they
-- blame nothing specific, and used to be all a user could read.
local CLOSING_LINES = {
	"[MLX-DEPS] Network attempt 6/6 failed (code 2) -- giving up.",
	"[MLX-DEPS] ❌ uv sync failed; the uv error above names the cause.",
}





-- ====================================
-- ====================================
-- ======= 1/ Fixture Utilities =======
-- ====================================
-- ====================================

--- Runs a callback with a fixed HOME and the launcher's environment.
--- @param env table Variables to answer; false means unset.
--- @param callback function
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

--- Creates the recorded world a scenario runs in.
--- @param opts table|nil { installed, uname, macos }
--- @return table world
local function new_world(opts)
	opts = opts or {}
	local world = {
		files = {}, dirs = {}, links = {},
		tasks = {}, errors = {}, window_errors = {}, window_sessions = 0,
		dialogs = {}, answers = {}, deferred = {}, notices = {}, spawns = {},
		alternatives = 0,
		uname = opts.uname or "arm64", macos = opts.macos or "15.1",
	}
	if opts.installed then
		world.dirs[MLX_VENV] = true
		world.files[MLX_VENV .. "/bin/python"] = true
		world.files[MLX_VENV .. "/.last_sync_hash"] = true
	end
	return world
end

--- Fake filesystem: the Application Support tree follows the world, every
--- other path (driver root, script) exists.
--- @param world table
--- @return table fs
local function fake_fs(world)
	local function mode_of(path)
		if path:sub(1, #APP_SUPPORT) ~= APP_SUPPORT then return "file" end
		if world.files[path] then return "file" end
		if world.dirs[path] then return "directory" end
		return nil
	end
	local function attributes(path, attribute)
		local mode = mode_of(path)
		if attribute == "mode" then return mode end
		return mode and { mode = mode } or nil
	end
	return {
		attributes = attributes,
		symlinkAttributes = function(path, attribute)
			if world.links[path] then
				if attribute == "mode" then return "link" end
				return { mode = "link" }
			end
			return attributes(path, attribute)
		end,
	}
end

--- Records every native task and lets the scenario stream and finish it.
--- @param world table
--- @return table task_api
local function task_api(world)
	return {
		new = function(executable, completion, stream, args)
			if type(stream) == "table" then args, stream = stream, nil end
			local task = { executable = executable, args = args or {}, completion = completion, stream = stream }
			function task:start()
				if type(world.on_start) == "function" then world.on_start(self) end
				if world.start_mode == "false" then return false end
				if world.start_mode == "nil" then return nil end
				if world.start_mode == "throw" then error("Independent native start refusal") end
				return self
			end
			function task:terminate()
				self.terminate_calls = (self.terminate_calls or 0) + 1
				return self
			end
			function task:isRunning() return false end
			function task.emit(stdout, stderr) return task.stream(task, stdout or "", stderr or "") end
			function task.finish(code, stdout, stderr) return task.completion(code, stdout or "", stderr or "") end
			function task.command() return task.args[#task.args] end
			world.tasks[#world.tasks + 1] = task
			return task
		end,
	}
end

--- Answers keys from the real locale files.
--- @param locale string Locale code.
local function speak(locale)
	local Locale = require("infra.locale")
	Locale.set_locale(locale)
	local function get(key)
		local text = Locale.get(key)
		if text == nil or text == "" then return key end
		return text
	end
	package.loaded["infra.i18n"] = {
		get = get,
		format = function(key, ...)
			local text = get(key)
			local args = table.pack(...)
			for n = 1, args.n do
				text = text:gsub("{" .. n .. "}", (tostring(args[n]):gsub("%%", "%%%%")))
			end
			return text
		end,
	}
end

--- Loads the real checker, router and offer over the world's doubles.
--- @param world table
--- @return table checker
--- @return table router
--- @return table offer
local function load_world(world)
	local logger = helpers.make_logger_stub()
	logger.error = function(_, fmt, ...)
		local ok, text = pcall(string.format, fmt, ...)
		world.errors[#world.errors + 1] = ok and text or tostring(fmt)
	end
	package.loaded["infra.logger"] = logger
	-- Only native boundaries are doubled: the policy bytes and parser remain real.
	package.loaded["adapters.file_system"] = {
		exists = function(path) return fake_fs(world).attributes(path, "mode") ~= nil end,
		read = function(path)
			helpers.assert_true(path:find("/_shared/", 1, true) ~= nil, "native fixture reads actual shared source data")
			local file = assert(io.open(path, "rb"))
			local text = file:read("*a")
			file:close()
			return text
		end,
		path_status = function(path)
			local attributes = fake_fs(world).attributes(path)
			return attributes and "present" or "absent", attributes
		end,
	}
	-- Load the unchanged producer with its canonical path spelling on every host.
	local network_path = assert(package.searchpath("modules.llm.network_env", package.path))
	network_path = network_path:gsub("\\", "/")
	package.loaded["modules.llm.network_env"] = assert(loadfile(network_path))()
	package.loaded["ui.download_window"] = {
		is_active = function() return world.window_sessions > 0 end,
		session_id = function() return world.window_sessions end,
		show = function() world.window_sessions = world.window_sessions + 1; return true end,
		hide = function() return true end,
		set_step = function() end, set_detail = function() end,
		set_progress = function() end, append_log = function() end,
		set_error = function(message) world.window_errors[#world.window_errors + 1] = message end,
	}
	package.loaded["modules.llm.pty_process_group"] = {
		create = function() return "/tmp/fixture-pty.py" end,
		remove = function() return true end,
	}
	for _, name in ipairs({ "adapters.task_lifecycle", "adapters.timer_scheduler",
		"modules.llm.backend_detector", "modules.llm.mlx_bootstrap_diagnosis" }) do
		package.loaded[name] = nil
	end
	local checker = helpers.load_with_stubs("modules.llm.mlx_deps_checker", {
		fs = fake_fs(world),
		task = task_api(world),
		execute = function(command)
			if command:find("uname", 1, true) then return world.uname .. "\n", true end
			if command:find("sw_vers", 1, true) then return world.macos .. "\n", true end
			return "", true
		end,
	})
	-- Controlled native receipt boundary: unstructured stderr is never promoted
	-- into proof. The real diagnosis and canonical interpreter consume these
	-- manually authored typed receipts for the action cases that need them.
	local Diagnosis = require("modules.llm.mlx_bootstrap_diagnosis")
	local classify = Diagnosis.classify
	Diagnosis.classify = function(lines, exit_code, context)
		if world.native_network_receipt ~= nil then
			context = context or {}
			context.network_receipt = world.native_network_receipt
			local raw = package.loaded["adapters.file_system"].read(
				require("infra.paths").shared("modules/network/managed_network.json"))
			context.network_contract = require("network.failure").new(require("json").decode(raw))
		end
		return classify(lines, exit_code, context)
	end
	package.loaded["infra.dialog_util"] = {
		-- The network failures' offer: its actions, then « Plus tard ».
		choose = function(title, body, choices, cancel_label)
			world.dialogs[#world.dialogs + 1] = {
				title = title, body = body, choices = choices, cancel = cancel_label,
				primary = choices[1], secondary = choices[2],
			}
			local answer = table.remove(world.answers, 1)
			if answer == "primary" then return 1 end
			if answer == "secondary" then return 2 end
			return nil
		end,
		block_alert = function(...)
			local title, body, primary, secondary = ...
			world.dialogs[#world.dialogs + 1] = {
				title = title, body = body, primary = primary, secondary = secondary,
				argument_count = select("#", ...),
			}
			local answer = table.remove(world.answers, 1)
			if answer == "primary" then return primary end
			return secondary
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind, on_click)
			world.notices[#world.notices + 1] = { title = title, body = body, kind = kind, on_click = on_click }
			return true
		end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(_, callback, label)
			world.deferred[#world.deferred + 1] = { callback = callback, label = label }
			return true
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args)
			world.spawns[#world.spawns + 1] = { executable = executable, args = args }
			return { start = function() return true end }
		end,
	}
	local router = require("ui.menu.menu_llm.runtime_install_offer")
	local offer = require("ui.menu.menu_llm.mlx_repair_offer")
	return checker, router, offer
end

--- Runs the deferred dialogs the offer scheduled.
--- @param world table
local function drain(world)
	while #world.deferred > 0 do
		table.remove(world.deferred, 1).callback()
	end
end

--- Runs one scenario in the launcher layout with its modules owned.
--- @param scenario function Receives nothing; builds its own world.
--- @param env table|nil Environment, the launcher's by default.
--- @return function test
local function scoped(scenario, env)
	return function()
		helpers.with_stub_scope(OWNED, function()
			with_environment(env or LAUNCHER_ENV, scenario)
			-- The scope restores the real module; releasing the stub here too
			-- keeps the suite-wide shell_runner hygiene gate able to see it.
			package.loaded["adapters.shell_runner"] = nil
		end)
	end
end

--- Streams lines the way the PTY delivers them: CRLF, in chunks that split
--- a line in two, all of it on stdout.
--- @param task table Recorded task.
--- @param lines table Lines to stream.
local function stream_lines(task, lines)
	local text = table.concat(lines, "\r\n") .. "\r\n"
	local middle = math.floor(#text / 2)
	task.emit("VENV_SYNC_RAN\r\nVENV_CREATING\r\n", "")
	task.emit(text:sub(1, middle), "")
	task.emit(text:sub(middle + 1), "")
end

--- Reports whether any recorded ERROR log contains a text.
--- @param world table
--- @param needle string
--- @return boolean
local function logged(world, needle)
	for _, line in ipairs(world.errors) do
		if line:find(needle, 1, true) then return true end
	end
	return false
end





-- ==========================================
-- ==========================================
-- ======= 2/ Failure Names Its Cause =======
-- ==========================================
-- ==========================================

helpers.describe("A failed MLX bootstrap names its cause (mlx-bootstrap-exit-stderr)", function()
	helpers.it("surfaces the streamed error of an exit 1, never an unknown cause", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("fr")
		local results = {}
		helpers.assert_true(checker.install_for_selection(function(ok) results[#results + 1] = ok end))
		helpers.assert_eq(#world.tasks, 1)
		stream_lines(world.tasks[1], {
			"[MLX-DEPS] ❌ pyproject.toml introuvable à /fixture/pyproject.toml — projet corrompu.",
		})
		-- hs.task hands the streaming callback everything it read: the
		-- completion carries no output at all.
		world.tasks[1].finish(1, "", "")
		helpers.assert_eq(results, { false })
		helpers.assert_eq(checker.get_state(), "failed")
		local message = checker.get_failure_message()
		helpers.assert_true(message:find("pyproject.toml introuvable", 1, true) ~= nil,
			"the failure must quote the line the script printed, got: " .. message)
		helpers.assert_true(message:find("Cause inconnue", 1, true) == nil, message)
		helpers.assert_true(message:find("L’installation s’est arrêtée avec le code 1.", 1, true) ~= nil, message)
		helpers.assert_true(world.window_errors[1]:find("pyproject.toml introuvable", 1, true) ~= nil,
			"the progress window must show the same cause")
		helpers.assert_true(logged(world, "exit=1"), "the failure must be logged with its exit code")
		helpers.assert_true(logged(world, "pyproject.toml introuvable"),
			"the ERROR log must carry the full retained tail")
	end))

	helpers.it("keeps a one-line error delivered with the exit itself", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("fr")
		helpers.assert_true(checker.install_for_selection())
		world.tasks[1].finish(1, "[MLX-DEPS] ❌ uv.lock is missing at /fixture/uv.lock — the project is incomplete.\n", "")
		local message = checker.get_failure_message()
		helpers.assert_true(message:find("uv.lock is missing", 1, true) ~= nil,
			"a single line must not be dropped as a partial first line, got: " .. message)
	end))

	helpers.it("finds the uv error above the retry loop's closing lines", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("fr")
		helpers.assert_true(checker.install_for_selection())
		local lines = {
			"error: Distribution `mlx==0.31.2 @ registry+https://pypi.org/simple` can't be installed because it doesn't have a source distribution or wheel for the current platform",
		}
		for attempt = 1, 20 do lines[#lines + 1] = "DEBUG uv verbose line " .. attempt end
		for _, line in ipairs(CLOSING_LINES) do lines[#lines + 1] = line end
		stream_lines(world.tasks[1], lines)
		world.tasks[1].finish(1, "", "")
		local cause = checker.get_failure_cause()
		helpers.assert_eq(cause.kind, "python",
			"a supported Mac handed no wheel for its platform got a foreign interpreter")
		local message = checker.get_failure_message()
		helpers.assert_true(message:find("wheel for the current platform", 1, true) ~= nil, message)
		helpers.assert_true(message:find("Le Python utilisé par l’installation ne peut pas faire fonctionner MLX.", 1, true) ~= nil,
			message)
	end))

	helpers.it("strips the PTY's terminal colors and carriage returns", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		helpers.assert_true(checker.install_for_selection())
		world.tasks[1].emit("\27[1m\27[31merror\27[0m: No space left on device (os error 28)\r\n", "")
		world.tasks[1].finish(1, "", "")
		local cause = checker.get_failure_cause()
		helpers.assert_eq(cause.kind, "disk_full")
		helpers.assert_eq(cause.line, "error: No space left on device (os error 28)")
	end))

	helpers.it("names the import failure that made the script refuse to publish", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("fr")
		helpers.assert_true(checker.install_for_selection())
		stream_lines(world.tasks[1], {
			"DEPS_SYNCED", "IMPORT_CHECKING",
			"Traceback (most recent call last):",
			"ModuleNotFoundError: No module named 'mlx'",
			"[MLX-DEPS] ❌ MLX packages do not import with /fixture/python: ModuleNotFoundError: No module named 'mlx'",
		})
		world.tasks[1].finish(4, "", "")
		helpers.assert_eq(checker.get_state(), "failed", "a venv that does not import is never ready")
		helpers.assert_eq(checker.get_failure_cause().kind, "import_failed")
		local message = checker.get_failure_message()
		helpers.assert_true(message:find("Les paquets MLX sont installés mais ne se chargent pas.", 1, true) ~= nil,
			message)
		helpers.assert_true(message:find("No module named 'mlx'", 1, true) ~= nil, message)
	end))
end)

helpers.describe("Native PTY caller joins the original MLX task transaction", function()
	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains native " .. start_mode .. " start until its exact retirement receipt", scoped(function()
			local world = new_world()
			world.start_mode = start_mode
			local checker = load_world(world)
			package.loaded["adapters.python_interpreter"]._set_deps({
				read_head = function() return nil end,
				realpath = function(path) return path end,
				getenv = function() return nil end,
				select_link_target = function() return nil end,
				process_arch = function() return "arm64" end,
			})
			local retired, start_attempted, bound, pause_owner = false, false, false, nil
			helpers.assert_true(checker.configure_pause_owner({
				is_paused = function() return false end,
				is_pause_transition_pending = function() return false end,
				get_pause_epoch = function() return 0 end,
				register_pause_owner = function(_, owner) pause_owner = owner; return true end,
			}))
			package.loaded["adapters.native_bootstrap_pty"] = {
				prepare = function(source, environment, budget)
					helpers.assert_true(source:match("/modules/llm/ensure%-mlx%-deps%.sh$") ~= nil)
					helpers.assert_eq(budget, 1800000, "original bootstrap budget is preserved")
					helpers.assert_eq(#environment, 3, "original bootstrap environment joins native source")
					return {
						executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
						arguments = { "--managed-pty-worker", tostring(budget) },
						bind_input = function(task) bound = task; return true end,
						mark_start_attempted = function() start_attempted = true; return true end,
						rollback = function() return true end,
						settle = function(status) helpers.assert_eq(status, 64); return retired end,
					}, true
				end,
			}
			world.on_start = function(task)
				helpers.assert_eq(bound, task, "private input joins the same native handle before start")
				helpers.assert_true(start_attempted)
				helpers.assert_true(checker.is_task_running(), "original task slot is published before start")
			end
			helpers.assert_eq(checker.install_for_selection(nil), false)
			helpers.assert_eq(#world.tasks, 1, "no Python or alternate native task may be created")
			local task = world.tasks[1]
			helpers.assert_eq(task.executable, "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus")
			helpers.assert_eq(task.terminate_calls, 1, "start refusal joins the exact original rollback")
			helpers.assert_true(checker.is_task_running(), "signal acceptance is not native settlement")
			task.finish(64, "", "")
			helpers.assert_true(checker.is_task_running(), "callback without receipt retains native cleanup debt")
			helpers.assert_eq(checker.reset_bootstrap_state(), false)
			retired = true
			helpers.assert_true(pause_owner.pause(), "pause retries the same retained physical receipt")
			helpers.assert_eq(checker.is_task_running(), false)
		end))
	end
end)





-- ===================================================
-- ===================================================
-- ======= 3/ Permission Names Path And Button =======
-- ===================================================
-- ===================================================

helpers.describe("A permission failure names its path and its repair (mlx-bootstrap-permission-denied)", function()
	helpers.it("names the refused path and what the button will do", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("fr")
		helpers.assert_true(checker.install_for_selection())
		local lines = { "error: failed to create directory `/Users/fixture/.cache/uv`: Permission denied (os error 13)" }
		for _, line in ipairs(CLOSING_LINES) do lines[#lines + 1] = line end
		stream_lines(world.tasks[1], lines)
		world.tasks[1].finish(2, "", "")
		local cause = checker.get_failure_cause()
		helpers.assert_eq(cause.kind, "permission")
		helpers.assert_eq(cause.path, "/Users/fixture/.cache/uv")
		local message = checker.get_failure_message()
		helpers.assert_true(message:find("macOS a refusé l’accès à /Users/fixture/.cache/uv.", 1, true) ~= nil,
			message)
		helpers.assert_true(message:find("« Réparer l’installation MLX » supprime l’environnement MLX d’ErgoptiPlus ("
			.. MLX_VENV .. ") puis le réinstalle.", 1, true) ~= nil, message)
	end))

	helpers.it("offers the repair, then the Finder when the same path refuses it again", scoped(function()
		local world = new_world()
		local _, router = load_world(world)
		speak("fr")
		local selection = {}
		helpers.assert_true(router.select_mlx(function(ok) selection[#selection + 1] = ok end))
		stream_lines(world.tasks[1], { "error: failed to create directory `/Users/fixture/.cache/uv`: Permission denied (os error 13)" })
		world.tasks[1].finish(2, "", "")
		helpers.assert_eq(selection, { false })
		helpers.assert_eq(#world.deferred, 1, "the failure must schedule its repair dialog")
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].primary, "Réparer l’installation MLX")
		helpers.assert_true(world.dialogs[1].body:find("/Users/fixture/.cache/uv", 1, true) ~= nil)
		helpers.assert_eq(#world.tasks, 2, "the button must start the repair")
		helpers.assert_true(world.tasks[2].command():find("ERGOPTI_MLX_REPAIR=1", 1, true) ~= nil,
			"the button runs the script in repair mode")

		-- The repair's own removal is refused on the same kind of path.
		stream_lines(world.tasks[2], {
			"rm: " .. MLX_VENV .. "/lib/python3.11: Permission denied",
			"[MLX-DEPS] ❌ Cannot remove '" .. MLX_VENV .. "': rm: " .. MLX_VENV .. "/lib/python3.11: Permission denied",
		})
		world.tasks[2].finish(6, "", "")
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 2)
		helpers.assert_eq(world.dialogs[2].primary, "Afficher dans le Finder",
			"a path refused again is shown, not repaired a third time")
		helpers.assert_true(world.dialogs[2].body:find("Corbeille", 1, true) ~= nil,
			"the dialog says what to do in the Finder")
		helpers.assert_eq(#world.spawns, 1)
		helpers.assert_eq(world.spawns[1].executable, "/usr/bin/open")
		helpers.assert_eq(world.spawns[1].args, { "-R", MLX_VENV },
			"the Finder shows the folder the repair could not remove")
	end))
end)





-- =================================================
-- =================================================
-- ======= 4/ Broken Runtime Is Never Reused =======
-- =================================================
-- =================================================

helpers.describe("A runtime whose import probe failed is repaired, never reused (mlx-bootstrap-partial-venv)", function()
	helpers.it("reads as not installed even when its fingerprint cannot be removed", scoped(function()
		local world = new_world({ installed = true })
		local checker, router = load_world(world)
		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(#world.tasks, 0)

		local original_remove = os.remove
		os.remove = function(path) return nil, path .. ": Permission denied", 13 end
		local ok, invalidated = pcall(checker.invalidate_runtime, {
			kind = "import_failed", repairable = true,
			line = "ModuleNotFoundError: No module named 'mlx'",
		})
		os.remove = original_remove
		helpers.assert_true(ok, tostring(invalidated))
		helpers.assert_true(invalidated, "a refused fingerprint removal must not keep the runtime installed")
		helpers.assert_eq(checker.runtime_installed(), false)
		helpers.assert_eq(router.is_installed("mlx"), false,
			"the menu must offer the install again, or re-selecting MLX does nothing")

		helpers.assert_true(checker.install_for_selection())
		helpers.assert_eq(#world.tasks, 1, "the next selection must repair the broken runtime")
		helpers.assert_true(world.tasks[1].command():find("ERGOPTI_MLX_REPAIR=1", 1, true) ~= nil,
			"a broken runtime is removed and rebuilt, not reused")

		world.tasks[1].finish(0, "", "")
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(checker.runtime_installed(), true, "a successful repair clears the broken flag")
	end))

	helpers.it("repairs from the dialog's button, then restarts the MLX model", scoped(function()
		local world = new_world({ installed = true })
		local checker, _, offer = load_world(world)
		speak("fr")
		local resumed = 0
		offer.set_resume(function() resumed = resumed + 1; return true end)
		local cause = {
			kind = "import_failed", repairable = true,
			line = "ModuleNotFoundError: No module named 'mlx'",
		}
		helpers.assert_true(checker.invalidate_runtime(cause))
		helpers.assert_true(offer.offer(cause))
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].title, "L’installation de MLX a échoué")
		helpers.assert_true(world.dialogs[1].body:find("Les paquets MLX sont installés mais ne se chargent pas.", 1, true) ~= nil,
			world.dialogs[1].body)
		helpers.assert_true(world.dialogs[1].body:find("No module named 'mlx'", 1, true) ~= nil,
			"the dialog quotes the probe's error")
		helpers.assert_eq(#world.tasks, 1)
		helpers.assert_true(world.tasks[1].command():find("ERGOPTI_MLX_REPAIR=1", 1, true) ~= nil)
		helpers.assert_eq(resumed, 0, "nothing restarts before the repair succeeded")
		world.tasks[1].finish(0, "", "")
		helpers.assert_eq(resumed, 0, "the restart leaves the installer's completion first")
		helpers.assert_eq(world.notices[#world.notices].title, "Installation MLX réparée")
		helpers.assert_eq(#world.deferred, 1, "a success schedules only the model restart")
		drain(world)
		helpers.assert_eq(resumed, 1, "a repaired runtime restarts the model it could not load")
		helpers.assert_eq(#world.dialogs, 1, "a success offers nothing more")
	end))
end)





-- ==============================================
-- ==============================================
-- ======= 5/ A Failure Is Always Retried =======
-- ==============================================
-- ==============================================

helpers.describe("Selecting MLX again after a failure retries it (mlx-bootstrap-retry)", function()
	helpers.it("offers the repair, and the next selection starts a new install", scoped(function()
		local world = new_world()
		local checker, router = load_world(world)
		local results = {}
		helpers.assert_true(router.select_mlx(function(ok) results[#results + 1] = ok end))
		stream_lines(world.tasks[1], { "curl: (6) Could not resolve host: astral.sh" })
		world.tasks[1].finish(1, "", "")
		helpers.assert_eq(results, { false })
		helpers.assert_eq(checker.get_failure_cause().kind, "network_unknown")
		helpers.assert_eq(#world.deferred, 1, "every failed selection offers its repair")
		world.answers = { "later" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(#world.tasks, 1, "« Later » starts nothing")

		helpers.assert_true(router.select_mlx(function(ok) results[#results + 1] = ok end))
		helpers.assert_eq(#world.tasks, 2, "a selection after a failure is never blocked")
		world.tasks[2].finish(0, "", "")
		helpers.assert_eq(results, { false, true })
		helpers.assert_eq(checker.get_failure_cause(), nil)
	end))
end)





-- =========================================================
-- =========================================================
-- ======= 6/ The Repair Removes Only Ergopti's Venv =======
-- =========================================================
-- =========================================================

helpers.describe("The MLX repair only removes the venv Ergopti owns (mlx-bootstrap-repair-owned)", function()
	helpers.it("repairs Ergopti's own venv in repair mode", scoped(function()
		local world = new_world({ installed = true })
		local checker = load_world(world)
		helpers.assert_eq(checker.owned_venv_dir(), MLX_VENV)
		helpers.assert_true(checker.install_for_selection(nil, { repair = true }))
		helpers.assert_eq(#world.tasks, 1, "the repair rebuilds even an installed runtime")
		helpers.assert_true(world.tasks[1].command():find("ERGOPTI_MLX_REPAIR=1", 1, true) ~= nil)
	end))

	helpers.it("refuses a venv that is a symbolic link", scoped(function()
		local world = new_world({ installed = true })
		world.links[MLX_VENV] = true
		local checker = load_world(world)
		speak("fr")
		local owned, refusal = checker.owned_venv_dir()
		helpers.assert_eq(owned, nil)
		helpers.assert_eq(refusal, "symbolic link")
		local results = {}
		helpers.assert_eq(checker.install_for_selection(function(ok) results[#results + 1] = ok end,
			{ repair = true }), false)
		helpers.assert_eq(results, { false })
		helpers.assert_eq(#world.tasks, 0, "nothing may run against a folder Ergopti does not own")
		helpers.assert_eq(checker.get_failure_cause().kind, "foreign_path")
		helpers.assert_true(checker.get_failure_message():find(MLX_VENV .. " n’est pas un dossier créé par ErgoptiPlus",
			1, true) ~= nil, checker.get_failure_message())
	end))

	helpers.it("refuses a venv path with a parent segment", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		local owned, refusal = checker.owned_venv_dir()
		helpers.assert_eq(owned, nil)
		helpers.assert_eq(refusal, "relative segment")
		helpers.assert_eq(checker.install_for_selection(nil, { repair = true }), false)
		helpers.assert_eq(#world.tasks, 0)
	end, {
		HOME = "/Users/fixture/../intruder",
		ERGOPTI_CONFIG_DIR = LAUNCHER_ENV.ERGOPTI_CONFIG_DIR,
	}))
end)





-- ============================================
-- ============================================
-- ======= 7/ A Mac That Cannot Run MLX =======
-- ============================================
-- ============================================

helpers.describe("A Mac that cannot run MLX is told so and offered Ollama (mlx-bootstrap-unsupported)", function()
	helpers.it("refuses an Intel Mac before any download and offers Ollama", scoped(function()
		local world = new_world({ uname = "x86_64" })
		local _, router, offer = load_world(world)
		speak("fr")
		offer.set_alternative(function()
			world.alternatives = world.alternatives + 1
			return true
		end)
		local results = {}
		helpers.assert_eq(router.select_mlx(function(ok) results[#results + 1] = ok end), false)
		helpers.assert_eq(results, { false })
		helpers.assert_eq(#world.tasks, 0, "nothing is downloaded for a Mac MLX cannot run on")
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].title, "MLX n’est pas disponible sur ce Mac")
		helpers.assert_true(world.dialogs[1].body:find("Ce Mac : processeur Intel, macOS 15.", 1, true) ~= nil,
			world.dialogs[1].body)
		helpers.assert_true(world.dialogs[1].body:find("Ollama et les serveurs locaux du menu IA", 1, true) ~= nil,
			world.dialogs[1].body)
		helpers.assert_eq(world.dialogs[1].primary, "Utiliser Ollama")
		helpers.assert_eq(world.alternatives, 1, "the button selects Ollama")
	end))

	helpers.it("shows one OK button, never a nil second one, when Ollama is not offered", scoped(function()
		local world = new_world({ uname = "x86_64" })
		local _, router = load_world(world)
		speak("fr")
		helpers.assert_eq(router.select_mlx(), false)
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].primary, "OK")
		helpers.assert_eq(world.dialogs[1].secondary, nil)
		helpers.assert_eq(world.dialogs[1].argument_count, 3,
			"a nil second button followed by a style is refused by the native alert")
	end))

	helpers.it("refuses macOS 13 on Apple Silicon, and lets an unreadable probe try", scoped(function()
		local world = new_world({ uname = "arm64", macos = "13.6.1" })
		local _, router = load_world(world)
		speak("fr")
		helpers.assert_eq(router.select_mlx(), false)
		helpers.assert_eq(#world.tasks, 0)
		drain(world)
		helpers.assert_true(world.dialogs[1].body:find("Ce Mac : Apple Silicon, macOS 13.", 1, true) ~= nil,
			world.dialogs[1].body)

		local unknown = new_world({ uname = "", macos = "" })
		local _, unknown_router = load_world(unknown)
		helpers.assert_true(unknown_router.select_mlx())
		helpers.assert_eq(#unknown.tasks, 1, "a probe that proves nothing never refuses")
	end))

	helpers.it("keeps the macOS floor equal to the oldest locked MLX wheel", function()
		local lock_path = helpers.driver_root() .. "uv.lock"
		local handle = assert(io.open(lock_path, "r"))
		local lock = handle:read("*a")
		handle:close()
		local oldest = nil
		-- One block per package; wheel arrays hold no blank line.
		for block in (lock .. "\n\n"):gmatch("%[%[package%]%]\n(.-)\n\n") do
			local name = block:match('^name = "([^"]+)"')
			if name == "mlx" or name == "mlx-metal" then
				for major in block:gmatch("macosx_(%d+)_%d+_arm64") do
					major = tonumber(major)
					if oldest == nil or major < oldest then oldest = major end
				end
			end
		end
		helpers.assert_eq(oldest, 14, "uv.lock must pin macOS-tagged mlx wheels")
		helpers.with_stub_scope({ "modules.llm.backend_detector" }, function()
			local Detector = helpers.load_with_stubs("modules.llm.backend_detector")
			helpers.assert_eq(Detector.MLX_MIN_MACOS_MAJOR, oldest,
				"a floor below the oldest wheel picks MLX where uv sync cannot install it")
		end)
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 8/ A Missing Runtime Offers Its Install ===
-- ==================================================
-- ==================================================

helpers.describe("A missing MLX runtime is announced with its install button (mlx-runtime-missing-install)", function()
	--- Posts the boot notice of a missing runtime, in French, and clicks it.
	--- @param world table
	local function click_boot_notice(world)
		-- The router captures its locale owner when it loads: load it again
		-- once the real French strings answer.
		speak("fr")
		package.loaded["ui.menu.menu_llm.runtime_install_offer"] = nil
		local router = require("ui.menu.menu_llm.runtime_install_offer")
		helpers.assert_true(router.notify_if_missing("mlx"))
		helpers.assert_eq(#world.notices, 1)
		local notice = world.notices[1]
		helpers.assert_eq(notice.title, "Le moteur MLX n’est pas installé")
		helpers.assert_eq(notice.body, "L’IA reste désactivée tant qu’il n’est pas installé. Cliquez pour l’installer.")
		helpers.assert_true(notice.body:find("Sélectionnez", 1, true) == nil,
			"the notice used to name the menu row to select, with no action of its own")
		helpers.assert_eq(type(notice.on_click), "function", "the notice carries the click that opens its fix")
		helpers.assert_eq(#world.tasks, 0, "the boot notice never downloads by itself")
		notice.on_click()
	end

	helpers.it("opens the install offer from the boot notice, whose button installs the runtime", scoped(function()
		local world = new_world()
		local checker, _, offer = load_world(world)
		local resumed = 0
		offer.set_resume(function() resumed = resumed + 1; return true end)
		click_boot_notice(world)
		helpers.assert_eq(#world.deferred, 1, "the click schedules the install offer")
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		local dialog = world.dialogs[1]
		helpers.assert_eq(dialog.title, "Le moteur MLX n’est pas installé")
		helpers.assert_eq(dialog.primary, "Installer le moteur MLX")
		helpers.assert_eq(dialog.secondary, "Plus tard")
		helpers.assert_true(dialog.body:find("« Installer le moteur MLX » télécharge et installe l’environnement MLX d’ErgoptiPlus ("
			.. MLX_VENV .. ").", 1, true) ~= nil, dialog.body)
		helpers.assert_true(dialog.body:find("Sélectionnez", 1, true) == nil, dialog.body)

		helpers.assert_eq(#world.tasks, 1, "the button runs the installation")
		helpers.assert_true(world.tasks[1].command():find("ensure-mlx-deps.sh", 1, true) ~= nil,
			world.tasks[1].command())
		helpers.assert_true(world.tasks[1].command():find("ERGOPTI_MLX_REPAIR=1", 1, true) == nil,
			"an absent runtime is installed, not repaired")
		world.tasks[1].finish(0, "", "")
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(world.notices[#world.notices].title, "Moteur MLX installé")
		helpers.assert_eq(resumed, 0, "the restart leaves the installer's completion first")
		drain(world)
		helpers.assert_eq(resumed, 1, "an installed runtime restarts the MLX model")
		helpers.assert_eq(#world.dialogs, 1, "a success offers nothing more")
	end))

	helpers.it("names why a failed install failed and retries it with the repair button", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		click_boot_notice(world)
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.tasks, 1)
		stream_lines(world.tasks[1], { "curl: (6) Could not resolve host: astral.sh" })
		world.tasks[1].finish(1, "", "")
		helpers.assert_eq(checker.get_failure_cause().kind, "network_unknown")

		-- The failure reopens the offer with its cause, in the words the three
		-- drivers share (network.failure.unknown), and the button that retries.
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 2)
		local failed = world.dialogs[2]
		helpers.assert_eq(failed.title, "L’installation de MLX a échoué")
		helpers.assert_true(failed.body:find(package.loaded["infra.i18n"].get("network.failure.unknown"), 1, true) ~= nil, failed.body)
		helpers.assert_true(failed.body:find("Could not resolve host: astral.sh", 1, true) ~= nil,
			"the dialog quotes the line that proves the cause")
		helpers.assert_eq(failed.primary, "Réessayer")
		helpers.assert_eq(failed.secondary, package.loaded["infra.i18n"].get("error_dialog.open_log"))
		helpers.assert_eq(#world.tasks, 2, "the repair button retries at once")
		helpers.assert_true(world.tasks[2].command() ~= "", "retry owns a real native command")
		helpers.assert_true(world.tasks[2].command():find("ERGOPTI_MLX_REPAIR=1", 1, true) == nil,
			"an unknown network failure retries without authorizing removal of a valid runtime")

		-- A repair that fails in turn says why, with the same button.
		stream_lines(world.tasks[2], { "curl: (6) Could not resolve host: astral.sh" })
		world.tasks[2].finish(1, "", "")
		world.answers = { "later" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 3)
		helpers.assert_eq(world.dialogs[3].primary, "Réessayer")
		helpers.assert_true(world.dialogs[3].body:find(package.loaded["infra.i18n"].get("network.failure.unknown"), 1, true) ~= nil,
			world.dialogs[3].body)
		helpers.assert_eq(#world.tasks, 2, "« Plus tard » starts nothing")
	end))

	helpers.it("offers the install, not a repair, when a model check finds no runtime", scoped(function()
		local world = new_world()
		local _, _, offer = load_world(world)
		speak("en")
		helpers.assert_true(offer.offer({ kind = "missing", repairable = true }))
		world.answers = { "secondary" }
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].title, "The MLX runtime is not installed")
		helpers.assert_eq(world.dialogs[1].primary, "Install the MLX runtime")
		helpers.assert_true(world.dialogs[1].body:find("Select the MLX backend", 1, true) == nil,
			world.dialogs[1].body)
		helpers.assert_eq(#world.tasks, 0, "« Later » starts nothing")
	end))

	-- hardening-h-no-rosetta: the installer's PTY wrapper is Python.
	helpers.it("starts no Intel Python for the installer and offers a native one", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		local offers = {}
		package.loaded["ui.python_runtime_offer"] = {
			offer = function(state) offers[#offers + 1] = state; return true end,
		}
		local intel = "\207\250\237\254" .. "\7\0\0\1" .. string.rep("\0", 24)
		package.loaded["adapters.python_interpreter"]._set_deps({
			read_head = function(path)
				if path == helpers.HEALTHY_PYTHON then return intel end
				return nil
			end,
			realpath = function(path) return path end,
			getenv = function() return nil end,
			select_link_target = function() return nil end,
			process_arch = function() return "arm64" end,
		})
		click_boot_notice(world)
		world.answers = { "primary" }
		drain(world)
		helpers.assert_eq(#world.tasks, 0, "no interpreter may start under Rosetta")
		helpers.assert_eq(checker.get_failure_cause().kind, "no_native_python")
		drain(world)
		helpers.assert_eq(#offers, 1, "the MLX offer hands the fix to the Python offer")
		helpers.assert_eq(offers[1].kind, "python_not_native")
		helpers.assert_eq(offers[1].found[1].path, helpers.HEALTHY_PYTHON)
		helpers.assert_eq(#world.dialogs, 1, "no MLX repair dialog for a Python it cannot repair")
	end))

	-- hardening-h-no-rosetta: a venv an Intel interpreter built on Apple silicon.
	helpers.it("never starts an installed venv on an Intel Python and repairs it natively", scoped(function()
		local world = new_world({ installed = true })
		local checker, router = load_world(world)
		local intel = "\207\250\237\254" .. "\7\0\0\1" .. string.rep("\0", 24)
		package.loaded["adapters.python_interpreter"]._set_deps({
			read_head = function(path)
				if path == MLX_VENV .. "/bin/python" then return intel end
				if path == helpers.HEALTHY_PYTHON then
					return "\202\254\186\190" .. "\0\0\0\2" .. "\1\0\0\7" .. string.rep("\0", 16)
						.. "\1\0\0\12" .. string.rep("\0", 16)
				end
				return nil
			end,
			realpath = function(path) return path end,
			getenv = function() return nil end,
			select_link_target = function() return nil end,
			process_arch = function() return "arm64" end,
		})
		local cause = checker.foreign_interpreter_cause()
		helpers.assert_eq(cause.kind, "venv_not_native")
		helpers.assert_eq(cause.archs, "x86_64")

		-- The boot check reuses no such runtime and starts nothing.
		local results = {}
		helpers.assert_true(checker.check_and_install_deps(function(ok) results[#results + 1] = ok end))
		helpers.assert_eq(results, { false })
		helpers.assert_eq(#world.tasks, 0, "the Intel interpreter is never started")
		helpers.assert_eq(checker.get_state(), "missing")
		helpers.assert_true(checker.is_runtime_broken())
		helpers.assert_eq(checker.get_failure_cause().kind, "venv_not_native")

		-- Selecting MLX repairs it, on the native interpreter, telling the script the processor.
		helpers.assert_true(router.select_mlx(function() end))
		helpers.assert_eq(#world.tasks, 1)
		helpers.assert_eq(world.tasks[1].executable, "/bin/bash")
		helpers.assert_true(world.tasks[1].command():find(
			"exec '" .. helpers.HEALTHY_PYTHON .. "' -u '/tmp/fixture-pty.py'", 1, true) ~= nil,
			"the acknowledged shell must exec only the independently admitted native Python")
		local command = world.tasks[1].command()
		helpers.assert_true(command:find("ERGOPTI_MLX_REPAIR=1", 1, true) ~= nil, command)
		helpers.assert_true(command:find("ERGOPTI_NATIVE_ARCH='\\''arm64'\\''", 1, true) ~= nil, command)
	end))
end)





-- ==================================================
-- ==================================================
-- ======= 8/ Managed Network Failure Classes =======
-- ==================================================
-- ==================================================

helpers.describe("A network failure names its class and its fixes (mlx-bootstrap-network-classes)", function()
	helpers.it("classifies uv's and curl's failures into the classes the drivers share", scoped(function()
		local world = new_world()
		load_world(world)
		local Diagnosis = require("modules.llm.mlx_bootstrap_diagnosis")
		local cases = {
			{ "network_unknown", {
				"error: Request failed after 3 retries",
				"  Caused by: Failed to download `https://github.com/astral-sh/python-build-standalone/x.tar.gz`",
				"  Caused by: error sending request for url (https://github.com/astral-sh/x.tar.gz)",
				"  Caused by: client error (Connect)",
				"  Caused by: invalid peer certificate: UnknownIssuer",
			} },
			-- A company filter denying uv network access: "Operation not permitted",
			-- once read as a file permission that offered to show a folder.
			{ "network_unknown", {
				"  Caused by: error sending request for url (https://files.pythonhosted.org/packages/mlx.whl)",
				"  Caused by: client error (Connect)",
				"  Caused by: tcp connect error: Operation not permitted (os error 1)",
			} },
			{ "network_unknown", {
				"Permission error: operation not permitted",
				"Request failed after 3 retries",
				"Caused by: failed to download URL",
				"Error sending request for URL",
			} },
			{ "network_unknown", { "curl: (56) CONNECT tunnel failed, response 407", "HTTP/1.1 407 Proxy Authentication Required" } },
			{ "network_unknown", { "curl: (6) Could not resolve host: files.pythonhosted.org" } },
			{ "permission", { "error: failed to create directory `/Users/u/Library/Application Support/Ergopti/mlx-venv`: Operation not permitted (os error 1)" } },
		}
		for _, case in ipairs(cases) do
			local cause = Diagnosis.classify(case[2], 1)
			helpers.assert_eq(cause.kind, case[1], table.concat(case[2], " | "))
			helpers.assert_true(cause.repairable, case[1] .. " is retried")
		end
	end))

	helpers.it("offers the network settings for a relay refusal and opens them", scoped(function()
		local world = new_world()
		local checker, router = load_world(world)
		speak("fr")
		helpers.assert_true(router.select_mlx(function() end))
		world.native_network_receipt = { backend = "curl", stage = "proxy_connect",
			failure_provenance = "verified", proxy_connect_status = 407 }
		stream_lines(world.tasks[1], { "HTTP/1.1 407 Proxy Authentication Required" })
		world.tasks[1].finish(1, "", "")
		helpers.assert_eq(checker.get_failure_cause().kind, "proxy")
		world.answers = { "secondary" }
		drain(world)
		local dialog = world.dialogs[#world.dialogs]
		helpers.assert_eq(dialog.choices[1], "Réessayer")
		helpers.assert_eq(dialog.choices[2], "Ouvrir les réglages du proxy")
		helpers.assert_true(dialog.body:find(package.loaded["infra.i18n"].get("network.failure.proxy"), 1, true) ~= nil, dialog.body)
		local spawn = world.spawns[#world.spawns]
		helpers.assert_eq(spawn.executable, "/usr/bin/open")
		helpers.assert_eq(spawn.args[1], "x-apple.systempreferences:com.apple.Network-Settings.extension")
		helpers.assert_eq(#world.tasks, 1, "opening the settings starts no install")
	end))

	helpers.it("offers Ollama for a blocked host, and never a folder to show", scoped(function()
		local world = new_world()
		local checker, router, offer = load_world(world)
		speak("fr")
		offer.set_alternative(function() world.alternatives = world.alternatives + 1; return true end)
		helpers.assert_true(router.select_mlx(function() end))
		world.native_network_receipt = { backend = "native_socket", stage = "connect",
			failure_provenance = "verified", native_errno_domain = "posix", native_errno = "EACCES" }
		stream_lines(world.tasks[1], {
			"  Caused by: error sending request for url (https://files.pythonhosted.org/packages/mlx.whl)",
			"  Caused by: tcp connect error: Operation not permitted (os error 1)",
		})
		world.tasks[1].finish(1, "", "")
		helpers.assert_eq(checker.get_failure_cause().kind, "host_blocked")
		world.answers = { "secondary" }
		drain(world)
		local dialog = world.dialogs[#world.dialogs]
		helpers.assert_eq(dialog.choices[1], "Réessayer")
		helpers.assert_eq(dialog.choices[2], "Utiliser Ollama")
		helpers.assert_true(dialog.body:find("Le réseau bloque l'accès à ce serveur", 1, true) ~= nil, dialog.body)
		helpers.assert_eq(world.alternatives, 1, "« Utiliser Ollama » selects Ollama")
		offer.set_alternative(nil)
	end))
end)





-- =============================================
-- =============================================
-- ======= 10/ Network Failure Ownership =======
-- =============================================
-- =============================================

helpers.describe("Managed network failure actions retain their native revision", function()
	local function failed_world(installed, receipt, expected_kind)
		local world = new_world({ installed = installed == true })
		local checker, router, offer = load_world(world)
		world.native_network_receipt = receipt
		speak("en")
		helpers.assert_true(checker.install_for_selection(nil, installed and { repair = true } or nil))
		stream_lines(world.tasks[1], { "curl: (35) SSL connect error" })
		world.tasks[1].finish(1, "", "")
		local cause = checker.get_failure_cause()
		helpers.assert_eq(cause.kind, expected_kind or "network_unknown", "only the controlled native receipt can establish a network cause")
		helpers.assert_true(checker.failure_action_admitted(cause.failure_revision))
		return world, checker, router, offer, cause
	end

	helpers.it("managed-network-revision: failure copies retain one monotonic action revision", scoped(function()
		local world, checker, _, _, first = failed_world(false)
		local copy = checker.get_failure_cause()
		helpers.assert_true(first ~= copy, "the getter intentionally returns copies")
		helpers.assert_eq(first.failure_revision, copy.failure_revision)
		helpers.assert_true(checker.reset_bootstrap_state())
		helpers.assert_eq(false, checker.failure_action_admitted(first.failure_revision), "clearing the failure retires its dialog")
		helpers.assert_true(checker.install_for_selection())
		stream_lines(world.tasks[2], { "HTTP 403 Forbidden" })
		world.tasks[2].finish(1, "", "")
		local second = checker.get_failure_cause()
		helpers.assert_true(second.failure_revision > first.failure_revision)
		helpers.assert_true(checker.failure_action_admitted(second.failure_revision))
		helpers.assert_eq(false, checker.failure_action_admitted(first.failure_revision))
	end))

	helpers.it("managed-network-retry: unknown failure reuses a valid runtime without full repair", scoped(function()
		local world, checker, _, offer, first = failed_world(true)
		world.answers = { "primary" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].primary, package.loaded["infra.i18n"].get("network.action.retry"))
		helpers.assert_eq(#world.tasks, 1, "normal retry reuses valid Python and fingerprint, rather than launching repair")
		helpers.assert_true(world.files[MLX_VENV .. "/bin/python"])
		helpers.assert_true(world.files[MLX_VENV .. "/.last_sync_hash"])
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_nil(checker.get_failure_cause())
		helpers.assert_eq(false, checker.failure_action_admitted(first.failure_revision))
	end))


	helpers.it("managed-network-filesystem: typed permission retains canonical retry without rebuilding runtime", scoped(function()
		local world, checker, _, offer, first = failed_world(true, {
			backend = "native_fs", stage = "file_write", failure_provenance = "verified",
			native_errno_domain = "posix", native_errno = "EACCES",
		}, "permission")
		world.answers = { "primary" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(world.dialogs[1].choices[1], package.loaded["infra.i18n"].get("network.action.retry"))
		helpers.assert_eq(#world.tasks, 1, "typed download file failure never forces a valid runtime rebuild")
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_true(world.files[MLX_VENV .. "/bin/python"])
	end))

	helpers.it("managed-network-filesystem: typed disk failure retains canonical retry without rebuilding runtime", scoped(function()
		local world, checker, _, offer, first = failed_world(true, {
			backend = "native_fs", stage = "file_write", failure_provenance = "verified",
			native_errno_domain = "posix", native_errno = "ENOSPC",
		}, "disk_full")
		world.answers = { "primary" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(world.dialogs[1].choices[1], package.loaded["infra.i18n"].get("network.action.retry"))
		helpers.assert_eq(#world.tasks, 1, "typed download disk failure never forces a valid runtime rebuild")
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_true(world.files[MLX_VENV .. "/bin/python"])
	end))

	helpers.it("managed-network-modal: a newer failure rejects the retained retry choice", scoped(function()
		local world, checker, router, offer, first = failed_world(false)
		local calls = 0
		local original_select = router.select_mlx
		router.select_mlx = function(...)
			calls = calls + 1
			return original_select(...)
		end
		local original_choose = package.loaded["infra.dialog_util"].choose
		package.loaded["infra.dialog_util"].choose = function(...)
			local selected = original_choose(...)
			helpers.assert_true(checker.reset_bootstrap_state())
			helpers.assert_true(checker.install_for_selection())
			stream_lines(world.tasks[2], { "HTTP 451 unavailable" })
			world.tasks[2].finish(1, "", "")
			return selected
		end
		world.answers = { "primary" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(#world.tasks, 2, "a retained modal result cannot dispatch a third task")
		helpers.assert_eq(calls, 0, "stale choice never reaches the real selection router")
		helpers.assert_true(checker.get_failure_cause().failure_revision > first.failure_revision)
		helpers.assert_eq(false, checker.failure_action_admitted(first.failure_revision))
	end))

	helpers.it("managed-network-modal: a live successor install rejects retained retry admission", scoped(function()
		local world, checker, router, offer, first = failed_world(false)
		local calls = 0
		local original_select = router.select_mlx
		router.select_mlx = function(...)
			calls = calls + 1
			return original_select(...)
		end
		local original_choose = package.loaded["infra.dialog_util"].choose
		package.loaded["infra.dialog_util"].choose = function(...)
			local selected = original_choose(...)
			helpers.assert_true(checker.reset_bootstrap_state())
			helpers.assert_true(checker.install_for_selection())
			helpers.assert_true(checker.is_task_running())
			return selected
		end
		world.answers = { "primary" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(#world.tasks, 2)
		helpers.assert_eq(calls, 0, "retained failure cannot join or borrow the new native installation owner")
		helpers.assert_eq(false, offer.retry_failure(first.failure_revision))
		world.tasks[2].finish(0, "", "")
	end))


	local function host_policy_receipt()
		return { backend = "native_socket", stage = "connect", failure_provenance = "verified",
			native_errno_domain = "posix", native_errno = "EACCES" }
	end

	helpers.it("managed-network-alternative: a newer failure rejects the retained alternate choice", scoped(function()
		local world, checker, _, offer, first = failed_world(false, host_policy_receipt(), "host_blocked")
		offer.set_alternative(function() world.alternatives = world.alternatives + 1; return true end)
		local original_choose = package.loaded["infra.dialog_util"].choose
		package.loaded["infra.dialog_util"].choose = function(...)
			local selected = original_choose(...)
			helpers.assert_true(checker.reset_bootstrap_state())
			helpers.assert_true(checker.install_for_selection())
			stream_lines(world.tasks[2], { "HTTP 451 unavailable" })
			world.tasks[2].finish(1, "", "")
			return selected
		end
		world.answers = { "secondary" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(world.dialogs[1].choices[2], package.loaded["infra.i18n"].get("mlx.use_ollama"))
		helpers.assert_eq(world.alternatives, 0, "a stale alternate choice cannot borrow the successor failure revision")
		helpers.assert_eq(#world.tasks, 2)
		helpers.assert_true(checker.get_failure_cause().failure_revision > first.failure_revision)
		offer.set_alternative(nil)
	end))

	helpers.it("managed-network-alternative: missing actual selection never offers a backend action", scoped(function()
		local world, _, _, offer, first = failed_world(false, host_policy_receipt(), "host_blocked")
		offer.set_alternative(nil)
		world.answers = { "later" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		local labels = package.loaded["infra.i18n"]
		helpers.assert_eq(#world.dialogs[1].choices, 3)
		helpers.assert_eq(world.dialogs[1].choices[1], labels.get("network.action.retry"))
		helpers.assert_eq(world.dialogs[1].choices[2], labels.get("network.action.open_proxy_settings"))
		helpers.assert_eq(world.dialogs[1].choices[3], labels.get("error_dialog.open_log"))
		helpers.assert_eq(world.alternatives, 0)
	end))

	helpers.it("managed-network-modal: unavailable diagnostics never creates an actionable row", scoped(function()
		local world, _, _, offer, first = failed_world(false)
		package.loaded["infra.logger"].today_log_path = function() return nil end
		world.answers = { "later" }
		helpers.assert_true(offer.offer(first))
		drain(world)
		helpers.assert_eq(#world.dialogs[1].choices, 1)
		helpers.assert_eq(world.dialogs[1].choices[1], package.loaded["infra.i18n"].get("network.action.retry"))
		helpers.assert_eq(#world.spawns, 0)
	end))
end)

helpers.describe("MLX trusted bootstrap network admission", function()
	helpers.it("native PTY output cannot borrow the Python prelude admission", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		package.loaded["adapters.python_interpreter"]._set_deps({
			read_head = function() return nil end,
			realpath = function(path) return path end,
			getenv = function() return nil end,
			select_link_target = function() return nil end,
			process_arch = function() return "arm64" end,
		})
		local settled = false
		package.loaded["adapters.native_bootstrap_pty"] = {
			prepare = function(_, _, budget)
				return {
					executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
					arguments = { "--managed-pty-worker", tostring(budget) },
					bind_input = function() return true end,
					mark_start_attempted = function() return true end,
					rollback = function() return true end,
					settle = function(status)
						helpers.assert_eq(status, 78)
						settled = true
						return true
					end,
				}, true
			end,
		}
		speak("en")
		helpers.assert_true(checker.install_for_selection())
		local task = world.tasks[1]
		helpers.assert_eq(task.executable, "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus")
		task.emit("", "__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n")
		task.finish(78)
		helpers.assert_true(settled, "the native receipt owner retains terminal settlement")
		local cause = checker.get_failure_cause()
		helpers.assert_true(cause.kind ~= "proxy")
		helpers.assert_nil(cause.network_report)
	end))
	helpers.it("reports the pre-child automatic-route refusal using central proxy policy", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("en")
		helpers.assert_true(checker.install_for_selection())
		local task = world.tasks[1]

		task.emit("", "__ERGOPTI_OPAQUE_")
		task.emit("", "ADMISSION_V1__:refused:verified:unavailable\n")
		task.finish(78)
		local cause = checker.get_failure_cause()
		helpers.assert_eq(cause.kind, "proxy")
		helpers.assert_eq(cause.network_report.message_key, "network.failure.proxy")
		helpers.assert_eq(cause.network_report.evidence, "verified_proxy_resolution_unavailable")
		helpers.assert_true(checker.has_failed())
		helpers.assert_eq(task.executable, "/bin/bash")
		local command = task.command()
		local accepted = assert(command:find("__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted", 1, true))
		local execution = assert(command:find("exec ", 1, true))
		helpers.assert_true(accepted < execution, "trusted admission precedes the interpreter and installer")
		helpers.assert_true(command:sub(1, 2) == "( ", "the route exports stay in the admission subshell")
	end))
	helpers.it("accepted admission makes later child refusal frames non-authoritative", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("en")
		helpers.assert_true(checker.install_for_selection())
		world.tasks[1].emit("", "__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n")
		world.tasks[1].emit("", "__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n")
		world.tasks[1].finish(78)
		local cause = checker.get_failure_cause()
		helpers.assert_true(cause.kind ~= "proxy")
		helpers.assert_nil(cause.network_report)
	end))
	helpers.it("bare exit78 and wrong terminal never mint proxy authority", scoped(function()
		for _, row in ipairs({ { code = 78, stderr = "ordinary failure\n" },
			{ code = 1, stderr = "__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n" } }) do
			local world = new_world()
			local checker = load_world(world)
			speak("en")
			helpers.assert_true(checker.install_for_selection())
			world.tasks[1].finish(row.code, "", row.stderr)
			local cause = checker.get_failure_cause()
			helpers.assert_true(cause.kind ~= "proxy")
			helpers.assert_nil(cause.network_report)
		end
	end))
end)

helpers.describe("MLX native bootstrap admission", function()
	helpers.it("mlx-native-bootstrap-admission: the actual Python launcher admits the native receiver before installer dispatch", scoped(function()
		local world = new_world()
		local checker = load_world(world)
		speak("en")
		helpers.assert_true(checker.install_for_selection())
		local command = world.tasks[1].command()
		local receiver = assert(command:find("s.loader.exec_module(m); m._resolve_worker()", 1, true),
			"native wheel staging must not be rejected by the opaque-only gate")
		local execution = assert(command:find("exec ", 1, true))
		helpers.assert_true(receiver < execution, "identity admission precedes the actual Python PTY")
		helpers.assert_true(command:find("${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}", 1, true) ~= nil,
			"the original explicit route keeps its lower-case-first precedence")
		helpers.assert_true(command:find("managed_bootstrap_http.py", 1, true) ~= nil,
			"the native branch requires the actual installed staging helper")
		local Network = package.loaded["modules.llm.network_env"]
		local FileSystem = package.loaded["adapters.file_system"]
		local exists = FileSystem.exists
		FileSystem.exists = function(path)
			if path:sub(-#"/platform/network/native_http.py") == "/platform/network/native_http.py" then return false end
			return exists(path)
		end
		local prelude = Network.bootstrap_prelude("TEST", "/owned/python")
		local managed = Network.managed_http_prelude("TEST")
		FileSystem.exists = exists
		helpers.assert_type(prelude, "string", "manual/explicit branches must not require the unused native receiver")
		helpers.assert_nil(managed, "the public native-only owner still requires its receiver")
	end))
end)
