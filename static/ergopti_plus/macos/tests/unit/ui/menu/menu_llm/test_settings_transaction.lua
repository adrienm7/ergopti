--- tests/unit/ui/menu/menu_llm/test_settings_transaction.lua

--- ==============================================================================
--- MODULE: Transactional LLM Settings Regression
--- DESCRIPTION:
--- Proves that every LLM setting action restores state, native settings, runtime,
--- durable preferences, and rendered menu state when any boundary refuses.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"modules.llm.backend_detector",
	"infra.manifest_reader",
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
	"infra.preferences",
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
	require("infra.paths").shared_root()
	local preferences_owner = options.preferences or require("infra.preferences")
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
	if options.progressive_state ~= nil then state.llm_streaming_multi = options.progressive_state end
	if options.info_bar_state ~= nil then state.llm_show_info_bar = options.info_bar_state end
	if options.auto_raise_state ~= nil then state.llm_auto_raise_temp = options.auto_raise_state end
	if options.prediction_count ~= nil then state.llm_num_predictions = options.prediction_count end
	if options.trigger_states then
		state.llm_instant_on_word_end, state.llm_after_hotstring = table.unpack(options.trigger_states)
	end
	if options.privacy_states then
		state.llm_url_bar_filter_enabled, state.llm_secure_field_filter_enabled = table.unpack(options.privacy_states)
	end
	local runtime = clone_value(state)
	local display_generation = 0
	local persisted = clone_value(state)
	local publication_id = 0
	package.loaded["infra.preferences"] = options.preferences or {
		flat_key_for = preferences_owner.flat_key_for,
		state_value_for = preferences_owner.state_value_for,
		current_view = function() return clone_value(persisted), {status = "ok", content = "owned fixture"} end,
		source_snapshot = function() return {status = "ok", content = "owned fixture"} end,
		source_matches = function(expected, current)
			return type(expected) == "table" and type(current) == "table" and expected.status == current.status and expected.content == current.content
		end,
		publication_receipt = function()
			return {id = publication_id, source = {status = "ok", content = "owned fixture"}}
		end,
	}
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
		done = function() end,
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
		fs = saved_hs.fs,
		execute = function(command)
			if command == "/usr/bin/uname -m" then return "x86_64" end
			if command == "/usr/bin/sw_vers -productVersion" then return "14.5" end
			error("unexpected architecture probe: " .. command)
		end,
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
		streaming_snapshot = function()
			return { owner = runtime, generation = display_generation,
				backend = runtime.llm_backend, enabled = runtime.llm_enabled,
				streaming = runtime.llm_streaming, blocked = false }
		end,
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
	package.loaded["infra.i18n"] = {get = options.translate or function(key) return key end}
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
	local display_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
		json_decode = function(raw)
			local root = assert(require("json").decode(raw))
			if options.navigation_reverse then
				root.llm_navigation_rows[1], root.llm_navigation_rows[2] = root.llm_navigation_rows[2], root.llm_navigation_rows[1]
			end
			if options.navigation_label then root.llm_navigation_rows[1].i18n = options.navigation_label end
			if options.navigation_absent then root.llm_navigation_rows = {} end
			if options.navigation_invalid then root.llm_navigation_rows[1].i18n = 2 end
			if options.info_label then root.llm_display_menu[2].i18n = options.info_label end
			for index, row in ipairs(root.llm_display_menu) do
				if row.id == "llm_show_all" then
					if options.show_all_label then row.i18n = options.show_all_label end
					if options.show_all_first then table.remove(root.llm_display_menu, index); table.insert(root.llm_display_menu, 1, row) end
					break
				end
			end
			if options.info_last then
				for index, row in ipairs(root.llm_display_menu) do
					if row.id == "llm_info_bar" then table.remove(root.llm_display_menu, index); table.insert(root.llm_display_menu, row); break end
				end
			end
			if root.llm_generation_menu then
				if options.auto_label then root.llm_generation_menu[2].i18n = options.auto_label end
				if options.auto_first then
					root.llm_generation_menu[1], root.llm_generation_menu[2] = root.llm_generation_menu[2], root.llm_generation_menu[1]
				end
			end
			if options.trigger_label then root.llm_trigger_menu[2].i18n = options.trigger_label end
			if options.trigger_first then
				local row = table.remove(root.llm_trigger_menu, 2)
				table.insert(root.llm_trigger_menu, 1, row)
			end
			if options.info_first then
				root.llm_display_menu[1], root.llm_display_menu[2] = root.llm_display_menu[2], root.llm_display_menu[1]
			end
			return root
		end,
		i18n = { get = function(key) return key end, section = function(key) return key end },
		logger = Logger,
	}))
	package.loaded["infra.manifest_menu"] = {
		command_row = display_renderer.command_row,
		template_rows = display_renderer.template_rows,
		check_row = display_renderer.check_row,
		get_array = display_renderer.get_array,
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
		build = function(key, category, handlers, groups, ctx, providers)
			if key == "llm_display_menu" or key == "llm_generation_menu" or key == "llm_trigger_menu" then
				return display_renderer.build(key, category, handlers, groups, ctx, providers)
			end
			local items = {}
			for _, id in ipairs({
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

	local owned_save
	if options.preference_source then
		owned_save = require("ui.menu.preferences_transaction").bind(options.preferences, {
			path = options.preference_source, state = state, hotfiles = {}, core_modules = {},
			initial_state = state, initial_preferences = state,
			restore_runtime = function(snapshot)
				return require("ui.menu.preferences_transaction").restore_table(runtime, snapshot)
			end,
		})
	end

	local function save_prefs()
		if owned_save then
			calls.save = calls.save + 1
			histories.save[#histories.save + 1] = clone_value(state)
			local committed = owned_save()
			if committed == true then
				persisted = clone_value(state)
				if options.after_save then options.after_save() end
			end
			return committed
		end
		local committed = run_boundary("save", clone_value(state), function()
			persisted = clone_value(state)
		end, true)
		if committed == true then publication_id = publication_id + 1 end
		return committed
	end

	local function update_menu()
		if options.before_menu then options.before_menu(calls.menu + 1) end
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
					apply_llm_profile_shortcut = noop,
					restore_shortcuts = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.menu_layout"] = {
			row_ids = function()
				return {
					"llm_generation_settings",
					"llm_navigation",
				}
			end,
			row_disabled = function() return false end,
			has_health_dot = function() return false end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = require("tests.support.runtime_checker_stub")({
			check_and_install_deps = noop,
		})
		package.loaded["modules.llm.ollama_deps_checker"] = require("tests.support.runtime_checker_stub")({
			check_and_install_deps = noop,
		})

		package.loaded["ui.menu.menu_llm"] = nil
		local MenuLLM = require("ui.menu.menu_llm")
		local handler = MenuLLM.create({
			state = state,
			keymap = keymap,
			save_prefs = save_prefs,
			update_menu = update_menu,
			active_tasks = {},
		})
		assert(type(handler.build_item) == "function", table.concat(errors, "\n"))
		local submenu = handler.build_item().submenu
		if options.navigation_only then
			return { rebuild = function() return handler.build_item().submenu end }
		end
		local generation = find_item(submenu, "menu.llm.generation_menu_title")
		local predictions = find_item(generation.menu, "menu.llm.num_predictions_label")
		local reset_predictions = find_item(generation.menu, "menu.llm.reset_label")
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
		retire_display = function() display_generation = display_generation + 1 end,
		set_prompt = function(value) prompt_value = value end,
		persisted = function() return persisted end,
		rendered = function() return rendered end,
		streaming_menu = function()
			return StreamingPanel.build({
				state = state,
				keymap = keymap,
				is_disabled = false,
				is_paused = function() return options.paused == true end,
				save_prefs = save_prefs,
				update_menu = update_menu,
				settings_mgr = manager,
			})
		end,
		temperature_menu = function()
			local rows = {}
			local generation_ctx = TemperaturePanel.build({
				state = state,
				keymap = keymap,
				is_disabled = false,
				save_prefs = save_prefs,
				update_menu = update_menu,
				settings_mgr = manager,
			}, rows)
			if generation_ctx then
				return package.loaded["infra.manifest_menu"].build("llm_generation_menu", "LLM", nil, nil, generation_ctx, {
					["llm_generation_values"] = function() return rows end,
				})
			end
			return package.loaded["infra.manifest_menu"].render_rows(rows)
		end,
		top_level_callbacks = build_top_level_callbacks,
		trigger_menu = function()
			return TriggerPanel.build({
				state = state,
				keymap = keymap,
				is_disabled = false,
				is_paused = function() return options.paused == true end,
				save_prefs = save_prefs,
				update_menu = update_menu,
				settings_mgr = manager,
			})
		end,
		app_change = function(value) return app_change(value) end,
	}

	local ok, err = xpcall(function() callback(fixture) end, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end

--- Finds the actual indentation submenu without a competing native label policy.
--- @param menu table Rendered AI display rows.
--- @return table row
local function indentation_item(menu)
	for _, row in ipairs(menu) do
		if type(row.title) == "string" and row.title:sub(1, #"menu.llm.indent_label") == "menu.llm.indent_label" and row.menu then return row end
	end
	error("the declared indentation choice is absent")
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
		return indentation_item(f.streaming_menu()).menu[10].fn()
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





-- ==========================================
-- ==========================================
-- ======= 8/ Shared Info Bar Control =======
-- ==========================================
-- ==========================================

--- Reads the independently captured toggle states and shared label identity.
--- @return table corpus
local function info_bar_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/info_bar_control.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared Info Bar control", function()
	helpers.it("replays both checked states through the actual acknowledged setting owner", function()
		local corpus = info_bar_corpus()
		helpers.assert_eq(#corpus.states, 2)
		for _, selected in ipairs(corpus.states) do
			with_fixture({info_bar_state = selected}, function(fixture)
				local menu = fixture.streaming_menu()
				local row = assert(find_item(menu, corpus.row.i18n))
				helpers.assert_eq(menu[1], row, "the canonical Info Bar declaration is first on every OS")
				helpers.assert_eq(menu[#menu], indentation_item(menu), "the canonical indentation declaration owns the trailing position")
				helpers.assert_eq(row.checked or false, selected)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(fixture.state.llm_show_info_bar, not selected)
				helpers.assert_eq(fixture.persisted().llm_show_info_bar, not selected)
				helpers.assert_eq(fixture.runtime.llm_show_info_bar, not selected)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(fixture.calls.menu, 1)
			end)
		end
	end)

	helpers.it("moves the real check after indentation when its shared declaration moves last", function()
		with_fixture({info_last = true}, function(fixture)
			local menu = fixture.streaming_menu()
			helpers.assert_eq(menu[1].title, "menu.llm.show_streaming")
			helpers.assert_eq(menu[#menu].title, info_bar_corpus().row.i18n)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("uses the shared label while a refused writer preserves every publication", function()
		local corpus = info_bar_corpus()
		with_fixture({info_label = corpus.alternate_i18n, failures = {{name = "save", mode = "false"}}}, function(fixture)
			local menu = fixture.streaming_menu()
			local row = assert(find_item(menu, corpus.alternate_i18n), "the real native check must read the changed declaration")
			helpers.assert_eq(find_item(menu, corpus.row.i18n), nil, "no stale native label remains")
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_show_info_bar, true)
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, true)
			helpers.assert_eq(fixture.persisted().llm_show_info_bar, true)
			helpers.assert_eq(fixture.rendered().llm_show_info_bar, true)
			helpers.assert_eq(fixture.calls.menu, 0)
		end)
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 9/ Shared Automatic Temperature Check =======
-- =====================================================
-- =====================================================

--- Reads independent checkbox states and useful prediction counts.
--- @return table corpus
local function auto_raise_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/auto_raise_temperature.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared automatic temperature control", function()
	helpers.it("replays both states and prediction counts through the actual setting owner (shared-auto-raise)", function()
		local corpus = auto_raise_corpus()
		helpers.assert_eq(#corpus.states, 2)
		helpers.assert_eq(#corpus.prediction_counts, 2)
		for _, selected in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				with_fixture({auto_raise_state = selected, prediction_count = count}, function(fixture)
					local menu = fixture.temperature_menu()
					local row = assert(find_item(menu, corpus.row.i18n))
					helpers.assert_eq(row.checked or false, selected)
					helpers.assert_eq(row.disabled or false, count < 2)
					local result = row.fn()
					helpers.assert_eq(result, count >= 2)
					local expected = selected
					if count >= 2 then expected = not selected end
					helpers.assert_eq(fixture.state.llm_auto_raise_temp, expected)
					helpers.assert_eq(fixture.runtime.llm_auto_raise_temp, expected)
					helpers.assert_eq(fixture.persisted().llm_auto_raise_temp, expected)
					helpers.assert_eq(fixture.calls.save, count >= 2 and 1 or 0)
					helpers.assert_eq(fixture.calls.menu, count >= 2 and 1 or 0)
				end)
			end
		end
	end)

	helpers.it("follows the changed shared label and order without rewriting numeric controls (shared-auto-raise)", function()
		local corpus = auto_raise_corpus()
		with_fixture({auto_label = corpus.alternate_i18n, auto_first = true}, function(fixture)
			local menu = fixture.temperature_menu()
			helpers.assert_eq(menu[1].title, corpus.alternate_i18n)
			helpers.assert_true(menu[2].title:find("menu.llm.temperature_label", 1, true) ~= nil)
			helpers.assert_eq(find_item(menu, corpus.row.i18n), nil)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("refuses a delayed command after the actual prediction count becomes one (shared-auto-raise)", function()
		with_fixture({auto_raise_state = true, prediction_count = 2}, function(fixture)
			local row = assert(find_item(fixture.temperature_menu(), auto_raise_corpus().row.i18n))
			fixture.state.llm_num_predictions = 1
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.runtime.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.persisted().llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("keeps every publication after the existing writer refuses the command (shared-auto-raise)", function()
		with_fixture({auto_raise_state = true, failures = {{name = "save", mode = "false"}}}, function(fixture)
			local row = assert(find_item(fixture.temperature_menu(), auto_raise_corpus().row.i18n))
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.runtime.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.persisted().llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.rendered().llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.calls.menu, 0)
		end)
	end)
end)





-- ==================================
-- ==================================
-- ======= 6/ Show-All Parity =======
-- ==================================
-- ==================================

--- Loads explicit historical display semantics independently of native policy.
--- @return table
local function show_all_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/show_all_control.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared Show-all check", function()
	helpers.it("replays both progressive polarities through acknowledged native publication (shared-show-all)", function()
		local corpus = show_all_corpus()
		helpers.assert_eq(#corpus.states, 2)
		for _, expected in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				with_fixture({progressive_state = expected.progressive, prediction_count = count}, function(fixture)
					local row = assert(find_item(fixture.streaming_menu(), corpus.row.i18n))
					helpers.assert_eq(row.checked, expected.show_all)
					helpers.assert_eq(row.disabled == true, count < 2)
					local changed = row.fn()
					helpers.assert_eq(changed, count >= 2)
					local value = expected.progressive
					if count >= 2 then value = not expected.progressive end
					helpers.assert_eq(fixture.state.llm_streaming_multi, value)
					helpers.assert_eq(fixture.runtime.llm_streaming_multi, value)
					helpers.assert_eq(fixture.persisted().llm_streaming_multi, value)
				end)
			end
		end
	end)

	helpers.it("consumes the common Show-all label and row order (shared-show-all)", function()
		local corpus = show_all_corpus()
		with_fixture({progressive_state = true, show_all_label = corpus.alternate_i18n, show_all_first = true}, function(fixture)
			local rows = fixture.streaming_menu()
			helpers.assert_eq(rows[1].title, corpus.alternate_i18n)
			helpers.assert_eq(rows[1].checked, false)
			helpers.assert_eq(rows[2].title, "menu.llm.show_info_bar")
			helpers.assert_eq(rows[#rows], indentation_item(rows), "moving Show-all never revives a native leading indentation policy")
		end)
	end)

	helpers.it("refuses delayed Show-all changes when the current count loses its second slot (shared-show-all)", function()
		local options = {progressive_state = true, prediction_count = 2}
		with_fixture(options, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), show_all_corpus().row.i18n))
			fixture.state.llm_num_predictions = 1
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_streaming_multi, true)
			helpers.assert_eq(fixture.runtime.llm_streaming_multi, true)
			helpers.assert_eq(fixture.persisted().llm_streaming_multi, true)
			helpers.assert_eq(fixture.calls.save, 0)
			fixture.state.llm_num_predictions = 2
			options.paused = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, 0)
		end)
	end)

	helpers.it("keeps runtime, durable and rendered polarity after false, nil or throwing writers (shared-show-all)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_fixture({progressive_state = true, failures = {{name = "save", mode = mode}}}, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), show_all_corpus().row.i18n))
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.state.llm_streaming_multi, true)
				helpers.assert_eq(fixture.runtime.llm_streaming_multi, true)
				helpers.assert_eq(fixture.persisted().llm_streaming_multi, true)
				helpers.assert_eq(fixture.rendered().llm_streaming_multi, true)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end
	end)
end)






-- =============================================
-- =============================================
-- ======= 11/ Shared Automatic Triggers =======
-- =============================================
-- =============================================

--- Reads independent automatic-trigger states and declaration identity.
--- @return table corpus
local function trigger_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/automatic_trigger_controls.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared automatic trigger controls", function()
	helpers.it("replays every bool pair through actual durable setters independently of count (shared-automatic-triggers)", function()
		local corpus = trigger_corpus()
		helpers.assert_eq(#corpus.states, 4)
		for _, states in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				for index, expected in ipairs(corpus.rows) do
					with_fixture({trigger_states = states, prediction_count = count}, function(fixture)
						local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
						helpers.assert_eq(row.checked or false, states[index])
						helpers.assert_eq(row.disabled or false, false)
						helpers.assert_eq(row.fn(), true)
						helpers.assert_eq(fixture.state[expected.state], not states[index])
						helpers.assert_eq(fixture.runtime[expected.state], not states[index])
						helpers.assert_eq(fixture.persisted()[expected.state], not states[index])
						local neighbor = corpus.rows[index == 1 and 2 or 1]
						helpers.assert_eq(fixture.persisted()[neighbor.state], states[index == 1 and 2 or 1])
						helpers.assert_eq(fixture.calls.save, 1)
						helpers.assert_eq(fixture.calls.menu, 1)
					end)
				end
			end
		end
	end)

	helpers.it("honors declaration label and order without publishing sibling settings (shared-automatic-triggers)", function()
		local corpus = trigger_corpus()
		with_fixture({trigger_label = corpus.alternate_i18n, trigger_first = true}, function(fixture)
			local rows = fixture.trigger_menu()
			helpers.assert_eq(rows[1].title, corpus.alternate_i18n)
			helpers.assert_true(rows[2].title:find("menu.llm.debounce_label", 1, true) ~= nil)
			helpers.assert_eq(find_item(rows, corpus.rows[1].i18n), nil)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("rereads current values and refuses old callbacks after pause or master withdrawal (shared-automatic-triggers)", function()
		for _, expected in ipairs(trigger_corpus().rows) do
			local options = {trigger_states = {false, false}, prediction_count = 2}
			with_fixture(options, function(fixture)
				local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
				helpers.assert_eq(row.fn(), true)
				fixture.state.llm_num_predictions = 1
				helpers.assert_eq(row.fn(), true, "changing variant count does not revoke a trigger setting")
				helpers.assert_eq(fixture.state[expected.state], false)
				local saves, runtime_calls = fixture.calls.save, fixture.calls.runtime
				options.paused = true
				helpers.assert_eq(row.fn(), false)
				options.paused = false
				fixture.state.llm_enabled = false
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.calls.save, saves)
				helpers.assert_eq(fixture.calls.runtime, runtime_calls)
				helpers.assert_eq(fixture.persisted()[expected.state], false)
			end)
		end
	end)

	helpers.it("preserves all publication boundaries on false nil and throwing writers (shared-automatic-triggers)", function()
		for _, expected in ipairs(trigger_corpus().rows) do
			for _, mode in ipairs({"false", "nil", "throw"}) do
				with_fixture({failures = {{name = "save", mode = mode}}}, function(fixture)
					local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(fixture.state[expected.state], false)
					helpers.assert_eq(fixture.runtime[expected.state], false)
					helpers.assert_eq(fixture.persisted()[expected.state], false)
					helpers.assert_eq(fixture.rendered()[expected.state], false)
					helpers.assert_eq(fixture.calls.menu, 0)
				end)
			end
		end
	end)
end)

--- Reads independent native capability and stale-command expectations.
--- @return table corpus
local function token_streaming_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/token_streaming_control.json"), "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return assert(require("json").decode(text))
end

helpers.describe("shared token streaming policy", function()
	helpers.it("replays independent capability and admission vectors (shared-token-streaming)", function()
		local policy = require("llm.display_policy")
		local corpus = token_streaming_corpus()
		helpers.assert_eq(#corpus.capabilities, 9)
		helpers.assert_eq(#corpus.cases, 15)
		for _, vector in ipairs(corpus.capabilities) do
			helpers.assert_eq(policy.streaming_capable(vector.platform, vector.backend), vector.capable)
		end
		for _, vector in ipairs(corpus.cases) do
			local expected, current = {}, {}
			for key, value in pairs(corpus.base) do expected[key], current[key] = value, value end
			for key, value in pairs(vector.expected or {}) do expected[key] = value end
			for key, value in pairs(vector.current) do current[key] = value end
			local decision = policy.streaming_intent(expected, current)
			helpers.assert_eq(decision.admitted, vector.admitted, vector.id)
			if vector.admitted then helpers.assert_eq(decision.value, vector.value, vector.id) end
		end
	end)
end)

helpers.describe("native streaming checkbox admission", function()
	for _, condition in ipairs({ "paused", "off", "backend", "runtime disagreement", "retired owner" }) do
		helpers.it("refuses a retained checkbox after " .. condition .. " (shared-token-streaming)", function()
			local options = {}
			with_fixture(options, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), "menu.llm.show_streaming"))
				if condition == "paused" then options.paused = true end
				if condition == "off" then fixture.state.llm_enabled = false; fixture.runtime.llm_enabled = false end
				if condition == "backend" then fixture.state.llm_backend = "api"; fixture.runtime.llm_backend = "api" end
				if condition == "runtime disagreement" then fixture.runtime.llm_streaming = true end
				if condition == "retired owner" then fixture.retire_display() end
				local before = fixture.calls.save
				local result = row.fn()
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.calls.save, before)
				helpers.assert_eq(fixture.state.llm_streaming, false)
				helpers.assert_eq(fixture.persisted().llm_streaming, false)
				helpers.assert_eq(fixture.rendered().llm_streaming, false)
			end)
		end)
	end
end)

helpers.describe("macOS acknowledged token streaming checkbox", function()
	for _, race in ipairs({"before menu construction", "before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
	helpers.it("preserves a real foreign master winner " .. race .. " through compensation and a fresh second click (shared-token-streaming)", function()
		local path = require("infra.config_paths").get("ConfigTomlPath")
		local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.display]\nstreaming = false\nstreaming_multi = true\n[private]\nfuture = 42\n'
		local external = race == "before menu construction" and (initial .. '[llm.generation]\ntemperature = 0.9\n')
			or initial:gsub('enabled = true', 'enabled = false')
		local disk, attempts, unconditional, wrong_path = initial, 0, 0, false
		local previous_fs, previous_preferences = package.loaded["adapters.file_system"], package.loaded["infra.preferences"]
		package.loaded["adapters.file_system"] = {
			read_with_status = function(read_path)
				if read_path ~= path then wrong_path = true end
				return disk, "ok"
			end,
			write = function() unconditional = unconditional + 1; return false end,
			write_if_unchanged = function(write_path, content, source)
				if write_path ~= path then wrong_path = true end
				attempts = attempts + 1
				if attempts == 1 and race == "before forward acknowledgement" then disk = external end
				if source.status ~= "ok" or source.content ~= disk then return false, "source changed" end
				disk = content
				return true
			end,
		}
		package.loaded["infra.preferences"] = nil
		local preferences = require("infra.preferences")
		local ok, err = xpcall(function()
			local _, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			with_fixture({preferences = preferences, preference_source = path,
				failures = race ~= "before forward acknowledgement" and {{name = "menu", mode = "false"}} or {},
				after_save = function()
					if race == "between own acknowledgement and receipt admission" then disk = external end
				end,
				before_menu = function(occurrence)
					if occurrence == 1 and race == "after forward acknowledgement" then disk = external end
				end,
			}, function(fixture)
				local previous_temperature = fixture.state.llm_temperature
				if race == "before menu construction" then disk = external end
				local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
				if race == "before menu construction" then
					if row.fn then helpers.assert_eq(row.fn(), false) end
					helpers.assert_eq(disk, external, "stale compensation cannot overwrite the foreign temperature")
					helpers.assert_eq(row.disabled, true, "an already foreign full-document image is not action authority")
					helpers.assert_eq(attempts, 0)
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.manager.scope_idle(), true)
					helpers.assert_eq(preferences.publication_receipt(path), {id = 0})
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = initial})
					helpers.assert_eq(fixture.state.llm_temperature, previous_temperature)
					helpers.assert_eq(fixture.runtime.llm_temperature, previous_temperature)
					helpers.assert_eq(require("infra.toml.codec").decode(disk).llm.generation.temperature, 0.9)
					helpers.assert_eq(unconditional, 0)
					helpers.assert_eq(wrong_path, false)
					return
				end
				helpers.assert_eq(row.disabled == true, false)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(disk, external, "compensation cannot turn the external master on")
				local receipt = preferences.publication_receipt(path)
				if race == "before forward acknowledgement" then
					helpers.assert_eq(receipt.id, 0)
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = external})
				else
					helpers.assert_eq(receipt.id, 1, "only the true owned forward save issues authority")
					helpers.assert_eq(preferences.source_matches(receipt.source, {status = "ok", content = external}), false)
					local acknowledged = require("infra.toml.codec").decode(receipt.source.content)
					helpers.assert_eq(acknowledged.llm.enabled, true)
					helpers.assert_eq((acknowledged.llm.display or {}).streaming, nil, "acknowledged true follows the shared sparse default")
					helpers.assert_eq(preferences.source_snapshot(path), receipt.source)
				end
				helpers.assert_eq(attempts, 1, "compensation cannot borrow a foreign source")
				helpers.assert_eq(fixture.manager.scope_idle(), false, "refused compensation remains owned debt")
				helpers.assert_eq(fixture.state.llm_enabled, true)
				helpers.assert_eq(fixture.runtime.llm_enabled, true)
				local before = attempts
				local fresh = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
				helpers.assert_eq(fresh.disabled, true)
				if fresh.fn then helpers.assert_eq(fresh.fn(), false) end
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_streaming", value = false, runtime_fn = "set_llm_streaming", publish_setting = false,
				}), false, "a later action cannot borrow the foreign image to settle retained debt")
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.scope_idle(), false)
				helpers.assert_eq(disk, external)
				helpers.assert_eq(unconditional, 0)
				helpers.assert_eq(wrong_path, false)
			end)
		end, debug.traceback)
		package.loaded["adapters.file_system"], package.loaded["infra.preferences"] = previous_fs, previous_preferences
		if not ok then error(err, 0) end
	end)

	end

	helpers.it("refuses canonical master withdrawal independently of menu and runtime RAM (shared-token-streaming)", function()
		local canonical = {llm_enabled = true, llm_backend = "ollama", llm_streaming = false, llm_streaming_multi = true}
		with_fixture({preferences = {current_view = function() return clone_value(canonical), {status = "ok", content = tostring(canonical.llm_enabled)} end,
			source_snapshot = function() return {status = "ok", content = "true"} end,
			source_matches = function(expected, current) return expected.content == current.content end}}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
			canonical.llm_enabled = false
			local before = fixture.calls.save
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, before)
			helpers.assert_eq(fixture.state.llm_enabled, true)
			helpers.assert_eq(fixture.runtime.llm_enabled, true)
			helpers.assert_eq(fixture.state.llm_streaming, false)
		end)
	end)

	helpers.it("retires a held callback after actual progressive off/on transactions (shared-token-streaming)", function()
		with_fixture({}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
			for _, value in ipairs({false, true}) do
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_streaming_multi", value = value,
					runtime_fn = "set_llm_streaming_multi", publish_setting = false,
				}), true)
			end
			local before = fixture.calls.save
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, before)
			helpers.assert_eq(fixture.state.llm_streaming, false)
			helpers.assert_eq(fixture.persisted().llm_streaming, false)
		end)
	end)

	helpers.it("refuses actual progressive runtime disagreement (shared-token-streaming)", function()
		with_fixture({}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
			fixture.runtime.llm_streaming_multi = false
			local before = fixture.calls.save
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, before)
			helpers.assert_eq(fixture.state.llm_streaming, false)
		end)
	end)

	helpers.it("retains native rollback after false, nil or throwing durable writers (shared-token-streaming)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_fixture({failures = {{name = "save", mode = mode}}}, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.state.llm_streaming, false)
				helpers.assert_eq(fixture.runtime.llm_streaming, false)
				helpers.assert_eq(fixture.persisted().llm_streaming, false)
				helpers.assert_eq(fixture.rendered().llm_streaming, false)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end
	end)
