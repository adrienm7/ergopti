--- tests/unit/ui/menu/menu_llm/test_settings_transaction.lua

--- ==============================================================================
--- MODULE: Transactional LLM Settings Regression
--- DESCRIPTION:
--- Proves that every LLM setting action restores state, native settings, runtime,
--- durable preferences, and rendered menu state when any boundary refuses.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.storage",
	"ui.menu.menu_llm",
	"ui.menu.menu_llm.settings_manager",
	"ui.menu.menu_llm.trigger_panel",
	"ui.menu.menu_llm.streaming_panel",
	"ui.menu.menu_llm.temperature_panel",
	"ui.menu.menu_llm.models_manager",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.menu_llm.warmup_controller",
	"ui.menu.menu_llm.backend_panel",
	"ui.menu.menu_llm.api_panel",
	"ui.menu.menu_llm.models_selector",
	"ui.menu.menu_llm.model_switcher",
	"ui.menu.menu_llm.startup_controller",
	"ui.menu.menu_llm.trigger_orchestrator",
	"ui.menu.menu_llm.menu_layout",
	"modules.llm",
	"modules.llm.api_mlx",
	"modules.llm.mlx_deps_checker",
	"modules.llm.ollama_deps_checker",
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.dialog_util",
	"ui.menu.shortcut_utils",
	"infra.app_picker",
	"infra.manifest_menu",
}

local DEFAULT_STATE = {
	llm_enabled = false,
	llm_backend = "ollama",
	llm_model_mlx = "",
	llm_model_ollama = "",
	llm_debounce = 0.35,
	llm_max_words = 20,
	llm_min_words = 4,
	llm_temperature = 0.1,
	llm_context_length = 1500,
	llm_num_predictions = 1,
	llm_reset_on_nav = true,
	llm_show_info_bar = true,
	llm_auto_raise_temp = false,
	llm_streaming = false,
	llm_streaming_multi = false,
	llm_arrow_nav_enabled = true,
	llm_active_profile = "basic",
	llm_after_hotstring = false,
	llm_instant_on_word_end = false,
	llm_pred_indent = 0,
	llm_nav_modifiers = {"alt"},
	llm_val_modifiers = {"cmd"},
}

local function clone_value(value)
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, child in pairs(value) do clone[clone_value(key)] = clone_value(child) end
	return clone
end

local function find_item(items, title)
	for _, item in ipairs(items or {}) do
		if item.title == title then return item end
	end
	return nil
end

local function failure_for(options, name, occurrence)
	for _, failure in ipairs(options.failures or {}) do
		if failure.name == name and (failure.occurrence or 1) == occurrence then
			return failure
		end
	end
	return nil
end

