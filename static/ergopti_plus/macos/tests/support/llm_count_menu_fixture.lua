--- tests/support/llm_count_menu_fixture.lua

--- ==============================================================================
--- MODULE: LLM Count Menu Fixture
--- DESCRIPTION:
--- Builds the real menu and renderer while capturing its settings transaction boundary.
--- ==============================================================================

local helpers = require("tests.helpers")

return function(callback)
	local saved, previous_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, err = xpcall(function()
		for name in pairs(package.loaded) do
			if name:match("^ui%.menu%.menu_llm") or name:match("^modules%.llm")
				or name == "menu.renderer" then package.loaded[name] = nil end
		end
		helpers.load_with_stubs("infra.toml.codec")
		local file = assert(io.open(helpers.shared("modules/llm/defaults.json"), "r"))
		local raw = file:read("*a"); file:close()
		local defaults, state = hs.json.decode(raw), hs.json.decode(raw)
		state.llm_enabled, state.llm_backend, state.llm_model = true, "ollama", ""
		local noop = function() end
		local accept = function() return true end
		local calls = {}
		local outcome = true
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.i18n"] = { get = function(key)
			if key == "menu.llm.prediction_count_label" then return "%d prediction%s" end
			return key
		end, section = function(key) return key end }
		package.loaded["modules.llm"] = { DEFAULT_STATE = defaults,
			get_backend = function() return state.llm_backend end, set_backend = accept,
			get_current_model = function() return "" end }
		local models = { get_presets = function() return {} end,
			get_actual_model_name = function(name) return name end,
			get_model_info = function() return {} end, get_model_ram = function() return 0 end }
		package.loaded["ui.menu.menu_llm.models_manager"] = { new = function() return models end }
		package.loaded["ui.menu.menu_llm.profiles_manager"] = {
			new = function() return { get_menu_item = function() return {} end } end }
		package.loaded["ui.menu.menu_llm.settings_manager"] = { new = function()
			return { build_nav_modifier_menu = function() return {} end,
				build_val_modifier_menu = function() return {} end,
				apply_setting_transaction = function(request)
					calls[#calls + 1] = request
					return outcome
				end }
		end }
		for _, name in ipairs({ "temperature_panel", "streaming_panel", "trigger_panel" }) do
			package.loaded["ui.menu.menu_llm." .. name] = { build = function() return {} end }
		end
		package.loaded["ui.menu.menu_llm.backend_panel"] = {
			is_apple_silicon = function() return false end, build = function() return "backend", {} end }
		package.loaded["ui.menu.menu_llm.api_panel"] = {
			build = function() return nil, nil end, build_model_picker = function() return {} end }
		package.loaded["ui.menu.menu_llm.models_selector"] = { build = function() return {} end }
		package.loaded["ui.menu.menu_llm.model_switcher"] = { new = function()
			return { get_display_model_name = function(name) return name end,
				get_model_power_level = function() return 1 end, settle_recovery_debts = accept }
		end }
		package.loaded["ui.menu.menu_llm.startup_controller"] = { new = function() return noop end }
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = { new = function()
			return { bind_hotkey = noop, activate_hotkey = noop, apply_llm_shortcut = noop,
				apply_llm_profile_shortcut = noop, restore_shortcuts = accept }
		end }
		package.loaded["modules.llm.mlx_deps_checker"] = { check_and_install_deps = accept }
		package.loaded["modules.llm.ollama_deps_checker"] = { check_and_install_deps = accept }
		package.loaded["infra.manifest_menu"] = nil
		local menu = require("ui.menu.menu_llm").create({ state = state,
			keymap = { set_llm_model = accept }, save_prefs = accept, update_menu = accept, active_tasks = {} })
		helpers.assert_type(menu.build_item, "function")
		callback(menu, state, calls, function(value) outcome = value end)
	end, debug.traceback)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end