end)





-- ============================================
-- ============================================
-- ======= 8/ Shared Indentation Choice =======
-- ============================================
-- ============================================

helpers.describe("macOS shared indentation choice", function()
	helpers.it("renders fifteen distinct signed translated choices with selected canonical caption (shared-indentation)", function()
		with_fixture({}, function(fixture)
			local rows = fixture.streaming_menu()
			local parent = indentation_item(rows)
			helpers.assert_eq(#parent.menu, 15)
			for index, value in ipairs({-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7}) do
				local unit = value == 0 and "menu.llm.indent_none" or math.abs(value) == 1 and "menu.llm.indent_space" or "menu.llm.indent_spaces"
				local prefix = value == 0 and "" or (value > 0 and "+" or "") .. value .. " "
				helpers.assert_eq(parent.menu[index].title, prefix .. unit)
				helpers.assert_eq(parent.menu[index].checked or false, value == fixture.state.llm_pred_indent)
			end
			helpers.assert_eq(parent.title, "menu.llm.indent_label: +1 menu.llm.indent_space")
			helpers.assert_eq(rows[#rows], parent, "the canonical all-OS declaration owns the trailing position")
		end)
	end)

	for _, condition in ipairs({"paused", "off", "single", "runtime disagreement", "retired owner"}) do
		helpers.it("refuses a retained native choice after " .. condition .. " (shared-indentation)", function()
			local options = {}
			with_fixture(options, function(fixture)
				local command = assert(indentation_item(fixture.streaming_menu()).menu[1].fn)
				if condition == "paused" then options.paused = true end
				if condition == "off" then fixture.state.llm_enabled, fixture.runtime.llm_enabled = false, false end
				if condition == "single" then fixture.state.llm_num_predictions, fixture.runtime.llm_num_predictions = 1, 1 end
				if condition == "runtime disagreement" then fixture.runtime.llm_pred_indent = 2 end
				if condition == "retired owner" then fixture.retire_display() end
				local before = fixture.calls.save
				helpers.assert_eq(command(), false)
				helpers.assert_eq(fixture.calls.save, before)
				helpers.assert_eq(fixture.state.llm_pred_indent, 1)
				helpers.assert_eq(fixture.persisted().llm_pred_indent, 1)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end)
	end

	helpers.it("retains runtime and native settings rollback on false, nil and throwing canonical writers (shared-indentation)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_fixture({failures = {{name = "save", mode = mode}}}, function(fixture)
				local command = assert(indentation_item(fixture.streaming_menu()).menu[1].fn)
				helpers.assert_eq(command(), false)
				helpers.assert_eq(fixture.state.llm_pred_indent, 1)
				helpers.assert_eq(fixture.runtime.llm_pred_indent, 1)
				helpers.assert_eq(fixture.persisted().llm_pred_indent, 1)
				helpers.assert_eq(fixture.manager.scope_idle(), true)
				helpers.assert_true(fixture.calls.save >= 2, "native compensation must be acknowledged rather than skipped")
			end)
		end
	end)

	helpers.it("publishes negative, zero and positive numeric choices only once per current owner (shared-indentation)", function()
		for _, index in ipairs({1,8,15}) do
			with_fixture({}, function(fixture)
				local command = assert(indentation_item(fixture.streaming_menu()).menu[index].fn)
				local value = index - 8
				helpers.assert_eq(command(), true)
				helpers.assert_eq(fixture.state.llm_pred_indent, value)
				helpers.assert_eq(fixture.runtime.llm_pred_indent, value)
				helpers.assert_eq(fixture.persisted().llm_pred_indent, value)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(command(), false)
				helpers.assert_eq(fixture.calls.save, 1)
			end)
		end
	end)
end)

helpers.describe("macOS real-source indentation compensation", function()
	for _, race in ipairs({"before menu construction", "before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
	helpers.it("preserves a real foreign master winner " .. race .. " through compensation and a fresh second click for indentation (shared-indentation)", function()
		local path = require("infra.config_paths").get("ConfigTomlPath")
		local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.display]\npred_indent = 1\nstreaming = false\nstreaming_multi = true\n[llm.profiles]\nnum_predictions = 3\n[private]\nfuture = 42\n'
		local external = race == "before menu construction" and (initial .. '[llm.generation]\ntemperature = 0.9\n')
			or initial:gsub('enabled = true', 'enabled = false')
		local disk, attempts, unconditional, wrong_path = initial, 0, 0, false
		local previous_fs, previous_preferences = package.loaded["adapters.file_system"], package.loaded["infra.preferences"]
		package.loaded["adapters.file_system"] = {
			read_with_status = function(read_path)
				if read_path ~= path then wrong_path = true end
				return disk, "ok"
			end,
			write = function() unconditional = unconditional + 1; return false end,
			write_if_unchanged = function(write_path, content, source)
				if write_path ~= path then wrong_path = true end
				attempts = attempts + 1
				if attempts == 1 and race == "before forward acknowledgement" then disk = external end
				if source.status ~= "ok" or source.content ~= disk then return false, "source changed" end
				disk = content
				return true
			end,
		}
		package.loaded["infra.preferences"] = nil
		local preferences = require("infra.preferences")
		local ok, err = xpcall(function()
			local _, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			with_fixture({preferences = preferences, preference_source = path,
				failures = race ~= "before forward acknowledgement" and {{name = "menu", mode = "false"}} or {},
				after_save = function()
					if race == "between own acknowledgement and receipt admission" then disk = external end
				end,
				before_menu = function(occurrence)
					if occurrence == 1 and race == "after forward acknowledgement" then disk = external end
				end,
			}, function(fixture)
				local previous_temperature = fixture.state.llm_temperature
				if race == "before menu construction" then disk = external end
				local parent = indentation_item(fixture.streaming_menu())
				local row = parent.menu[1]
				if race == "before menu construction" then
					if row.fn then helpers.assert_eq(row.fn(), false) end
					helpers.assert_eq(disk, external, "stale compensation cannot overwrite the foreign temperature")
					helpers.assert_eq(parent.disabled, true, "an already foreign full-document image is not action authority")
					helpers.assert_eq(attempts, 0)
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.manager.scope_idle(), true)
					helpers.assert_eq(preferences.publication_receipt(path), {id = 0})
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = initial})
					helpers.assert_eq(fixture.state.llm_temperature, previous_temperature)
					helpers.assert_eq(fixture.runtime.llm_temperature, previous_temperature)
					helpers.assert_eq(require("infra.toml.codec").decode(disk).llm.generation.temperature, 0.9)
					helpers.assert_eq(unconditional, 0)
					helpers.assert_eq(wrong_path, false)
					return
				end
				helpers.assert_eq(parent.disabled == true, false)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(disk, external, "compensation cannot turn the external master on")
				local receipt = preferences.publication_receipt(path)
				if race == "before forward acknowledgement" then
					helpers.assert_eq(receipt.id, 0)
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = external})
				else
					helpers.assert_eq(receipt.id, 1, "only the true owned forward save issues authority")
					helpers.assert_eq(preferences.source_matches(receipt.source, {status = "ok", content = external}), false)
					local acknowledged = require("infra.toml.codec").decode(receipt.source.content)
					helpers.assert_eq(acknowledged.llm.enabled, true)
					helpers.assert_eq((acknowledged.llm.display or {}).pred_indent, -7, "only the requested signed offset belongs to the acknowledged source")
					helpers.assert_eq(preferences.source_snapshot(path), receipt.source)
				end
				helpers.assert_eq(attempts, 1, "compensation cannot borrow a foreign source")
				helpers.assert_eq(fixture.manager.scope_idle(), false, "refused compensation remains owned debt")
				helpers.assert_eq(fixture.state.llm_enabled, true)
				helpers.assert_eq(fixture.runtime.llm_enabled, true)
				local before = attempts
				local fresh = indentation_item(fixture.streaming_menu())
				helpers.assert_eq(fresh.disabled, true)
				if fresh.menu[1].fn then helpers.assert_eq(fresh.menu[1].fn(), false) end
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_pred_indent", value = 1, runtime_fn = "set_llm_pred_indent", publish_setting = true,
				}), false, "a later action cannot borrow the foreign image to settle retained debt")
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.scope_idle(), false)
				helpers.assert_eq(disk, external)
				helpers.assert_eq(unconditional, 0)
				helpers.assert_eq(wrong_path, false)
			end)
		end, debug.traceback)
		package.loaded["adapters.file_system"], package.loaded["infra.preferences"] = previous_fs, previous_preferences
		if not ok then error(err, 0) end
	end)

	end