local function with_fixture(options, callback)
	options = options or {}
	local saved_modules = {}
	for _, name in ipairs(MODULES) do
		saved_modules[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs

	local state = {
		llm_enabled = true,
		llm_backend = "ollama",
		llm_model = "",
		llm_model_mlx = "",
		llm_model_ollama = "",
		llm_active_profile = "basic",
		llm_profile_shortcuts = {},
		llm_trigger_shortcut = false,
		llm_debounce = 0.5,
		llm_max_words = 7,
		llm_min_words = 2,
		llm_temperature = 0.2,
		llm_context_length = 300,
		llm_num_predictions = 3,
		llm_reset_on_nav = true,
		llm_show_info_bar = true,
		llm_auto_raise_temp = false,
		llm_streaming = false,
		llm_streaming_multi = true,
		llm_pred_indent = 1,
		llm_nav_modifiers = {"ctrl"},
		llm_val_modifiers = {"shift"},
		llm_instant_on_word_end = false,
		llm_after_hotstring = false,
		llm_url_bar_filter_enabled = false,
		llm_secure_field_filter_enabled = false,
		llm_disabled_apps = {{name = "Old", appPath = "/Old.app"}},
	}
	local runtime = clone_value(state)
	local persisted = clone_value(state)
	local rendered = clone_value(state)
	local settings_store = clone_value(state)
	for key, value in pairs(options.runtime_overrides or {}) do
		runtime[key] = clone_value(value)
	end
	for key, value in pairs(options.setting_overrides or {}) do
		settings_store[key] = clone_value(value)
	end
	if options.setting_absent then settings_store[options.setting_absent] = nil end

	local calls = {
		runtime_get = 0,
		runtime = 0,
		settings = 0,
		settings_clear = 0,
		save = 0,
		menu = 0,
	}
	local histories = {
		runtime_get = {},
		runtime = {},
		settings = {},
		save = {},
		menu = {},
	}
	local errors = {}

	local function run_boundary(name, value, mutate, success_result)
		calls[name] = calls[name] + 1
		histories[name][#histories[name] + 1] = clone_value(value)
		local failure = failure_for(options, name, calls[name])
		if not failure or failure.mutate ~= false then mutate() end
		if failure then
			for key, committed_value in pairs(failure.restore_committed or {}) do
				state[key] = clone_value(committed_value)
				runtime[key] = clone_value(committed_value)
			end
			for key, committed_value in pairs(failure.restore_settings or {}) do
				settings_store[key] = clone_value(committed_value)
			end
			if failure.mode == "throw" then
				error(string.format("%s boundary exploded", name))
			end
			if failure.mode == "nil" then return nil end
			return false
		end
		return success_result
	end

	local Logger = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function(_, format_string, ...)
			local ok, message = pcall(string.format, tostring(format_string), ...)
			errors[#errors + 1] = ok and message or tostring(format_string)
		end,
		callback = function(_, label, fn, ...)
			local results = table.pack(xpcall(fn, debug.traceback, ...))
			if not results[1] then
				errors[#errors + 1] = tostring(label) .. ": " .. tostring(results[2])
			end
			return table.unpack(results, 1, results.n)
		end,
	}

	_G.hs = {
		http = {
			asyncGet = function() end,
		},
		settings = {
			get = function(key)
				local logical_key = key:match("^ergopti%.(.+)$")
				return clone_value(settings_store[logical_key])
			end,
			set = function(key, value)
				local logical_key = key:match("^ergopti%.(.+)$")
				return run_boundary("settings", {key = logical_key, value = value}, function()
					settings_store[logical_key] = clone_value(value)
				end, nil)
			end,
			clear = function(key, ...)
				if select("#", ...) ~= 0 then
					error("hs.settings.clear accepts exactly one argument")
				end
				calls.settings_clear = calls.settings_clear + 1
				local logical_key = key:match("^ergopti%.(.+)$")
				return run_boundary("settings", {key = logical_key, clear = true}, function()
					settings_store[logical_key] = nil
				end, true)
			end,
		},
	}

	package.loaded["modules.llm"] = {
		DEFAULT_STATE = clone_value(DEFAULT_STATE),
		get_backend = function() return state.llm_backend end,
		get_current_model = function() return state.llm_model or "" end,
		set_backend = function() return true end,
		set_llm_model_mlx = function() return true end,
		set_llm_model_ollama = function() return true end,
		is_backend_ready = function() return false end,
		is_backend_load_failed = function() return false end,
		load_api_entries = function() end,
	}
	package.loaded["infra.logger"] = Logger
	package.loaded["infra.notifications"] = {notify = function() end}
	package.loaded["infra.i18n"] = {get = function(key) return key end}
	local prompt_value = options.prompt_value or "0.75"
	package.loaded["infra.dialog_util"] = {
		text_prompt = function()
			return "button.ok", prompt_value
		end,
	}
	package.loaded["ui.menu.shortcut_utils"] = {
		shortcut_to_label = function() return "common.none" end,
		prompt_shortcut = function() return true end,
	}
	local app_change = nil
	package.loaded["infra.app_picker"] = {
		build_menu = function(_, on_change)
			app_change = on_change
			return {}
		end,
	}
	package.loaded["infra.manifest_menu"] = {
		render_rows = function(rows)
			local items = {}
			for _, row in ipairs(rows) do
				items[#items + 1] = {
					title = row.label or row.title,
					checked = row.checked,
					disabled = row.disabled,
					fn = row.action,
					menu = row.items or row.submenu,
				}
			end
			return items
		end,
		build = function(_, _, handlers)
			local items = {}
			for _, id in ipairs({
				"llm_num_predictions",
				"llm_generation_settings",
				"llm_navigation",
			}) do
				handlers[id](items)
			end
			return items
		end,
	}

	local keymap = {}
	keymap.set_llm_model = function() return true end
	for _, key in ipairs({
		"llm_debounce",
		"llm_max_words",
		"llm_min_words",
		"llm_temperature",
		"llm_context_length",
		"llm_num_predictions",
		"llm_reset_on_nav",
		"llm_show_info_bar",
		"llm_auto_raise_temp",
		"llm_streaming",
		"llm_streaming_multi",
		"llm_pred_indent",
		"llm_nav_modifiers",
		"llm_val_modifiers",
		"llm_instant_on_word_end",
		"llm_after_hotstring",
		"llm_url_bar_filter_enabled",
		"llm_secure_field_filter_enabled",
		"llm_disabled_apps",
	}) do
		keymap["set_" .. key] = function(value)
			return run_boundary("runtime", {key = key, value = value}, function()
				runtime[key] = clone_value(value)
			end, nil)
		end
	end
	keymap.get_llm_runtime_setting = function(key)
		calls.runtime_get = calls.runtime_get + 1
		histories.runtime_get[#histories.runtime_get + 1] = key
		local failure = failure_for(options, "runtime_get", calls.runtime_get)
		if failure then
			if failure.mode == "throw" then error("runtime getter exploded") end
			return false, nil
		end
		return true, clone_value(runtime[key])
	end

	local function save_prefs()
		return run_boundary("save", clone_value(state), function()
			persisted = clone_value(state)
		end, true)
	end

	local function update_menu()
		return run_boundary("menu", clone_value(state), function()
			rendered = clone_value(state)
		end, nil)
	end

	--- Clears setup telemetry while retaining every independently observable value.
	local function reset_observations()
		for name in pairs(calls) do calls[name] = 0 end
		for name in pairs(histories) do histories[name] = {} end
		for index = #errors, 1, -1 do errors[index] = nil end
	end

	local Settings = require("ui.menu.menu_llm.settings_manager")
	local TriggerPanel = require("ui.menu.menu_llm.trigger_panel")
	local StreamingPanel = require("ui.menu.menu_llm.streaming_panel")
	local TemperaturePanel = require("ui.menu.menu_llm.temperature_panel")
	local manager = Settings.new({
		state = state,
		keymap = keymap,
		save_prefs = save_prefs,
		update_menu = update_menu,
	})

	--- Builds and returns the callbacks exported by the real top-level menu tree.
	--- @return table callbacks Prediction selection, reset, and navigation actions.
	local function build_top_level_callbacks()
		local noop = function() end
		local models = {
			get_presets = function() return {} end,
			get_actual_model_name = function(name) return name end,
			get_model_info = function() return {} end,
			get_model_ram = function() return 0 end,
			check_requirements = noop,
		}
		package.loaded["ui.menu.menu_llm.models_manager"] = {
			new = function() return models end,
		}
		package.loaded["ui.menu.menu_llm.profiles_manager"] = {
			new = function()
				return {get_menu_item = function() return {} end}
			end,
		}
		package.loaded["ui.menu.menu_llm.warmup_controller"] = {warmup = noop}
		package.loaded["ui.menu.menu_llm.backend_panel"] = {
			is_apple_silicon = function() return false end,
			build = function() return "backend", {} end,
		}
		package.loaded["ui.menu.menu_llm.api_panel"] = {
			build = function() return nil, nil end,
			build_model_picker = function() return {} end,
		}
		package.loaded["ui.menu.menu_llm.models_selector"] = {
			build = function() return {} end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = {
			new = function()
				return {
					switch_model = noop,
					disable_model = noop,
					set_llm_profile = noop,
					apply_recommended_prompt_profile = noop,
					get_display_model_name = function(name) return name end,
					get_model_power_level = function() return 1 end,
					guarded_check_requirements = noop,
				}
			end,
		}
		package.loaded["modules.llm.api_mlx"] = {}
		package.loaded["ui.menu.menu_llm.startup_controller"] = {
			new = function() return noop end,
		}
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = {
			new = function()
				return {
					bind_hotkey = noop,
					activate_hotkey = noop,
					apply_llm_shortcut = noop,
					apply_llm_profile_shortcut = noop,
					restore_shortcuts = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.menu_layout"] = {
			row_ids = function()
				return {
					"llm_num_predictions",
					"llm_generation_settings",
					"llm_navigation",
				}
			end,
			row_disabled = function() return false end,
			has_health_dot = function() return false end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = {
			check_and_install_deps = noop,
		}
		package.loaded["modules.llm.ollama_deps_checker"] = {
			check_and_install_deps = noop,
		}

		package.loaded["ui.menu.menu_llm"] = nil
		local MenuLLM = require("ui.menu.menu_llm")
		local handler = MenuLLM.create({
			state = state,
			keymap = keymap,
			save_prefs = save_prefs,
			update_menu = update_menu,
			active_tasks = {},
		})
		local submenu = handler.build_item().submenu
		local predictions = find_item(submenu, "menu.llm.num_predictions_label")
		local generation = find_item(submenu, "menu.llm.generation_menu_title")
		local reset_predictions = find_item(submenu, "menu.llm.reset_label")
		local reset_on_nav = find_item(generation.menu, "menu.llm.reset_on_nav")
		reset_observations()
		return {
			select_predictions = predictions.menu[4].fn,
			reset_predictions = reset_predictions.fn,
			reset_on_nav = reset_on_nav.fn,
			rebuild = function() return handler.build_item().submenu end,
		}
	end

	local fixture = {
		state = state,
		runtime = runtime,
		settings_store = settings_store,
		calls = calls,
		histories = histories,
		errors = errors,
		manager = manager,
		set_prompt = function(value) prompt_value = value end,
		persisted = function() return persisted end,
		rendered = function() return rendered end,
		streaming_menu = function()
			return StreamingPanel.build({
				state = state,
				keymap = keymap,
				is_disabled = false,
				save_prefs = save_prefs,
				update_menu = update_menu,
				settings_mgr = manager,
			})
		end,
		temperature_menu = function()
			local rows = {}
			TemperaturePanel.build({
				state = state,
				keymap = keymap,
				is_disabled = false,
				save_prefs = save_prefs,
				update_menu = update_menu,
				settings_mgr = manager,
			}, rows)
			return package.loaded["infra.manifest_menu"].render_rows(rows)
		end,
		top_level_callbacks = build_top_level_callbacks,
		trigger_menu = function()
			return TriggerPanel.build({
				state = state,
				keymap = keymap,
				is_disabled = false,
				save_prefs = save_prefs,
				update_menu = update_menu,
				settings_mgr = manager,
				apply_llm_shortcut = function() return true end,
			})
		end,
		app_change = function(value) return app_change(value) end,
	}

	local ok, err = xpcall(function() callback(fixture) end, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end

local ENTRY_SPECS = {
	{
		name = "numeric",
		key = "llm_temperature",
		candidate = 0.75,
		publishes_setting = true,
		invoke = function(fixture)
			fixture.set_prompt("0.75")
			return fixture.manager.set_temperature()
		end,
	},
	{
		name = "reset",
		key = "llm_max_words",
		candidate = DEFAULT_STATE.llm_max_words,
		publishes_setting = true,
		invoke = function(fixture) return fixture.manager.reset_max_words() end,
	},
	{
		name = "toggle",
		key = "llm_instant_on_word_end",
		candidate = true,
		publishes_setting = false,
		invoke = function(fixture)
			local item = find_item(fixture.trigger_menu(), "menu.llm.instant_on_word_end")
			return item.fn()
		end,
	},
	{
		name = "modifier",
		key = "llm_nav_modifiers",
		candidate = {"shift"},
		publishes_setting = true,
		invoke = function(fixture)
			return find_item(fixture.manager.build_nav_modifier_menu(), "⇧ Shift").fn()
		end,
	},
}

local FAILURE_SPECS = {
	{name = "settings", mode = "false", settings_only = true},
	{name = "settings", mode = "throw", settings_only = true},
	{name = "runtime", mode = "false"},
	{name = "runtime", mode = "throw"},
	{name = "save", mode = "false"},
	{name = "save", mode = "throw"},
	{name = "menu", mode = "false"},
	{name = "menu", mode = "throw"},
}





-- ==============================================
-- ==============================================
-- ======= 1/ Failure compensation matrix =======
-- ==============================================
-- ==============================================

helpers.describe("HS-026 LLM settings transaction", function()
	for _, entry in ipairs(ENTRY_SPECS) do
		for _, failure in ipairs(FAILURE_SPECS) do
			if not failure.settings_only or entry.publishes_setting then
				helpers.it(string.format("HS-026 restores %s after %s %s", entry.name,
					failure.name, failure.mode), function()
					with_fixture({failures = {{
						name = failure.name,
						mode = failure.mode,
					}}}, function(fixture)
						local old_value = clone_value(fixture.state[entry.key])
						local call_ok, result = xpcall(function()
							return entry.invoke(fixture)
						end, debug.traceback)

						helpers.assert_true(call_ok,
							"the setting owner must contain boundary exceptions")
						helpers.assert_eq(result, false)
						helpers.assert_eq(fixture.state[entry.key], old_value)
						helpers.assert_eq(fixture.runtime[entry.key], old_value)
						helpers.assert_eq(fixture.persisted()[entry.key], old_value)
						helpers.assert_eq(fixture.rendered()[entry.key], old_value)
						if entry.publishes_setting then
							helpers.assert_eq(fixture.settings_store[entry.key], old_value)
						end
						helpers.assert_true(#fixture.errors >= 1,
							"a refused setting boundary must be file-logged")
					end)
				end)
			end
		end
	end

	for _, entry in ipairs(ENTRY_SPECS) do
		helpers.it("HS-026 commits " .. entry.name .. " exactly once", function()
			with_fixture({}, function(fixture)
				helpers.assert_eq(entry.invoke(fixture), true)
				helpers.assert_eq(fixture.state[entry.key], entry.candidate)
				helpers.assert_eq(fixture.runtime[entry.key], entry.candidate)
				helpers.assert_eq(fixture.persisted()[entry.key], entry.candidate)
				helpers.assert_eq(fixture.rendered()[entry.key], entry.candidate)
				helpers.assert_eq(fixture.calls.runtime, 1)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(fixture.calls.menu, 1)
				helpers.assert_eq(fixture.calls.settings,
					entry.publishes_setting and 1 or 0)
			end)
		end)
	end

	helpers.it("HS-026 retains refused compensation and settles it before retry", function()
		with_fixture({failures = {
			{name = "save", occurrence = 1, mode = "false"},
			{name = "runtime", occurrence = 2, mode = "false", mutate = false},
		}}, function(fixture)
			local entry = ENTRY_SPECS[1]
			helpers.assert_eq(entry.invoke(fixture), false)
			helpers.assert_eq(fixture.state[entry.key], 0.2)
			helpers.assert_eq(fixture.runtime[entry.key], entry.candidate,
				"a refused runtime rollback must remain observable as debt")
			helpers.assert_true(#fixture.errors >= 1,
				"unsettled compensation must be file-logged")

			helpers.assert_eq(entry.invoke(fixture), true)
			helpers.assert_eq(fixture.histories.runtime, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = entry.candidate},
			})
			helpers.assert_eq(fixture.runtime[entry.key], entry.candidate)
			helpers.assert_eq(fixture.persisted()[entry.key], entry.candidate)
		end)
	end)

	helpers.it("HS-026 reasserts old state after the persistence owner refuses rollback", function()
		with_fixture({failures = {
			{name = "menu", occurrence = 1, mode = "false"},
			{
				name = "save",
				occurrence = 2,
				mode = "false",
				restore_committed = {llm_temperature = 0.75},
				restore_settings = {llm_temperature = 0.75},
			},
		}}, function(fixture)
			local entry = ENTRY_SPECS[1]
			helpers.assert_eq(entry.invoke(fixture), false)
			helpers.assert_eq(fixture.state[entry.key], 0.2,
				"an outer persistence rollback must not republish its newer snapshot")
			helpers.assert_eq(fixture.runtime[entry.key], 0.2)
			helpers.assert_eq(fixture.settings_store[entry.key], 0.2)
			helpers.assert_eq(fixture.rendered()[entry.key], 0.2)
			helpers.assert_eq(fixture.histories.settings, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.2},
			})

			helpers.assert_eq(entry.invoke(fixture), true,
				"the retained persistence rollback must settle before retry")
			helpers.assert_eq(fixture.state[entry.key], entry.candidate)
			helpers.assert_eq(fixture.histories.settings, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = entry.candidate},
			}, "native plist restoration must remain debt until persistence settles")
		end)
	end)

	helpers.it("HS-026 clears a formerly absent native setting during rollback", function()
		with_fixture({
			setting_absent = "llm_temperature",
			failures = {{name = "menu", occurrence = 1, mode = "false"}},
		}, function(fixture)
			helpers.assert_eq(ENTRY_SPECS[1].invoke(fixture), false)
			helpers.assert_nil(fixture.settings_store.llm_temperature)
			helpers.assert_eq(fixture.calls.settings_clear, 1)
		end)
	end)

	helpers.it("HS-026 snapshots runtime independently from state and native settings", function()
		with_fixture({
			runtime_overrides = {llm_temperature = 0.4},
			setting_overrides = {llm_temperature = 0.6},
			failures = {{name = "menu", occurrence = 1, mode = "false"}},
		}, function(fixture)
			local entry = ENTRY_SPECS[1]
			helpers.assert_eq(entry.invoke(fixture), false)
			helpers.assert_eq(fixture.state[entry.key], 0.2)
			helpers.assert_eq(fixture.runtime[entry.key], 0.4,
				"runtime rollback must use the engine getter, not the state snapshot")
			helpers.assert_eq(fixture.settings_store[entry.key], 0.6,
				"native rollback must retain its independent plist snapshot")
			helpers.assert_eq(fixture.persisted()[entry.key], 0.2)
			helpers.assert_eq(fixture.rendered()[entry.key], 0.2)
			helpers.assert_eq(fixture.calls.runtime_get, 1)
			helpers.assert_eq(fixture.histories.runtime, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.4},
			})
		end)
	end)

	for _, mode in ipairs({"false", "throw"}) do
		helpers.it("HS-026 refuses a " .. mode .. " runtime snapshot before mutation", function()
			with_fixture({failures = {{name = "runtime_get", mode = mode}}}, function(fixture)
				local entry = ENTRY_SPECS[1]
				helpers.assert_eq(entry.invoke(fixture), false)
				helpers.assert_eq(fixture.state[entry.key], 0.2)
				helpers.assert_eq(fixture.runtime[entry.key], 0.2)
				helpers.assert_eq(fixture.settings_store[entry.key], 0.2)
				helpers.assert_eq(fixture.calls.runtime, 0)
				helpers.assert_eq(fixture.calls.save, 0)
				helpers.assert_eq(fixture.calls.settings, 0)
				helpers.assert_eq(fixture.calls.menu, 0)
				helpers.assert_true(#fixture.errors >= 1)
			end)
		end)
	end
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Finite Numeric Boundary ===========
-- ==============================================
-- ==============================================

helpers.describe("HS-055 LLM settings reject non-finite numbers", function()
	for _, case in ipairs({
		{name = "NaN", value = 0 / 0},
		{name = "positive infinity", value = math.huge},
		{name = "negative infinity", value = -math.huge},
	}) do
		helpers.it("refuses " .. case.name .. " before every mutation boundary", function()
			with_fixture({}, function(fixture)
				local result = fixture.manager.apply_setting_transaction({
					key = "llm_temperature",
					value = case.value,
					runtime_fn = "set_llm_temperature",
					publish_setting = true,
				})
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.state.llm_temperature, 0.2)
				helpers.assert_eq(fixture.runtime.llm_temperature, 0.2)
				helpers.assert_eq(fixture.settings_store.llm_temperature, 0.2)
				helpers.assert_eq(fixture.persisted().llm_temperature, 0.2)
				helpers.assert_eq(fixture.rendered().llm_temperature, 0.2)
				helpers.assert_eq(fixture.calls.runtime_get, 0)
				helpers.assert_eq(fixture.calls.runtime, 0)
				helpers.assert_eq(fixture.calls.save, 0)
				helpers.assert_eq(fixture.calls.settings, 0)
				helpers.assert_eq(fixture.calls.menu, 0)
				helpers.assert_true(#fixture.errors >= 1,
					"the finite-value refusal must be visible in the file log")
			end)
		end)
	end

	helpers.it("rejects prompt overflow through the real debounce entry path", function()
		with_fixture({}, function(fixture)
			fixture.set_prompt("1e999")
			helpers.assert_eq(fixture.manager.set_debounce(), false)
			helpers.assert_eq(fixture.state.llm_debounce, 0.5)
			helpers.assert_eq(fixture.runtime.llm_debounce, 0.5)
			helpers.assert_eq(fixture.settings_store.llm_debounce, 0.5)
			helpers.assert_eq(fixture.calls.runtime_get, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.settings, 0)
			helpers.assert_eq(fixture.calls.menu, 0)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Every production entry path =======
-- ==============================================
-- ==============================================

local ROUTES = {
	{name = "set debounce", key = "llm_debounce", invoke = function(f)
		f.set_prompt("900"); return f.manager.set_debounce()
	end},
	{name = "reset debounce", key = "llm_debounce", invoke = function(f)
		return f.manager.reset_debounce()
	end},
	{name = "set maximum words", key = "llm_max_words", invoke = function(f)
		f.set_prompt("8"); return f.manager.set_max_words()
	end},
	{name = "reset maximum words", key = "llm_max_words", invoke = function(f)
		return f.manager.reset_max_words()
	end},
	{name = "set minimum words", key = "llm_min_words", invoke = function(f)
		f.set_prompt("5"); return f.manager.set_min_words()
	end},
	{name = "reset minimum words", key = "llm_min_words", invoke = function(f)
		return f.manager.reset_min_words()
	end},
	{name = "set temperature", key = "llm_temperature", invoke = function(f)
		f.set_prompt("0.75"); return f.manager.set_temperature()
	end},
	{name = "reset temperature", key = "llm_temperature", invoke = function(f)
		return f.manager.reset_temperature()
	end},
	{name = "set context length", key = "llm_context_length", invoke = function(f)
		f.set_prompt("800"); return f.manager.set_context_length()
	end},
	{name = "reset context length", key = "llm_context_length", invoke = function(f)
		return f.manager.reset_context_length()
	end},
	{name = "set indentation", key = "llm_pred_indent", invoke = function(f)
		return f.manager.build_indent_menu()[10].fn()
	end},
	{name = "set navigation modifiers", key = "llm_nav_modifiers", invoke = function(f)
		return find_item(f.manager.build_nav_modifier_menu(), "⇧ Shift").fn()
	end},
	{name = "set validation modifiers", key = "llm_val_modifiers", invoke = function(f)
		return find_item(f.manager.build_val_modifier_menu(), "⌘ Cmd").fn()
	end},
	{name = "toggle instant word end", key = "llm_instant_on_word_end", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.instant_on_word_end").fn()
	end},
	{name = "toggle after hotstring", key = "llm_after_hotstring", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.after_hotstring").fn()
	end},
	{name = "toggle URL filter", key = "llm_url_bar_filter_enabled", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.disable_url_bars").fn()
	end},
	{name = "toggle secure-field filter", key = "llm_secure_field_filter_enabled", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.disable_password_fields").fn()
	end},
	{name = "change disabled applications", key = "llm_disabled_apps", invoke = function(f)
		f.trigger_menu()
		return f.app_change({{name = "New", appPath = "/New.app"}})
	end},
}

local SIBLING_ROUTES = {
	{
		name = "toggle info bar",
		key = "llm_show_info_bar",
		candidate = false,
		invoke = function(fixture)
			return find_item(fixture.streaming_menu(), "menu.llm.show_info_bar").fn()
		end,
	},
	{
		name = "toggle token streaming",
		key = "llm_streaming",
		candidate = true,
		invoke = function(fixture)
			return find_item(fixture.streaming_menu(), "menu.llm.show_streaming").fn()
		end,
	},
	{
		name = "toggle multi-prediction streaming",
		key = "llm_streaming_multi",
		candidate = false,
		invoke = function(fixture)
			return find_item(fixture.streaming_menu(), "menu.llm.show_all_at_once").fn()
		end,
	},
	{
		name = "toggle automatic temperature",
		key = "llm_auto_raise_temp",
		candidate = true,
		invoke = function(fixture)
			return find_item(fixture.temperature_menu(), "menu.llm.auto_raise_temp").fn()
		end,
	},
	{
		name = "select prediction count",
		key = "llm_num_predictions",
		candidate = 4,
		invoke = function(fixture)
			return fixture.top_level_callbacks().select_predictions()
		end,
	},
	{
		name = "reset prediction count",
		key = "llm_num_predictions",
		candidate = DEFAULT_STATE.llm_num_predictions,
		invoke = function(fixture)
			return fixture.top_level_callbacks().reset_predictions()
		end,
	},
	{
		name = "toggle navigation reset",
		key = "llm_reset_on_nav",
		candidate = false,
		invoke = function(fixture)
			return fixture.top_level_callbacks().reset_on_nav()
		end,
	},
}

local SIBLING_FAILURES = {
	{name = "runtime", mode = "false", runtime = 2, save = 0, menu = 0},
	{name = "runtime", mode = "throw", runtime = 2, save = 0, menu = 0},
	{name = "save", mode = "false", runtime = 2, save = 2, menu = 0},
	{name = "menu", mode = "false", runtime = 2, save = 2, menu = 2},
}

helpers.describe("HS-026 all LLM setting entry paths share the owner", function()
	for _, route in ipairs(ROUTES) do
		helpers.it("HS-026 routes " .. route.name .. " through rollback", function()
			with_fixture({failures = {{name = "runtime", mode = "false"}}}, function(fixture)
				local old_value = clone_value(fixture.state[route.key])
				local call_ok, result = xpcall(function()
					return route.invoke(fixture)
				end, debug.traceback)
				helpers.assert_true(call_ok)
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.state[route.key], old_value)
				helpers.assert_eq(fixture.runtime[route.key], old_value)
				helpers.assert_eq(fixture.persisted()[route.key], old_value)
				helpers.assert_eq(fixture.rendered()[route.key], old_value)
			end)
		end)
	end
end)





-- =======================================================
-- =======================================================
-- ======= 3/ Missed sibling callback transactions =======
-- =======================================================
-- =======================================================

helpers.describe("HS-026 missed LLM setting callbacks share the owner", function()
	for _, route in ipairs(SIBLING_ROUTES) do
		for _, failure in ipairs(SIBLING_FAILURES) do
			helpers.it(string.format("HS-026 restores %s after %s %s", route.name,
				failure.name, failure.mode), function()
				with_fixture({failures = {{
					name = failure.name,
					mode = failure.mode,
				}}}, function(fixture)
					local old_value = clone_value(fixture.state[route.key])
					local call_ok, result = xpcall(function()
						return route.invoke(fixture)
					end, debug.traceback)

					helpers.assert_true(call_ok,
						"the real menu callback must contain boundary exceptions")
					helpers.assert_eq(result, false)
					helpers.assert_eq(fixture.state[route.key], old_value)
					helpers.assert_eq(fixture.runtime[route.key], old_value)
					helpers.assert_eq(fixture.persisted()[route.key], old_value)
					helpers.assert_eq(fixture.rendered()[route.key], old_value)
					helpers.assert_eq(fixture.calls.runtime, failure.runtime)
					helpers.assert_eq(fixture.calls.save, failure.save)
					helpers.assert_eq(fixture.calls.menu, failure.menu)
					helpers.assert_eq(fixture.calls.settings, 0)
					helpers.assert_true(#fixture.errors >= 1,
						"the rejected callback must leave a contextual error")
				end)
			end)
		end

		helpers.it("HS-026 commits " .. route.name .. " exactly once", function()
			with_fixture({}, function(fixture)
				helpers.assert_eq(route.invoke(fixture), true)
				helpers.assert_eq(fixture.state[route.key], route.candidate)
				helpers.assert_eq(fixture.runtime[route.key], route.candidate)
				helpers.assert_eq(fixture.persisted()[route.key], route.candidate)
				helpers.assert_eq(fixture.rendered()[route.key], route.candidate)
				helpers.assert_eq(fixture.calls.runtime, 1)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(fixture.calls.menu, 1)
				helpers.assert_eq(fixture.calls.settings, 0)
			end)
		end)
	end

	helpers.it("HS-026 fences sibling callbacks behind retained rollback debt", function()
		with_fixture({failures = {
			{name = "save", occurrence = 1, mode = "false"},
			{name = "runtime", occurrence = 2, mode = "false", mutate = false},
		}}, function(fixture)
			local info_route = SIBLING_ROUTES[1]
			local streaming_route = SIBLING_ROUTES[2]
			helpers.assert_eq(info_route.invoke(fixture), false)
			helpers.assert_eq(fixture.state.llm_show_info_bar, true)
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, false,
				"a refused compensation must remain owned as recovery debt")

			helpers.assert_eq(streaming_route.invoke(fixture), true)
			helpers.assert_eq(fixture.histories.runtime, {
				{key = "llm_show_info_bar", value = false},
				{key = "llm_show_info_bar", value = true},
				{key = "llm_show_info_bar", value = true},
				{key = "llm_streaming", value = true},
			})
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, true)
			helpers.assert_eq(fixture.runtime.llm_streaming, true)
			helpers.assert_eq(fixture.persisted().llm_streaming, true)
			helpers.assert_eq(fixture.calls.runtime, 4)
			helpers.assert_eq(fixture.calls.save, 3)
			helpers.assert_eq(fixture.calls.menu, 1)
			helpers.assert_eq(fixture.calls.settings, 0)
		end)
	end)

	helpers.it("HS-026 rebuilds navigation labels from canonical state without runtime writes", function()
		with_fixture({}, function(fixture)
			local callbacks = fixture.top_level_callbacks()
			fixture.state.llm_nav_modifiers = {"ctrl"}
			fixture.state.llm_val_modifiers = {"shift"}
			fixture.runtime.llm_nav_modifiers = {"cmd"}
			fixture.runtime.llm_val_modifiers = {"alt"}
			fixture.settings_store.llm_nav_modifiers = {"alt"}
			fixture.settings_store.llm_val_modifiers = {"cmd"}

			local submenu = callbacks.rebuild()
			local navigation = find_item(submenu, "menu.llm.nav_menu_title")
			helpers.assert_true(navigation ~= nil, "the real navigation row must rebuild")
			helpers.assert_true(find_item(navigation.menu,
				"menu.llm.nav_label : ⌃ menu.llm.arrows") ~= nil,
				"navigation title must display the canonical state value")
			helpers.assert_true(find_item(navigation.menu,
				"menu.llm.val_label : ⇧ menu.llm.digits") ~= nil,
				"validation title must display the canonical state value")
			helpers.assert_eq(fixture.calls.runtime, 0,
				"a render-only rebuild must not invoke either runtime setter")
			helpers.assert_eq(fixture.runtime.llm_nav_modifiers, {"cmd"})
			helpers.assert_eq(fixture.runtime.llm_val_modifiers, {"alt"})
		end)
	end)
end)
