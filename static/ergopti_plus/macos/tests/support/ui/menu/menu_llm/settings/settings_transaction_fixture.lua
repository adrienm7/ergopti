--- tests/support/ui/menu/menu_llm/settings/settings_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_settings_transaction
--- DESCRIPTION:
--- Prelude shared by the test_settings_transaction_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
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
	"ui.menu.menu_llm.profile_label",
	"modules.llm.profiles",
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

--- Captures raw producer references independently of native materialization.
--- @param root table Genuine source row graph.
--- @return table snapshot Exact key/value references for every reachable table.
local function capture_row_graph(root)
	local snapshot = {}
	local function capture(node)
		if type(node) ~= "table" or snapshot[node] then return end
		local fields = {}; snapshot[node] = fields
		for key, value in next, node do fields[key] = value; capture(value) end
	end
	capture(root)
	return snapshot
end

--- Proves all captured rows, resources, callbacks and nested field references remain exact.
--- @param snapshot table Raw reference graph captured before the handoff.
local function assert_row_graph_unchanged(snapshot)
	for node, fields in pairs(snapshot) do
		for key, value in next, node do helpers.assert_true(rawequal(value, fields[key]), tostring(key)) end
		for key, value in pairs(fields) do helpers.assert_true(rawequal(rawget(node, key), value), tostring(key)) end
	end
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
	local mlx_loaded_dependencies = {}
	local profile_loaded_dependencies = {}
	local mlx_previous_json_codec = package.loaded["adapters.json_codec"]

	local state = {
		llm_enabled = true,
		llm_backend = "ollama",
		llm_model = "",
		llm_model_mlx = "",
		llm_model_ollama = "",
		llm_active_profile = "basic",
		llm_profile_shortcuts = {},
		llm_user_profiles = {},
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
	if options.enabled ~= nil then state.llm_enabled = options.enabled end
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
		json = options.native_mlx_port and saved_hs.json or nil,
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
	local locale_file = assert(io.open(helpers.shared("data/locales/en.json"), "r"))
	local profile_strings = assert(require("json").decode(locale_file:read("*a")))
	assert(locale_file:close())
	local function fixture_caption(key)
		if key:match("^menu%.profiles%.") or key:match("^llm%.profile%.") then return profile_strings[key] or key end
		return options.translate and options.translate(key) or key
	end
	package.loaded["infra.i18n"] = {get = fixture_caption, section = fixture_caption}
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
	local observed_selector_data
	local display_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
		json_decode = function(raw)
			local root = assert(require("json").decode(raw))
			if options.parent_id then
				for index, row in ipairs(root.llm_menu) do
					if row.id == options.parent_id then
						if options.parent_absent then table.remove(root.llm_menu, index)
						elseif options.parent_type then row.type = options.parent_type
						elseif options.parent_label then row.i18n = options.parent_label
						elseif options.parent_first then table.remove(root.llm_menu, index); table.insert(root.llm_menu, 1, row) end
						break
					end
				end
			end
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
		i18n = { get = fixture_caption, section = fixture_caption },
		logger = Logger,
	}))
	if options.observe_native_model_children then
		local genuine_render_rows = display_renderer.render_rows
		display_renderer.render_rows = function(...)
			local input = select(1, ...)
			local results = table.pack(genuine_render_rows(...))
			if observed_selector_data ~= nil and rawequal(input, observed_selector_data) then
				options.observe_native_model_children(results[1], input)
			end
			return table.unpack(results, 1, results.n)
		end
	end
	package.loaded["infra.manifest_menu"] = display_renderer

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
	if options.corrupt_trigger_child then
		local real_build = TriggerPanel.build
		local detached = {}; for key, value in pairs(TriggerPanel) do detached[key] = value end
		detached.build = function(...)
			local children = real_build(...)
			if options.corrupt_trigger_child == "named" then children.unowned = true
			elseif options.corrupt_trigger_child == "sparse" then children[#children + 2] = {title = "Unadmitted"}
			elseif options.corrupt_trigger_child == "cycle" then children[1].menu = children end
			return children
		end
		package.loaded["ui.menu.menu_llm.trigger_panel"] = detached
	end
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
		if options.native_mlx_port then
			models.get_installed_models = function() return {} end
			models.is_model_installed = function() return false end
		end
		package.loaded["ui.menu.menu_llm.models_manager"] = {
			new = function() return models end,
		}
		local prior_dependencies = {}
		for name, value in pairs(package.loaded) do prior_dependencies[name] = value end
		local core = package.loaded["modules.llm"]
		core.BUILTIN_PROFILES = require("modules.llm.profiles").BUILTIN_PROFILES
		local profile_constructor_sync = {}
		core.set_user_profiles = function()
			profile_constructor_sync[#profile_constructor_sync + 1] = "users"
			return true
		end
		core.set_active_profile = function()
			profile_constructor_sync[#profile_constructor_sync + 1] = "active"
			return true
		end
		package.loaded["ui.menu.menu_llm.profiles_manager"] = nil
		require("ui.menu.menu_llm.profiles_manager")
		for name, value in pairs(package.loaded) do
			if not rawequal(value, rawget(prior_dependencies, name)) then
				profile_loaded_dependencies[name] = { value = rawget(prior_dependencies, name) }
			end
		end
		package.loaded["ui.menu.menu_llm.warmup_controller"] = {warmup = noop}
		package.loaded["ui.menu.menu_llm.backend_panel"] = {
			is_apple_silicon = function() return false end,
			build = function() return "backend", {} end,
		}
		package.loaded["ui.menu.menu_llm.api_panel"] = {
			build = function() return nil, nil end,
			build_model_picker = function() return {} end,
		}
		if options.native_mlx_port then
			package.loaded["ui.menu.menu_llm.models_selector"] = nil
			local genuine_selector = require("ui.menu.menu_llm.models_selector")
			package.loaded["ui.menu.menu_llm.models_selector"] = {
				build = function(ctx)
					local children = genuine_selector.build(ctx)
					observed_selector_data = children
					if options.observe_model_children then options.observe_model_children(children) end
					return children
				end,
			}
		else
			package.loaded["ui.menu.menu_llm.models_selector"] = {
				build = function() return {} end,
			}
		end
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
		if options.native_mlx_port then
			local prior_dependencies = {}
			for name, value in pairs(package.loaded) do prior_dependencies[name] = value end
			package.loaded["adapters.json_codec"] = nil
			package.loaded["modules.llm.api_mlx"] = nil
			package.loaded["modules.llm.api_mlx"] = require("modules.llm.api_mlx")
			-- Restore only actual dependency entries changed by this genuine API, including false.
			for name, value in pairs(package.loaded) do
				if not rawequal(value, rawget(prior_dependencies, name)) then
					mlx_loaded_dependencies[name] = { value = rawget(prior_dependencies, name) }
				end
			end
		else
			package.loaded["modules.llm.api_mlx"] = {}
		end
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
		package.loaded["ui.menu.menu_llm.menu_layout"] = nil

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
			script_control = { is_paused = function() return options.paused == true end },
		})
		assert(type(handler.build_item) == "function", table.concat(errors, "\n"))
		local submenu = handler.build_item().submenu
		if options.parent_only then
			reset_observations()
			return { rebuild = function() return handler.build_item().submenu end }
		end
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
	for name, prior in pairs(mlx_loaded_dependencies) do package.loaded[name] = rawget(prior, "value") end
	for name, prior in pairs(profile_loaded_dependencies) do package.loaded[name] = rawget(prior, "value") end
	if options.native_mlx_port then package.loaded["adapters.json_codec"] = mlx_previous_json_codec end
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

local function info_bar_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/info_bar_control.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

local function token_streaming_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/token_streaming_control.json"), "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return assert(require("json").decode(text))
end

local function privacy_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/privacy_trigger_controls.json", "rb"))
	local bytes = file:read("*a")
	file:close()
	return assert(require("json").decode(bytes))
end

return {
	DEFAULT_STATE = DEFAULT_STATE,
	ENTRY_SPECS = ENTRY_SPECS,
	FAILURE_SPECS = FAILURE_SPECS,
	MODULES = MODULES,
	SIBLING_FAILURES = SIBLING_FAILURES,
	SIBLING_ROUTES = SIBLING_ROUTES,
	assert_row_graph_unchanged = assert_row_graph_unchanged,
	capture_row_graph = capture_row_graph,
	clone_value = clone_value,
	failure_for = failure_for,
	find_item = find_item,
	indentation_item = indentation_item,
	info_bar_corpus = info_bar_corpus,
	privacy_corpus = privacy_corpus,
	token_streaming_corpus = token_streaming_corpus,
	with_fixture = with_fixture,
}