end)

helpers.describe("macOS retained Info Bar source admission", function()
	for _, condition in ipairs({"paused", "master", "runtime value", "retired owner"}) do
		helpers.it("refuses a retained actual checkbox after " .. condition .. " (shared-info-bar)", function()
			local options = {prediction_count = 1, progressive_state = false}
			with_fixture(options, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
				helpers.assert_eq(row.disabled == true, false)
				if condition == "paused" then options.paused = true end
				if condition == "master" then fixture.state.llm_enabled, fixture.runtime.llm_enabled = false, false end
				if condition == "runtime value" then fixture.runtime.llm_show_info_bar = false end
				if condition == "retired owner" then fixture.retire_display() end
				local before = fixture.calls.save
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.calls.save, before)
				helpers.assert_eq(fixture.state.llm_show_info_bar, true)
				helpers.assert_eq(fixture.persisted().llm_show_info_bar, true)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end)
	end

	helpers.it("retires an acknowledged checkbox without restricting single predictions (shared-info-bar)", function()
		with_fixture({prediction_count = 1, progressive_state = false}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, 1)
			helpers.assert_eq(fixture.state.llm_show_info_bar, false)
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, false)
			helpers.assert_eq(fixture.persisted().llm_show_info_bar, false)
		end)
	end)
end)

