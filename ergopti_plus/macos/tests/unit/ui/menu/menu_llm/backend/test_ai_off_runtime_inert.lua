--- tests/unit/ui/menu/menu_llm/backend/test_ai_off_runtime_inert.lua

--- ==============================================================================
--- MODULE: AI Off Runtime Inertness Regression
--- DESCRIPTION:
--- With the AI switched off, the macOS driver bound every profile shortcut,
--- resumed the MLX download a reload interrupted, and ran `ollama list` from
--- the models manager constructor and every menu build. Windows and Linux keep
--- the AI inert until the switch-on. These cases drive the real startup
--- controller, trigger orchestrator and Ollama models manager behind fakes that
--- count bound hotkeys, spawned tasks and armed timers, then walk the switch
--- through on, off and on again (ai-off-inert-macos-2026-10-22).
--- ==============================================================================

local helpers = require("tests.helpers")

local OFF_MESSAGE = "Restored AI menu state activated with the AI off: its hotkeys and probes wait for the switch-on."





-- ==================================
-- ==================================
-- ======= 1/ Shared Fakes ==========
-- ==================================
-- ==================================

--- Builds a logger stub that records every formatted INFO line.
--- @return table logger, table lines
local function recording_logger()
	local logger = helpers.make_logger_stub()
	local lines = {}
	logger.info = function(_, fmt, ...)
		local ok, text = pcall(string.format, tostring(fmt), ...)
		lines[#lines + 1] = ok and text or tostring(fmt)
	end
	return logger, lines
end

--- Whether one recorded line equals the expected text.
--- @param lines table Recorded lines.
--- @param expected string Exact text.
--- @return boolean
local function logged(lines, expected)
	for _, line in ipairs(lines) do
		if line == expected then return true end
	end
	return false
end

--- Builds a one-shot timer scheduler that counts live timers.
--- @return table scheduler, table timers
local function counting_scheduler()
	local timers = {}
	local scheduler = {}
	function scheduler.after(delay, callback)
		local handle = { timer = {}, observers = {}, delay = delay, callback = callback }
		timers[#timers + 1] = handle
		return handle, true
	end
	function scheduler.cancel(handle)
		handle.timer = nil
		local observers = handle.observers
		handle.observers = {}
		for _, observer in ipairs(observers) do observer() end
		return true
	end
	function scheduler.onSettled(handle, observer)
		if handle.timer == nil then observer() else handle.observers[#handle.observers + 1] = observer end
		return true
	end
	function scheduler.fire(handle)
		if handle.timer == nil then return false end
		handle.timer = nil
		local observers = handle.observers
		handle.observers = {}
		local result = handle.callback()
		for _, observer in ipairs(observers) do observer() end
		return result
	end
	function scheduler.live()
		local count = 0
		for _, handle in ipairs(timers) do if handle.timer ~= nil then count = count + 1 end end
		return count
	end
	return scheduler, timers
end

--- Runs a body with exact module cache restoration.
--- @param names table Module names the body replaces.
--- @param body function Fixture body.
local function with_modules(names, body)
	local saved_hs = _G.hs
	local ok, err = xpcall(function() helpers.with_fresh_modules(names, body) end, debug.traceback)
	_G.hs = saved_hs
	if not ok then error(err, 0) end
end





-- ========================================
-- ========================================
-- ======= 2/ Startup Controller ==========
-- ========================================
-- ========================================

local STARTUP_MODULES = {
	"adapters.timer_scheduler",
	"adapters.json_codec",
	"infra.logger",
	"modules.llm",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.startup_controller",
	"ui.menu.menu_llm.requirement_operation_registry",
}

--- Builds the real startup controller with counting collaborators.
--- @param body function Receives the fixture.
local function with_startup(body)
	with_modules(STARTUP_MODULES, function()
		local logger, lines = recording_logger()
		local scheduler, timers = counting_scheduler()
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.timer_scheduler"] = scheduler
		package.loaded["adapters.json_codec"] = {
			decode = function() return { log_path = "/tmp/fixture.log" } end,
		}
		package.loaded["modules.llm"] = { BUILTIN_PROFILES = { { id = "basic" } } }
		package.loaded["ui.menu.menu_llm.prediction_lock_registry"] = {
			new = function() error("the fixture injects the exact lock registry") end,
		}
		package.loaded["ui.menu.menu_llm.startup_controller"] = nil
		local Startup = require("ui.menu.menu_llm.startup_controller")
		local fixture = {
			lines = lines, timers = timers, scheduler = scheduler,
			applies = 0, activations = 0, reattaches = 0, installed_reads = 0,
		}
		local state = {
			llm_enabled = false,
			llm_backend = "mlx",
			llm_profile_shortcuts = { basic = { mods = { "cmd" }, key = "b" } },
		}
		fixture.state = state
		local script_control = {
			get_pause_epoch = function() return 0 end,
			is_paused = function() return false end,
			is_pause_transition_pending = function() return false end,
			register_pause_owner = function() return true end,
		}
		fixture.check_startup, fixture.scope_idle, fixture.runtime = Startup.new({
			state = state,
			keymap = {},
			models_mgr = {
				create_requirement_owner = function() return {} end,
				pause_requirements = function() return true end,
				get_installed_models = function()
					fixture.installed_reads = fixture.installed_reads + 1
					return {}
				end,
				reattach_download = function()
					fixture.reattaches = fixture.reattaches + 1
					return true
				end,
				has_reattached_download = function() return false end,
			},
			guarded_check_requirements = function() return true end,
			save_prefs = function() return true end,
			update_menu = function() return true end,
			apply_llm_profile_shortcut = function()
				fixture.applies = fixture.applies + 1
				return true
			end,
			activate_hotkey = function()
				fixture.activations = fixture.activations + 1
				return true
			end,
			mlx_deps_checker = {},
			runtime_installed = function() return true end,
			deps = { script_control = script_control, update_menu = function() return true end },
			get_startup_silence = function() return false end,
			set_startup_silence = function() return true end,
			get_profile_hks = function() return { basic = "hotkey#1" } end,
			prediction_locks = {
				apply_preference = function() return true end,
				acquire = function() return true end,
				release = function() return true end,
				ensure_locked = function() return true end,
			},
		})
		--- Fires one reattachment timer with a present download session file.
		function fixture.fire(handle)
			local saved_open = io.open
			io.open = function(path, mode)
				if path == "/tmp/hs_mlx_active_download.json" then
					return { read = function() return "{}" end, close = function() return true end }
				end
				return saved_open(path, mode)
			end
			local ok, err = xpcall(function() return scheduler.fire(handle) end, debug.traceback)
			io.open = saved_open
			if not ok then error(err, 0) end
		end
		body(fixture)
	end)
end

helpers.describe("AI off: the startup controller stays inert (ai-off-inert-macos-2026-10-22)", function()
	helpers.it("binds no shortcut and arms no timer when the AI boots off", function()
		with_startup(function(f)
			helpers.assert_true(f.check_startup())
			helpers.assert_eq(#f.timers, 0, "no download reattachment timer may be armed with the AI off")
			helpers.assert_eq(f.applies, 0, "no profile shortcut may be bound with the AI off")
			helpers.assert_eq(f.activations, 0, "no hotkey may be activated with the AI off")
			helpers.assert_eq(f.installed_reads, 0, "no installed-model probe may run with the AI off")
			helpers.assert_true(logged(f.lines, OFF_MESSAGE),
				"the off boot logs the shared lifecycle line Windows writes")
			helpers.assert_true(f.scope_idle(), "an inert off boot leaves the startup scope idle")
		end)
	end)

	helpers.it("logs the very line the Windows driver writes for the same boot", function()
		local path = helpers.driver_root() .. "../windows/ui/menu/menu_llm/init.ahk"
		local file = assert(io.open(path, "rb"))
		local source = file:read("*a")
		assert(file:close())
		helpers.assert_true(source:find(OFF_MESSAGE, 1, true) ~= nil,
			"the off-boot lifecycle line must stay identical on Windows and macOS")
	end)

	helpers.it("arms the download reattachment on switch-on and disarms it on switch-off", function()
		with_startup(function(f)
			helpers.assert_true(f.check_startup())
			helpers.assert_type(f.runtime, "table", "the controller exposes its switch owner")

			f.state.llm_enabled = true
			helpers.assert_true(f.runtime.arm())
			helpers.assert_eq(f.scheduler.live(), 1, "the switch-on arms the reattachment once")
			helpers.assert_true(f.runtime.arm())
			helpers.assert_eq(f.scheduler.live(), 1, "a repeated switch-on arms no sibling")

			f.state.llm_enabled = false
			helpers.assert_true(f.runtime.disarm())
			helpers.assert_eq(f.scheduler.live(), 0, "the switch-off cancels the pending reattachment")
			helpers.assert_eq(f.reattaches, 0)

			f.state.llm_enabled = true
			helpers.assert_true(f.runtime.arm())
			helpers.assert_eq(f.scheduler.live(), 1, "switching on again re-arms the reattachment")
			f.fire(f.timers[#f.timers])
			helpers.assert_eq(f.reattaches, 1, "the re-armed reattachment runs once")
			helpers.assert_true(f.runtime.arm())
			helpers.assert_eq(f.scheduler.live(), 0, "a consumed reattachment is not armed twice")
		end)
	end)

	helpers.it("keeps the reattachment and shortcuts of a boot with the AI on", function()
		with_startup(function(f)
			f.state.llm_enabled = true
			helpers.assert_true(f.check_startup())
			helpers.assert_eq(f.scheduler.live(), 1, "the AI-on boot still arms its reattachment")
			helpers.assert_eq(f.applies, 1)
			helpers.assert_eq(f.activations, 1)
			helpers.assert_true(not logged(f.lines, OFF_MESSAGE))
		end)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 3/ Trigger Orchestrator ==========
-- ==========================================
-- ==========================================

local ORCHESTRATOR_MODULES = {
	"infra.logger",
	"modules.llm",
	"chord",
	"adapters.hotkey_registrar",
	"ui.menu.shortcut_utils",
	"ui.menu.menu_llm.trigger_orchestrator",
}

--- Builds the real orchestrator over a registrar that counts live bindings.
--- @param body function Receives the fixture.
local function with_orchestrator(body)
	with_modules(ORCHESTRATOR_MODULES, function()
		local logger, lines = recording_logger()
		package.loaded["infra.logger"] = logger
		package.loaded["modules.llm"] = { BUILTIN_PROFILES = { { id = "basic" }, { id = "advanced" } } }
		package.loaded["chord"] = {
			format = function(mods, key) return table.concat(mods, "+") .. "+" .. key end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {
			normalize_shortcut = function(mods, key)
				if type(mods) ~= "table" or type(key) ~= "string" then return nil end
				return { mods = mods, key = key }
			end,
		}
		local bindings = {}
		local next_token = 0
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function(chord)
				next_token = next_token + 1
				local handle = "hotkey#" .. next_token
				bindings[handle] = { chord = chord, enabled = true }
				return handle
			end,
			setEnabled = function(handle, enabled)
				if not bindings[handle] then return false end
				bindings[handle].enabled = enabled == true
				return true
			end,
			unbind = function(handle)
				bindings[handle] = nil
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = nil
		local state = {
			llm_enabled = false,
			llm_active_profile = "basic",
			llm_user_profiles = {},
			llm_profile_shortcuts = {
				basic = { mods = { "cmd" }, key = "b" },
				advanced = { mods = { "cmd" }, key = "a" },
			},
		}
		local profile_hks = {}
		local saves = 0
		local orchestrator = require("ui.menu.menu_llm.trigger_orchestrator").new({
			state = state,
			keymap = { reset_predictions = function() return true end, trigger_prediction = function() end },
			save_prefs = function() saves = saves + 1; return true end,
			update_menu = function() return true end,
			get_profile_hks = function() return profile_hks end,
			set_profile_hk = function(id, value) profile_hks[id] = value end,
		})
		body({
			state = state,
			orchestrator = orchestrator,
			lines = lines,
			profile_hks = profile_hks,
			saves = function() return saves end,
			bound = function()
				local count = 0
				for _ in pairs(bindings) do count = count + 1 end
				return count
			end,
			enabled = function()
				local count = 0
				for _, binding in pairs(bindings) do if binding.enabled then count = count + 1 end end
				return count
			end,
		})
	end)
end

helpers.describe("AI off: profile shortcuts bind nothing (ai-off-inert-macos-2026-10-22)", function()
	helpers.it("keeps a shortcut set while the AI is off as a preference only", function()
		with_orchestrator(function(f)
			helpers.assert_true(f.orchestrator.apply_llm_profile_shortcut("basic", { "ctrl" }, "p"))
			helpers.assert_eq(f.bound(), 0, "a shortcut chosen with the AI off binds no hotkey")
			helpers.assert_eq(f.state.llm_profile_shortcuts.basic.key, "p", "the choice is still kept")
			helpers.assert_eq(f.saves(), 1, "the choice is still saved")
			helpers.assert_true(f.orchestrator.restore_shortcuts({
				llm_profile_shortcuts = f.state.llm_profile_shortcuts,
			}))
			helpers.assert_eq(f.bound(), 0, "a restored snapshot binds nothing with the AI off")
		end)
	end)

	helpers.it("binds on switch-on, releases on switch-off, and binds again", function()
		with_orchestrator(function(f)
			helpers.assert_eq(f.bound(), 0)
			f.state.llm_enabled = true
			helpers.assert_true(f.orchestrator.arm_shortcuts())
			helpers.assert_eq(f.bound(), 2, "the switch-on binds every saved profile shortcut")
			helpers.assert_eq(f.enabled(), 2, "and delivers them")
			helpers.assert_true(logged(f.lines, "AI profile shortcuts armed: 2 bound."))
			helpers.assert_true(f.orchestrator.arm_shortcuts())
			helpers.assert_eq(f.bound(), 2, "a repeated switch-on binds no duplicate")

			f.state.llm_enabled = false
			helpers.assert_true(f.orchestrator.disarm_shortcuts())
			helpers.assert_eq(f.bound(), 0, "the switch-off releases every profile hotkey")
			helpers.assert_eq(next(f.profile_hks), nil)
			helpers.assert_eq(f.state.llm_profile_shortcuts.basic.key, "b", "the preferences survive")
			helpers.assert_true(logged(f.lines, "AI profile shortcuts disarmed: 2 released."))

			f.state.llm_enabled = true
			helpers.assert_true(f.orchestrator.arm_shortcuts())
			helpers.assert_eq(f.bound(), 2, "switching on again binds them again")
			helpers.assert_eq(f.enabled(), 2)
		end)
	end)
end)





-- =========================================
-- =========================================
-- ======= 4/ Ollama Models Manager ========
-- =========================================
-- =========================================

local OLLAMA_MODULES = {
	"infra.notifications",
	"infra.logger",
	"infra.i18n",
	"infra.text_utils",
	"modules.llm.ollama_binary",
	"core.llm.ollama_runtime_choice",
	"modules.llm.ollama_server_command",
	"modules.llm.network_env",
	"adapters.managed_ollama_pull",
	"modules.llm.opaque_network_admission",
	"modules.llm.ollama_endpoint",
	"adapters.shell_runner",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"adapters.http_client",
	"ui.download_window",
	"ui.menu.menu_llm.requirement_operation_registry",
	"ui.menu.menu_llm.models_manager_ollama",
}

--- Builds the real Ollama models manager over counting task and timer ports.
--- @param enabled boolean AI switch at construction.
--- @param body function Receives the fixture.
local function with_ollama_manager(enabled, body)
	with_modules(OLLAMA_MODULES, function()
		local scheduler = counting_scheduler()
		local tasks = {}
		local hs_tasks = 0
		_G.hs = {
			timer = {
				secondsSinceEpoch = function() return 100 end,
				doAfter = function() error("the manager must schedule through TimerScheduler") end,
			},
			task = { new = function() hs_tasks = hs_tasks + 1; return nil end },
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.text_utils"] = {}
		package.loaded["modules.llm.ollama_binary"] = {
			resolve = function() return "/opt/homebrew/bin/ollama", nil, "homebrew" end,
		}
		package.loaded["core.llm.ollama_runtime_choice"] = {}
		package.loaded["modules.llm.ollama_server_command"] = {}
		package.loaded["modules.llm.network_env"] = {}
		package.loaded["adapters.managed_ollama_pull"] = {}
		package.loaded["modules.llm.opaque_network_admission"] = {}
		package.loaded["modules.llm.ollama_endpoint"] = {
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["adapters.shell_runner"] = {}
		package.loaded["adapters.http_client"] = {}
		package.loaded["ui.download_window"] = {}
		package.loaded["adapters.timer_scheduler"] = scheduler
		package.loaded["adapters.task_lifecycle"] = {
			native = function(label, executable, on_done, args)
				local task = { label = label, executable = executable, args = args, on_done = on_done }
				function task:isRunning() return false end
				function task:terminate() return self end
				tasks[#tasks + 1] = task
				return task
			end,
			start = function() return true end,
		}
		package.loaded["ui.menu.menu_llm.requirement_operation_registry"] = nil
		package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
		local state = { llm_enabled = enabled }
		local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
			active_tasks = {},
			save_prefs = function() return true end,
			update_menu = function() return true end,
			state = state,
			keymap = {},
		}, {}, function() return 0 end)
		body({
			manager = manager,
			state = state,
			scheduler = scheduler,
			tasks = tasks,
			hs_tasks = function() return hs_tasks end,
			lists = function()
				local count = 0
				for _, task in ipairs(tasks) do
					if type(task.args) == "table" and task.args[1] == "list" then count = count + 1 end
				end
				return count
			end,
		})
	end)
end

helpers.describe("AI off: no `ollama list` runs (ai-off-inert-macos-2026-10-22)", function()
	helpers.it("constructs the manager without a timer or a task while the AI is off", function()
		with_ollama_manager(false, function(f)
			helpers.assert_eq(f.scheduler.live(), 0, "no warm-up timer may be armed with the AI off")
			helpers.assert_eq(#f.tasks, 0, "no task may be spawned with the AI off")
			helpers.assert_eq(f.hs_tasks(), 0)
			helpers.assert_type(f.manager.get_installed_models(), "table")
			helpers.assert_eq(f.lists(), 0, "a menu build with the AI off runs no `ollama list`")
		end)
	end)

	helpers.it("refreshes installed models once the AI is switched on, and stops when off", function()
		with_ollama_manager(false, function(f)
			f.state.llm_enabled = true
			f.manager.get_installed_models()
			helpers.assert_eq(f.lists(), 1, "the switch-on lets the menu read installed models")
			f.tasks[1].on_done(0, "NAME ID\nqwen:latest x\n", "")
			helpers.assert_eq(f.manager.get_installed_models()["qwen:latest"], true)

			f.state.llm_enabled = false
			f.manager.get_installed_models()
			helpers.assert_eq(f.lists(), 1, "the switch-off stops the refreshes again")
		end)
	end)

	helpers.it("keeps the warm-up refresh of a manager built with the AI on", function()
		with_ollama_manager(true, function(f)
			helpers.assert_eq(f.scheduler.live(), 1, "the AI-on construction pre-warms the cache")
		end)
	end)
end)

return true