helpers.describe("macOS real-source Info Bar compensation", function()
	for _, race in ipairs({"before menu construction", "before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
	helpers.it("preserves a real foreign master winner " .. race .. " through compensation and a fresh second click for Info Bar (shared-info-bar)", function()
		local path = require("infra.config_paths").get("ConfigTomlPath")
		local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.display]\npred_indent = 1\nshow_info_bar = true\nstreaming = false\nstreaming_multi = true\n[llm.profiles]\nnum_predictions = 3\n[private]\nfuture = 42\n'
		local external = race == "before menu construction" and (initial .. '[llm.generation]\ntemperature = 0.9\n')
			or initial:gsub('enabled = true', 'enabled = false')
		local disk, attempts, unconditional, wrong_path = initial, 0, 0, false
		local previous_fs, previous_preferences = package.loaded["adapters.file_system"], package.loaded["infra.preferences"]
		package.loaded["adapters.file_system"] = {
			read_with_status = function(read_path)
				if read_path ~= path then wrong_path = true end
				return disk, "ok"
			end,
			write = function() unconditional = unconditional + 1; return false end,
			write_if_unchanged = function(write_path, content, source)
				if write_path ~= path then wrong_path = true end
				attempts = attempts + 1
				if attempts == 1 and race == "before forward acknowledgement" then disk = external end
				if source.status ~= "ok" or source.content ~= disk then return false, "source changed" end
				disk = content
				return true
			end,
		}
		package.loaded["infra.preferences"] = nil
		local preferences = require("infra.preferences")
		local ok, err = xpcall(function()
			local _, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			with_fixture({preferences = preferences, preference_source = path,
				failures = race ~= "before forward acknowledgement" and {{name = "menu", mode = "false"}} or {},
				after_save = function()
					if race == "between own acknowledgement and receipt admission" then disk = external end
				end,
				before_menu = function(occurrence)
					if occurrence == 1 and race == "after forward acknowledgement" then disk = external end
				end,
			}, function(fixture)
				local previous_temperature = fixture.state.llm_temperature
				if race == "before menu construction" then disk = external end
				local parent = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
				local row = parent
				if race == "before menu construction" then
					if row.fn then helpers.assert_eq(row.fn(), false) end
					helpers.assert_eq(disk, external, "stale compensation cannot overwrite the foreign temperature")
					helpers.assert_eq(parent.disabled, true, "an already foreign full-document image is not action authority")
					helpers.assert_eq(attempts, 0)
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.manager.scope_idle(), true)
					helpers.assert_eq(preferences.publication_receipt(path), {id = 0})
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = initial})
					helpers.assert_eq(fixture.state.llm_temperature, previous_temperature)
					helpers.assert_eq(fixture.runtime.llm_temperature, previous_temperature)
					helpers.assert_eq(require("infra.toml.codec").decode(disk).llm.generation.temperature, 0.9)
					helpers.assert_eq(unconditional, 0)
					helpers.assert_eq(wrong_path, false)
					return
				end
				helpers.assert_eq(parent.disabled == true, false)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(disk, external, "compensation cannot turn the external master on")
				local receipt = preferences.publication_receipt(path)
				if race == "before forward acknowledgement" then
					helpers.assert_eq(receipt.id, 0)
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = external})
				else
					helpers.assert_eq(receipt.id, 1, "only the true owned forward save issues authority")
					helpers.assert_eq(preferences.source_matches(receipt.source, {status = "ok", content = external}), false)
					local acknowledged = require("infra.toml.codec").decode(receipt.source.content)
					helpers.assert_eq(acknowledged.llm.enabled, true)
					helpers.assert_eq((acknowledged.llm.display or {}).show_info_bar, false, "only the requested checkbox value belongs to the acknowledged source")
					helpers.assert_eq(preferences.source_snapshot(path), receipt.source)
				end
				helpers.assert_eq(attempts, 1, "compensation cannot borrow a foreign source")
				helpers.assert_eq(fixture.manager.scope_idle(), false, "refused compensation remains owned debt")
				helpers.assert_eq(fixture.state.llm_enabled, true)
				helpers.assert_eq(fixture.runtime.llm_enabled, true)
				local before = attempts
				local fresh = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
				helpers.assert_eq(fresh.disabled, true)
				if fresh.fn then helpers.assert_eq(fresh.fn(), false) end
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_show_info_bar", value = true, runtime_fn = "set_llm_show_info_bar", publish_setting = false,
				}), false, "a later action cannot borrow the foreign image to settle retained debt")
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.scope_idle(), false)
				helpers.assert_eq(disk, external)
				helpers.assert_eq(unconditional, 0)
				helpers.assert_eq(wrong_path, false)
			end)
		end, debug.traceback)
		package.loaded["adapters.file_system"], package.loaded["infra.preferences"] = previous_fs, previous_preferences
		if not ok then error(err, 0) end
	end)

	end
end)



--- Reads independent privacy rows and complete boolean states.
--- @return table corpus
local function privacy_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/privacy_trigger_controls.json", "rb"))
	local bytes = file:read("*a")
	file:close()
	return assert(require("json").decode(bytes))
end

helpers.describe("Shared privacy trigger checks", function()
	helpers.it("publishes every independent bool pair through existing owners and refuses repeat held clicks (shared-privacy-triggers)", function()
		local corpus = privacy_corpus()
		helpers.assert_eq(#corpus.states, 4)
		for _, states in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				for index, expected in ipairs(corpus.rows) do
					with_fixture({privacy_states = states, prediction_count = count}, function(fixture)
						local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
						helpers.assert_eq(row.checked or false, states[index])
						helpers.assert_eq(row.disabled or false, false)
						helpers.assert_eq(row.fn(), true)
						helpers.assert_eq(fixture.state[expected.hs], not states[index])
						helpers.assert_eq(fixture.runtime[expected.hs], not states[index])
						helpers.assert_eq(fixture.persisted()[expected.hs], not states[index])
						local neighbor = corpus.rows[index == 1 and 2 or 1]
						helpers.assert_eq(fixture.persisted()[neighbor.hs], states[index == 1 and 2 or 1])
						helpers.assert_eq(fixture.calls.save, 1)
						helpers.assert_eq(row.fn(), false)
						helpers.assert_eq(fixture.calls.save, 1)
					end)
				end
			end
		end
	end)

	for _, condition in ipairs({"paused", "master withdrawn", "runtime disagreement", "retired runtime"}) do
		helpers.it("refuses a held privacy callback after " .. condition .. " (shared-privacy-triggers)", function()
			for _, expected in ipairs(privacy_corpus().rows) do
				local options = {}
				with_fixture(options, function(fixture)
					local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
					if condition == "paused" then options.paused = true end
					if condition == "master withdrawn" then
						fixture.state.llm_enabled, fixture.runtime.llm_enabled = false, false
					end
					if condition == "runtime disagreement" then fixture.runtime[expected.hs] = not fixture.runtime[expected.hs] end
					if condition == "retired runtime" then fixture.runtime[expected.hs] = nil end
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.calls.runtime, 0)
				end)
			end
		end)
	end
end)


helpers.describe("Privacy native publication source ownership", function()
	for _, race in ipairs({"before menu construction", "after menu construction",
		"before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
		helpers.it("retains foreign bytes and acknowledged source debt " .. race .. " (shared-privacy-triggers)", function()
			for _, expected in ipairs(privacy_corpus().rows) do
				local path = require("infra.config_paths").get("ConfigTomlPath")
				local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.trigger]\nurl_bar_filter_enabled = false\nsecure_filter_enabled = false\n[private]\nfuture = 42\n'
				local external = initial:gsub('enabled = true', 'enabled = false'):gsub('future = 42', 'future = 73')
				local disk, attempts, unconditional, wrong_path = initial, 0, 0, false
				local previous_fs, previous_preferences = package.loaded["adapters.file_system"], package.loaded["infra.preferences"]
				package.loaded["adapters.file_system"] = {
					read_with_status = function(read_path)
						if read_path ~= path then wrong_path = true end
						return disk, "ok"
					end,
					write = function() unconditional = unconditional + 1; return false end,
					write_if_unchanged = function(write_path, content, source)
						if write_path ~= path then wrong_path = true end
						attempts = attempts + 1
						if attempts == 1 and race == "before forward acknowledgement" then disk = external end
						if source.status ~= "ok" or source.content ~= disk then return false, "source changed" end
						disk = content
						return true
					end,
				}
				package.loaded["infra.preferences"] = nil
				local preferences = require("infra.preferences")
				local ok, err = xpcall(function()
					local _, status = preferences.load(path)
					helpers.assert_eq(status, "ok")
					with_fixture({preferences = preferences, preference_source = path,
						failures = {{name = "menu", mode = "false"}},
						after_save = function()
							if race == "between own acknowledgement and receipt admission" then disk = external end
						end,
						before_menu = function(occurrence)
							if occurrence == 1 and race == "after forward acknowledgement" then disk = external end
						end,
					}, function(fixture)
						if race == "before menu construction" then disk = external end
						local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
						if race == "after menu construction" then disk = external end
						if row.fn then helpers.assert_eq(row.fn(), false) end
						helpers.assert_eq(disk, external)
						helpers.assert_eq(fixture.state[expected.hs], false)
						helpers.assert_eq(fixture.runtime[expected.hs], false)
						helpers.assert_eq(unconditional, 0)
						helpers.assert_eq(wrong_path, false)
						if race == "before menu construction" or race == "after menu construction" then
							helpers.assert_eq(attempts, 0)
							helpers.assert_eq(fixture.calls.runtime, 0)
							helpers.assert_eq(preferences.publication_receipt(path).id, 0)
							return
						end
						helpers.assert_eq(attempts, 1)
						helpers.assert_eq(fixture.manager.scope_idle(), false)
						local receipt = preferences.publication_receipt(path)
						helpers.assert_eq(receipt.id, race == "before forward acknowledgement" and 0 or 1)
						if receipt.id == 1 then
							helpers.assert_eq(preferences.source_matches(receipt.source, {status = "ok", content = external}), false)
							local own = require("infra.toml.codec").decode(receipt.source.content)
							helpers.assert_eq(own.llm.enabled, true)
							local owned_value = own.llm.trigger[expected.linux]
							if expected.neutral == true then
								helpers.assert_eq(owned_value, nil, "the acknowledged default is stored as owned absence")
								owned_value = expected.neutral
							end
							helpers.assert_eq(owned_value, true)
						end
						local fresh = assert(find_item(fixture.trigger_menu(), expected.i18n))
						helpers.assert_eq(fresh.disabled, true)
						if fresh.fn then helpers.assert_eq(fresh.fn(), false) end
						helpers.assert_eq(fixture.manager.apply_setting_transaction({key = expected.hs,
							value = true, runtime_fn = "set_" .. expected.hs, publish_setting = false}), false)
						helpers.assert_eq(attempts, 1)
						helpers.assert_eq(disk, external)
					end)
				end, debug.traceback)
				package.loaded["adapters.file_system"], package.loaded["infra.preferences"] = previous_fs, previous_preferences
				if not ok then error(err, 0) end
			end
		end)
	end
end)


helpers.describe("Shared privacy intent policy", function()
	helpers.it("replays independent strict snapshot types and exact identities (shared-privacy-triggers)", function()
		local corpus, policy = privacy_corpus(), require("llm.trigger_policy")
		for _, vector in ipairs(corpus.vectors) do
			local expected = clone_value(corpus.snapshot)
			expected.owner = {}
			local current = clone_value(corpus.snapshot)
			current.owner = expected.owner
			for key, value in pairs(vector.current or {}) do current[key] = value end
			for _, key in ipairs(vector.missing or {}) do current[key] = nil end
			if vector.new_owner then current.owner = {} end
			local actual = policy.intent(expected, current)
			helpers.assert_eq(actual.admitted, vector.admitted, vector.name)
			helpers.assert_eq(actual.value, vector.value, vector.name)
			if not policy.ready(current) then helpers.assert_eq(policy.intent(current, expected).admitted, false) end
		end
	end)
end)


helpers.describe("LLM navigation: shared native child declarations", function()
	helpers.it("(llm-nav-shared) consumes actual reordered labels and missing declarations", function()
		with_fixture({ navigation_reverse = true, navigation_label = "button.cancel" }, function(fixture)
			local parent = find_item(fixture.top_level_callbacks().rebuild(), "menu.llm.nav_menu_title")
			helpers.assert_eq(#parent.menu, 2)
			helpers.assert_true(parent.menu[1].title:find("button.cancel", 1, true) == 1)
			helpers.assert_true(parent.menu[2].title:find("menu.llm.nav_label", 1, true) == 1)
			helpers.assert_eq(type(parent.menu[1].menu), "table", "the actual validation picker remains a whole subtree")
			helpers.assert_eq(type(parent.menu[2].menu), "table", "the actual navigation picker remains a whole subtree")
			helpers.assert_eq(fixture.calls.runtime, 0)
			helpers.assert_eq(fixture.calls.save, 0)
		end)
		with_fixture({ navigation_absent = true }, function(fixture)
			local parent = find_item(fixture.top_level_callbacks().rebuild(), "menu.llm.nav_menu_title")
			helpers.assert_eq(#parent.menu, 0, "absent shared children never acquire native fallback rows")
			helpers.assert_eq(fixture.calls.save, 0)
		end)
		with_fixture({ navigation_invalid = true }, function(fixture)
			local parent = find_item(fixture.top_level_callbacks().rebuild(), "menu.llm.nav_menu_title")
			helpers.assert_eq(#parent.menu, 1, "a malformed label is refused before native rendering")
			helpers.assert_true(parent.menu[1].title:find("menu.llm.val_label", 1, true) == 1)
		end)
	end)

	helpers.it("(llm-nav-shared) preserves all twenty-one actual captions and native ranges", function()
		local Json = require("json")
		local root = helpers.driver_root() .. "../_shared/"
		local file = assert(io.open(root .. "data/locale_order.json", "r"))
		local locales = assert(Json.decode(file:read("*a"))).order; file:close()
		helpers.assert_eq(#locales, 21)
		local manifest_file = assert(io.open(helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json", "r"))
		local definitions = assert(Json.decode(manifest_file:read("*a"))).llm_navigation_rows; manifest_file:close()
		local corpus_file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/llm_navigation_rows.json", "r"))
		local expected = assert(Json.decode(corpus_file:read("*a"))).rows; corpus_file:close()
		helpers.assert_eq(#definitions, 2, "both actual declared modifier providers must be present")
		helpers.assert_eq(#expected, 2, "the independent navigation corpus must be nonempty and complete")
		for index, definition in ipairs(definitions) do
			helpers.assert_eq({ definition.id, definition.type, definition.i18n },
				{ expected[index].id, expected[index].type, expected[index].i18n })
		end
		for _, locale in ipairs(locales) do
			local input = assert(io.open(root .. "data/locales/" .. locale .. ".json", "r"))
			local catalogue = assert(Json.decode(input:read("*a"))); input:close()
			local matched_paths = {}
			local function translated(key)
				local direct = catalogue[key]
				local value = catalogue
				local matched = 0
				for segment in key:gmatch("[^.]+") do
					matched = matched + 1
					value = type(value) == "table" and value[segment] or nil
				end
				matched_paths[#matched_paths + 1] = matched
				if direct ~= nil then return direct end
				return value or key
			end
			with_fixture({ translate = translated, navigation_only = true }, function(fixture)
				for _, count in ipairs({ 1, 2, 10 }) do
					fixture.state.llm_num_predictions = count
					fixture.state.llm_nav_modifiers, fixture.state.llm_val_modifiers = {}, {}
					local parent = find_item(fixture.top_level_callbacks().rebuild(), translated("menu.llm.nav_menu_title"))
					helpers.assert_eq(#parent.menu, 2)
					helpers.assert_true(parent.menu[1].title:find(translated("menu.llm.nav_label"), 1, true) == 1)
					helpers.assert_true(parent.menu[2].title:find(string.format(translated("menu.llm.val_label"), count == 10 and "1-0" or "1-" .. count), 1, true) == 1)
					helpers.assert_eq(parent.menu[1].disabled == true, count < 2)
					helpers.assert_eq(parent.menu[2].disabled == true, count < 2)
					helpers.assert_eq(type(parent.menu[1].menu[1].fn), "function", "the real modifier owner stays callable")
					helpers.assert_eq(fixture.calls.save, 0)
				end
			end)
			helpers.assert_true(#matched_paths > 0, "real locale lookups must execute")
			for _, matched in ipairs(matched_paths) do
				helpers.assert_true(matched > 0, "every actual locale lookup matches a nonempty key path")
			end
		end
	end)
end)
